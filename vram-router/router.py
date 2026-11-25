import asyncio
import configparser
import json
import os
import secrets
from pathlib import Path
from typing import Any, Dict, List, Set

import httpx
from fastapi import Depends, FastAPI, HTTPException, Request
from fastapi.responses import JSONResponse, Response, StreamingResponse

app = FastAPI(title="VRAM Combo Router")

LLAMACPP_URL = os.getenv("LLAMACPP_URL", "http://llamacpp:8080").rstrip("/")
STRATA_URL = os.getenv("STRATA_URL", "http://strata:11435").rstrip("/")
STRATA_URLS_ENV = os.getenv("STRATA_URLS", "")
MODELS_INI_PATH = os.getenv("MODELS_INI_PATH", "/app/models.ini")
MODEL_CONFIG_PATH = os.getenv("MODEL_CONFIG_PATH", "/app/model-config.json")

LLAMACPP_API_KEY = os.getenv("LLAMACPP_API_KEY", "").strip()
STRATA_API_KEY = os.getenv("STRATA_API_KEY", "").strip()
ROUTER_API_KEY = os.getenv("ROUTER_API_KEY", "").strip()

# Default 50 MB limit to protect against oversized payloads while allowing large prompts/images
MAX_REQUEST_BYTES = int(os.getenv("MAX_REQUEST_MB", "50")) * 1024 * 1024

# Optional extra Strata model IDs added on top of model-config.json and models.ini
STRATA_MODELS_ENV = os.getenv("STRATA_MODELS", "")

# Default allowed co-resident combos (overridden when model-config.json defines allowed_combos)
ALLOWED_COMBOS: List[Set[str]] = [
    {"qwen3.8-flash-next-iq2_xs"},
    {"qwen-small", "embed-model"},
]

# Default sticky/eviction priority by model name (overridden when model-config.json defines evict_costs)
EVICT_COST: Dict[str, int] = {
    "embed-model": 20,
}

MODEL_BACKEND: Dict[str, str] = {}
MODEL_URL: Dict[str, str] = {}
STRATA_ENDPOINTS: List[str] = []
transition_lock = asyncio.Lock()


def parse_ini_model_names(ini_path: Path) -> List[str]:
    """Extract model preset section names from llama.cpp's models.ini."""
    if not ini_path.exists():
        raise FileNotFoundError(f"models.ini not found at {ini_path}")

    parser = configparser.ConfigParser(interpolation=None, strict=False)
    parser.optionxform = str  # Keep exact casing
    parser.read(ini_path, encoding="utf-8")

    names: List[str] = []
    for section in parser.sections():
        if section.strip() in {"*"} or section.lower() in {"default", "defaults", "global", "server"}:
            continue
        names.append(section)
    return names


def load_json_config(cfg_path: Path) -> Dict[str, Any]:
    """Load optional model-config.json containing strata_models, allowed_combos, and evict_costs."""
    if not cfg_path.exists():
        print(f"[router] note: {cfg_path} not found, using defaults and env vars")
        return {}

    with cfg_path.open("r", encoding="utf-8") as f:
        data = json.load(f)
    if not isinstance(data, dict):
        raise ValueError(f"{cfg_path} must contain a JSON object")
    return data


def _add_unique_endpoint(endpoints: List[str], url: str) -> None:
    cleaned = url.strip().rstrip("/")
    if cleaned and cleaned not in endpoints:
        endpoints.append(cleaned)


def load_models_registry() -> None:
    cfg_data = load_json_config(Path(MODEL_CONFIG_PATH))
    registry: Dict[str, str] = {}
    urls: Dict[str, str] = {}
    strata_endpoints: List[str] = []

    _add_unique_endpoint(strata_endpoints, STRATA_URL)
    for raw_url in STRATA_URLS_ENV.split(","):
        _add_unique_endpoint(strata_endpoints, raw_url)

    # 1. Register llama.cpp models from models.ini
    for name in parse_ini_model_names(Path(MODELS_INI_PATH)):
        registry[name] = "llamacpp"
        urls[name] = LLAMACPP_URL

    # 2. Register Strata models from model-config.json (dict {id: url} or list [id, ...]) + env
    raw_strata = cfg_data.get("strata_models", [])
    if isinstance(raw_strata, dict):
        for m_id, m_url in raw_strata.items():
            clean_id = str(m_id).strip()
            clean_url = str(m_url).strip().rstrip("/") or STRATA_URL
            if clean_id:
                registry[clean_id] = "strata"
                urls[clean_id] = clean_url
                _add_unique_endpoint(strata_endpoints, clean_url)
    elif isinstance(raw_strata, list):
        for m in raw_strata:
            clean_id = str(m).strip()
            if clean_id:
                registry[clean_id] = "strata"
                urls[clean_id] = STRATA_URL
    elif isinstance(raw_strata, str) and raw_strata.strip():
        for m in raw_strata.split(","):
            clean_id = m.strip()
            if clean_id:
                registry[clean_id] = "strata"
                urls[clean_id] = STRATA_URL

    for raw_name in STRATA_MODELS_ENV.split(","):
        clean_id = raw_name.strip()
        if clean_id:
            registry[clean_id] = "strata"
            urls.setdefault(clean_id, STRATA_URL)

    # 3. Load allowed combos from model-config.json if present
    if "allowed_combos" in cfg_data:
        new_combos: List[Set[str]] = []
        raw_combos = cfg_data.get("allowed_combos")
        if not isinstance(raw_combos, list):
            raise ValueError("'allowed_combos' in model-config.json must be a list of lists")
        for group in raw_combos:
            if not isinstance(group, list):
                raise ValueError("Each item in 'allowed_combos' must be a list of model names")
            combo_set = {str(m).strip() for m in group if str(m).strip() in registry}
            if combo_set:
                new_combos.append(combo_set)
        ALLOWED_COMBOS.clear()
        ALLOWED_COMBOS.extend(new_combos)

    # 4. Load eviction costs from model-config.json if present
    if "evict_costs" in cfg_data:
        raw_costs = cfg_data.get("evict_costs")
        if not isinstance(raw_costs, dict):
            raise ValueError("'evict_costs' in model-config.json must be an object")
        new_costs: Dict[str, int] = {}
        for k, v in raw_costs.items():
            model_key = str(k).strip()
            if model_key in registry:
                new_costs[model_key] = int(v)
        EVICT_COST.clear()
        EVICT_COST.update(new_costs)

    MODEL_BACKEND.clear()
    MODEL_BACKEND.update(registry)
    MODEL_URL.clear()
    MODEL_URL.update(urls)
    STRATA_ENDPOINTS.clear()
    STRATA_ENDPOINTS.extend(strata_endpoints)

    print(
        f"[router] loaded {len(MODEL_BACKEND)} models across {len(STRATA_ENDPOINTS)} strata endpoint(s), "
        f"{len(ALLOWED_COMBOS)} combos: {MODEL_URL}"
    )


load_models_registry()


def backend_headers(backend: str, content_type: bool = False) -> dict[str, str]:
    key = LLAMACPP_API_KEY if backend == "llamacpp" else STRATA_API_KEY
    headers: dict[str, str] = {}
    if key:
        headers["Authorization"] = f"Bearer {key}"
    if content_type:
        headers["Content-Type"] = "application/json"
    return headers


def validate_proxy_subpath(subpath: str) -> str:
    cleaned = subpath.strip("/")
    segments = [seg for seg in cleaned.split("/") if seg]
    if not segments or any(seg in {".", ".."} for seg in segments):
        raise HTTPException(status_code=400, detail="Invalid proxy path")
    return "/".join(segments)


async def read_bounded_body(request: Request) -> bytes:
    content_length = request.headers.get("content-length")
    if content_length:
        try:
            if int(content_length) > MAX_REQUEST_BYTES:
                raise HTTPException(status_code=413, detail="Request body too large")
        except ValueError:
            raise HTTPException(status_code=400, detail="Invalid Content-Length header")

    body = await request.body()
    if len(body) > MAX_REQUEST_BYTES:
        raise HTTPException(status_code=413, detail="Request body too large")
    return body


async def verify_router_key(request: Request) -> None:
    if not ROUTER_API_KEY:
        return

    token = ""
    auth = request.headers.get("authorization", "")
    if auth.lower().startswith("bearer "):
        token = auth[7:].strip()
    elif request.headers.get("x-api-key"):
        token = request.headers.get("x-api-key", "").strip()

    if not token or not secrets.compare_digest(token, ROUTER_API_KEY):
        raise HTTPException(
            status_code=401,
            detail="Invalid or missing API key",
            headers={"WWW-Authenticate": "Bearer"},
        )


def _normalize_model_entry(
    entry: Dict[str, Any], default_status: str = "unloaded"
) -> Dict[str, Any]:
    """Ensure every model carries llama.cpp router-mode status: {'value': 'loaded' | 'unloaded'}."""
    item = dict(entry)
    raw_status = item.get("status")
    if isinstance(raw_status, dict) and raw_status.get("value"):
        val = str(raw_status["value"]).strip().lower()
        item["status"] = {**raw_status, "value": val}
    elif isinstance(raw_status, str) and raw_status.strip():
        item["status"] = {"value": raw_status.strip().lower()}
    else:
        item["status"] = {"value": default_status}
    return item


def models_to_evict(target: str, currently_loaded: Set[str]) -> Set[str]:
    if target in currently_loaded:
        return set()

    valid_sets = [s for s in ALLOWED_COMBOS if target in s]
    if not valid_sets:
        return set(currently_loaded)

    best_keep = max(
        valid_sets,
        key=lambda s: sum(EVICT_COST.get(m, 1) for m in (currently_loaded & s)),
    )
    return currently_loaded - best_keep


async def get_loaded_models(client: httpx.AsyncClient) -> Set[str]:
    loaded: Set[str] = set()

    try:
        r = await client.get(
            f"{LLAMACPP_URL}/models",
            headers=backend_headers("llamacpp"),
            timeout=10.0,
        )
        if r.status_code == 200:
            for m in r.json().get("data", []):
                status = m.get("status")
                val = status.get("value") if isinstance(status, dict) else status
                if str(val).strip().lower() == "loaded" and m.get("id") in MODEL_BACKEND:
                    loaded.add(m["id"])
    except Exception as e:
        print(f"[router] warning: could not query llama.cpp /models: {e}")

    for s_url in STRATA_ENDPOINTS:
        try:
            r = await client.get(
                f"{s_url}/v1/models",
                headers=backend_headers("strata"),
                timeout=10.0,
            )
            if r.status_code == 200:
                for m in r.json().get("data", []):
                    m_id = m.get("id")
                    status = m.get("status")
                    val = status.get("value") if isinstance(status, dict) else status
                    if m_id in MODEL_BACKEND:
                        MODEL_URL.setdefault(m_id, s_url)
                        if str(val).strip().lower() == "loaded":
                            loaded.add(m_id)
        except Exception as e:
            print(f"[router] warning: could not query strata {s_url}/v1/models: {e}")

    return loaded


async def unload_model(client: httpx.AsyncClient, model_id: str) -> None:
    backend = MODEL_BACKEND.get(model_id)
    if not backend:
        return
    base_url = MODEL_URL.get(model_id, STRATA_URL if backend == "strata" else LLAMACPP_URL)
    print(f"[router] unloading {model_id} from {backend} ({base_url})")

    if backend == "strata":
        r = await client.post(
            f"{base_url}/unload",
            json={"model": model_id},
            headers=backend_headers("strata", content_type=True),
            timeout=60.0,
        )
        if r.status_code in {404, 405, 415}:
            print(
                f"[router] note: strata ({base_url}) returned {r.status_code} on /unload "
                f"({r.text[:120]}); continuing"
            )
            return
        r.raise_for_status()
    elif backend == "llamacpp":
        r = await client.post(
            f"{base_url}/models/unload",
            json={"model": model_id},
            headers=backend_headers("llamacpp", content_type=True),
            timeout=60.0,
        )
        r.raise_for_status()


async def build_router_models_list() -> Dict[str, Any]:
    merged_by_id: Dict[str, Dict[str, Any]] = {}
    targets = [(f"{LLAMACPP_URL}/models", "llamacpp", LLAMACPP_URL)] + [
        (f"{s_url}/v1/models", "strata", s_url) for s_url in STRATA_ENDPOINTS
    ]

    async with httpx.AsyncClient(timeout=10.0) as client:
        for url, backend, base_url in targets:
            try:
                r = await client.get(
                    url,
                    headers=backend_headers(backend),
                    timeout=10.0,
                )
                if r.status_code == 200:
                    for raw_m in r.json().get("data", []):
                        m_id = raw_m.get("id")
                        if m_id:
                            merged_by_id[m_id] = _normalize_model_entry(raw_m)
                            if backend == "strata" and m_id in MODEL_BACKEND:
                                MODEL_URL[m_id] = base_url
            except Exception as e:
                print(f"[router] model list skipped {url}: {e}")

    # Keep registered models visible as unloaded even if a backend is stopped or omits unloaded entries
    for m_id, backend in MODEL_BACKEND.items():
        if m_id not in merged_by_id:
            merged_by_id[m_id] = {
                "id": m_id,
                "object": "model",
                "owned_by": backend,
                "status": {"value": "unloaded"},
            }

    return {"object": "list", "data": list(merged_by_id.values())}


@app.post("/reload-config", dependencies=[Depends(verify_router_key)])
async def reload_config():
    async with transition_lock:
        load_models_registry()
    return {
        "status": "reloaded",
        "models": MODEL_BACKEND,
        "model_urls": MODEL_URL,
        "strata_endpoints": STRATA_ENDPOINTS,
        "allowed_combos": [sorted(list(s)) for s in ALLOWED_COMBOS],
        "evict_costs": EVICT_COST,
    }


@app.get("/v1/models", dependencies=[Depends(verify_router_key)])
@app.get("/models", dependencies=[Depends(verify_router_key)])
async def list_models():
    return await build_router_models_list()


@app.post("/models/unload", dependencies=[Depends(verify_router_key)])
@app.post("/v1/models/unload", dependencies=[Depends(verify_router_key)])
async def api_unload_model(request: Request):
    try:
        payload = await request.json()
    except Exception:
        raise HTTPException(status_code=400, detail="Invalid JSON body")

    target_model = str(payload.get("model", "")).strip()
    if not target_model or target_model not in MODEL_BACKEND:
        raise HTTPException(status_code=404, detail=f"Unknown model: {target_model}")

    async with transition_lock:
        async with httpx.AsyncClient(timeout=60.0) as client:
            await unload_model(client, target_model)

    return {"success": True}


@app.post("/models/load", dependencies=[Depends(verify_router_key)])
@app.post("/v1/models/load", dependencies=[Depends(verify_router_key)])
async def api_load_model(request: Request):
    try:
        payload = await request.json()
    except Exception:
        raise HTTPException(status_code=400, detail="Invalid JSON body")

    target_model = str(payload.get("model", "")).strip()
    if not target_model or target_model not in MODEL_BACKEND:
        raise HTTPException(status_code=404, detail=f"Unknown model: {target_model}")

    backend = MODEL_BACKEND[target_model]
    base_url = MODEL_URL.get(target_model, STRATA_URL if backend == "strata" else LLAMACPP_URL)

    async with transition_lock:
        async with httpx.AsyncClient(timeout=600.0) as client:
            loaded = await get_loaded_models(client)
            if target_model in loaded:
                return {"success": True}

            for m in models_to_evict(target_model, loaded):
                await unload_model(client, m)

            if backend == "llamacpp":
                r = await client.post(
                    f"{base_url}/models/load",
                    json={"model": target_model},
                    headers=backend_headers("llamacpp", content_type=True),
                    timeout=600.0,
                )
                r.raise_for_status()
            elif backend == "strata":
                # Strata loads on demand; trigger a 1-token warm-up completion
                r = await client.post(
                    f"{base_url}/v1/chat/completions",
                    json={
                        "model": target_model,
                        "messages": [{"role": "user", "content": "hi"}],
                        "max_tokens": 1,
                        "stream": False,
                    },
                    headers=backend_headers("strata", content_type=True),
                    timeout=600.0,
                )
                r.raise_for_status()

    return {"success": True}


@app.post("/v1/{path:path}", dependencies=[Depends(verify_router_key)])
async def proxy_inference(path: str, request: Request):
    safe_path = validate_proxy_subpath(path)
    raw_body = await read_bounded_body(request)
    try:
        payload = json.loads(raw_body)

    except json.JSONDecodeError:
        raise HTTPException(status_code=400, detail="Invalid JSON body")

    target_model = payload.get("model")
    if not target_model or target_model not in MODEL_BACKEND:
        raise HTTPException(status_code=404, detail=f"Unknown model: {target_model}")


    tool_names = [
    (t.get("function") or {}).get("name") or t.get("name")
    for t in (payload.get("tools") or [])
    ]
    print(
        f"[router] -> {target_model} path={safe_path} stream={payload.get('stream')} "
        f"tool_choice={payload.get('tool_choice')} tools={tool_names}",
        flush=True,
    )

    async with transition_lock:
        async with httpx.AsyncClient(timeout=60.0) as client:
            loaded = await get_loaded_models(client)
            evict = models_to_evict(target_model, loaded)
            for m in evict:
                await unload_model(client, m)

    backend = MODEL_BACKEND[target_model]
    upstream_base = MODEL_URL.get(
        target_model, STRATA_URL if backend == "strata" else LLAMACPP_URL
    )
    upstream_url = f"{upstream_base}/v1/{safe_path}"
    headers = backend_headers(backend, content_type=True)

    is_stream = bool(payload.get("stream", False))

    if not is_stream:
        async with httpx.AsyncClient(timeout=None) as client:
            resp = await client.post(upstream_url, content=raw_body, headers=headers)
            try:
                return JSONResponse(status_code=resp.status_code, content=resp.json())
            except ValueError:
                media_type = resp.headers.get("content-type", "text/plain")
                return Response(
                    content=resp.content,
                    status_code=resp.status_code,
                    media_type=media_type,
                )

    async def stream_generator():
        async with httpx.AsyncClient(timeout=None) as client:
            async with client.stream(
                "POST", upstream_url, content=raw_body, headers=headers
            ) as resp:
                async for chunk in resp.aiter_bytes():
                    yield chunk

    return StreamingResponse(stream_generator(), media_type="text/event-stream")
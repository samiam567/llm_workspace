"""
title: Llama.cpp Performance & Progress Monitor
author: Antigravity
author_url: https://github.com/ggml-org/llama.cpp
description: Real-time monitor for llama.cpp: tracks model loading progress via /models/sse, prompt processing progress and prefill speed via return_progress, live generation tokens per second (t/s) via timings_per_token, KV cache reuse percentage, and speculative decoding metrics.
version: 1.0.0
license: MIT
requirements: aiohttp
"""

from __future__ import annotations

import asyncio
import json
import logging
import time
from typing import Any, Awaitable, Callable, Optional

import aiohttp
from pydantic import BaseModel, Field

log = logging.getLogger("llamacpp_filter")

# Stage human-readable labels matching llama.cpp web UI
STAGE_LABELS = {
    "text_model": "Loading weights",
    "spec_model": "Loading draft",
    "mmproj_model": "Loading projector",
}

TAIL_SHARE = 0.1


def calc_model_load_fraction(progress: dict[str, Any]) -> float:
    """Calculate normalized model load fraction (0.0 to 1.0) matching llama.cpp's progress.ts."""
    if not progress:
        return 0.0

    stages = progress.get("stages") or []
    current = progress.get("current", "")
    value = float(progress.get("value", 0.0))

    if not stages or current not in stages:
        return max(0.0, min(1.0, value))

    tail_count = max(len(stages) - 1, 0)
    text_ceiling = 1.0 - (tail_count * TAIL_SHARE)
    idx = stages.index(current)

    if idx <= 0:
        return value * text_ceiling

    return text_ceiling + ((idx - 1) + value) * TAIL_SHARE


def format_duration(ms: float) -> str:
    """Format millisecond duration into human-readable string."""
    if ms < 1000:
        return f"{int(ms)} ms"
    seconds = ms / 1000.0
    if seconds < 60:
        return f"{seconds:.2f} s"
    minutes = int(seconds // 60)
    rem_seconds = seconds % 60
    return f"{minutes}m {rem_seconds:.1f}s"


class Filter:
    class Valves(BaseModel):
        priority: int = Field(
            default=5,
            description="Priority level for filter execution (lower runs earlier).",
        )
        llamacpp_base_url: str = Field(
            default="http://llamacpp:8080",
            description="Base URL of llama.cpp server instance (accessible from Open WebUI container).",
        )
        llamacpp_api_key: str = Field(
            default="",
            description="API key for llama.cpp server if configured with --api-key.",
        )
        enable_model_load_tracking: bool = Field(
            default=True,
            description="Track real-time model loading progress from llama.cpp /models/sse feed.",
        )
        enable_prompt_progress: bool = Field(
            default=True,
            description="Track and display prompt processing progress and prefill speed.",
        )
        enable_live_tps: bool = Field(
            default=True,
            description="Track and display real-time generation speed (tokens per second).",
        )
        show_status_pill: bool = Field(
            default=True,
            description="Display real-time updates in the message status pill.",
        )
        append_summary_footer: bool = Field(
            default=True,
            description="Append a collapsible Markdown summary of performance metrics to the assistant response.",
        )
        auto_inject_params: bool = Field(
            default=True,
            description="Automatically inject return_progress=True and timings_per_token=True into llama.cpp requests.",
        )
        status_prefix: str = Field(
            default="llama.cpp",
            description="Prefix to use in status notifications.",
        )
        debug_mode: bool = Field(
            default=False,
            description="Print verbose debug logs to container stdout.",
        )

    def __init__(self):
        self.valves = self.Valves()

    def _get_headers(self) -> dict[str, str]:
        headers = {"Accept": "application/json"}
        if self.valves.llamacpp_api_key:
            headers["Authorization"] = f"Bearer {self.valves.llamacpp_api_key}"
        return headers

    def _normalize_model_name(self, raw_model: str) -> str:
        """Strip proxy/Open WebUI prefixes to get the base model/preset name."""
        if not raw_model:
            return ""
        for prefix in ("openai/", "litellm/", "ap.", "ltllm.", "local/"):
            if raw_model.startswith(prefix):
                raw_model = raw_model[len(prefix):]
        return raw_model

    async def _check_if_model_loaded(self, model_name: str) -> Optional[bool]:
        """Query /models to determine if the target model is already loaded in memory."""
        url = f"{self.valves.llamacpp_base_url.rstrip('/')}/models"
        norm_name = self._normalize_model_name(model_name).lower()

        try:
            timeout = aiohttp.ClientTimeout(total=2.0)
            async with aiohttp.ClientSession(timeout=timeout) as session:
                async with session.get(url, headers=self._get_headers()) as resp:
                    if resp.status != 200:
                        return None
                    data = await resp.json()
                    models = data.get("models") or data.get("data") or []
                    for m in models:
                        mid = str(m.get("id") or m.get("name") or "").lower()
                        if mid == norm_name or norm_name in mid or mid in norm_name:
                            status_val = m.get("status", {}).get("value")
                            return status_val == "loaded"
        except Exception as e:
            if self.valves.debug_mode:
                log.debug("[LLAMACPP] Failed to check model status from %s: %s", url, e)
        return None

    async def _track_model_loading(
        self,
        target_model: str,
        emitter: Callable[[dict], Awaitable[None]],
        state: dict[str, Any],
    ) -> None:
        """Listen to /models/sse and emit real-time model loading progress to Open WebUI."""
        url = f"{self.valves.llamacpp_base_url.rstrip('/')}/models/sse"
        prefix = self.valves.status_prefix
        norm_target = self._normalize_model_name(target_model).lower()

        headers = {"Accept": "text/event-stream"}
        if self.valves.llamacpp_api_key:
            headers["Authorization"] = f"Bearer {self.valves.llamacpp_api_key}"

        start_time = time.time()
        timeout = aiohttp.ClientTimeout(total=300.0, sock_connect=5.0, sock_read=60.0)

        try:
            async with aiohttp.ClientSession(timeout=timeout) as session:
                async with session.get(url, headers=headers) as resp:
                    if resp.status != 200:
                        if self.valves.debug_mode:
                            log.debug("[LLAMACPP] /models/sse returned HTTP %s", resp.status)
                        return

                    async for raw_line in resp.content:
                        if state.get("stop_load_tracker", False):
                            break

                        line = raw_line.decode("utf-8", "replace").strip()
                        if not line.startswith("data:"):
                            continue

                        payload_str = line[5:].strip()
                        if not payload_str:
                            continue

                        try:
                            record = json.loads(payload_str)
                        except json.JSONDecodeError:
                            continue

                        event_type = record.get("event")
                        event_model = str(record.get("model") or "").lower()
                        event_data = record.get("data") or {}

                        # Check if event targets our model or router broadcast
                        is_target = (
                            not event_model
                            or event_model == "*"
                            or event_model in norm_target
                            or norm_target in event_model
                        )
                        if not is_target:
                            continue

                        if event_type == "model_status":
                            status = event_data.get("status")
                            if status == "loading":
                                state["model_was_loading"] = True
                                progress = event_data.get("progress") or {}
                                stage = progress.get("current", "text_model")
                                stage_label = STAGE_LABELS.get(stage, "Loading weights")
                                fraction = calc_model_load_fraction(progress)
                                pct = int(round(fraction * 100))

                                if self.valves.show_status_pill and emitter:
                                    await emitter(
                                        {
                                            "type": "status",
                                            "data": {
                                                "description": f"⏳ [{prefix}] {stage_label}: {pct}%...",
                                                "done": False,
                                                "hidden": False,
                                            },
                                        }
                                    )
                            elif status == "loaded":
                                state["model_loaded"] = True
                                load_duration = time.time() - start_time
                                state["model_load_duration_s"] = load_duration

                                if self.valves.show_status_pill and emitter:
                                    msg = (
                                        f"✅ [{prefix}] Model loaded in {load_duration:.1f}s · Preparing prompt..."
                                        if state.get("model_was_loading")
                                        else f"✅ [{prefix}] Model ready in VRAM"
                                    )
                                    await emitter(
                                        {
                                            "type": "status",
                                            "data": {
                                                "description": msg,
                                                "done": False,
                                                "hidden": False,
                                            },
                                        }
                                    )
                                break
                            elif status == "unloaded":
                                if self.valves.debug_mode:
                                    log.debug("[LLAMACPP] Model reported unloaded on SSE")
        except asyncio.CancelledError:
            pass
        except Exception as e:
            if self.valves.debug_mode:
                log.debug("[LLAMACPP] Error tracking /models/sse: %s", e)

    # --------------------------------------------------------------------------
    # INLET: Intercept request, inject flags, and check/monitor model loading
    # --------------------------------------------------------------------------
    async def inlet(
        self,
        body: dict,
        __user__: Optional[dict] = None,
        __metadata__: Optional[dict] = None,
        __event_emitter__: Optional[Callable[[dict], Awaitable[None]]] = None,
    ) -> dict:
        metadata = __metadata__ if isinstance(__metadata__, dict) else {}
        requested_model = body.get("model", "")

        # Initialize tracking state in metadata for lifecycle persistence
        state = {
            "requested_model": requested_model,
            "normalized_model": self._normalize_model_name(requested_model),
            "start_time": time.time(),
            "first_token_time": None,
            "last_status_emit": 0.0,
            "generated_tokens": 0,
            "prompt_progress": None,
            "timings": None,
            "stop_load_tracker": False,
            "model_was_loading": False,
            "model_loaded": False,
            "model_load_duration_s": 0.0,
            "load_task": None,
        }
        metadata["_llamacpp_tracker"] = state

        # Inject return_progress and timings_per_token parameters
        if self.valves.auto_inject_params:
            body["return_progress"] = True
            body["timings_per_token"] = True
            # For OpenAI client / proxies forwarding via extra_body
            extra_body = body.setdefault("extra_body", {})
            extra_body["return_progress"] = True
            extra_body["timings_per_token"] = True

        # Check and initiate model load tracking
        if self.valves.enable_model_load_tracking and __event_emitter__:
            is_loaded = await self._check_if_model_loaded(requested_model)
            if is_loaded is False or is_loaded is None:
                # Model is either not loaded, or router will resolve on request
                task = asyncio.create_task(
                    self._track_model_loading(requested_model, __event_emitter__, state)
                )
                state["load_task"] = task

        return body

    # --------------------------------------------------------------------------
    # STREAM: Parse SSE chunks for prompt_progress, timings, and token speed
    # --------------------------------------------------------------------------
    async def stream(
        self,
        event: dict,
        __event_emitter__: Optional[Callable[[dict], Awaitable[None]]] = None,
        __metadata__: Optional[dict] = None,
        __body__: Optional[dict] = None,
    ) -> dict:
        if not isinstance(event, dict):
            return event

        metadata = __metadata__ if isinstance(__metadata__, dict) else {}
        state = metadata.get("_llamacpp_tracker")
        if not state:
            return event

        prefix = self.valves.status_prefix
        now = time.time()

        # Stop model load tracking once stream starts delivering chunks
        if not state.get("stop_load_tracker"):
            state["stop_load_tracker"] = True
            load_task: Optional[asyncio.Task] = state.get("load_task")
            if load_task and not load_task.done():
                load_task.cancel()

        # 1. Check for prompt processing progress
        progress_data = event.get("prompt_progress")
        if progress_data and isinstance(progress_data, dict):
            state["prompt_progress"] = progress_data
            if self.valves.enable_prompt_progress and self.valves.show_status_pill and __event_emitter__:
                total = progress_data.get("total", 0)
                cache = progress_data.get("cache", 0)
                processed = progress_data.get("processed", 0)
                time_ms = progress_data.get("time_ms", 0.0)

                actual_total = total - cache
                actual_processed = processed - cache

                if actual_total > 0 and actual_processed > 0:
                    pct = int(round((actual_processed / actual_total) * 100))
                    speed = (actual_processed / (time_ms / 1000.0)) if time_ms > 0 else 0.0
                    eta_sec = (time_ms / 1000.0) * (actual_total / actual_processed - 1) if actual_processed < actual_total else 0.0

                    # Throttle updates to avoid overloading the UI
                    if (now - state["last_status_emit"]) >= 0.25:
                        eta_str = f" · ETA: {max(0.1, eta_sec):.1f}s" if eta_sec > 0.1 else ""
                        await __event_emitter__(
                            {
                                "type": "status",
                                "data": {
                                    "description": f"🔄 [{prefix}] Prompt: {pct}% ({speed:.1f} t/s{eta_str})",
                                    "done": False,
                                    "hidden": False,
                                },
                            }
                        )
                        state["last_status_emit"] = now
                elif cache > 0 and actual_total == 0:
                    if (now - state["last_status_emit"]) >= 0.5:
                        await __event_emitter__(
                            {
                                "type": "status",
                                "data": {
                                    "description": f"⚡ [{prefix}] KV Cache 100% Hit ({cache} tokens reused)",
                                    "done": False,
                                    "hidden": False,
                                },
                            }
                        )
                        state["last_status_emit"] = now

        # 2. Check for token generation
        choices = event.get("choices") or []
        has_content = False
        if choices and isinstance(choices, list):
            delta = choices[0].get("delta") or {}
            content = delta.get("content")
            if content:
                has_content = True
                state["generated_tokens"] += 1
                if state["first_token_time"] is None:
                    state["first_token_time"] = now

        # 3. Check for timings in chunk
        chunk_timings = event.get("timings")
        if chunk_timings and isinstance(chunk_timings, dict):
            state["timings"] = chunk_timings

        # 4. Live generation tokens per second status
        if has_content and self.valves.enable_live_tps and self.valves.show_status_pill and __event_emitter__:
            if (now - state["last_status_emit"]) >= 0.35:
                timings = state.get("timings") or {}
                if timings.get("predicted_per_second"):
                    live_tps = float(timings["predicted_per_second"])
                    tok_count = timings.get("predicted_n", state["generated_tokens"])
                else:
                    first_t = state["first_token_time"] or state["start_time"]
                    gen_elapsed = max(0.001, now - first_t)
                    tok_count = state["generated_tokens"]
                    live_tps = tok_count / gen_elapsed

                await __event_emitter__(
                    {
                        "type": "status",
                        "data": {
                            "description": f"⚡ [{prefix}] Generating: {live_tps:.1f} t/s ({tok_count} tokens)",
                            "done": False,
                            "hidden": False,
                        },
                    }
                )
                state["last_status_emit"] = now

        return event

    # --------------------------------------------------------------------------
    # OUTLET: Generate completion statistics, status pill, and Markdown details
    # --------------------------------------------------------------------------
    async def outlet(
        self,
        body: dict,
        __user__: Optional[dict] = None,
        __metadata__: Optional[dict] = None,
        __event_emitter__: Optional[Callable[[dict], Awaitable[None]]] = None,
    ) -> dict:
        metadata = __metadata__ if isinstance(__metadata__, dict) else {}
        state = metadata.get("_llamacpp_tracker")
        if not state:
            return body

        # Clean up any lingering background tasks
        state["stop_load_tracker"] = True
        load_task: Optional[asyncio.Task] = state.get("load_task")
        if load_task and not load_task.done():
            load_task.cancel()

        end_time = time.time()
        start_time = state["start_time"]
        first_token_time = state.get("first_token_time")
        prefix = self.valves.status_prefix
        timings = state.get("timings") or {}
        progress = state.get("prompt_progress") or {}

        # Extract or calculate primary metrics
        if timings:
            gen_tokens = int(timings.get("predicted_n", state["generated_tokens"]))
            gen_ms = float(timings.get("predicted_ms", 0.0))
            gen_tps = float(timings.get("predicted_per_second") or (gen_tokens / (gen_ms / 1000.0) if gen_ms > 0 else 0.0))

            prompt_tokens = int(timings.get("prompt_n", 0))
            prompt_ms = float(timings.get("prompt_ms", 0.0))
            prompt_tps = float(timings.get("prompt_per_second") or (prompt_tokens / (prompt_ms / 1000.0) if prompt_ms > 0 else 0.0))

            cached_tokens = int(timings.get("cache_n", 0))
            draft_tokens = int(timings.get("draft_n", 0))
            draft_accepted = int(timings.get("draft_n_accepted", 0))
        else:
            # Fallback estimation from timestamps and counters
            total_elapsed_s = max(0.001, end_time - start_time)
            ttft_s = (first_token_time - start_time) if first_token_time else 0.0
            gen_elapsed_s = max(0.001, end_time - (first_token_time or start_time))

            gen_tokens = state["generated_tokens"]
            gen_ms = gen_elapsed_s * 1000.0
            gen_tps = gen_tokens / gen_elapsed_s if gen_tokens > 0 else 0.0

            prompt_tokens = progress.get("total", 0)
            prompt_ms = ttft_s * 1000.0
            prompt_tps = prompt_tokens / (prompt_ms / 1000.0) if prompt_ms > 0 and prompt_tokens > 0 else 0.0

            cached_tokens = progress.get("cache", 0)
            draft_tokens = 0
            draft_accepted = 0

        # Calculate KV Cache Hit Rate
        total_prompt_evaluated = prompt_tokens + cached_tokens
        cache_hit_pct = (cached_tokens / total_prompt_evaluated * 100.0) if total_prompt_evaluated > 0 else 0.0

        # Calculate Time to First Token (TTFT)
        if prompt_ms > 0:
            ttft_ms = prompt_ms
        elif first_token_time:
            ttft_ms = (first_token_time - start_time) * 1000.0
        else:
            ttft_ms = 0.0

        total_latency_ms = (end_time - start_time) * 1000.0

        # Build Status Pill Line
        summary_parts = []
        if gen_tps > 0:
            summary_parts.append(f"⚡ {gen_tps:.1f} t/s")
        if prompt_tps > 0:
            summary_parts.append(f"Prefill: {prompt_tps:.1f} t/s")
        if gen_tokens > 0:
            summary_parts.append(f"{gen_tokens} tokens in {format_duration(gen_ms)}")
        if cached_tokens > 0:
            summary_parts.append(f"Cache: {cache_hit_pct:.0f}%")

        if summary_parts:
            status_text = " · ".join(summary_parts)
        else:
            status_text = f"✅ [{prefix}] Completed"

        if self.valves.show_status_pill and __event_emitter__:
            try:
                await __event_emitter__(
                    {
                        "type": "status",
                        "data": {
                            "description": status_text,
                            "done": True,
                            "hidden": False,
                        },
                    }
                )
            except Exception as e:
                if self.valves.debug_mode:
                    log.debug("[LLAMACPP] Error updating final status: %s", e)

        # Build Collapsible Markdown Summary
        if self.valves.append_summary_footer:
            rows = []
            rows.append(f"| **Generation Speed** | `{gen_tps:.2f} t/s` ({gen_tokens} tokens in {format_duration(gen_ms)}) |")
            if prompt_tokens > 0 or prompt_ms > 0:
                rows.append(f"| **Prompt Processing (Prefill)** | `{prompt_tps:.2f} t/s` ({prompt_tokens} tokens in {format_duration(prompt_ms)}) |")
            if cached_tokens > 0 or total_prompt_evaluated > 0:
                rows.append(f"| **KV Cache Reuse** | `{cached_tokens} / {total_prompt_evaluated} tokens ({cache_hit_pct:.1f}%)` |")
            if ttft_ms > 0:
                rows.append(f"| **Time to First Token (TTFT)** | `{format_duration(ttft_ms)}` |")
            rows.append(f"| **Total Latency** | `{format_duration(total_latency_ms)}` |")

            if state.get("model_was_loading") and state.get("model_load_duration_s"):
                rows.append(f"| **Model Load Time** | `{state['model_load_duration_s']:.2f} s` |")

            if draft_tokens > 0:
                draft_rate = (draft_accepted / draft_tokens * 100.0) if draft_tokens > 0 else 0.0
                rows.append(f"| **Speculative Decoding** | `{draft_accepted} / {draft_tokens} accepted ({draft_rate:.1f}%)` |")

            target_display = state.get("normalized_model") or state.get("requested_model") or "llama.cpp"
            rows.append(f"| **Model / Backend** | `{target_display}` |")

            table_content = "\n".join(rows)
            summary_title = f"⚡ **llama.cpp Stats**: `{gen_tps:.1f} t/s` · {gen_tokens} tokens in {format_duration(gen_ms)}"

            markdown_block = (
                f"\n\n<details>\n"
                f"<summary>{summary_title}</summary>\n\n"
                f"| Metric | Value |\n"
                f"| :--- | :--- |\n"
                f"{table_content}\n"
                f"</details>\n"
            )

            # Append to assistant message
            messages = body.get("messages")
            if isinstance(messages, list) and messages:
                last_msg = messages[-1]
                if last_msg.get("role") == "assistant":
                    content = last_msg.get("content", "")
                    last_msg["content"] = content + markdown_block

        return body

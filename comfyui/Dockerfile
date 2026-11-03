
FROM pytorch/pytorch:2.14.1-cuda13.0-cudnn9-runtime

ENV PYTHONUNBUFFERED=1 \
    PIP_NO_CACHE_DIR=1 \
    HF_HUB_DISABLE_TELEMETRY=1 \
    COMFYUI_AUTOFREE_ENABLED=1 \
    COMFYUI_AUTOFREE_IDLE_SECONDS=120 \
    COMFYUI_AUTOFREE_POLL_INTERVAL=3

RUN apt-get update && apt-get install -y --no-install-recommends \
    git \
    ffmpeg \
    libgl1 \
    libglib2.0-0 \
    libsm6 \
    libxext6 \
    libxrender1 \
    python3-venv \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /opt/ComfyUI

RUN python -m venv --system-site-packages /opt/venv

ENV PATH="/opt/venv/bin:$PATH"

ARG COMFYUI_VERSION=v0.37.0

RUN git clone --depth 1 --branch ${COMFYUI_VERSION} \
    https://github.com/Comfy-Org/ComfyUI.git .

# Install ComfyUI requirements while preserving PyTorch
RUN grep -Ev '^(torch|torchvision|torchaudio)$' requirements.txt \
    > /tmp/requirements.txt \
    && python -m pip install --no-cache-dir -r /tmp/requirements.txt

# Install AutoFreeMemory
RUN git clone --depth 1 \
    https://github.com/Nlepetit/ComfyUI-AutoFreeMemory.git \
    /opt/ComfyUI/custom_nodes/ComfyUI-AutoFreeMemory

COPY extra_model_paths.yaml /opt/ComfyUI/extra_model_paths.yaml

EXPOSE 8188

CMD ["bash", "-c", "mkdir -p /workspace/user /workspace/output /workspace/input && exec python main.py --listen 0.0.0.0 --port 8188 --lowvram --extra-model-paths-config /opt/ComfyUI/extra_model_paths.yaml --user-directory /workspace/user --output-directory /workspace/output --input-directory /workspace/input"]

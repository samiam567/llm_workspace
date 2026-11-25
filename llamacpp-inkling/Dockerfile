FROM nvidia/cuda:12.4.1-runtime-ubuntu22.04

RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates curl libgomp1 && \
    rm -rf /var/lib/apt/lists/*

WORKDIR /opt/llama.cpp
RUN curl -fL -o /tmp/llama.tar.gz \
    https://github.com/unslothai/llama.cpp/releases/download/b12649-mix-c7059d6/app-b12649-mix-c7059d6-linux-x64-cuda12-legacy.tar.gz && \
    tar -xzf /tmp/llama.tar.gz -C /opt/llama.cpp && \
    rm -f /tmp/llama.tar.gz && \
    chmod +x /opt/llama.cpp/llama-server

ENV PATH="/opt/llama.cpp:${PATH}"
ENTRYPOINT ["/opt/llama.cpp/llama-server"]

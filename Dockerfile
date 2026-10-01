# ============================================================
# Voicebox — Local TTS Server with Web UI
# 3-stage build: Frontend → Python deps → Runtime
#
# Build variants:
#   CPU (default):  docker compose up --build
#   ROCm (AMD GPU): docker compose -f docker-compose.yml -f docker-compose.rocm.yml up --build
# ============================================================

ARG PYTORCH_VARIANT=cpu

# === Stage 1: Build frontend ===
FROM oven/bun:1 AS frontend

WORKDIR /build

COPY package.json bun.lock CHANGELOG.md ./
COPY app/ ./app/
COPY web/ ./web/

RUN sed -i 's/\r$//' package.json && \
    sed -i '/"tauri"/d; /"landing"/d' package.json && \
    sed -i -z 's/,\n  ]/\n  ]/' package.json

RUN bun install --no-save
RUN cd web && bunx --bun vite build


# === Stage 2: Build Python dependencies ===
FROM python:3.11-slim AS backend-builder

ARG PYTORCH_VARIANT=cpu
ARG ROCM_VERSION=6.3

WORKDIR /build

RUN apt-get update && apt-get install -y --no-install-recommends \
    git \
    build-essential \
    && rm -rf /var/lib/apt/lists/*

# Install into the same virtual environment throughout the build.
# Keep this path identical in the runtime stage.
RUN python -m venv /opt/voicebox-venv
ENV PATH="/opt/voicebox-venv/bin:${PATH}"

RUN python -m pip install --no-cache-dir --upgrade pip

COPY backend/requirements.txt .

# Install a matching Torch/TorchAudio pair before other Python packages.
# The ROCm pin below is specifically for ROCM_VERSION=6.3.
RUN if [ "$PYTORCH_VARIANT" = "rocm" ]; then \
      if [ "$ROCM_VERSION" != "6.3" ]; then \
        echo "This Dockerfile pins Torch/TorchAudio for ROCm 6.3; update the pins before using another ROCM_VERSION." >&2; \
        exit 1; \
      fi; \
      python -m pip install --no-cache-dir \
        --index-url "https://download.pytorch.org/whl/rocm${ROCM_VERSION}" \
        'torch==2.9.1+rocm6.3' \
        'torchaudio==2.9.1+rocm6.3'; \
    elif [ "$PYTORCH_VARIANT" = "cpu" ]; then \
      python -m pip install --no-cache-dir \
        --index-url https://download.pytorch.org/whl/cpu \
        'torch==2.9.1' \
        'torchaudio==2.9.1'; \
    else \
      echo "Unsupported PYTORCH_VARIANT: $PYTORCH_VARIANT" >&2; \
      exit 1; \
    fi

RUN python -m pip install --no-cache-dir -r requirements.txt

# These packages have dependency pins that conflict with this build.
RUN python -m pip install --no-cache-dir --no-deps chatterbox-tts
RUN python -m pip install --no-cache-dir --no-deps hume-tada
RUN python -m pip install --no-cache-dir --no-deps \
    git+https://github.com/QwenLM/Qwen3-TTS.git

# Catch a mixed or overwritten Torch/TorchAudio installation at build time.
RUN python -c 'import torch, torchaudio; print("torch:", torch.__version__, "torchaudio:", torchaudio.__version__, "HIP:", torch.version.hip)' && \
    if [ "$PYTORCH_VARIANT" = "rocm" ]; then \
      python -c 'import torch, torchaudio; assert torch.__version__ == "2.9.1+rocm6.3", torch.__version__; assert torchaudio.__version__ == "2.9.1+rocm6.3", torchaudio.__version__; assert torch.version.hip, "Torch has no HIP support"'; \
    else \
      python -c 'import torch, torchaudio; assert torch.__version__.split("+")[0] == "2.9.1", torch.__version__; assert torchaudio.__version__.split("+")[0] == "2.9.1", torchaudio.__version__; assert torch.version.hip is None, "Unexpected HIP build"'; \
    fi


# === Stage 3: Runtime ===
FROM python:3.11-slim

RUN groupadd -r voicebox && \
    useradd -r -g voicebox -m -s /bin/bash voicebox

WORKDIR /app

RUN apt-get update && apt-get install -y --no-install-recommends \
    ffmpeg \
    curl \
    gosu \
    && rm -rf /var/lib/apt/lists/*

COPY --from=backend-builder /opt/voicebox-venv /opt/voicebox-venv
ENV PATH="/opt/voicebox-venv/bin:${PATH}"

COPY --chown=voicebox:voicebox backend/ /app/backend/
COPY --from=frontend --chown=voicebox:voicebox /build/web/dist /app/frontend/

RUN mkdir -p /app/data/generations /app/data/profiles /app/data/cache \
    && chown -R voicebox:voicebox /app/data

EXPOSE 17493

HEALTHCHECK --interval=30s --timeout=10s --retries=3 --start-period=60s \
    CMD curl -f http://localhost:17493/health || exit 1

COPY --chmod=755 scripts/rocm-entrypoint.sh /usr/local/bin/entrypoint.sh
RUN sed -i 's/\r$//' /usr/local/bin/entrypoint.sh

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
CMD ["uvicorn", "backend.main:app", "--host", "0.0.0.0", "--port", "17493"]

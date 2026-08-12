FROM node:22-bookworm-slim

ENV NODE_ENV=production \
    HOST=0.0.0.0 \
    PORT=4173 \
    SLATESYNC_DATA_DIR=/var/lib/slatesync/data \
    PADDLEOCR_PYTHON=/opt/slatesync-ocr/bin/python \
    PADDLE_PDX_CACHE_HOME=/var/lib/slatesync/paddlex \
    PYTHONDONTWRITEBYTECODE=1 \
    PIP_NO_CACHE_DIR=1

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
      ca-certificates \
      libgl1 \
      libglib2.0-0 \
      libgomp1 \
      libsm6 \
      libxext6 \
      libxrender1 \
      python3 \
      python3-venv \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

COPY package.json package-lock.json requirements-ocr.txt ./
RUN npm ci --omit=dev \
    && python3 -m venv /opt/slatesync-ocr \
    && /opt/slatesync-ocr/bin/python -m pip install --upgrade pip \
    && /opt/slatesync-ocr/bin/python -m pip install -r requirements-ocr.txt

COPY server.mjs slatesync.config.json ./
COPY lib ./lib
COPY public ./public
COPY scripts/paddleocr_runner.py ./scripts/paddleocr_runner.py

RUN mkdir -p /var/lib/slatesync/paddlex /var/lib/slatesync/data \
    && chown -R node:node /var/lib/slatesync

USER node

EXPOSE 4173

HEALTHCHECK --interval=30s --timeout=5s --start-period=30s --retries=3 \
  CMD node -e "fetch('http://127.0.0.1:4173/healthz').then(r=>{if(!r.ok)process.exit(1)}).catch(()=>process.exit(1))"

CMD ["node", "server.mjs"]

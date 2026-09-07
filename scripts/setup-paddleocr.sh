#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
PROJECT_DIR=$(dirname -- "$SCRIPT_DIR")
PADDLE_RESOURCE_DIR="$PROJECT_DIR/SlateSyncApp/Resources/PaddleOCR"
OCR_VENV="$PROJECT_DIR/.venv-paddleocr"

# The runner is retained for migration compatibility, but the current OCR
# setup entrypoint must not install a product dependency on another OS.
if [ "$(uname -s)" != "Darwin" ]; then
  echo "[SlateSync] 当前产品仅支持在 macOS 主机上安装 PaddleOCR。" >&2
  exit 1
fi

python3 -m venv "$OCR_VENV"
"$OCR_VENV/bin/python" -m pip install --upgrade pip
"$OCR_VENV/bin/python" -m pip install -r "$PADDLE_RESOURCE_DIR/requirements-ocr.txt"
"$OCR_VENV/bin/python" "$PADDLE_RESOURCE_DIR/paddleocr_runner.py" --check

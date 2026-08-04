#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
PROJECT_DIR=$(dirname -- "$SCRIPT_DIR")
OCR_VENV="$PROJECT_DIR/.venv-paddleocr"

python3 -m venv "$OCR_VENV"
"$OCR_VENV/bin/python" -m pip install --upgrade pip
"$OCR_VENV/bin/python" -m pip install -r "$PROJECT_DIR/requirements-ocr.txt"
"$OCR_VENV/bin/python" "$SCRIPT_DIR/paddleocr_runner.py" --check

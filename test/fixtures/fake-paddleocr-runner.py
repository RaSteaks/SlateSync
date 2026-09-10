#!/usr/bin/env python3
"""Small protocol-only runner used to test Node's resident Worker lifecycle."""

import json
import os
import sys
import time


SENTINEL = "__SLATESYNC_OCR_JSON__"
PROGRESS_SENTINEL = "__SLATESYNC_OCR_PROGRESS__"


def write(prefix, value):
    sys.stdout.write(prefix + json.dumps(value, separators=(",", ":")) + "\n")
    sys.stdout.flush()


def bump_counter():
    cache_home = os.environ.get("PADDLE_PDX_CACHE_HOME")
    path = os.path.join(cache_home, "warmups.txt") if cache_home else None
    if not path:
        return
    try:
        with open(path, "r", encoding="utf-8") as handle:
            current = int(handle.read() or "0")
    except (FileNotFoundError, ValueError):
        current = 0
    with open(path, "w", encoding="utf-8") as handle:
        handle.write(str(current + 1))


def main():
    if "--server" not in sys.argv:
        request = json.load(sys.stdin)
        write(SENTINEL, {"ok": True, "pages": request.get("pages", [])})
        return

    for raw_line in sys.stdin:
        request = json.loads(raw_line)
        request_id = request.get("requestId")
        request_type = request.get("type")
        if request_type == "shutdown":
            write(SENTINEL, {"requestId": request_id, "ok": True, "type": "shutdown"})
            return
        if request_type == "warmup":
            bump_counter()
            write(PROGRESS_SENTINEL, {"requestId": request_id, "stage": "loading"})
            write(PROGRESS_SENTINEL, {"requestId": request_id, "stage": "ready"})
            write(SENTINEL, {"requestId": request_id, "ok": True, "type": "warmup"})
            continue
        payload = request.get("payload", {})
        # The fixture uses the protocol's language field as an explicit test
        # marker; production PaddleOCR never relies on arbitrary child env keys.
        delay = 1.0 if payload.get("language") == "test-delay" else 0.0
        if delay > 0:
            time.sleep(delay)
        pages = [
            {"pageNumber": page.get("pageNumber", index + 1), "views": []}
            for index, page in enumerate(payload.get("pages", []))
        ]
        write(PROGRESS_SENTINEL, {
            "requestId": request_id,
            "stage": "ready",
            "completedViews": 0,
            "totalViews": 0,
        })
        write(SENTINEL, {
            "requestId": request_id,
            "ok": True,
            "modelVersion": payload.get("modelVersion"),
            "profile": payload.get("profile"),
            "pages": pages,
        })


if __name__ == "__main__":
    main()

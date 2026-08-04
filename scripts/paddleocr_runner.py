#!/usr/bin/env python3
"""SlateSync PaddleOCR bridge.

Reads one JSON request from stdin and writes one sentinel-prefixed JSON response
to stdout. PaddleOCR logs are redirected to stderr so the Node caller can parse
the result reliably.
"""

import argparse
import base64
import contextlib
import json
import os
import sys
import time


SENTINEL = "__SLATESYNC_OCR_JSON__"
PROGRESS_SENTINEL = "__SLATESYNC_OCR_PROGRESS__"


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--check", action="store_true")
    args = parser.parse_args()

    try:
        with contextlib.redirect_stdout(sys.stderr):
            import cv2
            import numpy as np
            import paddle
            from paddleocr import PaddleOCR
    except Exception as error:
        emit(
            {
                "ok": False,
                "error": {
                    "code": "dependency_missing",
                    "message": f"PaddleOCR 依赖不可用：{error}",
                },
            },
            3,
        )

    if args.check:
        try:
            import importlib.metadata

            paddleocr_version = importlib.metadata.version("paddleocr")
        except Exception:
            paddleocr_version = "unknown"
        emit(
            {
                "ok": True,
                "paddleVersion": getattr(paddle, "__version__", "unknown"),
                "paddleOcrVersion": paddleocr_version,
            }
        )

    try:
        request = json.load(sys.stdin)
    except Exception as error:
        emit(
            {
                "ok": False,
                "error": {
                    "code": "invalid_input",
                    "message": f"OCR 输入不是有效 JSON：{error}",
                },
            },
            2,
        )

    model_version = clean_string(request.get("modelVersion")) or "PP-OCRv5"
    profile = clean_string(request.get("profile")) or "balanced"
    detection_model = clean_string(request.get("detectionModel"))
    recognition_model = clean_string(request.get("recognitionModel"))
    recognition_batch_size = clamp_int(
        request.get("recognitionBatchSize"), 1, 64, 8
    )
    language = clean_string(request.get("language")) or "ch"
    device = clean_string(request.get("device")) or "cpu"
    minimum_confidence = clamp_float(request.get("minimumConfidence"), 0.0, 1.0, 0.1)
    max_blocks = clamp_int(request.get("maxBlocksPerView"), 0, 10000, 0)

    os.environ.setdefault("PADDLE_PDX_DISABLE_MODEL_SOURCE_CHECK", "True")
    started = time.monotonic()
    try:
        with contextlib.redirect_stdout(sys.stderr):
            pipeline_options = dict(
                lang=language,
                ocr_version=model_version,
                device=device,
                use_doc_orientation_classify=False,
                use_doc_unwarping=False,
                use_textline_orientation=False,
                text_recognition_batch_size=recognition_batch_size,
                text_rec_score_thresh=0.0,
            )
            if detection_model:
                pipeline_options["text_detection_model_name"] = detection_model
            if recognition_model:
                pipeline_options["text_recognition_model_name"] = recognition_model
            pipeline = PaddleOCR(**pipeline_options)
    except Exception as error:
        emit(
            {
                "ok": False,
                "error": {
                    "code": "initialization_failed",
                    "message": f"PaddleOCR 初始化失败：{error}",
                },
            },
            4,
        )

    requested_pages = request.get("pages") or []
    total_views = sum(len(page.get("images") or []) for page in requested_pages)
    completed_views = 0
    emit_progress(
        {
            "stage": "ready",
            "profile": profile,
            "completedViews": 0,
            "totalViews": total_views,
        }
    )

    pages = []
    try:
        for page_index, page in enumerate(requested_pages):
            page_number = clamp_int(page.get("pageNumber"), 1, 10000, page_index + 1)
            views = []
            for view_index, data_url in enumerate(page.get("images") or []):
                view = recognize_view(
                    pipeline,
                    cv2,
                    np,
                    data_url,
                    view_index,
                    minimum_confidence,
                    max_blocks,
                )
                views.append(view)
                completed_views += 1
                emit_progress(
                    {
                        "stage": "view-complete",
                        "pageNumber": page_number,
                        "viewIndex": view_index,
                        "completedViews": completed_views,
                        "totalViews": total_views,
                        "durationMs": view["durationMs"],
                        "blockCount": len(view["blocks"]),
                    }
                )
            pages.append({"pageNumber": page_number, "views": views})
    except Exception as error:
        emit(
            {
                "ok": False,
                "error": {
                    "code": "inference_failed",
                    "message": f"PaddleOCR 推理失败：{error}",
                },
            },
            5,
        )

    emit(
        {
            "ok": True,
            "engine": "PaddleOCR",
            "modelVersion": model_version,
            "profile": profile,
            "detectionModel": detection_model or None,
            "recognitionModel": recognition_model or None,
            "recognitionBatchSize": recognition_batch_size,
            "language": language,
            "device": device,
            "durationMs": round((time.monotonic() - started) * 1000),
            "pages": pages,
        }
    )


def recognize_view(
    pipeline,
    cv2,
    np,
    data_url,
    view_index,
    minimum_confidence,
    max_blocks,
):
    raw = decode_data_url(data_url)
    image = cv2.imdecode(np.frombuffer(raw, dtype=np.uint8), cv2.IMREAD_COLOR)
    if image is None:
        raise ValueError(f"第 {view_index + 1} 个视图无法解码")
    height, width = image.shape[:2]
    started = time.monotonic()
    with contextlib.redirect_stdout(sys.stderr):
        results = list(pipeline.predict(image))

    blocks = []
    for result in results:
        payload = getattr(result, "json", result)
        if callable(payload):
            payload = payload()
        if isinstance(payload, dict) and isinstance(payload.get("res"), dict):
            payload = payload["res"]
        if not isinstance(payload, dict):
            continue
        texts = to_list(payload.get("rec_texts"))
        scores = to_list(payload.get("rec_scores"))
        boxes = to_list(payload.get("rec_boxes"))
        polygons = to_list(payload.get("rec_polys"))
        for index, text in enumerate(texts):
            normalized_text = str(text or "").strip()
            score = safe_float(scores[index] if index < len(scores) else 0.0)
            if not normalized_text or score < minimum_confidence:
                continue
            box = box_at(boxes, polygons, index)
            if box is None:
                continue
            x1, y1, x2, y2 = box
            blocks.append(
                {
                    "order": len(blocks),
                    "text": normalized_text,
                    "confidence": round(score, 5),
                    "bbox": [round(x1), round(y1), round(x2), round(y2)],
                    "bboxNormalized": [
                        round(x1 / width, 5),
                        round(y1 / height, 5),
                        round(x2 / width, 5),
                        round(y2 / height, 5),
                    ],
                }
            )

    blocks.sort(key=lambda block: (block["bbox"][1], block["bbox"][0]))
    truncated = max_blocks > 0 and len(blocks) > max_blocks
    if truncated:
        blocks = select_blocks_with_page_coverage(blocks, max_blocks)
    for index, block in enumerate(blocks):
        block["order"] = index
    return {
        "viewIndex": view_index,
        "viewType": "full" if view_index == 0 else "core-detail",
        "width": width,
        "height": height,
        "durationMs": round((time.monotonic() - started) * 1000),
        "truncated": truncated,
        "blocks": blocks,
    }


def select_blocks_with_page_coverage(blocks, limit):
    """Bound output without always deleting the bottom of a dense page."""
    if limit <= 0 or len(blocks) <= limit:
        return blocks
    if limit == 1:
        return [blocks[len(blocks) // 2]]
    last_index = len(blocks) - 1
    indices = [round(slot * last_index / (limit - 1)) for slot in range(limit)]
    return [blocks[index] for index in indices]


def decode_data_url(value):
    if not isinstance(value, str) or "," not in value:
        raise ValueError("图片不是有效 Data URL")
    header, encoded = value.split(",", 1)
    if not header.startswith("data:image/") or ";base64" not in header:
        raise ValueError("OCR 只支持 Base64 图片 Data URL")
    return base64.b64decode(encoded, validate=True)


def box_at(boxes, polygons, index):
    if index < len(boxes):
        box = to_list(boxes[index])
        if len(box) >= 4:
            return [safe_float(box[0]), safe_float(box[1]), safe_float(box[2]), safe_float(box[3])]
    if index < len(polygons):
        points = to_list(polygons[index])
        coordinates = [to_list(point) for point in points]
        coordinates = [point for point in coordinates if len(point) >= 2]
        if coordinates:
            xs = [safe_float(point[0]) for point in coordinates]
            ys = [safe_float(point[1]) for point in coordinates]
            return [min(xs), min(ys), max(xs), max(ys)]
    return None


def to_list(value):
    if value is None:
        return []
    if hasattr(value, "tolist"):
        return value.tolist()
    if isinstance(value, (list, tuple)):
        return list(value)
    return []


def safe_float(value):
    try:
        return float(value)
    except Exception:
        return 0.0


def clamp_float(value, minimum, maximum, fallback):
    try:
        return min(max(float(value), minimum), maximum)
    except Exception:
        return fallback


def clamp_int(value, minimum, maximum, fallback):
    try:
        return min(max(int(value), minimum), maximum)
    except Exception:
        return fallback


def clean_string(value):
    return value.strip() if isinstance(value, str) else ""


def emit(value, exit_code=0):
    sys.stdout.write(SENTINEL + json.dumps(value, ensure_ascii=False, separators=(",", ":")) + "\n")
    sys.stdout.flush()
    raise SystemExit(exit_code)


def emit_progress(value):
    sys.stdout.write(
        PROGRESS_SENTINEL
        + json.dumps(value, ensure_ascii=False, separators=(",", ":"))
        + "\n"
    )
    sys.stdout.flush()


if __name__ == "__main__":
    main()

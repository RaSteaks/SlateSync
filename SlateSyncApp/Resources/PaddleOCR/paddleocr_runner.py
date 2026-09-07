#!/usr/bin/env python3
"""SlateSync PaddleOCR bridge.

Reads one JSON request from stdin, or serves requestId-tagged JSON lines in
``--server`` mode. PaddleOCR logs are redirected to stderr so the Node caller
can parse responses and progress reliably.
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
    parser.add_argument("--server", action="store_true")
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

    if args.server:
        server_main(cv2, np, PaddleOCR)
        return

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

    os.environ.setdefault("PADDLE_PDX_DISABLE_MODEL_SOURCE_CHECK", "True")
    config = request_config(request)
    try:
        with contextlib.redirect_stdout(sys.stderr):
            pipeline = create_pipeline(config, PaddleOCR)
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

    response = recognize_request(request, pipeline, cv2, np)
    emit(response, 0 if response.get("ok") else 5)


def request_config(request):
    """Normalize model-affecting and output parameters at the Python boundary."""
    model_version = normalize_model_version(request.get("modelVersion"))
    return {
        "modelVersion": model_version,
        "profile": clean_string(request.get("profile")) or "custom",
        "detectionModel": model_override_for_version(
            request.get("detectionModel"), model_version
        ),
        "recognitionModel": model_override_for_version(
            request.get("recognitionModel"), model_version
        ),
        "recognitionBatchSize": clamp_int(
            request.get("recognitionBatchSize"), 1, 64, 8
        ),
        "textDetLimitSideLen": clamp_int(
            request.get("textDetLimitSideLen"), 320, 4096, 960
        ),
        "language": clean_string(request.get("language")) or "ch",
        "device": clean_string(request.get("device")) or "cpu",
        "minimumConfidence": clamp_float(
            request.get("minimumConfidence"), 0.0, 1.0, 0.1
        ),
        "maxBlocksPerView": clamp_int(
            request.get("maxBlocksPerView"), 0, 10000, 0
        ),
    }


def create_pipeline(config, paddle_ocr):
    """Create exactly one pipeline for a server configuration."""
    pipeline_options = dict(
        lang=config["language"],
        ocr_version=config["modelVersion"],
        device=config["device"],
        use_doc_orientation_classify=False,
        use_doc_unwarping=False,
        use_textline_orientation=False,
        text_recognition_batch_size=config["recognitionBatchSize"],
        text_rec_score_thresh=0.0,
    )
    if config["detectionModel"]:
        pipeline_options["text_detection_model_name"] = config["detectionModel"]
    if config["recognitionModel"]:
        pipeline_options["text_recognition_model_name"] = config["recognitionModel"]
    return paddle_ocr(**pipeline_options)


def normalize_model_version(value):
    normalized = clean_string(value)
    lower = normalized.lower()
    if lower == "pp-ocrv5":
        return "PP-OCRv5"
    if lower == "pp-ocrv6":
        return "PP-OCRv6"
    # Keep future/local version identifiers usable even though the Settings UI
    # currently exposes only the versions with known model defaults.
    return normalized or "PP-OCRv6"


def model_override_for_version(value, model_version):
    model = clean_string(value)
    if not model or model_version not in {"PP-OCRv5", "PP-OCRv6"}:
        return model
    lower = model.lower()
    belongs_to_v5 = lower.startswith("pp-ocrv5_")
    belongs_to_v6 = lower.startswith("pp-ocrv6_")
    # Preserve hand-entered custom IDs, but never mix a known model generation
    # with the selected OCR version.
    if model_version == "PP-OCRv5" and belongs_to_v6:
        return ""
    if model_version == "PP-OCRv6" and belongs_to_v5:
        return ""
    return model


def server_main(cv2, np, paddle_ocr):
    """Keep imports and the native model alive while requests arrive in order."""
    pipeline = None
    pipeline_key = None
    warmed_key = None
    for raw_line in sys.stdin:
        line = raw_line.strip()
        if not line:
            continue
        request_id = None
        try:
            request = json.loads(line)
            request_id = clean_string(request.get("requestId")) or None
        except Exception as error:
            emit_server(
                {
                    "requestId": request_id,
                    "ok": False,
                    "error": {
                        "code": "invalid_input",
                        "message": f"OCR 输入不是有效 JSON：{error}",
                    },
                }
            )
            continue

        request_type = clean_string(request.get("type")).lower()
        if request_type == "shutdown":
            emit_server({"requestId": request_id, "ok": True, "type": "shutdown"})
            break
        if request_type not in {"warmup", "recognize"}:
            emit_server(
                {
                    "requestId": request_id,
                    "ok": False,
                    "error": {"code": "invalid_type", "message": "未知的 OCR Worker 请求类型"},
                }
            )
            continue

        payload = request.get("payload") if request_type == "recognize" else request
        payload = payload if isinstance(payload, dict) else {}
        config = request_config(payload)
        key = json.dumps(
            {
                # Profile is a legacy alias; the resolved model fields are
                # the only fields that change this resident pipeline.
                key: config[key]
                for key in (
                    "modelVersion",
                    "detectionModel",
                    "recognitionModel",
                    "recognitionBatchSize",
                    "textDetLimitSideLen",
                    "language",
                    "device",
                )
            },
            sort_keys=True,
        )
        try:
            if pipeline is None or pipeline_key != key:
                emit_progress(
                    {
                        "requestId": request_id,
                        "stage": "loading",
                        "profile": config["profile"],
                        "completedViews": 0,
                        "totalViews": 0,
                    }
                )
                with contextlib.redirect_stdout(sys.stderr):
                    pipeline = create_pipeline(config, paddle_ocr)
                pipeline_key = key

            warmup_duration_ms = 0
            if warmed_key != key:
                started = time.monotonic()
                warmup_image = np.full((160, 480, 3), 255, dtype=np.uint8)
                with contextlib.redirect_stdout(sys.stderr):
                    # Warm every newly created pipeline, including when a
                    # caller sends recognize before an explicit warmup line.
                    list(
                        pipeline.predict(
                            warmup_image,
                            text_det_limit_side_len=config["textDetLimitSideLen"],
                        )
                    )
                warmup_duration_ms = round((time.monotonic() - started) * 1000)
                warmed_key = key
                emit_progress(
                    {
                        "requestId": request_id,
                        "stage": "ready",
                        "profile": config["profile"],
                        "completedViews": 0,
                        "totalViews": 0,
                    }
                )

            if request_type == "warmup":
                emit_server(
                    {
                        "requestId": request_id,
                        "ok": True,
                        "type": "warmup",
                        "modelVersion": config["modelVersion"],
                        "warmupDurationMs": warmup_duration_ms,
                    }
                )
            else:
                response = recognize_request(
                    payload,
                    pipeline,
                    cv2,
                    np,
                    request_id=request_id,
                    config=config,
                )
                emit_server(response)
        except Exception as error:
            # Server errors belong to this request; keep the process alive so a
            # later task can retry or the Node layer can fall back one-shot.
            emit_server(
                {
                    "requestId": request_id,
                    "ok": False,
                    "error": {
                        "code": "worker_failed",
                        "message": f"PaddleOCR Worker 处理失败：{error}",
                    },
                }
            )


def recognize_request(request, pipeline, cv2, np, request_id=None, config=None):
    config = config or request_config(request)
    requested_pages = request.get("pages") or []
    total_views = sum(len(page.get("images") or []) for page in requested_pages)
    completed_views = 0
    emit_progress(
        {
            "requestId": request_id,
            "stage": "ready",
            "profile": config["profile"],
            "completedViews": 0,
            "totalViews": total_views,
        }
    )

    started = time.monotonic()
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
                    config["minimumConfidence"],
                    config["maxBlocksPerView"],
                    config["textDetLimitSideLen"],
                )
                views.append(view)
                completed_views += 1
                emit_progress(
                    {
                        "requestId": request_id,
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
        return {
            "requestId": request_id,
            "ok": False,
            "error": {
                "code": "inference_failed",
                "message": f"PaddleOCR 推理失败：{error}",
            },
        }

    return {
        "requestId": request_id,
        "ok": True,
        "engine": "PaddleOCR",
        "modelVersion": config["modelVersion"],
        "profile": config["profile"],
        "detectionModel": config["detectionModel"] or None,
        "recognitionModel": config["recognitionModel"] or None,
        "recognitionBatchSize": config["recognitionBatchSize"],
        "textDetLimitSideLen": config["textDetLimitSideLen"],
        "language": config["language"],
        "device": config["device"],
        "durationMs": round((time.monotonic() - started) * 1000),
        "pages": pages,
    }


def recognize_view(
    pipeline,
    cv2,
    np,
    data_url,
    view_index,
    minimum_confidence,
    max_blocks,
    text_det_limit_side_len,
):
    raw = decode_data_url(data_url)
    image = cv2.imdecode(np.frombuffer(raw, dtype=np.uint8), cv2.IMREAD_COLOR)
    if image is None:
        raise ValueError(f"第 {view_index + 1} 个视图无法解码")
    height, width = image.shape[:2]
    started = time.monotonic()
    with contextlib.redirect_stdout(sys.stderr):
        results = list(
            pipeline.predict(
                image,
                text_det_limit_side_len=text_det_limit_side_len,
            )
        )

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


def emit_server(value):
    """Write one response line without terminating the resident Worker."""
    sys.stdout.write(
        SENTINEL + json.dumps(value, ensure_ascii=False, separators=(",", ":")) + "\n"
    )
    sys.stdout.flush()


def emit_progress(value):
    sys.stdout.write(
        PROGRESS_SENTINEL
        + json.dumps(value, ensure_ascii=False, separators=(",", ":"))
        + "\n"
    )
    sys.stdout.flush()


if __name__ == "__main__":
    main()

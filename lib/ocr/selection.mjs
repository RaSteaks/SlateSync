// Shared local OCR selection policy.
//
// The Main process uses this module both when exposing capability status and
// when starting recognition. Keeping the precedence here prevents the Settings
// page from promising a different engine than the recognition pipeline uses.
import { paddleOcrPublicConfig } from "./paddleocr.mjs";
import { visionOcrPublicConfig } from "./vision.mjs";

export function resolveOcrSelection(env = process.env, options = {}) {
  const autoEnable = options.autoEnable ?? env === process.env;
  const vision = options.vision || visionOcrPublicConfig(env, { autoEnable });
  const paddle = options.paddle || paddleOcrPublicConfig(env, { autoEnable });
  const visionMode = explicitMode(env.VISIONOCR_ENABLED);
  const paddleMode = explicitMode(env.PADDLEOCR_ENABLED);

  // Required mode is deliberately checked before explicit optional flags so a
  // strict configuration can never be silently bypassed by another engine.
  if (vision.required) {
    return selected(vision, "required", "Vision OCR 已设置为必需模式。");
  }
  if (paddle.required) {
    return selected(paddle, "required", "PaddleOCR 已设置为必需模式。") ;
  }
  if (visionMode.enabled) {
    return selected(vision, "explicit", "已通过 VISIONOCR_ENABLED=true 指定。");
  }
  if (paddleMode.enabled) {
    return selected(paddle, "explicit", "已通过 PADDLEOCR_ENABLED=true 指定。") ;
  }
  if (visionMode.disabled) {
    if (paddle.enabled) {
      return selected(
        paddle,
        "fallback",
        "Vision OCR 已显式关闭，自动转用可用的 PaddleOCR。",
      );
    }
    return unavailable(
      paddleMode.disabled
        ? "Vision OCR 与 PaddleOCR 均已显式关闭。"
        : "Vision OCR 已显式关闭，PaddleOCR 未启用或不可用。",
      paddle,
    );
  }
  if (vision.enabled) {
    return selected(
      vision,
      "auto",
      "自动模式检测到 macOS Vision OCR 工具链，优先使用 Vision OCR。",
    );
  }
  if (paddle.enabled) {
    return selected(
      paddle,
      "auto",
      "Vision OCR 不可用，自动转用已配置的 PaddleOCR。",
    );
  }
  return unavailable(
    paddleMode.disabled
      ? "PaddleOCR 已显式关闭，且没有可用的 Vision OCR。"
      : "没有检测到可用的本地 OCR；识别将降级为页面图片识别。",
    paddle,
  );
}

function selected(engine, mode, reason) {
  return {
    id: engine.id,
    engine,
    mode,
    reason,
  };
}

function unavailable(reason, fallbackEngine) {
  return {
    id: null,
    // The runtime keeps Paddle as its no-op fallback implementation so the
    // existing optional-OCR path can return a normal page-image result.
    engine: fallbackEngine,
    mode: "disabled",
    reason,
  };
}

function explicitMode(value) {
  const mode = String(value || "").trim().toLowerCase();
  return {
    enabled: ["1", "true", "yes", "on"].includes(mode),
    disabled: ["0", "false", "no", "off"].includes(mode),
  };
}

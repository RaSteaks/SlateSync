// Non-sensitive environment settings exposed by the Global Settings page.
// Values are stored as user-level overrides and merged into the Main-process
// environment at runtime; API keys intentionally do not belong in this file.

const URL_KEYS = new Set([
  "OPENAI_BASE_URL",
  "OPENROUTER_BASE_URL",
  "OPENROUTER_SITE_URL",
  "TOKENPLAN_BASE_URL",
  "DASHSCOPE_BASE_URL",
  "OPENAI_COMPATIBLE_BASE_URL",
]);

const INTEGER_RANGES = {
  MAX_BODY_MB: [20, 200],
  MODEL_REQUEST_TIMEOUT_MS: [30_000, 3_600_000],
  MODEL_REQUEST_MAX_RETRIES: [0, 3],
  MODEL_PAGE_CONCURRENCY: [1, 6],
  MAX_CONCURRENT_RECOGNITIONS: [1, 16],
  PADDLEOCR_RECOGNITION_BATCH_SIZE: [1, 64],
  PADDLEOCR_MAX_BLOCKS_PER_VIEW: [0, 10_000],
  VISIONOCR_MAX_BLOCKS_PER_VIEW: [0, 10_000],
};

const NUMBER_RANGES = {
  PADDLEOCR_MIN_CONFIDENCE: [0, 1],
  VISIONOCR_MIN_CONFIDENCE: [0, 1],
};

const ENUM_VALUES = {
  OPENAI_COMPATIBLE_API_MODE: ["chat-completions", "responses"],
  OPENAI_COMPATIBLE_JSON_MODE: ["json_schema", "json_object", "prompt"],
  OPENAI_COMPATIBLE_IMAGE_DETAIL: ["auto", "low", "high", "original"],
  PADDLEOCR_ENABLED: ["auto", "true", "false"],
  PADDLEOCR_REQUIRED: ["true", "false"],
  PADDLEOCR_PROFILE: ["fast", "balanced", "accurate"],
  VISIONOCR_ENABLED: ["auto", "true", "false"],
  VISIONOCR_REQUIRED: ["true", "false"],
  VISIONOCR_RECOGNITION_LEVEL: ["accurate", "fast"],
  VISIONOCR_USE_LANGUAGE_CORRECTION: ["true", "false"],
};

const DEFAULT_VALUES = {
  OPENAI_BASE_URL: "https://api.openai.com/v1",
  OPENROUTER_BASE_URL: "https://openrouter.ai/api/v1",
  OPENROUTER_SITE_URL: "https://github.com/RaSteaks/SlateSync",
  TOKENPLAN_BASE_URL: "https://dashscope.aliyuncs.com/compatible-mode/v1",
  DASHSCOPE_BASE_URL: "https://dashscope.aliyuncs.com/compatible-mode/v1",
  OPENAI_COMPATIBLE_BASE_URL: "https://your-provider.example/v1",
  OPENAI_COMPATIBLE_MODEL: "your-vision-model",
  OPENAI_COMPATIBLE_API_MODE: "chat-completions",
  OPENAI_COMPATIBLE_JSON_MODE: "json_object",
  OPENAI_COMPATIBLE_IMAGE_DETAIL: "high",
  SLATESYNC_CONFIG_PATH: "slatesync.config.json",
  MAX_BODY_MB: "80",
  MODEL_REQUEST_TIMEOUT_MS: "180000",
  MODEL_REQUEST_MAX_RETRIES: "1",
  MODEL_PAGE_CONCURRENCY: "2",
  MAX_CONCURRENT_RECOGNITIONS: "1",
  PADDLEOCR_ENABLED: "auto",
  PADDLEOCR_REQUIRED: "false",
  PADDLEOCR_MODEL_VERSION: "PP-OCRv5",
  PADDLEOCR_PROFILE: "balanced",
  PADDLEOCR_LANGUAGE: "ch",
  PADDLEOCR_DEVICE: "cpu",
  PADDLEOCR_DETECTION_MODEL: "",
  PADDLEOCR_RECOGNITION_MODEL: "",
  PADDLEOCR_RECOGNITION_BATCH_SIZE: "",
  PADDLEOCR_PYTHON: "",
  PADDLEOCR_MIN_CONFIDENCE: "0.10",
  PADDLEOCR_MAX_BLOCKS_PER_VIEW: "0",
  PADDLEOCR_TIMEOUT_MS: "auto",
  PADDLE_PDX_CACHE_HOME: "",
  VISIONOCR_ENABLED: "auto",
  VISIONOCR_REQUIRED: "false",
  VISIONOCR_LANGUAGE: "zh-Hans",
  VISIONOCR_RECOGNITION_LEVEL: "accurate",
  VISIONOCR_USE_LANGUAGE_CORRECTION: "true",
  VISIONOCR_MIN_CONFIDENCE: "0.10",
  VISIONOCR_MAX_BLOCKS_PER_VIEW: "0",
  VISIONOCR_TIMEOUT_MS: "auto",
  VISIONOCR_BINARY: "",
};

// Keep this list explicit so a renderer request cannot write arbitrary
// process-level environment variables or accidentally persist a secret.
export const GLOBAL_SETTING_KEYS = Object.freeze(Object.keys(DEFAULT_VALUES));
export const GLOBAL_SETTING_DEFAULTS = Object.freeze({ ...DEFAULT_VALUES });

const GLOBAL_SETTING_KEY_SET = new Set(GLOBAL_SETTING_KEYS);

export function sanitizeGlobalConfig(value) {
  if (!value || typeof value !== "object" || Array.isArray(value)) return {};
  const sanitized = {};
  for (const key of GLOBAL_SETTING_KEYS) {
    if (typeof value[key] !== "string") continue;
    const normalized = value[key].trim();
    if (!normalized) continue;
    // A hand-edited or older file must not be able to inject an invalid URL,
    // enum or number into the startup environment. Invalid persisted entries
    // are ignored and the next read falls back to .env/defaults.
    try {
      sanitized[key] = validateGlobalSettingValue(key, normalized);
    } catch {
      delete sanitized[key];
    }
  }
  return sanitized;
}

// Validate only the fields supplied by a save request. Empty strings remove a
// user override and intentionally fall back to .env or the built-in default.
export function normalizeGlobalSettingsPatch(value = {}) {
  if (!value || typeof value !== "object" || Array.isArray(value)) {
    throw new Error("全局配置必须是 JSON 对象");
  }
  const normalized = {};
  for (const [key, rawValue] of Object.entries(value)) {
    if (!GLOBAL_SETTING_KEY_SET.has(key)) {
      throw new Error(`不支持的全局配置项：${key}`);
    }
    if (rawValue == null) {
      normalized[key] = "";
      continue;
    }
    if (typeof rawValue !== "string") {
      throw new Error(`${key} 必须是文本值`);
    }
    const nextValue = rawValue.trim();
    if (!nextValue) {
      normalized[key] = "";
      continue;
    }
    normalized[key] = validateGlobalSettingValue(key, nextValue);
  }
  return normalized;
}

// An explicit enable action is also a routing choice. Normalize the two OCR
// flags at the settings boundary so the legacy form and the Modern Renderer
// cannot leave a stale Vision preference masking a newly enabled PaddleOCR.
export function normalizeOcrRoutingPatch(patch = {}) {
  const normalized = { ...patch };
  if (normalized.PADDLEOCR_ENABLED === "true") {
    normalized.VISIONOCR_ENABLED = "false";
    normalized.VISIONOCR_REQUIRED = "false";
  } else if (normalized.VISIONOCR_ENABLED === "true") {
    normalized.PADDLEOCR_ENABLED = "false";
    normalized.PADDLEOCR_REQUIRED = "false";
  }
  return normalized;
}

export function applyGlobalConfig(env = {}, globalConfig = {}) {
  const nextEnv = { ...env };
  for (const [key, value] of Object.entries(sanitizeGlobalConfig(globalConfig))) {
    nextEnv[key] = value;
  }
  return nextEnv;
}

export function resolveGlobalSettingValues(env = {}) {
  return Object.fromEntries(
    GLOBAL_SETTING_KEYS.map((key) => [
      key,
      clean(env[key]) || GLOBAL_SETTING_DEFAULTS[key],
    ]),
  );
}

export function listGlobalOverrides(globalConfig = {}) {
  return GLOBAL_SETTING_KEYS.filter((key) => Boolean(globalConfig?.[key]));
}

function validateGlobalSettingValue(key, value) {
  if (URL_KEYS.has(key)) return safeHttpUrl(key, value);

  const enumValues = ENUM_VALUES[key];
  if (enumValues) {
    const normalized = value.toLowerCase();
    if (!enumValues.includes(normalized)) {
      throw new Error(`${key} 必须是 ${enumValues.join("、")} 之一`);
    }
    return normalized;
  }

  const integerRange = INTEGER_RANGES[key];
  if (integerRange) return numericValue(key, value, integerRange, true);

  const numberRange = NUMBER_RANGES[key];
  if (numberRange) return numericValue(key, value, numberRange, false);

  if (key === "PADDLEOCR_TIMEOUT_MS") {
    if (value.toLowerCase() === "auto") return "auto";
    return numericValue(key, value, [10_000, 3_600_000], true);
  }

  if (key === "VISIONOCR_TIMEOUT_MS") {
    if (value.toLowerCase() === "auto") return "auto";
    // Keep the persisted range aligned with MAX_TIMEOUT_MS in vision.mjs.
    return numericValue(key, value, [10_000, 1_800_000], true);
  }

  if (key === "VISIONOCR_LANGUAGE" || key === "PADDLEOCR_LANGUAGE") {
    return safeText(key, value, 120);
  }
  if (key.endsWith("_MODEL") || key.endsWith("_MODEL_VERSION")) {
    return safeText(key, value, 200);
  }
  if (key.endsWith("_PATH") || key.endsWith("_BINARY") || key === "SLATESYNC_CONFIG_PATH" || key === "PADDLE_PDX_CACHE_HOME") {
    return safeText(key, value, 2048);
  }
  return safeText(key, value, 200);
}

function numericValue(key, value, [minimum, maximum], integer) {
  const numeric = Number(value);
  if (!Number.isFinite(numeric) || (integer && !Number.isInteger(numeric)) || numeric < minimum || numeric > maximum) {
    const kind = integer ? "整数" : "数字";
    throw new Error(`${key} 必须是 ${minimum}–${maximum} 之间的${kind}`);
  }
  return String(numeric);
}

function safeHttpUrl(key, value) {
  let parsed;
  try {
    parsed = new URL(value);
  } catch {
    throw new Error(`${key} 必须是有效的 http(s) URL`);
  }
  if (!["http:", "https:"].includes(parsed.protocol)) {
    throw new Error(`${key} 只支持 http:// 或 https://`);
  }
  if (parsed.username || parsed.password || parsed.search || parsed.hash) {
    throw new Error(`${key} 不能包含账号、密码、查询参数或片段`);
  }
  return parsed.toString().replace(/\/$/, "");
}

function safeText(key, value, maximum) {
  if (value.length > maximum || /[\u0000-\u001f\u007f]/.test(value)) {
    throw new Error(`${key} 必须是 1–${maximum} 个不含控制字符的文本`);
  }
  return value;
}

function clean(value) {
  return typeof value === "string" ? value.trim() : "";
}

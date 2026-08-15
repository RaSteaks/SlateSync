// Provider, model, and workflow configuration.
//
// Declares the supported API providers (endpoint, env keys, transport) and the
// curated model catalog, resolves provider/model IDs against discovered models,
// loads and validates slatesync.config.json, and assembles the public config
// shape sent to the renderer.
import { readFile, stat } from "node:fs/promises";
import {
  describeProviderModel,
  registeredModel,
  validModelId,
} from "./model-catalog.mjs";
import { paddleOcrPublicConfig } from "./ocr/paddleocr.mjs";
import { visionOcrPublicConfig } from "./ocr/vision.mjs";

export const PROVIDERS = {
  openai: {
    id: "openai",
    label: "OpenAI 官方 API",
    envKey: "OPENAI_API_KEY",
    baseUrlEnv: "OPENAI_BASE_URL",
    defaultBaseUrl: "https://api.openai.com/v1",
    transport: "responses",
    requiredEnv: ["OPENAI_API_KEY"],
  },
  openrouter: {
    id: "openrouter",
    label: "OpenRouter API",
    envKey: "OPENROUTER_API_KEY",
    baseUrlEnv: "OPENROUTER_BASE_URL",
    defaultBaseUrl: "https://openrouter.ai/api/v1",
    transport: "chat-completions",
    requiredEnv: ["OPENROUTER_API_KEY"],
  },
  tokenplan: {
    id: "tokenplan",
    label: "阿里云 Token Plan",
    envKey: "TOKENPLAN_API_KEY",
    baseUrlEnv: "TOKENPLAN_BASE_URL",
    defaultBaseUrl: "https://dashscope.aliyuncs.com/compatible-mode/v1",
    transport: "chat-completions",
    chatJsonMode: "json_schema",
    supportsDirectPdf: false,
    requiredEnv: ["TOKENPLAN_API_KEY"],
  },
  dashscope: {
    id: "dashscope",
    label: "阿里云百炼（DashScope）",
    envKey: "DASHSCOPE_API_KEY",
    baseUrlEnv: "DASHSCOPE_BASE_URL",
    defaultBaseUrl: "https://dashscope.aliyuncs.com/compatible-mode/v1",
    transport: "chat-completions",
    chatJsonMode: "json_schema",
    supportsDirectPdf: false,
    requiredEnv: ["DASHSCOPE_API_KEY"],
  },
  "openai-compatible": {
    id: "openai-compatible",
    label: "OpenAI 兼容 API",
    envKey: "OPENAI_COMPATIBLE_API_KEY",
    baseUrlEnv: "OPENAI_COMPATIBLE_BASE_URL",
    modelEnv: "OPENAI_COMPATIBLE_MODEL",
    transportEnv: "OPENAI_COMPATIBLE_API_MODE",
    jsonModeEnv: "OPENAI_COMPATIBLE_JSON_MODE",
    imageDetailEnv: "OPENAI_COMPATIBLE_IMAGE_DETAIL",
    defaultBaseUrl: "",
    transport: "chat-completions",
    requiredEnv: [
      "OPENAI_COMPATIBLE_API_KEY",
      "OPENAI_COMPATIBLE_BASE_URL",
      "OPENAI_COMPATIBLE_MODEL",
    ],
  },
};

export const CUSTOM_MODEL_ID = "openai-compatible/custom";

export const DEFAULT_WORKFLOW_CONFIG = Object.freeze({
  slate: Object.freeze({
    maxDirectoryDepth: 4,
  }),
  resolve: Object.freeze({
    fieldFormats: Object.freeze({
      scene: "XXX",
      shot: "XX",
      take: "XX",
    }),
    comments: Object.freeze({
      goodTake: "_OK",
      holdTake: "_KP",
    }),
  }),
});

export const MODELS = [
  {
    id: "qwen/qwen3.7-flash",
    label: "Qwen 3.7 Flash",
    description: "快速中文视觉识别",
    providers: ["openrouter"],
    openRouterStructuredOutputs: false,
    qualityScore: 76,
    pricePerMillion: {
      openrouter: { input: 0.03, output: 0.13 },
    },
    price: "$0.03 / $0.13 每百万 token",
  },
  {
    id: "openai/gpt-5.6-luna",
    directId: "gpt-5.6-luna",
    imageDetail: "original",
    label: "GPT-5.6 Luna",
    description: "高吞吐视觉识别",
    providers: ["openai", "openrouter"],
    openRouterStructuredOutputs: true,
    qualityScore: 88,
    pricePerMillion: {
      openai: { input: 1, output: 6 },
      openrouter: { input: 0.5, output: 3 },
    },
    prices: {
      openai: "$1.00 / $6.00 每百万 token",
      openrouter: "$0.50 / $3.00 每百万 token · 当前促销价",
    },
    priceUpdatedAt: "2026-07-31",
  },
  {
    id: "openai/gpt-5.6-terra",
    directId: "gpt-5.6-terra",
    imageDetail: "original",
    label: "GPT-5.6 Terra",
    description: "高准确率视觉识别",
    providers: ["openai", "openrouter"],
    openRouterStructuredOutputs: true,
    qualityScore: 95,
    pricePerMillion: {
      openai: { input: 2.5, output: 15 },
      openrouter: { input: 1.25, output: 7.5 },
    },
    prices: {
      openai: "$2.50 / $15.00 每百万 token",
      openrouter: "$1.25 / $7.50 每百万 token · 当前促销价",
    },
    priceUpdatedAt: "2026-08-03",
  },
  {
    id: "openai/gpt-4o-mini",
    directId: "gpt-4o-mini",
    imageDetail: "high",
    label: "GPT-4o mini",
    description: "稳定基准模型",
    providers: ["openai", "openrouter"],
    openRouterStructuredOutputs: true,
    qualityScore: 74,
    pricePerMillion: {
      openai: { input: 0.15, output: 0.6 },
      openrouter: { input: 0.15, output: 0.6 },
    },
    price: "$0.15 / $0.60 每百万 token",
  },
  {
    id: "qwen3.7-plus",
    imageDetail: "high",
    label: "Qwen 3.7 Plus",
    description: "Token Plan 高质量中文视觉识别",
    providers: ["tokenplan"],
    qualityScore: 87,
    valueScore: 83,
  },
  {
    id: "qwen3.8-max",
    imageDetail: "high",
    label: "Qwen 3.8 Max",
    description: "百炼多模态旗舰 · 高精度视觉推理",
    providers: ["tokenplan", "dashscope"],
    qualityScore: 93,
    valueScore: 78,
  },
  {
    id: "qwen3.7-max",
    imageDetail: "high",
    label: "Qwen 3.7 Max",
    description: "百炼多模态视觉理解",
    providers: ["dashscope"],
    qualityScore: 91,
    valueScore: 80,
  },
  {
    id: "qwen3.6-flash",
    imageDetail: "high",
    label: "Qwen 3.6 Flash",
    description: "Token Plan 快速中文视觉识别",
    providers: ["tokenplan"],
    qualityScore: 76,
    valueScore: 88,
  },
  {
    id: "qwen3.6-plus",
    imageDetail: "high",
    label: "Qwen 3.6 Plus",
    description: "Token Plan 均衡视觉识别（团队版）",
    providers: ["tokenplan"],
    qualityScore: 84,
    valueScore: 85,
  },
  {
    id: "qwen-vl-max-latest",
    imageDetail: "high",
    label: "Qwen VL Max",
    description: "百炼高精度中文视觉理解",
    providers: ["dashscope"],
    qualityScore: 90,
    valueScore: 82,
  },
  {
    id: "qwen3-vl-plus-latest",
    imageDetail: "high",
    label: "Qwen3 VL Plus",
    description: "百炼均衡中文视觉识别",
    providers: ["dashscope"],
    qualityScore: 85,
    valueScore: 88,
  },
  {
    id: "qwen-vl-plus-latest",
    imageDetail: "high",
    label: "Qwen VL Plus",
    description: "百炼快速中文视觉识别",
    providers: ["dashscope"],
    qualityScore: 78,
    valueScore: 90,
  },
];

export function resolveProvider(providerId, env = process.env) {
  const provider = PROVIDERS[providerId];
  if (!provider) return null;
  if (providerId !== "openai-compatible") return provider;

  return {
    ...provider,
    transport: normalizeCompatibleTransport(env[provider.transportEnv]),
    chatJsonMode: normalizeCompatibleJsonMode(env[provider.jsonModeEnv]),
  };
}

export function resolveModel(providerId, requestedId, env = process.env) {
  const discovered = registeredModel(providerId, requestedId);
  if (discovered) return discovered;

  if (providerId === "openai-compatible") {
    if (requestedId !== CUSTOM_MODEL_ID) return null;
    const apiId = cleanEnv(env.OPENAI_COMPATIBLE_MODEL);
    if (!apiId) return null;
    return {
      ...compatibleModel(env),
      apiId,
    };
  }

  const model = MODELS.find((candidate) => candidate.id === requestedId);
  if (model?.providers.includes(providerId)) {
    return {
      ...model,
      apiId:
        providerId === "openai" ? model.directId || model.id : model.id,
    };
  }

  if (providerId === "openai" && validModelId(requestedId)) {
    const apiId = requestedId.replace(/^openai\//, "");
    return describeProviderModel(providerId, { id: apiId }, {
      publicId: `openai/${apiId}`,
    });
  }

  return null;
}

export async function loadWorkflowConfig(path) {
  let parsed;
  try {
    const source = await readFile(path, "utf8");
    parsed = JSON.parse(source.replace(/^\uFEFF/, ""));
  } catch (error) {
    throw new Error(`无法读取 SlateSync 配置文件 ${path}：${error.message}`);
  }
  return normalizeWorkflowConfig(parsed);
}

// Returns an async getter that re-reads slatesync.config.json whenever the
// file's mtime/size changes, so edits apply without restarting the process.
// A reload that fails (parse/validation error) keeps the last valid config.
export function createWorkflowConfigProvider(path) {
  let cache = null;
  return async function getWorkflowConfig() {
    let signature = "";
    try {
      const stats = await stat(path);
      signature = `${stats.mtimeMs}:${stats.size}`;
    } catch {
      return cache ? cache.config : loadWorkflowConfig(path);
    }
    if (cache && cache.signature === signature) return cache.config;
    try {
      const config = await loadWorkflowConfig(path);
      cache = { signature, config };
      return config;
    } catch (error) {
      if (cache) return cache.config;
      throw error;
    }
  };
}

export function normalizeWorkflowConfig(value = {}) {
  if (!value || typeof value !== "object" || Array.isArray(value)) {
    throw new Error("SlateSync 配置必须是 JSON 对象");
  }

  const requestedDepth = value.slate?.maxDirectoryDepth ??
    DEFAULT_WORKFLOW_CONFIG.slate.maxDirectoryDepth;
  const maxDirectoryDepth = Number(requestedDepth);
  if (
    !Number.isInteger(maxDirectoryDepth) ||
    maxDirectoryDepth < 1 ||
    maxDirectoryDepth > 12
  ) {
    throw new Error("slate.maxDirectoryDepth 必须是 1–12 的整数");
  }

  const configuredFormats = value.resolve?.fieldFormats || {};
  const fieldFormats = Object.fromEntries(
    Object.entries(DEFAULT_WORKFLOW_CONFIG.resolve.fieldFormats).map(
      ([field, fallback]) => [
        field,
        normalizeFieldFormat(configuredFormats[field] ?? fallback, field),
      ],
    ),
  );

  const configuredComments = value.resolve?.comments || {};
  const comments = Object.fromEntries(
    Object.entries(DEFAULT_WORKFLOW_CONFIG.resolve.comments).map(
      ([field, fallback]) => [
        field,
        normalizeCommentToken(
          configuredComments[field] ?? fallback,
          `resolve.comments.${field}`,
        ),
      ],
    ),
  );

  return {
    slate: { maxDirectoryDepth },
    resolve: { fieldFormats, comments },
  };
}

export function publicConfig(
  env = process.env,
  workflow = DEFAULT_WORKFLOW_CONFIG,
  options = {},
) {
  const normalizedWorkflow = normalizeWorkflowConfig(workflow);
  // When a caller passes a derived env (e.g. a runtime-key overlay), the
  // identity check against process.env would disable auto-enabled OCR;
  // expose an explicit override so status endpoints match recognition.
  const ocrAutoEnable = options.ocrAutoEnable ?? env === process.env;
  const { pythonPath: _privatePythonPath, ...ocr } = paddleOcrPublicConfig(env, {
    autoEnable: ocrAutoEnable,
  });
  const { binaryPath: _privateBinaryPath, ...vision } = visionOcrPublicConfig(env, {
    autoEnable: ocrAutoEnable,
  });
  return {
    providers: Object.values(PROVIDERS).map((provider) => ({
      id: provider.id,
      label: provider.label,
      configured: provider.requiredEnv.every((key) => Boolean(cleanEnv(env[key]))),
      requiredEnv: [...provider.requiredEnv],
    })),
    models: [...MODELS, compatibleModel(env)].map(withoutPricing),
    ocr,
    ocrEngines: [ocr, vision],
    upload: {
      acceptedTypes: [
        "image/jpeg",
        "image/png",
        "image/webp",
        "application/pdf",
      ],
      maxBytes: 20 * 1024 * 1024,
    },
    workflow: normalizedWorkflow,
  };
}

function compatibleModel(env) {
  const apiId = cleanEnv(env.OPENAI_COMPATIBLE_MODEL);
  return {
    id: CUSTOM_MODEL_ID,
    label: apiId || "自定义视觉模型",
    description: apiId
      ? `OpenAI 兼容模型：${apiId}`
      : "通过环境变量配置任意 OpenAI 兼容视觉模型",
    providers: ["openai-compatible"],
    imageDetail: normalizeImageDetail(env.OPENAI_COMPATIBLE_IMAGE_DETAIL),
    price: "价格由兼容 API 服务商决定",
  };
}

function normalizeCompatibleTransport(value) {
  return String(value || "").trim().toLowerCase() === "responses"
    ? "responses"
    : "chat-completions";
}

function normalizeCompatibleJsonMode(value) {
  const normalized = String(value || "").trim().toLowerCase();
  if (["json_schema", "json_object", "prompt"].includes(normalized)) {
    return normalized;
  }
  return "json_object";
}

function normalizeImageDetail(value) {
  const normalized = String(value || "").trim().toLowerCase();
  return ["auto", "low", "high", "original"].includes(normalized)
    ? normalized
    : "high";
}

function cleanEnv(value) {
  return typeof value === "string" ? value.trim() : "";
}

function normalizeFieldFormat(value, field) {
  const format = String(value || "").trim().toUpperCase();
  if (!/^X{1,6}$/.test(format)) {
    throw new Error(
      `resolve.fieldFormats.${field} 必须由 1–6 个 X 组成`,
    );
  }
  return format;
}

function normalizeCommentToken(value, field) {
  const token = typeof value === "string" ? value.trim() : "";
  if (!token || token.length > 32 || /[\r\n]/.test(token)) {
    throw new Error(
      `${field} 必须是 1–32 个字符、不含换行的非空文本`,
    );
  }
  return token;
}

function withoutPricing(model) {
  const publicModel = { ...model };
  delete publicModel.price;
  delete publicModel.prices;
  delete publicModel.pricePerMillion;
  delete publicModel.priceUpdatedAt;
  return publicModel;
}

const PRICE_DATE = "2026-08-02";

const OPENAI_MODEL_PROFILES = [
  profile(/^gpt-5\.6(?:-sol)?(?:-\d{4}-\d{2}-\d{2})?$/, "GPT-5.6 Sol", 100, 5, 30, "旗舰视觉理解"),
  profile(/^gpt-5\.6-terra(?:-\d{4}-\d{2}-\d{2})?$/, "GPT-5.6 Terra", 95, 2.5, 15, "高准确率视觉识别"),
  profile(/^gpt-5\.6-luna(?:-\d{4}-\d{2}-\d{2})?$/, "GPT-5.6 Luna", 88, 1, 6, "高吞吐视觉识别"),
  profile(/^gpt-5\.5-pro(?:-\d{4}-\d{2}-\d{2})?$/, "GPT-5.5 Pro", 98, null, null, "高准确率专业模型"),
  profile(/^gpt-5\.5(?:-\d{4}-\d{2}-\d{2})?$/, "GPT-5.5", 95, null, null, "高准确率通用模型"),
  profile(/^gpt-5\.4-pro(?:-\d{4}-\d{2}-\d{2})?$/, "GPT-5.4 Pro", 97, null, null, "高准确率专业模型"),
  profile(/^gpt-5\.4-mini(?:-\d{4}-\d{2}-\d{2})?$/, "GPT-5.4 mini", 89, 0.75, 4.5, "快速视觉识别"),
  profile(/^gpt-5\.4-nano(?:-\d{4}-\d{2}-\d{2})?$/, "GPT-5.4 nano", 76, 0.2, null, "轻量批量识别"),
  profile(/^gpt-5\.4(?:-\d{4}-\d{2}-\d{2})?$/, "GPT-5.4", 94, 2.5, 15, "高准确率视觉理解"),
  profile(/^gpt-5\.2-pro(?:-\d{4}-\d{2}-\d{2})?$/, "GPT-5.2 Pro", 94, null, null, "上一代专业模型"),
  profile(/^gpt-5\.2(?:-\d{4}-\d{2}-\d{2})?$/, "GPT-5.2", 90, 1.75, null, "上一代高质量模型"),
  profile(/^gpt-5\.1(?:-\d{4}-\d{2}-\d{2})?$/, "GPT-5.1", 87, null, null, "上一代通用模型"),
  profile(/^gpt-5-pro(?:-\d{4}-\d{2}-\d{2})?$/, "GPT-5 Pro", 92, null, null, "质量优先推理模型"),
  profile(/^gpt-5-mini(?:-\d{4}-\d{2}-\d{2})?$/, "GPT-5 mini", 84, 0.25, 2, "轻量精确任务"),
  profile(/^gpt-5-nano(?:-\d{4}-\d{2}-\d{2})?$/, "GPT-5 nano", 72, null, null, "低延迟批量任务"),
  profile(/^gpt-5(?:-\d{4}-\d{2}-\d{2})?$/, "GPT-5", 88, 1.25, 10, "通用视觉推理"),
  profile(/^o3-pro(?:-\d{4}-\d{2}-\d{2})?$/, "o3-pro", 91, null, null, "质量优先视觉推理"),
  profile(/^o3(?:-\d{4}-\d{2}-\d{2})?$/, "o3", 87, null, null, "视觉推理模型"),
  profile(/^o4-mini(?:-\d{4}-\d{2}-\d{2})?$/, "o4-mini", 83, null, null, "快速视觉推理"),
  profile(/^gpt-4\.1-mini(?:-\d{4}-\d{2}-\d{2})?$/, "GPT-4.1 mini", 79, 0.4, 1.6, "快速视觉理解"),
  profile(/^gpt-4\.1-nano(?:-\d{4}-\d{2}-\d{2})?$/, "GPT-4.1 nano", 68, null, null, "轻量视觉理解"),
  profile(/^gpt-4\.1(?:-\d{4}-\d{2}-\d{2})?$/, "GPT-4.1", 85, 2, 8, "稳定视觉理解"),
  profile(/^gpt-4o-mini(?:-\d{4}-\d{2}-\d{2})?$/, "GPT-4o mini", 74, 0.15, 0.6, "稳定轻量基准"),
  profile(/^gpt-4o(?:-\d{4}-\d{2}-\d{2})?$/, "GPT-4o", 84, 2.5, 10, "上一代视觉模型"),
];

const discoveredModels = new Map();

export function describeOpenAiVisionModel(apiId) {
  const cleanId = normalizeModelId(apiId).replace(/^openai\//, "");
  if (!cleanId || excludedOpenAiModel(cleanId)) return null;
  const match = OPENAI_MODEL_PROFILES.find((candidate) =>
    candidate.pattern.test(cleanId),
  );
  if (!match) return null;
  return descriptorFromProfile(match, cleanId);
}

export function describeProviderModel(providerId, apiModel, options = {}) {
  const apiId = normalizeModelId(apiModel?.id || apiModel);
  if (!apiId) return null;
  if (!options.fixed && excludedRecognitionModel(apiId)) return null;
  const architecture = apiModel?.architecture || {};
  const inputModalities = normalizeModalities(architecture.input_modalities);
  const outputModalities = normalizeModalities(architecture.output_modalities);
  const hasDeclaredModalities = inputModalities.length > 0 || outputModalities.length > 0;

  let profile = describeOpenAiVisionModel(apiId);
  if (providerId === "openrouter") {
    if (
      hasDeclaredModalities &&
      (!inputModalities.includes("image") || !outputModalities.includes("text"))
    ) {
      return null;
    }
    if (!hasDeclaredModalities && !profile && !options.fixed) return null;
    profile ||= describeThirdPartyVisionModel(apiId);
  } else if (providerId === "openai") {
    if (!profile) return null;
  } else if (providerId === "openai-compatible") {
    const configuredId = normalizeModelId(options.configuredModelId);
    if (
      hasDeclaredModalities &&
      (!inputModalities.includes("image") || !outputModalities.includes("text"))
    ) {
      return null;
    }
    if (!hasDeclaredModalities && apiId !== configuredId && !profile) return null;
    profile ||= describeThirdPartyVisionModel(apiId);
  } else if (providerId === "tokenplan" || providerId === "dashscope") {
    if (
      hasDeclaredModalities &&
      (!inputModalities.includes("image") || !outputModalities.includes("text"))
    ) {
      return null;
    }
    if (
      !hasDeclaredModalities &&
      !options.fixed &&
      !knownDashScopeVisionModel(apiId)
    ) {
      return null;
    }
    profile ||= describeThirdPartyVisionModel(apiId);
  } else {
    return null;
  }

  const remotePricing = parseRemotePricing(apiModel?.pricing);
  const inputPrice = remotePricing.input ?? options.inputPrice ?? profile.inputPrice;
  const outputPrice =
    remotePricing.output ?? options.outputPrice ?? profile.outputPrice;
  const qualityScore = options.qualityScore ?? profile.qualityScore;
  const valueScore = options.valueScore ??
    calculateValueScore(qualityScore, inputPrice, outputPrice);
  const supportedParameters = Array.isArray(apiModel?.supported_parameters)
    ? apiModel.supported_parameters
    : [];

  return {
    id: publicModelId(providerId, apiId, options.publicId),
    apiId,
    label:
      options.label || modelLabel(profile.label || prettifyModelId(apiId), apiId),
    description: options.description || profile.description,
    providers: [providerId],
    fixed: Boolean(options.fixed),
    fixedPriority: Number.isFinite(options.fixedPriority)
      ? options.fixedPriority
      : null,
    discovered: true,
    verifiedAvailable: true,
    imageDetail: options.imageDetail || profile.imageDetail || "high",
    qualityScore,
    qualityLabel: qualityLabel(qualityScore),
    valueScore,
    valueLabel: valueLabel(valueScore),
    pricePerMillion: {
      input: inputPrice,
      output: outputPrice,
    },
    price: formatPrice(inputPrice, outputPrice),
    priceUpdatedAt:
      remotePricing.input != null || remotePricing.output != null
        ? "API 实时"
        : options.priceUpdatedAt || profile.priceUpdatedAt,
    openRouterStructuredOutputs:
      providerId === "openrouter"
        ? supportsStructuredOutputs(supportedParameters, options)
        : true,
  };
}

export function sortVisionModels(models) {
  return [...models].sort((left, right) => {
    if (left.fixed !== right.fixed) return left.fixed ? -1 : 1;
    if (left.fixed && right.fixed) {
      return (
        (left.fixedPriority ?? Number.MAX_SAFE_INTEGER) -
          (right.fixedPriority ?? Number.MAX_SAFE_INTEGER) ||
        left.label.localeCompare(right.label, "zh-CN")
      );
    }
    return (
      (right.valueScore ?? 0) - (left.valueScore ?? 0) ||
      (right.qualityScore ?? 0) - (left.qualityScore ?? 0) ||
      comparablePrice(left) - comparablePrice(right) ||
      left.label.localeCompare(right.label, "zh-CN")
    );
  });
}

export function registerDiscoveredModels(providerId, models) {
  const entries = new Map();
  for (const model of models || []) {
    entries.set(model.id, model);
  }
  discoveredModels.set(providerId, entries);
}

export function registeredModel(providerId, publicId) {
  return discoveredModels.get(providerId)?.get(publicId) || null;
}

export function validModelId(value) {
  return (
    typeof value === "string" &&
    value.length >= 1 &&
    value.length <= 220 &&
    /^[A-Za-z0-9][A-Za-z0-9._:/@-]*$/.test(value)
  );
}

function profile(pattern, label, qualityScore, inputPrice, outputPrice, description) {
  return {
    pattern,
    label,
    qualityScore,
    inputPrice,
    outputPrice,
    description,
    imageDetail: /^GPT-5\.6/.test(label) ? "original" : "high",
    priceUpdatedAt: PRICE_DATE,
  };
}

function descriptorFromProfile(profileValue, apiId) {
  return {
    ...profileValue,
    pattern: undefined,
    apiId,
  };
}

function describeThirdPartyVisionModel(apiId) {
  const id = apiId.toLowerCase();
  let qualityScore = 70;
  let description = "API 声明支持图像输入与文本输出";

  if (/qwen3\.8-max/.test(id)) {
    qualityScore = 93;
    description = "高精度中文视觉推理";
  } else if (/qwen3\.7-max/.test(id)) {
    qualityScore = 91;
    description = "高精度多模态视觉理解";
  } else if (/qwen3\.7[-/](?:plus|flash)|qwen3\.7-(?:plus|flash)/.test(id)) {
    qualityScore = id.includes("plus") ? 87 : 76;
    description = id.includes("plus")
      ? "高质量中文视觉识别"
      : "快速中文视觉识别";
  } else if (/qwen3\.6-(?:plus|flash)/.test(id)) {
    qualityScore = id.includes("plus") ? 84 : 76;
    description = id.includes("plus")
      ? "均衡中文视觉识别"
      : "快速中文视觉识别";
  } else if (/qwen3-vl/.test(id)) {
    qualityScore = 84;
    description = "均衡中文视觉识别";
  } else if (/qwen.*(?:vl|vision)/.test(id)) {
    qualityScore = id.includes("thinking") ? 84 : 79;
    description = "中文文档与 OCR 视觉模型";
  } else if (/claude.*opus/.test(id)) {
    qualityScore = 97;
    description = "质量优先视觉理解";
  } else if (/claude.*sonnet/.test(id)) {
    qualityScore = 91;
    description = "高质量视觉理解";
  } else if (/claude.*haiku/.test(id)) {
    qualityScore = 77;
    description = "快速视觉理解";
  } else if (/gemini.*pro/.test(id)) {
    qualityScore = 94;
    description = "高质量多模态理解";
  } else if (/gemini.*flash/.test(id)) {
    qualityScore = id.includes("lite") ? 74 : 86;
    description = "高吞吐多模态识别";
  } else if (/grok/.test(id)) {
    qualityScore = 88;
    description = "通用多模态理解";
  } else if (/minimax/.test(id)) {
    qualityScore = 85;
    description = "通用多模态理解";
  } else if (/gemma/.test(id)) {
    qualityScore = 76;
    description = "开放视觉模型";
  } else if (/pixtral|mistral.*(?:vision|small)/.test(id)) {
    qualityScore = 78;
    description = "开放视觉理解模型";
  }

  return {
    label: prettifyModelId(apiId),
    description,
    qualityScore,
    inputPrice: null,
    outputPrice: null,
    imageDetail: "high",
    priceUpdatedAt: null,
  };
}

function knownTokenPlanVisionModel(apiId) {
  return /^qwen3\.(?:8-max(?:-preview)?|7-plus|6-(?:plus|flash))(?:-\d{4}-\d{2}-\d{2})?$/i.test(
    apiId,
  );
}

function knownDashScopeVisionModel(apiId) {
  return /^qwen(?:\d(?:\.\d+)?)?-vl(?:-[\w.-]+)?$/i.test(apiId) ||
    /^qwen-vl-(?:max|plus)(?:-[\w.-]+)?$/i.test(apiId) ||
    // BaiLian multimodal flagships: qwen3.8-max and the vision-enabled
    // qwen3.7-max snapshots carry image understanding without a -vl suffix.
    /^qwen3\.(?:8-max|7-max)(?:-[\w.-]+)?$/i.test(apiId);
}

function excludedOpenAiModel(id) {
  return /(?:audio|realtime|transcrib|tts|image|embedding|moderation|search|deep-research|codex|computer-use|chat-latest)/i.test(
    id,
  );
}

function excludedRecognitionModel(id) {
  return /(?:^|[/:._-])(?:audio|realtime|transcrib(?:e|er|ing)?|tts|image(?:s)?|embedding(?:s)?|moderation|search|deep-research|codex|computer-use)(?:$|[/:._-])/i.test(
    id,
  );
}

function normalizeModalities(value) {
  return Array.isArray(value)
    ? value.map((item) => String(item).trim().toLowerCase()).filter(Boolean)
    : [];
}

function parseRemotePricing(pricing) {
  return {
    input: perTokenToMillion(pricing?.prompt ?? pricing?.input),
    output: perTokenToMillion(pricing?.completion ?? pricing?.output),
  };
}

function perTokenToMillion(value) {
  if (value == null || value === "") return null;
  const numeric = Number(value);
  return Number.isFinite(numeric) && numeric >= 0 ? numeric * 1_000_000 : null;
}

function supportsStructuredOutputs(parameters, options) {
  if (typeof options.openRouterStructuredOutputs === "boolean") {
    return options.openRouterStructuredOutputs;
  }
  return parameters.some((parameter) =>
    ["response_format", "structured_outputs"].includes(String(parameter)),
  );
}

function calculateValueScore(qualityScore, inputPrice, outputPrice) {
  const effectivePrice =
    inputPrice == null && outputPrice == null
      ? null
      : (inputPrice || 0) + (outputPrice || 0) * 0.2;
  const costScore =
    effectivePrice == null
      ? 50
      : Math.max(20, 100 - 28 * Math.log10(1 + effectivePrice));
  return Math.round(qualityScore * 0.7 + costScore * 0.3);
}

function qualityLabel(score) {
  if (score >= 96) return "S";
  if (score >= 90) return "A+";
  if (score >= 84) return "A";
  if (score >= 77) return "B+";
  return "B";
}

function valueLabel(score) {
  if (score >= 90) return "S";
  if (score >= 84) return "A+";
  if (score >= 78) return "A";
  if (score >= 70) return "B+";
  return "B";
}

function comparablePrice(model) {
  const input = model.pricePerMillion?.input;
  const output = model.pricePerMillion?.output;
  return input == null && output == null
    ? Number.MAX_SAFE_INTEGER
    : (input || 0) + (output || 0) * 0.2;
}

function formatPrice(inputPrice, outputPrice) {
  if (inputPrice == null && outputPrice == null) return "价格未知";
  return `$${formatNumber(inputPrice)} / $${formatNumber(outputPrice)} 每百万 token`;
}

function formatNumber(value) {
  if (value == null) return "?";
  if (value === 0) return "0";
  return Number(value.toFixed(4)).toString();
}

function publicModelId(providerId, apiId, explicitId) {
  if (explicitId) return explicitId;
  if (providerId === "openai") return `openai/${apiId.replace(/^openai\//, "")}`;
  return apiId;
}

function prettifyModelId(apiId) {
  const name = apiId.split("/").at(-1) || apiId;
  return name
    .split("-")
    .map((part) => (/^\d/.test(part) ? part : part.charAt(0).toUpperCase() + part.slice(1)))
    .join(" ");
}

function modelLabel(baseLabel, apiId) {
  const snapshot = apiId.match(/-(\d{4}-\d{2}-\d{2})$/)?.[1];
  return snapshot ? `${baseLabel} · ${snapshot}` : baseLabel;
}

function normalizeModelId(value) {
  return typeof value === "string" ? value.trim() : "";
}

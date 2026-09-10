// Model description, curation, and ranking.
//
// Maps a provider-returned model id to a user-facing descriptor (label, quality
// and value scores, price) using static profiles for known OpenAI/Qwen models
// plus heuristics for third-party models, and ranks the resulting list for the
// UI.
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
const discoveredRevisions = new Map();

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
  const inputModalities = modelModalities(apiModel, "input");
  const outputModalities = modelModalities(apiModel, "output");
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
  } else if (providerId === "openai-compatible" || options.customProvider) {
    const configuredId = normalizeModelId(options.configuredModelId);
    if (
      hasDeclaredModalities &&
      (!inputModalities.includes("image") || !outputModalities.includes("text"))
    ) {
      return null;
    }
    if (!hasDeclaredModalities && apiId !== configuredId && !profile && !options.allowUnknown) return null;
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
  const qualityScore = options.qualityScore ?? profile.qualityScore ?? null;
  const valueScore = options.valueScore ??
    calculateValueScore(qualityScore, inputPrice, outputPrice);
  const supportedParameters = Array.isArray(apiModel?.supported_parameters)
    ? apiModel.supported_parameters
    : [];

  return {
    id: publicModelId(providerId, apiId, options.publicId),
    apiId,
    // OpenRouter model IDs are normally vendor/model. Keep the vendor on the
    // descriptor so every Renderer can group the long catalog consistently,
    // while still deriving a stable fallback when the API omits owned_by.
    vendor: modelVendor(apiId, apiModel?.owned_by || apiModel?.ownedBy || apiModel?.owner || apiModel?.vendor || apiModel?.organization || apiModel?.provider || apiModel?.provider_id || apiModel?.publisher || apiModel?.creator),
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
    qualitySource: qualityScore != null ? "SlateSync 维护的模型族参考评级" : null,
    qualityUpdatedAt: qualityScore != null
      ? (options.qualityUpdatedAt || profile.qualityUpdatedAt || profile.priceUpdatedAt || PRICE_DATE)
      : null,
    valueSource: valueScore != null
      ? (remotePricing.input != null || remotePricing.output != null ? "接口实时价格" : "内置价格目录")
      : null,
    valueUpdatedAt: valueScore != null
      ? (remotePricing.input != null || remotePricing.output != null ? new Date().toISOString() : options.priceUpdatedAt || profile.priceUpdatedAt)
      : null,
    capabilityStatus: options.capabilityStatus || (hasDeclaredModalities ? "declared" : "inferred"),
    capabilitySource: options.capabilitySource || (hasDeclaredModalities ? "API architecture" : "maintained model family"),
    capabilityCheckedAt: options.capabilityCheckedAt || null,
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

function modelVendor(apiId, ownedBy) {
  const rawOwner = ownedBy && typeof ownedBy === "object"
    ? (ownedBy.id || ownedBy.name || ownedBy.slug || "")
    : ownedBy;
  const declared = String(rawOwner || "").trim();
  if (declared) return declared.toLowerCase().replace(/\s+/g, "-");
  const rawId = String(apiId || "");
  const prefix = rawId.includes("/") ? rawId.split("/", 1)[0].trim() : "";
  if (prefix) return prefix.toLowerCase();
  const family = rawId.toLowerCase();
  if (/^(gpt|o[34])/.test(family)) return "openai";
  if (/qwen/.test(family)) return "qwen";
  if (/claude/.test(family)) return "anthropic";
  if (/gemini|gemma/.test(family)) return "google";
  if (/deepseek/.test(family)) return "deepseek";
  if (/llama/.test(family)) return "meta";
  if (/mistral|pixtral/.test(family)) return "mistralai";
  if (/minimax/.test(family)) return "minimax";
  return "other";
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
      nullableScore(right.valueScore, left.valueScore) ||
      nullableScore(right.qualityScore, left.qualityScore) ||
      comparablePrice(left) - comparablePrice(right) ||
      left.label.localeCompare(right.label, "zh-CN")
    );
  });
}

export function registerDiscoveredModels(providerId, models, revision = null) {
  // A slower discovery response from an older connection revision must not
  // overwrite a newer registration that is already eligible for recognition.
  if (discoveredRevisions.has(providerId)) {
    const previousRevision = discoveredRevisions.get(providerId);
    if (
      (revision == null && previousRevision != null) ||
      (revision != null && previousRevision != null && Number(revision) < Number(previousRevision))
    ) return;
  }
  const entries = new Map();
  for (const model of models || []) {
    entries.set(model.id, model);
    // A legacy alias is the public key, but older project snapshots may have
    // stored the physical API ID. Keep both lookup keys without creating a
    // second model/count entry in discovery results.
    if (model.apiId && !entries.has(model.apiId)) entries.set(model.apiId, model);
  }
  discoveredModels.set(providerId, entries);
  // `null` is an intentional unversioned sentinel. Deleting the entry would
  // let a null-revision registration satisfy a later revisioned lookup.
  discoveredRevisions.set(providerId, revision == null ? null : Number(revision));
}

export function registeredModel(providerId, publicId, revision = null) {
  if (!discoveredModels.has(providerId) || !discoveredRevisions.has(providerId)) return null;
  const registeredRevision = discoveredRevisions.get(providerId);
  if (
    (revision == null && registeredRevision != null) ||
    (revision != null && registeredRevision !== Number(revision))
  ) return null;
  return discoveredModels.get(providerId)?.get(publicId) || null;
}

export function clearRegisteredModels(providerId) {
  if (providerId) {
    discoveredModels.delete(providerId);
    discoveredRevisions.delete(providerId);
  } else {
    discoveredModels.clear();
    discoveredRevisions.clear();
  }
}

export function validModelId(value) {
  return (
    typeof value === "string" &&
    value.length >= 1 &&
    value.length <= 220 &&
    /^[A-Za-z0-9][A-Za-z0-9._:/@-]*$/.test(value)
  );
}

/** IDs known to represent non-recognition models (audio, embeddings, image generation, etc.). */
export function excludedModelId(value) {
  return excludedRecognitionModel(String(value || ""));
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
  // Unknown families must remain explicitly unrated; a synthetic B score is
  // misleading when a provider only declares image/text modalities.
  let qualityScore = null;
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
  } else if (/claude-(?:3|4).*opus/.test(id)) {
    qualityScore = 97;
    description = "质量优先视觉理解";
  } else if (/claude-(?:3|4).*sonnet/.test(id)) {
    qualityScore = 91;
    description = "高质量视觉理解";
  } else if (/claude-(?:3|4).*haiku/.test(id)) {
    qualityScore = 77;
    description = "快速视觉理解";
  } else if (/gemini.*(?:pro|ultra|vision)/.test(id)) {
    qualityScore = 94;
    description = "高质量多模态理解";
  } else if (/gemini.*flash/.test(id)) {
    qualityScore = id.includes("lite") ? 74 : 86;
    description = "高吞吐多模态识别";
  } else if (/grok-(?:2|3|vision)/.test(id)) {
    qualityScore = 88;
    description = "通用多模态理解";
  } else if (/minimax.*(?:vl|vision)/.test(id)) {
    qualityScore = 85;
    description = "通用多模态理解";
  } else if (/gemma[-./]?3(?:[-./](?:4b|12b|27b|vision))/.test(id)) {
    qualityScore = 76;
    description = "开放视觉模型";
  } else if (/llama.*vision/.test(id)) {
    qualityScore = 78;
    description = "开放视觉理解模型";
  } else if (/pixtral|mistral.*vision/.test(id)) {
    qualityScore = 78;
    description = "开放视觉理解模型";
  }

  return {
    label: prettifyModelId(apiId),
    description,
    qualityScore,
    // The catalog's quality references are maintained separately from live
    // billing data. Keep a dated source for known families while leaving the
    // price timestamp null so value ratings still require real pricing.
    qualityUpdatedAt: qualityScore != null ? PRICE_DATE : null,
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
  return /(?:audio|realtime|whisper|speech|asr|stt|transcrib|transcription|tts|image|dall-e|imagen|stable-diffusion|imagegen|text-to-image|flux|sdxl|midjourney|embedding|moderation|search|deep-research|codex|computer-use|chat-latest)/i.test(
    id,
  );
}

function excludedRecognitionModel(id) {
  // Keep common speech aliases (Whisper/STT/ASR/transcription) alongside the
  // explicit audio family so a multimodal selector never offers non-text
  // endpoints that happen to omit the word "audio" from their ID.
  return /(?:^|[/:._-])(?:audio|realtime|whisper|speech|asr|stt|transcrib(?:e|er|ing|tion)?|tts|image(?:s)?|dall-e|imagen|stable-diffusion|imagegen|text-to-image|flux|sdxl|midjourney|embedding(?:s)?|moderation|search|deep-research|codex|computer-use)(?:$|[/:._-])/i.test(
    id,
  );
}

export function modelModalities(apiModel, direction) {
  const architecture = apiModel?.architecture || {};
  const capabilityFlags = capabilityFlagModalities(apiModel, direction);
  const candidates = [
    architecture[`${direction}_modalities`],
    architecture[`${direction}Modalities`],
    architecture[direction],
    architecture[`${direction}_types`],
    architecture[`${direction}_type`],
    architecture?.[direction]?.type,
    architecture?.[direction]?.modality,
    architecture?.[direction]?.modalities,
    architecture?.[direction]?.types,
    apiModel?.[`${direction}_modalities`],
    apiModel?.[`${direction}Modalities`],
    apiModel?.[`${direction}_types`],
    apiModel?.[`${direction}Types`],
    apiModel?.[`${direction}Type`],
    apiModel?.[`${direction}_type`],
    apiModel?.[direction],
    apiModel?.[`${direction}s`],
    apiModel?.[direction]?.modalities,
    apiModel?.[direction]?.types,
    apiModel?.[direction]?.type,
    apiModel?.capabilities?.[direction],
    apiModel?.capabilities?.[direction]?.modality,
    apiModel?.capabilities?.[direction]?.modalities,
    apiModel?.capabilities?.[direction]?.types,
    apiModel?.capabilities?.[`${direction}_modalities`],
    apiModel?.capabilities?.[`${direction}Modalities`],
    Array.isArray(apiModel?.capabilities) ? apiModel.capabilities : null,
    capabilityFlags,
    apiModel?.modality,
    architecture?.modality,
    architecture?.type,
    architecture?.modalities,
    apiModel?.modalities?.[direction],
    apiModel?.modalities?.[`${direction}_modalities`],
    // Some OpenAI-compatible servers expose one shared `modalities` array;
    // treat it as the advertised capability set for both directions.
    Array.isArray(apiModel?.modalities) ? apiModel.modalities : null,
    apiModel?.types?.[direction],
    apiModel?.types?.[`${direction}_modalities`],
    architecture?.modalities?.[direction],
    architecture?.modalities?.[`${direction}_modalities`],
    architecture?.types?.[direction],
    architecture?.types?.[`${direction}_modalities`],
  ];
  for (const candidate of candidates) {
    const normalized = normalizeModalities(candidate);
    if (normalized.length) return normalized;
  }
  return [];
}

function capabilityFlagModalities(apiModel, direction) {
  const capabilities = apiModel?.capabilities && typeof apiModel.capabilities === "object"
    ? apiModel.capabilities
    : {};
  const flags = [];
  const imageKeys = direction === "input"
    ? ["vision", "image", "images", "image_input", "input_image", "supports_vision", "supports_image_input"]
    : ["vision_output", "image_output", "output_image", "supports_image_output"];
  const textKeys = direction === "input"
    ? ["text", "text_input", "input_text", "supports_text_input"]
    : ["text", "text_output", "output_text", "text_generation", "supports_text_output"];
  if (imageKeys.some((key) => capabilities[key] === true) ||
      (direction === "input" && apiModel?.supports_vision === true)) flags.push("image");
  if (textKeys.some((key) => capabilities[key] === true) ||
      (direction === "output" && apiModel?.supports_text === true)) flags.push("text");
  return flags;
}

function normalizeModalities(value) {
  const values = Array.isArray(value)
    ? value
    : typeof value === "string"
      ? value.split(/[\s,]+/)
      : value && typeof value === "object"
        ? [value.modality, value.type, value.name, value.id]
        : [];
  return values.map((item) => {
    const normalized = String(item).trim().toLowerCase();
    if (["vision", "visions", "images", "image", "image_input", "input_image", "multimodal"].includes(normalized)) return "image";
    if (["text_generation", "text-generation", "text_output", "text", "output_text", "text_input", "input_text"].includes(normalized)) return "text";
    return normalized;
  }).filter(Boolean);
}

function parseRemotePricing(pricing) {
  return {
    // Compatible gateways mirror OpenRouter's prompt/completion keys, but
    // some return explicit input_per_token/output_per_token aliases.
    input: perTokenToMillion(pricing?.prompt ?? pricing?.input ?? pricing?.input_per_token ?? pricing?.inputPerToken),
    output: perTokenToMillion(pricing?.completion ?? pricing?.output ?? pricing?.output_per_token ?? pricing?.outputPerToken),
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

export function calculateValueScore(qualityScore, inputPrice, outputPrice) {
  if (qualityScore == null || (inputPrice == null && outputPrice == null)) return null;
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

export function qualityLabel(score) {
  if (score == null) return "精度暂无数据";
  if (score >= 96) return "S";
  if (score >= 90) return "A+";
  if (score >= 84) return "A";
  if (score >= 77) return "B+";
  return "B";
}

export function valueLabel(score) {
  if (score == null) return "价格未知";
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

function nullableScore(right, left) {
  if (right == null && left == null) return 0;
  // Missing ratings are unknown, not a recommendation. Keep scored models
  // ahead of unrated discoveries so a picker does not promote arbitrary
  // models merely because their score is unavailable.
  if (right == null) return -1;
  if (left == null) return 1;
  return right - left;
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

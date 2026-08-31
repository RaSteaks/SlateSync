// Live model discovery against provider /models endpoints.
//
// Fetches each provider's model list, filters to vision-capable models via
// lib/model-catalog.mjs, merges the curated fixed models, caches the result
// briefly, and falls back to static models on failure.
import {
  CUSTOM_MODEL_ID,
  MODELS,
  publicConfig,
  resolveProvider,
} from "./config.mjs";
import {
  describeOpenAiVisionModel,
  describeProviderModel,
  excludedModelId,
  modelModalities,
  registerDiscoveredModels,
  sortVisionModels,
  validModelId,
} from "./model-catalog.mjs";
import { customModelDescriptor, legacyProviderModelId } from "./provider-registry.mjs";

const DISCOVERY_TIMEOUT_MS = 15_000;
const CACHE_TTL_MS = 5 * 60 * 1000;
const cache = new Map();

export async function discoverVisionModels(
  providerId,
  options = {},
) {
  const env = options.env || process.env;
  const fetchImpl = options.fetchImpl || fetch;
  const registry = options.registry;
  const provider = registry?.resolveProvider(providerId) || resolveProvider(providerId, env);
  if (!provider) throw discoveryError("未知 API 服务商", 400);

  const missing = (provider.requiredEnv || []).filter(
    (key) => !String(env[key] || "").trim(),
  );
  if (missing.length) {
    throw discoveryError(`尚未配置 ${missing.join("、")}`, 400);
  }

  const baseUrl = normalizeBaseUrl(
    provider.baseUrl || env[provider.baseUrlEnv] || provider.defaultBaseUrl,
    provider.baseUrlEnv || "Base URL",
  );
  // The compatible provider's fixed descriptor contains its configured API
  // model, so changing that global setting must not reuse the prior snapshot.
  const configuredModelId = providerId === "openai-compatible"
    ? (provider.customProvider
      ? legacyProviderModelId(provider.customProvider)
      : String(env.OPENAI_COMPATIBLE_MODEL || "").trim())
    : null;
  const cacheKey = JSON.stringify([providerId, baseUrl, configuredModelId, provider.revision || null]);
  const cached = cache.get(cacheKey);
  if (
    options.cache !== false &&
    !options.forceRefresh &&
    cached &&
    Date.now() - cached.createdAt < CACHE_TTL_MS
  ) {
    return cached.value;
  }

  const apiKey = registry?.getApiKey
    ? registry.getApiKey(providerId)
    : String(env[provider.envKey] || "").trim();
  let payload;
  let modelsEndpointAvailable = true;
  try {
    payload = await fetchModelList({
      provider,
      baseUrl,
      apiKey,
      env,
      fetchImpl,
    });
  } catch (error) {
    // Some local gateways intentionally omit GET /models. Manual IDs remain
    // valid in that case and are returned as pending instead of being hidden
    // behind a hard discovery error.
    if (provider.custom && [404, 405, 501].includes(Number(error?.status))) {
      payload = {};
      modelsEndpointAvailable = false;
    } else {
      throw error;
    }
  }
  let apiModels = null;
  if (Array.isArray(payload?.data)) apiModels = payload.data;
  else if (Array.isArray(payload?.models)) apiModels = payload.models;
  else if (provider.custom) {
    modelsEndpointAvailable = false;
    apiModels = [];
  }
  if (!apiModels) {
    throw discoveryError(`${provider.label} 没有返回有效的模型列表`, 502);
  }

  const fixedModels = provider.custom
    ? []
    : providerFixedModels(providerId, env);
  const discovered = [];
  const pendingModels = [];
  const failedModels = [];
  const unsupportedModels = [];
  const apiUnsupportedIds = new Set();
  const apiFailedIds = new Set();
  let unsupportedModelCount = 0;
  for (const apiModel of apiModels) {
    const apiId = modelIdFromPayload(apiModel);
    if (!apiId) continue;
    if (!validModelId(apiId)) {
      unsupportedModels.push({ id: apiId.slice(0, 220), reason: "模型 ID 无效", capabilityStatus: "unsupported" });
      apiUnsupportedIds.add(apiId.slice(0, 220));
      continue;
    }
    const normalizedApiModel = typeof apiModel === "string"
      ? { id: apiId }
      : { ...(apiModel || {}), id: apiId };
    if (excludedModelId(apiId)) {
      unsupportedModels.push({ id: apiId, reason: unsupportedReason(normalizedApiModel), capabilityStatus: "unsupported" });
      apiUnsupportedIds.add(apiId);
      continue;
    }
    const fixed = fixedModels.find((candidate) => candidate.apiId === apiId);
    const descriptor = describeDiscoveredModel(providerId, normalizedApiModel, {
      provider,
      configuredModelId: env.OPENAI_COMPATIBLE_MODEL,
      apiKey,
      ...(fixed || {}),
    });
    if (descriptor?.capabilityStatus === "pending" || descriptor?.capabilityStatus === "canceled") pendingModels.push(descriptor);
    else if (descriptor?.capabilityStatus === "failed") failedModels.push(descriptor);
    else if (descriptor) discovered.push(descriptor);
    else {
      unsupportedModels.push({ id: apiId, reason: unsupportedReason(normalizedApiModel), capabilityStatus: "unsupported" });
      apiUnsupportedIds.add(apiId);
    }
    if (descriptor?.capabilityStatus === "failed") apiFailedIds.add(apiId);
  }

  // Manual IDs are intentionally not promoted until the explicit probe says
  // they accept the synthetic image/JSON request for this config revision.
  const manualIds = provider.customProvider?.manualModelIds || [];
  for (const modelId of manualIds) {
    if (excludedModelId(modelId)) {
      unsupportedModels.push({
        id: modelId,
        reason: unsupportedReason({ id: modelId }),
        capabilityStatus: "unsupported",
      });
      continue;
    }
    const verified = provider.customProvider?.capabilityCache?.[modelId];
    if (verified?.status === "verified" && Number(verified.revision) === Number(provider.revision)) {
      const verifiedDescriptor = customModelDescriptor(provider.customProvider, modelId, {
        capabilityStatus: "verified",
        capabilitySource: verified.capabilitySource || "probe",
        capabilityMessage: redactDiscoverySecret(verified.message, apiKey),
        capabilityCheckedAt: verified.checkedAt || null,
      });
      discovered.push(verifiedDescriptor);
    } else if (verified?.status === "failed" && Number(verified.revision) === Number(provider.revision)) {
      failedModels.push(customModelDescriptor(provider.customProvider, modelId, {
        capabilityStatus: "failed",
        capabilitySource: verified.capabilitySource || "synthetic image probe",
        capabilityMessage: redactDiscoverySecret(verified.message, apiKey),
        capabilityCheckedAt: verified.checkedAt || null,
      }));
    } else if (verified?.status === "canceled" && Number(verified.revision) === Number(provider.revision)) {
      pendingModels.push(customModelDescriptor(provider.customProvider, modelId, {
        capabilityStatus: "canceled",
        capabilitySource: verified.capabilitySource || "synthetic image probe",
        capabilityMessage: redactDiscoverySecret(verified.message, apiKey),
        capabilityCheckedAt: verified.checkedAt || null,
      }));
    } else if (
      // A gateway's explicit pure-text/audio declaration or a failed probe is
      // stronger than a manually-entered fallback ID; do not reclassify the
      // same model as pending merely because it also appears in the manual list.
      !apiUnsupportedIds.has(modelId) &&
      !apiFailedIds.has(modelId) &&
      !discovered.some((model) => model.apiId === modelId) &&
      !pendingModels.some((model) => model.apiId === modelId)
    ) {
      pendingModels.push(customModelDescriptor(provider.customProvider, modelId));
    }
  }
  const legacyId = legacyProviderModelId(provider.customProvider);
  // The non-materialized legacy provider already receives its alias through
  // providerFixedModels; only a v2 record needs this compatibility overlay.
  if (legacyId && !excludedModelId(legacyId) && provider.customProvider) {
    const verification = provider.customProvider.capabilityCache?.[legacyId];
    const alias = customModelDescriptor(provider.customProvider, legacyId, {
      capabilityStatus: verification?.status === "verified"
        ? "verified"
        : verification?.status === "failed"
          ? "failed"
          : verification?.status === "canceled"
            ? "canceled"
            : "pending",
      capabilitySource: verification?.capabilitySource || "legacy alias",
      capabilityMessage: redactDiscoverySecret(verification?.message, apiKey),
      capabilityCheckedAt: verification?.checkedAt || null,
    });
    alias.id = CUSTOM_MODEL_ID;
    alias.apiId = legacyId;
    if (alias.capabilityStatus === "verified") {
      discovered.unshift(alias);
    } else if (verification?.status === "failed") {
      failedModels.unshift(alias);
    } else if (verification?.status === "canceled") {
      // A canceled probe must remain pending; only a record with no explicit
      // probe result uses the historical compatibility declaration.
      alias.capabilityStatus = "canceled";
      alias.capabilitySource = alias.capabilitySource || "synthetic image probe";
      pendingModels.unshift(alias);
    } else {
      // The fixed legacy alias remains selectable for compatibility even when
      // a v2 materialized record has no modern capability cache yet. UUID
      // custom records continue to keep the same model in pending status.
      alias.capabilityStatus = "declared";
      alias.capabilitySource = alias.capabilitySource || "legacy compatibility alias";
      discovered.unshift(alias);
    }
  }

  // A few gateways return duplicate IDs with different metadata records. A
  // usable declaration wins first; explicit failed/unsupported outcomes then
  // outrank incomplete pending rows so counts describe model IDs, not rows.
  const usableModels = dedupeByApiId(discovered);
  const usableApiIds = new Set(usableModels.map((model) => model.apiId || model.id));
  const uniquePending = dedupeByApiId(pendingModels)
    .filter((model) => !usableApiIds.has(model.apiId || model.id));
  const uniqueFailed = dedupeByApiId(failedModels)
    .filter((model) => !usableApiIds.has(model.apiId || model.id));
  const failedApiIds = new Set(uniqueFailed.map((model) => model.apiId || model.id));
  const uniqueUnsupported = dedupeByApiId(unsupportedModels)
    .filter((item) => !usableApiIds.has(item.id) && !failedApiIds.has(item.id));
  const unsupportedApiIds = new Set(uniqueUnsupported.map((item) => item.id));
  // Explicit failures and unsupported declarations are stronger than a
  // duplicate row with missing modality metadata. Keep a model in pending
  // only when no usable, failed, or unsupported row identifies it.
  const filteredPending = uniquePending.filter((model) => {
    const id = model.apiId || model.id;
    return !failedApiIds.has(id) && !unsupportedApiIds.has(id);
  });
  unsupportedModelCount = uniqueUnsupported.length;

  const unique = usableModels;
  const models = sortVisionModels(unique);
  const availableModelCount = modelsEndpointAvailable
    ? new Set(apiModels.map(modelIdFromPayload).filter(Boolean)).size
    : null;
  // Tag dynamic registrations with the connection revision so a response
  // from an in-flight discovery cannot satisfy recognition after an edit.
  registerDiscoveredModels(providerId, models, provider.custom ? provider.revision : null);
  const value = {
    provider: providerId,
    source: "api",
    refreshedAt: new Date().toISOString(),
    // Count unique IDs so duplicate gateway rows do not inflate the summary
    // counters or make a provider look more capable than it is.
    availableModelCount,
    visionModelCount: models.length,
    fixedModelCount: models.filter((model) => model.fixed).length,
    pendingModelCount: filteredPending.length,
    pendingModels: filteredPending,
    unsupportedModelCount,
    unsupportedModels: uniqueUnsupported,
    failedModelCount: uniqueFailed.length,
    failedModels: uniqueFailed,
    statusCounts: {
      usable: models.length,
      pending: filteredPending.length,
      unsupported: unsupportedModelCount,
      failed: uniqueFailed.length,
    },
    models,
  };
  if (!modelsEndpointAvailable) {
    value.modelsEndpointAvailable = false;
    value.warning = "接口未提供 /models；请从手动模型 ID 中选择并验证。";
  }

  if (options.cache !== false) {
    cache.set(cacheKey, { createdAt: Date.now(), value });
  }
  return value;
}

export function staticProviderModels(providerId, env = process.env, options = {}) {
  if (options.registry) {
    const registry = options.registry;
    const provider = registry.resolveProvider(providerId);
    if (provider?.customProvider) {
      const record = provider.customProvider;
      const models = record.manualModelIds.filter((modelId) => !excludedModelId(modelId)).map((modelId) => {
        const verified = record.capabilityCache?.[modelId];
        const capabilityStatus = verified?.status === "verified"
          ? "verified"
          : verified?.status === "failed"
            ? "failed"
            : verified?.status === "canceled"
              ? "canceled"
            : "pending";
        return customModelDescriptor(record, modelId, {
          capabilityStatus,
          capabilitySource: verified?.capabilitySource || "manual",
          capabilityMessage: redactDiscoverySecret(verified?.message, registry.getApiKey(providerId)),
          capabilityCheckedAt: verified?.checkedAt || null,
        });
      });
      const legacyModelId = legacyProviderModelId(record);
      if (legacyModelId) {
        const verification = record.capabilityCache?.[legacyModelId];
        const alias = customModelDescriptor(record, legacyModelId, {
          capabilityStatus: verification?.status === "verified"
            ? "verified"
            : verification?.status === "failed"
              ? "failed"
              : verification?.status === "canceled"
                ? "canceled"
                : "declared",
          capabilitySource: verification?.capabilitySource || "legacy compatibility alias",
          capabilityMessage: redactDiscoverySecret(verification?.message, options.registry.getApiKey(providerId)),
          capabilityCheckedAt: verification?.checkedAt || null,
        });
        alias.id = CUSTOM_MODEL_ID;
        alias.apiId = legacyModelId;
        models.unshift(alias);
      }
      return dedupeByApiId(models);
    }
  }
  const fixed = providerFixedModels(providerId, env);
  const models = fixed
    .map((candidate) =>
      describeProviderModel(providerId, { id: candidate.apiId }, candidate),
    )
    .filter(Boolean)
    .map((model) => ({
      ...model,
      discovered: false,
      verifiedAvailable: false,
    }));
  return sortVisionModels(models);
}

export function clearModelDiscoveryCache(providerId = null) {
  if (!providerId) {
    cache.clear();
    return;
  }
  for (const key of cache.keys()) {
    try {
      if (JSON.parse(key)[0] === providerId) cache.delete(key);
    } catch {
      cache.delete(key);
    }
  }
}

async function fetchModelList({
  provider,
  baseUrl,
  apiKey,
  env,
  fetchImpl,
}) {
  const headers = {
    Accept: "application/json",
  };
  if (apiKey) headers.Authorization = `Bearer ${apiKey}`;
  if (provider.id === "openrouter") {
    headers["X-Title"] = "SlateSync";
    if (env.OPENROUTER_SITE_URL) {
      headers["HTTP-Referer"] = env.OPENROUTER_SITE_URL;
    }
  }

  let response;
  try {
    response = await fetchImpl(`${baseUrl}/models`, {
      method: "GET",
      headers,
      signal: AbortSignal.timeout(DISCOVERY_TIMEOUT_MS),
    });
  } catch (error) {
    if (error.name === "TimeoutError") {
      throw discoveryError("读取模型列表超时，请稍后刷新", 504);
    }
    throw discoveryError(`无法读取模型列表：${redactDiscoverySecret(error?.message, apiKey)}`, 502);
  }

  const raw = await response.text();
  let data;
  try {
    data = raw ? JSON.parse(raw) : {};
  } catch {
    // A number of local OpenAI-compatible gateways answer an omitted
    // `/models` route with an HTML 404/405 page. Preserve that status so the
    // caller can fall back to its manually configured model IDs instead of
    // misclassifying the endpoint as a generic upstream failure.
    if (provider.custom && [404, 405, 501].includes(Number(response.status))) {
      throw discoveryError(
        `${provider.label} 未提供可解析的模型列表（HTTP ${response.status}）`,
        response.status,
      );
    }
    if (provider.custom && response.status >= 200 && response.status < 300) {
      // Some local gateways answer an unsupported `/models` route with a
      // successful HTML/empty body. Treat that as an unavailable list so
      // manually entered IDs still reach the pending verification workflow.
      throw discoveryError(
        `${provider.label} 返回了无法解析的模型列表（HTTP ${response.status}）`,
        501,
      );
    }
    throw discoveryError(
      `${provider.label} 返回了无法解析的模型列表（HTTP ${response.status}）`,
      502,
    );
  }
  if (!response.ok || data.error) {
    const message = redactDiscoverySecret(
      data.error?.message ||
      data.message ||
      `读取模型列表失败（HTTP ${response.status}）`,
      apiKey,
    );
    throw discoveryError(
      `${message}${providerAuthErrorHint(provider, response.status, data, apiKey)}`,
      response.status || 502,
    );
  }
  return data;
}

// DashScope compatible-mode rejects invalid keys with a plain OpenAI-style
// message; append the official common causes so users can fix it on their own.
function providerAuthErrorHint(provider, status, data, apiKey) {
  if (provider.id !== "dashscope" && provider.id !== "tokenplan") return "";
  const serialized = JSON.stringify(data || {});
  const authFailure =
    status === 401 ||
    /invalid[_-]api[_-]key|InvalidApiKey/i.test(serialized) ||
    /Incorrect API key|Invalid API[- ]?key/i.test(serialized);
  if (!authFailure) return "";
  if (/^sk-sp-/i.test(String(apiKey || "").trim())) {
    return "（当前 Key 为 sk-sp- 开头的 Token Plan/Coding Plan 团队版专属 Key：必须配合控制台“我的订阅”中显示的专属 Base URL（TOKENPLAN_BASE_URL / DASHSCOPE_BASE_URL）使用，不能混用通用兼容地址）";
  }
  return "（百炼 Key 排查：Key 应以 sk- 开头且复制完整；若为 sk-sp- 开头的 Token Plan/Coding Plan 专属 Key，必须配合控制台提供的专属 Base URL，不能混用通用兼容地址）";
}

function providerFixedModels(providerId, env) {
  const configured = MODELS.filter((model) =>
    model.providers.includes(providerId),
  ).map((model, index) => ({
    publicId: model.id,
    apiId:
      providerId === "openai" ? model.directId || model.id : model.id,
    label: model.label,
    description: model.description,
    imageDetail: model.imageDetail,
    openRouterStructuredOutputs: model.openRouterStructuredOutputs,
    qualityScore: model.qualityScore,
    valueScore: model.valueScore,
    inputPrice: model.pricePerMillion?.[providerId]?.input,
    outputPrice: model.pricePerMillion?.[providerId]?.output,
    priceUpdatedAt: model.priceUpdatedAt,
    fixed: true,
    fixedPriority: index,
  }));

  if (providerId === "openai-compatible") {
    const compatible = publicConfig(env).models.find(
      (model) => model.id === CUSTOM_MODEL_ID,
    );
    const apiId = String(env.OPENAI_COMPATIBLE_MODEL || "").trim();
    if (compatible && apiId) {
      configured.push({
        publicId: compatible.id,
        apiId,
        label: compatible.label,
        description: compatible.description,
        imageDetail: compatible.imageDetail,
        // The legacy alias can point at any provider-owned model. Do not
        // fabricate a B/B+ rating when the maintained catalog has no profile.
        qualityScore: null,
        valueScore: null,
        fixed: true,
        fixedPriority: 0,
      });
    }
  }
  return configured;
}

function describeDiscoveredModel(providerId, apiModel, options) {
  if (!options.provider?.custom) {
    return describeProviderModel(providerId, apiModel, options);
  }
  const verified = options.provider.customProvider?.capabilityCache?.[String(apiModel?.id || "").trim()];
  if (verified?.status === "verified" && Number(verified.revision) === Number(options.provider.revision)) {
    return customModelDescriptor(options.provider.customProvider, apiModel.id, {
      capabilityStatus: "verified",
      capabilitySource: verified.capabilitySource || "synthetic image probe",
      capabilityMessage: redactDiscoverySecret(verified.message, options.apiKey),
      capabilityCheckedAt: verified.checkedAt || null,
      pricing: apiModel.pricing,
      vendor: modelVendorHint(apiModel),
    });
  }
  if (verified?.status === "failed" && Number(verified.revision) === Number(options.provider.revision)) {
    // An explicit failed probe takes precedence over optimistic metadata from
    // a gateway; the user must retry before this model can re-enter a project.
    return customModelDescriptor(options.provider.customProvider, apiModel.id, {
      capabilityStatus: "failed",
      capabilitySource: verified.capabilitySource || "synthetic image probe",
      capabilityMessage: redactDiscoverySecret(verified.message, options.apiKey),
      capabilityCheckedAt: verified.checkedAt || null,
      pricing: apiModel.pricing,
      vendor: modelVendorHint(apiModel),
    });
  }
  if (verified?.status === "canceled" && Number(verified.revision) === Number(options.provider.revision)) {
    return customModelDescriptor(options.provider.customProvider, apiModel.id, {
      capabilityStatus: "canceled",
      capabilitySource: verified.capabilitySource || "synthetic image probe",
      capabilityMessage: redactDiscoverySecret(verified.message, options.apiKey),
      capabilityCheckedAt: verified.checkedAt || null,
      pricing: apiModel.pricing,
      vendor: modelVendorHint(apiModel),
    });
  }
  const inputModalities = modelModalities(apiModel, "input");
  const outputModalities = modelModalities(apiModel, "output");
  const declared = inputModalities.length > 0 || outputModalities.length > 0;
  if (declared) {
    // A gateway that reports only one direction has incomplete metadata, not
    // proof of incompatibility; let the user explicitly probe that model.
    if (!inputModalities.length || !outputModalities.length) {
      return customModelDescriptor(options.provider.customProvider, apiModel.id, {
        vendor: modelVendorHint(apiModel),
        capabilitySource: "API modality metadata incomplete",
        pricing: apiModel.pricing,
      });
    }
    if (!inputModalities.includes("image") || !outputModalities.includes("text")) return null;
  }
  if (!declared) {
    // A known maintained family may be inferred safely; all other IDs await a
    // user-selected probe instead of being silently offered for recognition.
    const inferred = knownVisionFamily(apiModel.id)
      ? describeProviderModel("openai-compatible", {
          ...apiModel,
          architecture: { input_modalities: ["image"], output_modalities: ["text"] },
        }, {
          ...options,
          customProvider: true,
          allowUnknown: true,
          imageDetail: options.provider.customProvider?.imageDetail,
        })
      : null;
    if (inferred) return { ...inferred, providers: [options.provider.id], capabilityStatus: "inferred", capabilitySource: "maintained model family" };
    return customModelDescriptor(options.provider.customProvider, apiModel.id, {
      vendor: modelVendorHint(apiModel),
      capabilitySource: "API 未声明 modality，等待显式探针",
      pricing: apiModel.pricing,
    });
  }
  const descriptor = describeProviderModel("openai-compatible", apiModel, {
    ...options,
    customProvider: true,
    allowUnknown: true,
    imageDetail: options.provider.customProvider?.imageDetail,
    publicId: apiModel.id,
    capabilityStatus: "declared",
    capabilitySource: "API architecture",
  });
  return descriptor
    ? { ...descriptor, providers: [options.provider.id] }
    : customModelDescriptor(options.provider.customProvider, apiModel.id, {
      capabilityStatus: "declared",
      capabilitySource: "API architecture",
      vendor: modelVendorHint(apiModel),
      pricing: apiModel.pricing,
    });
}

function knownVisionFamily(modelId) {
  const id = String(modelId || "").toLowerCase();
  // Only infer families with a maintained multimodal variant. Broad names
  // such as `gemma` or `mistral` also cover text-only checkpoints, which must
  // remain pending until the user explicitly probes them.
  // The curated OpenAI catalog is also reliable when a gateway omits
  // modality metadata (for example `openai/gpt-4o`). Reuse its maintained
  // profile instead of duplicating a second, drifting regex list here.
  if (describeOpenAiVisionModel(id)) return true;
  return /(?:qwen(?:\d(?:\.\d+)?[-./])?(?:vl|vision)|qwen3\.8-max|qwen3\.7-(?:max|plus|flash)|qwen3\.6-(?:plus|flash)|claude-(?:3|4)|gemini(?:-|$)|grok-(?:2|3|vision)|minimax[-./].*(?:vl|vision)|pixtral|mistral[-./].*vision|gemma[-./]?3(?:[-./](?:4b|12b|27b|vision))|llama[-./].*vision)/i.test(id);
}

// Provider APIs use several spellings for ownership. Keep the precedence in
// one helper so custom model groups remain stable across gateway dialects.
function modelVendorHint(apiModel) {
  return apiModel?.owned_by || apiModel?.ownedBy || apiModel?.owner ||
    apiModel?.vendor || apiModel?.organization || apiModel?.provider ||
    apiModel?.provider_id || apiModel?.publisher || apiModel?.creator;
}

function unsupportedReason(apiModel) {
  const input = modelModalities(apiModel, "input");
  const output = modelModalities(apiModel, "output");
  if (input.length || output.length) {
    if (!input.includes("image")) return "接口声明不支持图像输入";
    if (!output.includes("text")) return "接口声明不支持文本输出";
  }
  return "模型属于音频、嵌入、生图或其他不支持的模型类型";
}

function modelIdFromPayload(apiModel) {
  if (typeof apiModel === "string") return apiModel.trim();
  return String(apiModel?.id || apiModel?.model || apiModel?.name || "").trim();
}

function dedupeByApiId(items) {
  const unique = new Map();
  for (const item of items || []) {
    const physicalId = item?.apiId || item?.id;
    if (!physicalId || unique.has(physicalId)) continue;
    unique.set(physicalId, item);
  }
  return [...unique.values()];
}

function normalizeBaseUrl(value, envName) {
  const normalized = String(value || "").trim();
  let parsed;
  try {
    parsed = new URL(normalized);
  } catch {
    throw discoveryError(`${envName} 必须是有效的 http(s) URL`, 400);
  }
  if (!["http:", "https:"].includes(parsed.protocol)) {
    throw discoveryError(`${envName} 只支持 http:// 或 https://`, 400);
  }
  if (parsed.username || parsed.password || parsed.search || parsed.hash || normalized.includes("?") || normalized.includes("#")) {
    throw discoveryError(`${envName} 不能包含账号、密码、查询参数或片段`, 400);
  }
  return parsed.toString().replace(/\/+$/, "");
}

function discoveryError(message, status) {
  const error = new Error(message);
  error.status = status;
  error.providerError = true;
  return error;
}

function redactDiscoverySecret(value, secret) {
  const message = String(value || "");
  const normalizedSecret = String(secret || "").trim();
  return normalizedSecret ? message.split(normalizedSecret).join("[已隐藏]") : message;
}

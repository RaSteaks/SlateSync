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
  describeProviderModel,
  registerDiscoveredModels,
  sortVisionModels,
} from "./model-catalog.mjs";

const DISCOVERY_TIMEOUT_MS = 15_000;
const CACHE_TTL_MS = 5 * 60 * 1000;
const cache = new Map();

export async function discoverVisionModels(
  providerId,
  options = {},
) {
  const env = options.env || process.env;
  const fetchImpl = options.fetchImpl || fetch;
  const provider = resolveProvider(providerId, env);
  if (!provider) throw discoveryError("未知 API 服务商", 400);

  const missing = provider.requiredEnv.filter(
    (key) => !String(env[key] || "").trim(),
  );
  if (missing.length) {
    throw discoveryError(`尚未配置 ${missing.join("、")}`, 400);
  }

  const baseUrl = normalizeBaseUrl(
    env[provider.baseUrlEnv] || provider.defaultBaseUrl,
    provider.baseUrlEnv,
  );
  // The compatible provider's fixed descriptor contains its configured API
  // model, so changing that global setting must not reuse the prior snapshot.
  const configuredModelId = providerId === "openai-compatible"
    ? String(env.OPENAI_COMPATIBLE_MODEL || "").trim()
    : null;
  const cacheKey = JSON.stringify([providerId, baseUrl, configuredModelId]);
  const cached = cache.get(cacheKey);
  if (
    options.cache !== false &&
    !options.forceRefresh &&
    cached &&
    Date.now() - cached.createdAt < CACHE_TTL_MS
  ) {
    return cached.value;
  }

  const apiKey = String(env[provider.envKey]).trim();
  const payload = await fetchModelList({
    provider,
    baseUrl,
    apiKey,
    env,
    fetchImpl,
  });
  const apiModels = Array.isArray(payload.data) ? payload.data : null;
  if (!apiModels) {
    throw discoveryError(`${provider.label} 没有返回有效的模型列表`, 502);
  }

  const fixedModels = providerFixedModels(providerId, env);
  const discovered = [];
  for (const apiModel of apiModels) {
    const apiId = String(apiModel?.id || "").trim();
    if (!apiId) continue;
    const fixed = fixedModels.find((candidate) => candidate.apiId === apiId);
    const descriptor = describeProviderModel(providerId, apiModel, {
      configuredModelId: env.OPENAI_COMPATIBLE_MODEL,
      ...(fixed || {}),
    });
    if (descriptor) discovered.push(descriptor);
  }

  const unique = dedupeByPublicId(discovered);
  const models = sortVisionModels(unique);
  registerDiscoveredModels(providerId, models);
  const value = {
    provider: providerId,
    source: "api",
    refreshedAt: new Date().toISOString(),
    availableModelCount: apiModels.length,
    visionModelCount: models.length,
    fixedModelCount: models.filter((model) => model.fixed).length,
    models,
  };

  if (options.cache !== false) {
    cache.set(cacheKey, { createdAt: Date.now(), value });
  }
  return value;
}

export function staticProviderModels(providerId, env = process.env) {
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

export function clearModelDiscoveryCache() {
  cache.clear();
}

async function fetchModelList({
  provider,
  baseUrl,
  apiKey,
  env,
  fetchImpl,
}) {
  const headers = {
    Authorization: `Bearer ${apiKey}`,
    Accept: "application/json",
  };
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
    throw discoveryError(`无法读取模型列表：${error.message}`, 502);
  }

  const raw = await response.text();
  let data;
  try {
    data = raw ? JSON.parse(raw) : {};
  } catch {
    throw discoveryError(
      `${provider.label} 返回了无法解析的模型列表（HTTP ${response.status}）`,
      502,
    );
  }
  if (!response.ok || data.error) {
    const message =
      data.error?.message ||
      data.message ||
      `读取模型列表失败（HTTP ${response.status}）`;
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
        qualityScore: 75,
        fixed: true,
        fixedPriority: 0,
      });
    }
  }
  return configured;
}

function dedupeByPublicId(models) {
  const unique = new Map();
  for (const model of models) {
    const current = unique.get(model.id);
    if (!current || (!current.fixed && model.fixed)) {
      unique.set(model.id, model);
    }
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
  if (parsed.username || parsed.password || parsed.search || parsed.hash) {
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

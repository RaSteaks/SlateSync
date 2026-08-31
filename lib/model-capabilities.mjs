// Lightweight capability probes for configured model endpoints.
//
// The JSON Schema check is text-only and secret-free; the separate custom-model
// capability probe uses a deterministic synthetic image, never a user image.
// Together they distinguish request-format support from actual Vision input.
import { resolveProvider } from "./config.mjs";

const JSON_SCHEMA_CHECK_TIMEOUT_MS = 30_000;
const JSON_SCHEMA_PROBE_NAME = "slatesync_json_schema_probe";
const JSON_SCHEMA_PROBE_SCHEMA = Object.freeze({
  type: "object",
  additionalProperties: false,
  properties: {
    ok: { type: "boolean" },
    marker: { type: "string" },
  },
  required: ["ok", "marker"],
});

export async function checkOpenAiCompatibleJsonSchema(options = {}) {
  const env = options.env || process.env;
  const fetchImpl = options.fetchImpl || fetch;
  const provider = resolveProvider("openai-compatible", env);
  if (!provider) throw capabilityError("未知 API 服务商", 400);

  const missing = provider.requiredEnv.filter(
    (key) => !String(env[key] || "").trim(),
  );
  if (missing.length) {
    throw capabilityError(`尚未配置 ${missing.join("、")}`, 400);
  }

  const baseUrl = normalizeBaseUrl(
    env[provider.baseUrlEnv],
    provider.baseUrlEnv,
  );
  const model = String(env[provider.modelEnv] || "").trim();
  const transport = provider.transport === "responses"
    ? "responses"
    : "chat-completions";
  const endpoint = transport === "responses"
    ? `${baseUrl}/responses`
    : `${baseUrl}/chat/completions`;
  const apiKey = String(env[provider.envKey] || "").trim();
  const payload = transport === "responses"
    ? responsesProbePayload(model)
    : chatCompletionsProbePayload(model);

  let response;
  try {
    response = await fetchImpl(endpoint, {
      method: "POST",
      headers: capabilityHeaders(apiKey),
      body: JSON.stringify(payload),
      signal: AbortSignal.timeout(JSON_SCHEMA_CHECK_TIMEOUT_MS),
    });
  } catch (error) {
    throw capabilityError(
      `无法连接模型服务：${redactSecret(error?.message, apiKey) || "未知网络错误"}`,
      502,
    );
  }

  const data = await readJson(response, provider.label);
  const providerMessage =
    data?.error?.message ||
    data?.message ||
    `模型服务请求失败（HTTP ${response.status}）`;
  if (!response.ok || data?.error) {
    return capabilityResult({
      supported: false,
      model,
      transport,
      status: response.status || 502,
      message: `接口拒绝 JSON Schema：${redactSecret(providerMessage, apiKey)}`,
    });
  }

  const text = transport === "responses"
    ? extractResponsesText(data)
    : extractChatText(data);
  const parsed = parseProbeJson(text);
  if (!parsed) {
    return capabilityResult({
      supported: false,
      model,
      transport,
      status: response.status || 200,
      message: "接口接受了 JSON Schema 请求，但模型没有返回可解析的 JSON 探针。",
    });
  }

  const supported = parsed.ok === true && parsed.marker === "slatesync";
  return capabilityResult({
    supported,
    model,
    transport,
    status: response.status || 200,
    message: supported
      ? "接口支持 JSON Schema，且模型返回符合探针结构。"
      : "接口接受了 JSON Schema 请求，但模型返回的数据不符合探针结构。",
  });
}

function chatCompletionsProbePayload(model) {
  return {
    model,
    stream: false,
    max_tokens: 32,
    messages: [
      {
        role: "system",
        content: "你正在进行 JSON Schema 能力检测。只返回符合 Schema 的 JSON 对象，不要解释。",
      },
      {
        role: "user",
        content: '请返回 ok=true、marker="slatesync"。',
      },
    ],
    response_format: {
      type: "json_schema",
      json_schema: {
        name: JSON_SCHEMA_PROBE_NAME,
        strict: true,
        schema: JSON_SCHEMA_PROBE_SCHEMA,
      },
    },
  };
}

function responsesProbePayload(model) {
  return {
    model,
    store: false,
    max_output_tokens: 32,
    input: [
      {
        role: "user",
        content: [
          {
            type: "input_text",
            text: '请返回 ok=true、marker="slatesync"。只返回 JSON。',
          },
        ],
      },
    ],
    text: {
      format: {
        type: "json_schema",
        name: JSON_SCHEMA_PROBE_NAME,
        strict: true,
        schema: JSON_SCHEMA_PROBE_SCHEMA,
      },
    },
  };
}

async function readJson(response, providerLabel) {
  const raw = await response.text();
  try {
    return raw ? JSON.parse(raw) : {};
  } catch {
    throw capabilityError(
      `${providerLabel} 返回了无法解析的 JSON（HTTP ${response.status}）`,
      502,
    );
  }
}

function extractChatText(data) {
  const content = data?.choices?.[0]?.message?.content;
  if (typeof content === "string") return content;
  if (content && typeof content === "object" && !Array.isArray(content)) {
    return JSON.stringify(content);
  }
  if (Array.isArray(content)) {
    return content
      .filter((part) => part?.type === "text" && typeof part.text === "string")
      .map((part) => part.text)
      .join("");
  }
  return "";
}

function extractResponsesText(data) {
  if (typeof data?.output_text === "string") return data.output_text;
  return (data?.output || [])
    .flatMap((output) => output?.content || [])
    .filter((content) => content?.type === "output_text" && typeof content.text === "string")
    .map((content) => content.text)
    .join("");
}

function parseProbeJson(text) {
  if (text && typeof text === "object" && !Array.isArray(text)) return text;
  const cleaned = String(text || "")
    .trim()
    .replace(/^```(?:json)?\s*/i, "")
    .replace(/\s*```$/, "");
  if (!cleaned) return null;
  try {
    const value = JSON.parse(cleaned);
    return value && typeof value === "object" && !Array.isArray(value)
      ? value
      : null;
  } catch {
    return null;
  }
}

function capabilityResult({ supported, model, transport, status, message, capabilityStatus }) {
  return {
    supported: Boolean(supported),
    model,
    transport,
    status: Number.isInteger(status) ? status : null,
    checkedAt: new Date().toISOString(),
    message,
    capabilityStatus: capabilityStatus || (supported ? "verified" : "failed"),
  };
}

function normalizeBaseUrl(value, envName) {
  const normalized = String(value || "").trim();
  let parsed;
  try {
    parsed = new URL(normalized);
  } catch {
    throw capabilityError(`${envName} 必须是有效的 http(s) URL`, 400);
  }
  if (!["http:", "https:"].includes(parsed.protocol)) {
    throw capabilityError(`${envName} 只支持 http:// 或 https://`, 400);
  }
  if (parsed.username || parsed.password || parsed.search || parsed.hash || normalized.includes("?") || normalized.includes("#")) {
    throw capabilityError(`${envName} 不能包含账号、密码、查询参数或片段`, 400);
  }
  return parsed.toString().replace(/\/+$/, "");
}

function capabilityError(message, status) {
  const error = new Error(message);
  error.status = status;
  error.providerError = true;
  return error;
}

/**
 * A deterministic, project-free PNG contains a marker that is not present in
 * the prompt. Requiring the model to read it prevents text-only endpoints
 * from passing the Vision probe by merely echoing the requested JSON shape.
 */
const SYNTHETIC_PROBE_IMAGE =
  "data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAMAAAABACAAAAABpBycDAAAAvklEQVR4nO3Vyw7EIAxD0fz/T7dL1JaAeUgW1fVqJMDJ6WbiOjzhXmA1ANwB4A4AdwC4A8AdAO40APHM0KlaWisYawYAAEA6pr2EurGQ0pd+qcbjiRUBpH0AtEcA0ioA2iMAaRWA78v0Lz09jSzCYgAAANgJGCrqjBEvl4Par3qXOhSAchnA1FRljHj5RwC5FMDArP5lAFNT5Vn9y9sAUYl6ugJ41SsKAAAAHB4A7gBwB4A7ANwB4A4AdwC4cwNDxuNd0vBXMwAAAABJRU5ErkJggg==";
export const SYNTHETIC_PROBE_MARKER = "ss-7q";

/**
 * Probe a user-selected set of models with bounded concurrency. The callback
 * is Main-owned progress only; no image, prompt, or response is persisted.
 */
export async function probeCustomModels({
  provider,
  apiKey = "",
  modelIds = [],
  fetchImpl = fetch,
  signal = null,
  concurrency = 2,
  timeoutMs = 30_000,
  onProgress,
} = {}) {
  if (!provider?.baseUrl) throw capabilityError("缺少自定义接口 Base URL", 400);
  const ids = [...new Set((modelIds || [])
    .map((id) => String(id || "").trim())
    .filter(isProbeModelId))];
  const results = [];
  let cursor = 0;
  let completed = 0;
  const worker = async () => {
    while (true) {
      if (signal?.aborted) return;
      const index = cursor++;
      if (index >= ids.length) return;
      const model = ids[index];
      const result = await probeCustomModel({
        provider,
        apiKey,
        model,
        fetchImpl,
        signal,
        timeoutMs,
      });
      results[index] = result;
      completed += 1;
      onProgress?.({
        model,
        completed,
        total: ids.length,
        percent: ids.length ? Math.round((completed / ids.length) * 100) : 100,
        result,
      });
    }
  };
  const workers = Array.from({ length: Math.max(1, Math.min(2, concurrency)) }, () => worker());
  await Promise.all(workers);
  return {
    canceled: Boolean(signal?.aborted),
    results: results.filter(Boolean),
    completed,
    total: ids.length,
  };
}

function isProbeModelId(value) {
  return value.length >= 1 && value.length <= 220 && /^[A-Za-z0-9][A-Za-z0-9._:/@-]*$/.test(value);
}

export async function probeCustomModel({
  provider,
  apiKey = "",
  model,
  fetchImpl = fetch,
  signal = null,
  timeoutMs = 30_000,
} = {}) {
  // Keep injected/legacy records on the same canonical transport path as the
  // registry; a capitalized Responses value must not silently hit Chat API.
  const transport = String(provider.transport || "").trim().toLowerCase() === "responses"
    ? "responses"
    : "chat-completions";
  if (signal?.aborted) {
    return capabilityResult({
      supported: false,
      model: String(model || "").trim(),
      transport,
      status: null,
      message: "探针已取消",
      capabilityStatus: "canceled",
    });
  }
  const baseUrl = normalizeBaseUrl(provider.baseUrl, "Base URL");
  const normalizedJsonMode = String(provider.jsonMode || "").trim().toLowerCase();
  const jsonMode = ["json_schema", "json_object", "prompt"].includes(normalizedJsonMode)
    ? normalizedJsonMode
    : "json_schema";
  const endpoint = `${baseUrl}/${transport === "responses" ? "responses" : "chat/completions"}`;
  const imageDetail = ["auto", "low", "high", "original"].includes(provider.imageDetail)
    ? provider.imageDetail
    : "low";
  const payload = transport === "responses"
    ? responsesVisionProbePayload(model, jsonMode, imageDetail)
    : chatVisionProbePayload(model, jsonMode, imageDetail);
  const safeTimeoutMs = Number.isFinite(Number(timeoutMs))
    ? Math.max(0, Number(timeoutMs))
    : 30_000;
  const timeoutController = new AbortController();
  let timeoutHandle = null;
  let timedOut = false;
  let removeAbortListener = () => {};
  let cancellationPromise = null;
  try {
    // A race in addition to AbortSignal keeps the 30-second bound reliable
    // for injected/fake fetch implementations that do not observe signals.
    const timeoutPromise = new Promise((_, reject) => {
      timeoutHandle = setTimeout(() => {
        timedOut = true;
        timeoutController.abort(new DOMException("模型探针超时", "TimeoutError"));
        reject(new DOMException("模型探针超时", "TimeoutError"));
      }, safeTimeoutMs);
    });
    const requestSignal = signal && AbortSignal.any
      ? AbortSignal.any([signal, timeoutController.signal])
      : signal || timeoutController.signal;
    const requestPromise = fetchImpl(endpoint, {
      method: "POST",
      headers: capabilityHeaders(apiKey),
      body: JSON.stringify(payload),
      signal: requestSignal,
    });
    const races = [requestPromise, timeoutPromise];
    if (signal) {
      cancellationPromise = new Promise((_, reject) => {
        const rejectCanceled = () => reject(signal.reason || new DOMException("探针已取消", "AbortError"));
        if (signal.aborted) rejectCanceled();
        else {
          signal.addEventListener("abort", rejectCanceled, { once: true });
          removeAbortListener = () => signal.removeEventListener("abort", rejectCanceled);
        }
      });
      races.push(cancellationPromise);
    }
    const response = await Promise.race(races);
    // A response that races cancellation must not be promoted to a verified
    // capability after the user has already stopped the probe.
    if (signal?.aborted) {
      return capabilityResult({
        supported: false,
        model,
        transport,
        status: null,
        message: "探针已取消",
        capabilityStatus: "canceled",
      });
    }
    // The response body is part of the same per-model deadline. A test double
    // or a misbehaving gateway can resolve fetch() and still stall text(), so
    // race parsing against both timeout and user cancellation as well.
    const bodyRaces = [readJson(response, provider.label || "自定义接口"), timeoutPromise];
    if (cancellationPromise) bodyRaces.push(cancellationPromise);
    const data = await Promise.race(bodyRaces);
    if (signal?.aborted) {
      return capabilityResult({
        supported: false,
        model,
        transport,
        status: null,
        message: "探针已取消",
        capabilityStatus: "canceled",
      });
    }
    if (!response.ok || data?.error) {
      return capabilityResult({
        supported: false,
        model,
        transport,
        status: response.status || 502,
        message: redactSecret(data?.error?.message || `模型探针失败（HTTP ${response.status}）`, apiKey),
        capabilityStatus: "failed",
      });
    }
    const text = transport === "responses" ? extractResponsesText(data) : extractChatText(data);
    const parsed = parseProbeJson(text);
    const supported = parsed?.ok === true && parsed?.marker === SYNTHETIC_PROBE_MARKER;
    return capabilityResult({
      supported,
      model,
      transport,
      status: response.status || 200,
      message: supported ? "图像输入、文本输出与 JSON 响应探针通过。" : "接口返回内容未满足图像/JSON 能力探针。",
      capabilityStatus: supported ? "verified" : "failed",
    });
  } catch (error) {
    const canceled = Boolean(signal?.aborted);
    return capabilityResult({
      supported: false,
      model,
      transport,
      status: null,
      message: canceled
        ? "探针已取消"
        : timedOut
          ? `模型探针超时（单次等待上限 ${Math.round(safeTimeoutMs / 1000)} 秒）`
          : `无法连接模型服务：${redactSecret(error?.message, apiKey) || "未知网络错误"}`,
      capabilityStatus: canceled ? "canceled" : "failed",
    });
  } finally {
    if (timeoutHandle) clearTimeout(timeoutHandle);
    removeAbortListener();
  }
}

function chatVisionProbePayload(model, jsonMode, imageDetail = "low") {
  const payload = {
    model,
    stream: false,
    max_tokens: 32,
    messages: [{
      role: "user",
      content: [
        { type: "text", text: "请识别图片中唯一的黑色大写文本，并仅返回 JSON；ok 必须为 true，marker 必须是你读到的文本的小写形式。" },
        { type: "image_url", image_url: { url: SYNTHETIC_PROBE_IMAGE, detail: imageDetail } },
      ],
    }],
  };
  applyJsonMode(payload, jsonMode);
  return payload;
}

function responsesVisionProbePayload(model, jsonMode, imageDetail = "low") {
  const payload = {
    model,
    store: false,
    max_output_tokens: 32,
    input: [{
      role: "user",
      content: [
        { type: "input_text", text: "请识别图片中唯一的黑色大写文本，并仅返回 JSON；ok 必须为 true，marker 必须是你读到的文本的小写形式。" },
        { type: "input_image", image_url: SYNTHETIC_PROBE_IMAGE, detail: imageDetail },
      ],
    }],
  };
  if (jsonMode === "json_schema") {
    payload.text = { format: { type: "json_schema", name: JSON_SCHEMA_PROBE_NAME, strict: true, schema: JSON_SCHEMA_PROBE_SCHEMA } };
  } else if (jsonMode === "json_object") {
    payload.text = { format: { type: "json_object" } };
  }
  return payload;
}

function applyJsonMode(payload, mode) {
  if (mode === "json_schema") {
    payload.response_format = { type: "json_schema", json_schema: { name: JSON_SCHEMA_PROBE_NAME, strict: true, schema: JSON_SCHEMA_PROBE_SCHEMA } };
  } else if (mode === "json_object") {
    payload.response_format = { type: "json_object" };
  }
}

function capabilityHeaders(apiKey) {
  const headers = { "Content-Type": "application/json", Accept: "application/json" };
  // Local/LAN services may intentionally be unauthenticated; never send an
  // empty Bearer token because some gateways treat it as an invalid credential.
  const normalizedKey = String(apiKey || "").trim();
  if (normalizedKey) headers.Authorization = `Bearer ${normalizedKey}`;
  return headers;
}

function redactSecret(value, secret) {
  const message = String(value || "");
  const normalizedSecret = String(secret || "").trim();
  if (!normalizedSecret) return message;
  return message.split(normalizedSecret).join("[已隐藏]");
}

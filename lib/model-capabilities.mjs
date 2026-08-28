// Lightweight capability probes for configured model endpoints.
//
// This module deliberately sends a text-only, secret-free probe instead of a
// user image. It answers whether the compatible endpoint accepts the provider's
// JSON Schema request shape and whether the selected model actually returns the
// requested object, which are separate failure modes for local servers.
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
  const payload = transport === "responses"
    ? responsesProbePayload(model)
    : chatCompletionsProbePayload(model);

  let response;
  try {
    response = await fetchImpl(endpoint, {
      method: "POST",
      headers: {
        Authorization: `Bearer ${String(env[provider.envKey]).trim()}`,
        "Content-Type": "application/json",
        Accept: "application/json",
      },
      body: JSON.stringify(payload),
      signal: AbortSignal.timeout(JSON_SCHEMA_CHECK_TIMEOUT_MS),
    });
  } catch (error) {
    throw capabilityError(
      `无法连接模型服务：${error?.message || "未知网络错误"}`,
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
      message: `接口拒绝 JSON Schema：${providerMessage}`,
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

function capabilityResult({ supported, model, transport, status, message }) {
  return {
    supported: Boolean(supported),
    model,
    transport,
    status: Number.isInteger(status) ? status : null,
    checkedAt: new Date().toISOString(),
    message,
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
  if (parsed.username || parsed.password || parsed.search || parsed.hash) {
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

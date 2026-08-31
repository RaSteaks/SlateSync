// Validation and normalization for machine-level OpenAI-compatible providers.
// Keeping this module pure lets Main, IPC tests, and migration code share the
// same safety rules without ever passing credentials through the Renderer.
import { randomUUID } from "node:crypto";

export const CUSTOM_PROVIDER_PREFIX = "openai-compatible:";
export const CUSTOM_PROVIDER_TRANSPORTS = Object.freeze([
  "chat-completions",
  "responses",
]);
export const CUSTOM_PROVIDER_JSON_MODES = Object.freeze([
  "json_schema",
  "json_object",
  "prompt",
]);
export const CUSTOM_PROVIDER_IMAGE_DETAILS = Object.freeze([
  "auto",
  "low",
  "high",
  "original",
]);

const MODEL_ID_PATTERN = /^[A-Za-z0-9][A-Za-z0-9._:/@-]*$/;

export function isCustomProviderId(value) {
  return typeof value === "string" && value.startsWith(CUSTOM_PROVIDER_PREFIX) &&
    /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(value.slice(CUSTOM_PROVIDER_PREFIX.length));
}

export function newCustomProviderId() {
  return `${CUSTOM_PROVIDER_PREFIX}${randomUUID()}`;
}

export function normalizeCustomProvider(input, options = {}) {
  if (!input || typeof input !== "object") {
    throw providerValidationError("接口记录必须是对象");
  }
  const suppliedId = input.id ?? options.id;
  const rawId = suppliedId == null || suppliedId === ""
    ? newCustomProviderId()
    : String(suppliedId).trim();
  // UUIDs are case-insensitive; canonicalizing their suffix keeps duplicate
  // records from bypassing the registry's ID check with mixed casing.
  const id = isCustomProviderId(rawId)
    ? `${CUSTOM_PROVIDER_PREFIX}${rawId.slice(CUSTOM_PROVIDER_PREFIX.length).toLowerCase()}`
    : rawId;
  if (!isCustomProviderId(id) && id !== "openai-compatible") {
    throw providerValidationError("接口 ID 无效");
  }
  const name = normalizeProviderName(input.name ?? input.label);
  const baseUrl = normalizeProviderBaseUrl(input.baseUrl || input.url);
  // Persist protocol and JSON mode in their canonical lowercase form so old
  // environment snapshots cannot silently fall back to Chat Completions.
  const normalizedTransport = String(input.transport || "").trim().toLowerCase();
  const transport = CUSTOM_PROVIDER_TRANSPORTS.includes(normalizedTransport)
    ? normalizedTransport
    : "chat-completions";
  const normalizedJsonMode = String(input.jsonMode || "").trim().toLowerCase();
  const jsonMode = CUSTOM_PROVIDER_JSON_MODES.includes(normalizedJsonMode)
    ? normalizedJsonMode
    : "json_schema";
  const imageDetail = CUSTOM_PROVIDER_IMAGE_DETAILS.includes(input.imageDetail)
    ? input.imageDetail
    : "high";
  const manualModelIds = normalizeModelIds(input.manualModelIds ?? input.models);
  const revision = normalizeRevision(input.revision);
  const normalizedCache = normalizeCapabilityCache(
    input.capabilityCache ?? input.verification ?? input.capabilityVerification,
    revision,
  );
  // Keep all revision-scoped probe outcomes, including IDs returned by a
  // gateway's /models endpoint. The manual list remains the user's source of
  // truth; the cache is deliberately broader so verified/failed/canceled
  // discovery results can be rendered without mutating that list.
  const capabilityCache = normalizedCache;
  return {
    id,
    name,
    // `label` is retained in the persisted shape for early v2 snapshots and
    // makes migration/diagnostic inspection readable without exposing keys.
    label: name,
    baseUrl,
    transport,
    jsonMode,
    imageDetail,
    manualModelIds,
    revision,
    capabilityCache,
  };
}

export function sanitizeCustomProviders(value) {
  if (!Array.isArray(value)) return [];
  const result = [];
  const seenIds = new Set();
  const seenNames = new Set();
  for (const candidate of value) {
    try {
      if (!candidate?.id) continue;
      const normalized = normalizeCustomProvider(candidate, { generateId: false });
      const nameKey = normalized.name.toLowerCase();
      if (seenIds.has(normalized.id) || seenNames.has(nameKey)) continue;
      seenIds.add(normalized.id);
      seenNames.add(nameKey);
      result.push(normalized);
    } catch {
      // A malformed record is discarded during migration rather than making
      // the whole global settings page unreadable.
    }
  }
  return result;
}

export function normalizeProviderName(value) {
  const name = String(value || "").trim();
  // Count Unicode code points rather than UTF-16 units so a pair of surrogate
  // characters (for example an emoji in a localized name) occupies one slot.
  const characterCount = [...name].length;
  if (characterCount < 1 || characterCount > 60) {
    throw providerValidationError("接口名称需为 1–60 个字符");
  }
  if ([...name].some((character) => /[\u0000-\u001f\u007f-\u009f]/.test(character))) {
    throw providerValidationError("接口名称不能包含控制字符");
  }
  return name;
}

export function normalizeProviderBaseUrl(value) {
  const normalized = String(value || "").trim();
  let parsed;
  try {
    parsed = new URL(normalized);
  } catch {
    throw providerValidationError("Base URL 必须是有效的 http(s) URL");
  }
  if (!["http:", "https:"].includes(parsed.protocol)) {
    throw providerValidationError("Base URL 只支持 http:// 或 https://");
  }
  // URL treats a trailing bare `?`/`#` as an empty search/hash, but those
  // delimiters are still user-supplied query/fragment syntax and are rejected
  // to keep endpoint identity deterministic.
  if (parsed.username || parsed.password || parsed.search || parsed.hash || normalized.includes("?") || normalized.includes("#")) {
    throw providerValidationError("Base URL 不能包含账号、密码、查询参数或片段");
  }
  return parsed.toString().replace(/\/+$/, "");
}

export function normalizeModelIds(value) {
  if (!Array.isArray(value)) return [];
  const unique = new Set();
  for (const item of value) {
    const modelId = String(item || "").trim();
    if (!modelId || modelId.length > 220 || !MODEL_ID_PATTERN.test(modelId)) continue;
    unique.add(modelId);
  }
  return [...unique];
}

export function normalizeRevision(value) {
  const revision = Number(value);
  return Number.isSafeInteger(revision) && revision > 0 ? revision : 1;
}

export function bumpProviderRevision(provider) {
  return normalizeCustomProvider({
    ...provider,
    revision: normalizeRevision(provider?.revision) + 1,
    // A connection change invalidates every prior explicit verification.
    capabilityCache: {},
  });
}

export function providerValidationError(message, status = 400) {
  const error = new Error(message);
  error.status = status;
  error.code = "CUSTOM_PROVIDER_INVALID";
  return error;
}

function normalizeCapabilityCache(value, revision) {
  if (!value || typeof value !== "object" || Array.isArray(value)) return {};
  const cache = {};
  for (const [modelId, entry] of Object.entries(value)) {
    if (!MODEL_ID_PATTERN.test(modelId) || !entry || typeof entry !== "object") continue;
    if (Number(entry.revision) !== revision || !["verified", "failed", "canceled"].includes(entry.status)) continue;
    cache[modelId] = {
      status: entry.status,
      revision,
      checkedAt: typeof entry.checkedAt === "string" ? entry.checkedAt : null,
      transport: CUSTOM_PROVIDER_TRANSPORTS.includes(entry.transport)
        ? entry.transport
        : undefined,
      message: typeof entry.message === "string"
        ? sanitizeCapabilityMessage(entry.message)
        : undefined,
      capabilitySource: typeof entry.capabilitySource === "string"
        ? sanitizeCapabilityMessage(entry.capabilitySource).slice(0, 120)
        : "probe",
    };
  }
  return cache;
}

function sanitizeCapabilityMessage(value) {
  // Imported snapshots and older probe adapters may contain a gateway-echoed
  // bearer token. Strip common credential forms before the cache reaches disk;
  // Main still performs an exact-key redaction for provider-specific secrets.
  return String(value)
    .slice(0, 500)
    .replace(/Bearer\s+[A-Za-z0-9._~+/=-]+/gi, "Bearer [已隐藏]")
    .replace(/\bsk-[A-Za-z0-9._-]+\b/g, "[已隐藏]");
}

// Runtime Provider Registry.
//
// Built-in providers remain defined in lib/config.mjs for compatibility, but
// user-created endpoints are resolved here in Main only. This keeps endpoint
// URLs and optional credentials out of process.env and out of Renderer DTOs.
import {
  CUSTOM_MODEL_ID,
  PROVIDERS,
  normalizeLegacyCompatibleOptions,
  publicConfig,
  resolveModel as resolveStaticModel,
  resolveProvider as resolveStaticProvider,
} from "./config.mjs";
import {
  describeProviderModel,
  excludedModelId,
  calculateValueScore,
  qualityLabel,
  registeredModel,
  validModelId,
  valueLabel,
} from "./model-catalog.mjs";
import {
  isCustomProviderId,
  normalizeCustomProvider,
} from "./custom-provider.mjs";

/**
 * Resolve the persisted model behind the historical openai-compatible alias.
 * Materialized records must never fall back to a mutable environment value.
 */
export function legacyProviderModelId(record) {
  return record?.id === "openai-compatible"
    ? String(record.manualModelIds?.[0] || "").trim()
    : "";
}

export function createProviderRegistry({
  env = process.env,
  customProviders = [],
  providerKeys = new Map(),
} = {}) {
  const records = new Map();
  for (const candidate of customProviders || []) {
    try {
      const provider = normalizeCustomProvider(candidate);
      records.set(provider.id, provider);
    } catch {
      // global-config-store already removes malformed records; this defensive
      // guard keeps a damaged in-memory snapshot from breaking recognition.
    }
  }

  function customRecord(providerId) {
    return records.get(providerId) || null;
  }

  function resolveProvider(providerId) {
    const record = customRecord(providerId);
    if (record) {
      // The materialized legacy slot can come from an older snapshot that
      // predates canonical transport/json-mode normalization. Reapply its
      // historical Responses mapping at the runtime boundary as well.
      const legacyOptions = record.id === "openai-compatible"
        ? normalizeLegacyCompatibleOptions(record.transport, record.jsonMode)
        : null;
      return {
        id: record.id,
        label: record.name,
        type: "custom",
        custom: true,
        editable: true,
        // The materialized legacy slot keeps its historical required Key
        // contract; only generated UUID connections make authentication truly
        // optional for local/LAN gateways.
        envKey: record.id === "openai-compatible" ? "OPENAI_COMPATIBLE_API_KEY" : undefined,
        baseUrl: record.baseUrl,
        transport: legacyOptions?.transport || record.transport,
        chatJsonMode: legacyOptions?.jsonMode || record.jsonMode,
        jsonMode: legacyOptions?.jsonMode || record.jsonMode,
        imageDetail: record.imageDetail,
        requiredEnv: record.id === "openai-compatible" ? ["OPENAI_COMPATIBLE_API_KEY"] : [],
        revision: record.revision,
        customProvider: record,
      };
    }
    const builtin = resolveStaticProvider(providerId, env);
    return builtin
      ? { ...builtin, type: "builtin", custom: false, editable: false }
      : null;
  }

  function getApiKey(providerId) {
    const record = customRecord(providerId);
    if (record) {
      const stored = String(providerKeys?.get?.(providerId) || providerKeys?.[providerId] || "").trim();
      // The exact legacy ID may still be backed by OPENAI_COMPATIBLE_API_KEY
      // from .env; materializing its v2 record must not strand that credential.
      return stored || (providerId === "openai-compatible"
        ? String(env.OPENAI_COMPATIBLE_API_KEY || "").trim()
        : "");
    }
    const provider = resolveProvider(providerId);
    return provider?.envKey ? String(env[provider.envKey] || "").trim() : "";
  }

  function resolveModel(providerId, requestedId) {
    const record = customRecord(providerId);
    if (!record) return resolveStaticModel(providerId, requestedId, env);
    let modelId = String(requestedId || "").trim();
    const legacyAliasRequested = providerId === "openai-compatible" && modelId === CUSTOM_MODEL_ID;
    if (legacyAliasRequested) {
      modelId = legacyProviderModelId(record);
    }
    // A materialized record with no persisted model is unresolved rather than
    // silently targeting a later environment-model change.
    if (!modelId || !validModelId(modelId)) return null;
    const verification = record.capabilityCache?.[modelId];
    if (
      verification &&
      Number(verification.revision) === Number(record.revision) &&
      ["failed", "canceled"].includes(verification.status)
    ) {
      // A previously registered declaration can outlive a failed/canceled
      // probe. The explicit result is authoritative until the user retries;
      // otherwise recognition could silently bypass the pending gate.
      return null;
    }
    const discovered = registeredModel(providerId, modelId, record.revision);
    if (discovered?.verifiedAvailable || ["declared", "inferred", "verified"].includes(discovered?.capabilityStatus)) {
      return discovered;
    }
    if (legacyAliasRequested && verification?.status !== "failed") {
      // The historical alias was intentionally usable without a probe. Keep
      // that contract after v2 materialization while newly-added UUID models
      // still require an explicit verified cache entry.
      return customModelDescriptor(record, modelId, {
        capabilityStatus: verification?.status === "verified" ? "verified" : "declared",
        capabilitySource: verification?.capabilitySource || "legacy compatibility alias",
        capabilityMessage: verification?.message || null,
        capabilityCheckedAt: verification?.checkedAt || null,
      });
    }
    if (verification?.status === "verified" && Number(verification.revision) === record.revision) {
      return customModelDescriptor(record, modelId, {
        capabilityStatus: "verified",
        capabilitySource: verification.capabilitySource || "probe",
        capabilityCheckedAt: verification.checkedAt || null,
      });
    }
    return null;
  }

  function listProviderSummaries() {
    const builtin = Object.values(PROVIDERS).map((provider) => ({
      id: provider.id,
      label: provider.id === "openai-compatible" && records.has(provider.id)
        ? records.get(provider.id).name
        : provider.label,
      configured: provider.id === "openai-compatible" && records.has(provider.id)
        ? Boolean(records.get(provider.id).baseUrl
          && records.get(provider.id).manualModelIds?.length
          && getApiKey(provider.id))
        : provider.requiredEnv.every((key) => Boolean(String(env[key] || "").trim())),
      requiredEnv: [...provider.requiredEnv],
      type: records.has(provider.id) ? "custom" : "builtin",
      editable: provider.id === "openai-compatible",
    }));
    const existing = new Set(builtin.map((provider) => provider.id));
    for (const record of records.values()) {
      if (existing.has(record.id)) continue;
      builtin.push({
        id: record.id,
        label: record.name,
        configured: true,
        requiredEnv: [],
        type: "custom",
        editable: true,
      });
    }
    return builtin;
  }

  function publicModels() {
    // Once the legacy slot is materialized, the environment-derived static
    // alias may point at an obsolete model. The persisted record below is the
    // sole source for that physical API ID.
    const staticModels = publicConfig(env).models.filter((model) =>
      !(model.id === CUSTOM_MODEL_ID && records.has("openai-compatible")),
    );
    const dynamic = [];
    for (const record of records.values()) {
      for (const modelId of record.manualModelIds) {
        if (excludedModelId(modelId)) continue;
        const verification = record.capabilityCache?.[modelId];
        const capabilityStatus = verification?.status === "verified"
          ? "verified"
          : verification?.status === "failed"
            ? "failed"
            : verification?.status === "canceled"
              ? "canceled"
              : "pending";
        const descriptor = customModelDescriptor(record, modelId, {
          capabilityStatus,
          capabilitySource: verification?.capabilitySource || "manual",
          capabilityMessage: redactSecret(verification?.message, getApiKey(record.id)),
          capabilityCheckedAt: verification?.checkedAt || null,
        });
        dynamic.push(descriptor);
      }
      const legacyModelId = legacyProviderModelId(record);
      if (legacyModelId) {
        // Keep the historical `openai-compatible/custom` choice visible even
        // after the old slot is materialized as a v2 record. Its API model is
        // still stored separately so recognition can target the real ID.
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
          capabilityMessage: redactSecret(verification?.message, getApiKey(record.id)),
          capabilityCheckedAt: verification?.checkedAt || null,
        });
        alias.id = CUSTOM_MODEL_ID;
        alias.apiId = legacyModelId;
        dynamic.push(alias);
      }
    }
    // Registry callers represent the Main-to-Renderer public surface. Keep
    // rating provenance/date fields, but never expose raw token prices that
    // were used internally to derive the value label.
    return dedupeModels([...staticModels, ...dynamic]).map(withoutPricing);
  }

  return {
    customProviders: [...records.values()],
    customRecord,
    resolveProvider,
    resolveModel,
    getApiKey,
    listProviderSummaries,
    publicModels,
  };
}

export function customModelDescriptor(record, modelId, options = {}) {
  const safeId = String(modelId || "").trim();
  const capabilityStatus = options.capabilityStatus || "pending";
  const maintained = describeProviderModel("openai-compatible", {
    id: safeId,
    architecture: { input_modalities: ["image"], output_modalities: ["text"] },
  }, {
    customProvider: true,
    allowUnknown: true,
    imageDetail: record.imageDetail || "high",
  });
  const maintainedQuality = maintained?.qualityScore ?? null;
  const remotePricing = normalizeRemotePricing(options.pricing);
  const valueScore = options.valueScore ?? (
    maintainedQuality != null && (remotePricing.input != null || remotePricing.output != null)
      ? calculateValueScore(maintainedQuality, remotePricing.input, remotePricing.output)
      : null
  );
  return {
    id: safeId,
    apiId: safeId,
    label: safeId,
    description: capabilityStatus === "verified"
      ? "自定义接口模型，合成图像能力探针已通过"
      : capabilityStatus === "failed"
        ? "自定义接口模型探针失败"
        : capabilityStatus === "pending" || capabilityStatus === "canceled"
          ? "自定义接口模型，等待显式能力验证"
          : maintained?.description || "自定义接口模型，等待能力验证",
    providers: [record.id],
    vendor: normalizeVendor(options.vendor) || inferVendor(safeId),
    imageDetail: record.imageDetail || "high",
    fixed: false,
    discovered: false,
    verifiedAvailable: capabilityStatus === "verified",
    capabilityStatus,
    capabilitySource: options.capabilitySource || "manual",
    capabilityMessage: options.capabilityMessage || null,
    capabilityCheckedAt: options.capabilityCheckedAt || null,
    // A maintained family can supply precision guidance, but custom endpoint
    // prices are never guessed from that family and therefore remain unknown.
    qualityScore: maintainedQuality,
    valueScore,
    qualityLabel: qualityLabel(maintainedQuality),
    valueLabel: valueLabel(valueScore),
    qualitySource: maintainedQuality != null ? "SlateSync 维护的模型族参考评级" : null,
    qualityUpdatedAt: maintainedQuality != null ? (maintained?.qualityUpdatedAt || null) : null,
    valueSource: valueScore != null ? (options.valueSource || "接口实时价格") : null,
    valueUpdatedAt: valueScore != null ? (options.valueUpdatedAt || new Date().toISOString()) : null,
  };
}

function normalizeVendor(value) {
  const raw = value && typeof value === "object"
    ? (value.id || value.name || value.slug || "")
    : value;
  const vendor = String(raw || "").trim();
  return vendor ? vendor.toLowerCase().replace(/\s+/g, "-") : "";
}

export function augmentPublicConfig(config, registry) {
  if (!registry) return config;
  return {
    ...config,
    providers: registry.listProviderSummaries(),
    models: registry.publicModels(),
    // Keep the legacy exact ID in the fixed compatibility Provider surface;
    // the custom registry DTO contains only generated UUID connections.
    customProviders: registry.customProviders.filter((provider) => isCustomProviderId(provider.id)).map((provider) => ({
      id: provider.id,
      name: provider.name,
      label: provider.name,
      baseUrl: provider.baseUrl,
      transport: provider.transport,
      jsonMode: provider.jsonMode,
      imageDetail: provider.imageDetail,
      manualModelIds: [...provider.manualModelIds],
      revision: provider.revision,
      keyConfigured: Boolean(registry.getApiKey(provider.id)),
      capabilityCache: Object.fromEntries(Object.entries(provider.capabilityCache || {}).map(([modelId, value]) => {
        const safeMessage = redactSecret(value.message, registry.getApiKey(provider.id));
        return [modelId, {
          status: value.status,
          revision: value.revision,
          checkedAt: (() => {
            const checkedAt = redactSecret(value.checkedAt, registry.getApiKey(provider.id));
            return checkedAt ? checkedAt.slice(0, 80) : null;
          })(),
          capabilitySource: (() => {
            const source = redactSecret(value.capabilitySource, registry.getApiKey(provider.id));
            return source ? source.slice(0, 120) : undefined;
          })(),
          ...(safeMessage ? { message: safeMessage } : {}),
        }];
      })),
    })),
  };
}

function withoutPricing(model) {
  const publicModel = { ...model };
  delete publicModel.price;
  delete publicModel.prices;
  delete publicModel.pricePerMillion;
  // Raw provider price timestamps identify billing data rather than a rating
  // source; Renderer receives valueSource/valueUpdatedAt instead.
  delete publicModel.priceUpdatedAt;
  return publicModel;
}

export function providerForRequest(registry, providerId) {
  return registry?.resolveProvider(providerId) || resolveStaticProvider(providerId);
}

function dedupeModels(models) {
  const byKey = new Map();
  for (const model of models || []) {
    // `id` is a public compatibility alias, while `apiId` is the physical
    // model sent to the endpoint. Count and expose one entry per API model.
    const key = `${model.providers?.[0] || ""}:${model.apiId || model.id}`;
    const previous = byKey.get(key);
    // Dynamic legacy aliases carry the current probe status and must replace
    // the static compatibility placeholder when both share an ID.
    if (
      !previous
      || publicModelPriority(model) > publicModelPriority(previous)
      || (
        publicModelPriority(model) === publicModelPriority(previous)
        && model.id === CUSTOM_MODEL_ID
      )
    ) {
      byKey.set(key, model);
    }
  }
  return [...byKey.values()];
}

function publicModelPriority(model) {
  return {
    verified: 40,
    failed: 30,
    declared: 25,
    inferred: 25,
    pending: 20,
    canceled: 15,
  }[model?.capabilityStatus] || (model?.discovered ? 10 : 0);
}

function inferVendor(modelId) {
  if (modelId.includes("/")) return modelId.split("/", 1)[0].toLowerCase();
  const id = modelId.toLowerCase();
  if (/qwen/.test(id)) return "qwen";
  if (/claude/.test(id)) return "anthropic";
  if (/gemini|gemma/.test(id)) return "google";
  if (/gpt|^o[34]/.test(id)) return "openai";
  if (/grok/.test(id)) return "xai";
  if (/deepseek/.test(id)) return "deepseek";
  if (/llama/.test(id)) return "meta";
  if (/mistral|pixtral/.test(id)) return "mistralai";
  if (/minimax/.test(id)) return "minimax";
  return "other";
}

function normalizeRemotePricing(pricing) {
  const perMillion = (value) => {
    if (value == null || value === "") return null;
    const numeric = Number(value);
    return Number.isFinite(numeric) && numeric >= 0 ? numeric * 1_000_000 : null;
  };
  return {
    // OpenRouter uses prompt/completion while several gateways expose the
    // same per-token rates as input_per_token/output_per_token; accepting both
    // keeps live value ratings useful without guessing a currency or unit.
    input: perMillion(pricing?.prompt ?? pricing?.input ?? pricing?.input_per_token ?? pricing?.inputPerToken),
    output: perMillion(pricing?.completion ?? pricing?.output ?? pricing?.output_per_token ?? pricing?.outputPerToken),
  };
}

function redactSecret(value, secret) {
  const message = value == null ? null : String(value);
  const normalizedSecret = String(secret || "").trim();
  return normalizedSecret && message
    ? message.split(normalizedSecret).join("[已隐藏]")
    : message;
}

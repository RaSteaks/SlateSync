import type { ModelData } from "../../../shared/contracts/index.js";

const OPENROUTER_PRIMARY_COUNT = 10;

export interface ModelOptionGroup {
  readonly key: string;
  readonly label: string;
  readonly models: readonly ModelData[];
  /** Fixed recommendations stay open; large vendor buckets can collapse. */
  readonly collapsible?: boolean;
}

/**
 * Keep the common choices visible without throwing away discovered models.
 * OpenRouter and multi-vendor custom catalogs are grouped by the vendor
 * metadata returned by the API; single-vendor providers retain a flat list.
 */
export function groupModelOptions(
  providerId: string,
  models: readonly ModelData[],
): readonly ModelOptionGroup[] {
  const available = dedupeModels(models);
  if (!available.length) return [];
  if (providerId !== "openrouter" && !hasMultipleVendors(available)) {
    return [{ key: "available", label: "可用视觉模型", models: available, collapsible: false }];
  }

  if (providerId !== "openrouter") {
    return vendorGroups(providerId, available);
  }

  const recommended = providerId === "openrouter" ? available.filter(isRecommendedModel) : [];
  const featured = [...recommended];
  for (const model of available) {
    if (featured.length >= OPENROUTER_PRIMARY_COUNT) break;
    if (!isRecommendedModel(model)) featured.push(model);
  }

  const featuredIds = new Set(featured.map((model) => model.id));
  const remaining = available.filter((model) => !featuredIds.has(model.id));
  const groups: ModelOptionGroup[] = [];
  if (featured.length) {
    groups.push({
      key: "openrouter-featured",
      label: `推荐模型 · 优先 ${OPENROUTER_PRIMARY_COUNT} 个`,
      models: featured,
      collapsible: false,
    });
  }

  groups.push(...vendorGroups(providerId, remaining, "其余"));
  return groups;
}

function vendorGroups(providerId: string, models: readonly ModelData[], suffix = "") {
  const groups: ModelOptionGroup[] = [];
  const byVendor = new Map<string, ModelData[]>();
  for (const model of models) {
    const vendor = model.vendor || model.id.split("/", 1)[0] || "other";
    const bucket = byVendor.get(vendor) || [];
    bucket.push(model);
    byVendor.set(vendor, bucket);
  }
  for (const [vendor, vendorModels] of byVendor) {
    groups.push({
      key: `${providerId}-vendor-${vendor}`,
      label: `${vendorLabel(vendor)}${suffix ? ` · ${suffix} ${vendorModels.length} 个` : ` · ${vendorModels.length} 个`}`,
      models: vendorModels,
      collapsible: true,
    });
  }
  return groups;
}

function hasMultipleVendors(models: readonly ModelData[]): boolean {
  const vendors = new Set(models.map((model) => model.vendor || model.id.split("/", 1)[0] || "other"));
  return vendors.size > 1 && models.length >= 2;
}

export function modelOptionLabel(model: ModelData): string {
  const indicators = [model.qualityLabel ? `精度 ${model.qualityLabel}` : "", model.valueLabel ? `性价比 ${model.valueLabel}` : ""]
    .filter(Boolean);
  return indicators.length
    ? `${model.label || model.id} · ${indicators.join(" · ")}`
    : model.label || model.id;
}

function dedupeModels(models: readonly ModelData[]): readonly ModelData[] {
  const seen = new Set<string>();
  return models.filter((model) => {
    if (!model.id || seen.has(model.id)) return false;
    seen.add(model.id);
    return true;
  });
}

function isRecommendedModel(model: ModelData): boolean {
  // Static config models predate the discovery metadata, so an absent
  // `fixed`/`discovered` pair still represents a curated recommendation.
  return model.fixed === true || (model.fixed !== false && model.discovered !== true);
}

function vendorLabel(vendor: string): string {
  const knownLabels: Record<string, string> = {
    anthropic: "Anthropic",
    deepseek: "DeepSeek",
    google: "Google",
    meta: "Meta",
    minimax: "MiniMax",
    mistralai: "Mistral AI",
    openai: "OpenAI",
    qwen: "Qwen",
    xai: "xAI",
    other: "其他",
  };
  const key = vendor.toLowerCase();
  return knownLabels[key] || vendor
    .split(/[-_]/g)
    .filter(Boolean)
    .map((part) => part.charAt(0).toUpperCase() + part.slice(1))
    .join(" ");
}

// Project-scoped recognition and Resolve output settings.
//
// These values are intentionally kept separate from machine-level secrets and
// OCR settings. The project database is the source of truth for this object;
// the workflow config only supplies defaults for new projects and Web mode.

export const PROJECT_SETTINGS_VERSION = 1;

export const DEFAULT_PROJECT_SETTINGS = Object.freeze({
  providerId: null,
  modelId: null,
  accuracyMode: "high",
  scenarioId: null,
  customPrompt: "",
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

export function projectSettingsFromWorkflow(workflowConfig = {}) {
  return normalizeProjectSettings({
    ...DEFAULT_PROJECT_SETTINGS,
    resolve: workflowConfig.resolve,
  });
}

export function normalizeProjectSettings(value = {}, fallback = {}) {
  const base = mergeSettings(DEFAULT_PROJECT_SETTINGS, fallback);
  const source = value && typeof value === "object" ? value : {};
  const resolve = source.resolve && typeof source.resolve === "object"
    ? source.resolve
    : {};
  const fallbackResolve = base.resolve || DEFAULT_PROJECT_SETTINGS.resolve;
  const fieldFormats = resolve.fieldFormats || {};
  const fallbackFormats = fallbackResolve.fieldFormats || {};
  const comments = resolve.comments || {};
  const fallbackComments = fallbackResolve.comments || {};

  return {
    version: PROJECT_SETTINGS_VERSION,
    providerId: cleanOptionalId(source.providerId, base.providerId),
    modelId: cleanOptionalId(source.modelId, base.modelId),
    accuracyMode: ["high", "standard"].includes(source.accuracyMode)
      ? source.accuracyMode
      : base.accuracyMode,
    scenarioId: cleanOptionalId(source.scenarioId, base.scenarioId),
    customPrompt: cleanPrompt(source.customPrompt ?? base.customPrompt),
    resolve: {
      fieldFormats: {
        scene: safeFieldFormat(fieldFormats.scene, fallbackFormats.scene),
        shot: safeFieldFormat(fieldFormats.shot, fallbackFormats.shot),
        take: safeFieldFormat(fieldFormats.take, fallbackFormats.take),
      },
      comments: {
        goodTake: safeCommentToken(comments.goodTake, fallbackComments.goodTake),
        holdTake: safeCommentToken(comments.holdTake, fallbackComments.holdTake),
      },
    },
  };
}

export function validateProjectSettings(value) {
  const normalized = normalizeProjectSettings(value);
  if (!/^X{1,6}$/.test(normalized.resolve.fieldFormats.scene)) {
    throw new Error("项目设置中的场格式必须由 1–6 个 X 组成");
  }
  if (!/^X{1,6}$/.test(normalized.resolve.fieldFormats.shot)) {
    throw new Error("项目设置中的镜格式必须由 1–6 个 X 组成");
  }
  if (!/^X{1,6}$/.test(normalized.resolve.fieldFormats.take)) {
    throw new Error("项目设置中的次格式必须由 1–6 个 X 组成");
  }
  return normalized;
}

function mergeSettings(base, override) {
  return {
    ...base,
    ...(override && typeof override === "object" ? override : {}),
    resolve: {
      ...(base.resolve || {}),
      ...(override?.resolve || {}),
      fieldFormats: {
        ...(base.resolve?.fieldFormats || {}),
        ...(override?.resolve?.fieldFormats || {}),
      },
      comments: {
        ...(base.resolve?.comments || {}),
        ...(override?.resolve?.comments || {}),
      },
    },
  };
}

function cleanOptionalId(value, fallback = null) {
  const cleaned = String(value || "").trim();
  return cleaned || fallback || null;
}

function cleanPrompt(value) {
  return String(value || "").trim().slice(0, 2000);
}

function safeFieldFormat(value, fallback) {
  const token = String(value || "").trim();
  return /^X{1,6}$/.test(token) ? token : fallback || "XXX";
}

function safeCommentToken(value, fallback) {
  const token = String(value || "").trim().slice(0, 32);
  return token && !/[\r\n]/.test(token)
    ? token
    : fallback || "_OK";
}

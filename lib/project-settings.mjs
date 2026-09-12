// Project-scoped settings compatibility boundary.
//
// Main owns this normalizer so Renderer callers may submit either the legacy
// v1 shape or the additive v2 shape without silently losing future JSON-safe
// branches. The stored form is always emitted as v2 after normalization.
import { RESOLVE_TEMPLATE_ID, normalizeResolveTemplateColumns, createResolveExportOptions, IMPORTED_TEMPLATE_ID, normalizeImportedColumns } from "../public/resolve-export-template.js";

export const PROJECT_SETTINGS_VERSION = 2;

const EXPORT_COLUMN_DEFAULTS = Object.freeze([
  Object.freeze({ key: "scene", header: "Scene", enabled: true }),
  Object.freeze({ key: "shot", header: "Shot", enabled: true }),
  Object.freeze({ key: "take", header: "Take", enabled: true }),
  Object.freeze({ key: "comments", header: "Comments", enabled: true }),
  Object.freeze({ key: "takeStatus", header: "Take Status", enabled: false }),
  Object.freeze({ key: "cardNumber", header: "Card Number", enabled: false }),
  Object.freeze({ key: "videoCode", header: "Video Code", enabled: false }),
  Object.freeze({ key: "sourcePage", header: "Source Page", enabled: false }),
]);

const EXPORT_FORMAT_DEFAULTS = Object.freeze({
  // `encoding` describes final output bytes. Source-file encodings belong to
  // the imported table contract and must never be stored here as GBK output.
  encoding: "utf-16le",
  bom: true,
  delimiter: ",",
  lineEnding: "\r\n",
  finalNewline: true,
});

const DEFAULT_EXPORT_OPTIONS = Object.freeze({
  columns: EXPORT_COLUMN_DEFAULTS,
  format: EXPORT_FORMAT_DEFAULTS,
  filenameTemplate: "{source}_场记识别.csv",
});

export const DEFAULT_PROJECT_SETTINGS = Object.freeze({
  version: PROJECT_SETTINGS_VERSION,
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
  export: Object.freeze(createResolveExportOptions()),
});

export function projectSettingsFromWorkflow(workflowConfig = {}) {
  return normalizeProjectSettings({
    ...DEFAULT_PROJECT_SETTINGS,
    resolve: workflowConfig.resolve,
  });
}

export function normalizeProjectSettings(value = {}, fallback = {}) {
  const source = isPlainRecord(value) ? value : {};
  const fallbackSource = isPlainRecord(fallback) ? fallback : {};
  assertSupportedVersion(source.version);
  assertSupportedVersion(fallbackSource.version);

  // Merge first so a legacy partial payload keeps the current project's
  // export preferences and future branches during an update.
  const base = mergeJsonRecords(DEFAULT_PROJECT_SETTINGS, fallbackSource);
  const merged = mergeJsonRecords(base, source);
  const resolve = isPlainRecord(merged.resolve) ? merged.resolve : {};
  const fallbackResolve = isPlainRecord(base.resolve)
    ? base.resolve
    : DEFAULT_PROJECT_SETTINGS.resolve;
  const fieldFormats = isPlainRecord(resolve.fieldFormats)
    ? resolve.fieldFormats
    : {};
  const fallbackFormats = isPlainRecord(fallbackResolve.fieldFormats)
    ? fallbackResolve.fieldFormats
    : {};
  const comments = isPlainRecord(resolve.comments) ? resolve.comments : {};
  const fallbackComments = isPlainRecord(fallbackResolve.comments)
    ? fallbackResolve.comments
    : {};

  return {
    ...merged,
    version: PROJECT_SETTINGS_VERSION,
    providerId: cleanOptionalId(merged.providerId, base.providerId),
    modelId: cleanOptionalId(merged.modelId, base.modelId),
    accuracyMode: ["high", "standard"].includes(merged.accuracyMode)
      ? merged.accuracyMode
      : base.accuracyMode,
    scenarioId: cleanOptionalId(merged.scenarioId, base.scenarioId),
    customPrompt: cleanPrompt(merged.customPrompt, base.customPrompt),
    resolve: {
      ...resolve,
      fieldFormats: {
        ...fieldFormats,
        scene: safeFieldFormat(fieldFormats.scene, fallbackFormats.scene),
        shot: safeFieldFormat(fieldFormats.shot, fallbackFormats.shot),
        take: safeFieldFormat(fieldFormats.take, fallbackFormats.take),
      },
      comments: {
        ...comments,
        goodTake: safeCommentToken(comments.goodTake, fallbackComments.goodTake),
        holdTake: safeCommentToken(comments.holdTake, fallbackComments.holdTake),
      },
    },
    // Preserve explicit pre-template settings while defaulting unconfigured projects to Resolve.
    export: normalizeExportOptions(source.export ?? fallbackSource.export ?? DEFAULT_PROJECT_SETTINGS.export, source.export?.templateId || fallbackSource.export?.templateId ? base.export : DEFAULT_EXPORT_OPTIONS),
  };
}

export function validateProjectSettings(value, fallback = {}) {
  const normalized = normalizeProjectSettings(value, fallback);
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

function normalizeExportOptions(value, fallback) {
  const source = isPlainRecord(value) ? value : {};
  const base = mergeJsonRecords(DEFAULT_EXPORT_OPTIONS, fallback);
  const merged = mergeJsonRecords(base, source);
  const rawColumns = Array.isArray(merged.columns)
    ? merged.columns
    : EXPORT_COLUMN_DEFAULTS;
  const normalizedColumns = rawColumns
    .map((column, index) => normalizeExportColumn(column, index))
    .filter(Boolean);
  const seenKeys = new Set();
  const columns = normalizedColumns.filter((column) => {
    if (seenKeys.has(column.key)) return false;
    seenKeys.add(column.key);
    return true;
  });
  const rawFormat = isPlainRecord(merged.format) ? merged.format : {};
  const baseFormat = isPlainRecord(base.format) ? base.format : {};
  const lineEnding = ["\r\n", "\n", "\r"].includes(rawFormat.lineEnding)
    ? rawFormat.lineEnding
    : ["\r\n", "\n", "\r"].includes(rawFormat.newline)
      ? rawFormat.newline
      : baseFormat.lineEnding;

  return {
    ...merged,
    // Persist the same locked headers/identity columns that the Worker exports.
    columns: merged.templateId === IMPORTED_TEMPLATE_ID ? normalizeImportedColumns(rawColumns) : merged.templateId === RESOLVE_TEMPLATE_ID ? normalizeResolveTemplateColumns(rawColumns) : columns.length > 0
      ? columns.some((column) => column.enabled)
        ? columns
        : [{ ...columns[0], enabled: true }, ...columns.slice(1)]
      : EXPORT_COLUMN_DEFAULTS,
    format: {
      ...rawFormat,
      encoding: ["utf-8", "utf-16le", "utf-16be"].includes(rawFormat.encoding)
        ? rawFormat.encoding
        : baseFormat.encoding || EXPORT_FORMAT_DEFAULTS.encoding,
      bom: typeof rawFormat.bom === "boolean"
        ? rawFormat.bom
        : Boolean(baseFormat.bom),
      delimiter: merged.templateId === RESOLVE_TEMPLATE_ID ? "," : safeDelimiter(rawFormat.delimiter, baseFormat.delimiter),
      lineEnding,
      finalNewline: typeof rawFormat.finalNewline === "boolean"
        ? rawFormat.finalNewline
        : Boolean(baseFormat.finalNewline),
    },
    filenameTemplate: safeFilenameTemplate(
      merged.filenameTemplate,
      base.filenameTemplate,
    ),
  };
}

function normalizeExportColumn(value, index) {
  if (!isPlainRecord(value)) return null;
  const key = String(value.key || "").trim();
  if (!key) return null;
  const fallback = EXPORT_COLUMN_DEFAULTS.find((column) => column.key === key)
    || EXPORT_COLUMN_DEFAULTS[index];
  return {
    ...value,
    key,
    header: cleanHeader(value.header, fallback?.header || key),
    enabled: typeof value.enabled === "boolean"
      ? value.enabled
      : Boolean(fallback?.enabled),
  };
}

function cleanOptionalId(value, fallback = null) {
  if (value === undefined) return fallback ?? null;
  if (value === null) return null;
  const cleaned = String(value).trim();
  return cleaned || null;
}

function cleanPrompt(value, fallback = "") {
  if (value === undefined) return String(fallback || "").trim().slice(0, 2000);
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

function safeDelimiter(value, fallback = ",") {
  const delimiter = String(value ?? "");
  return delimiter && delimiter.length <= 4 && !/[\r\n]/.test(delimiter)
    ? delimiter
    : fallback || ",";
}

function cleanHeader(value, fallback) {
  const header = String(value ?? "").trim().slice(0, 80);
  return header && !/[\r\n\u0000]/.test(header) ? header : fallback;
}

function safeFilenameTemplate(value, fallback) {
  const template = String(value ?? "").trim().slice(0, 160);
  return template && !/[\r\n\u0000]/.test(template)
    ? template
    : String(fallback || DEFAULT_EXPORT_OPTIONS.filenameTemplate);
}

function assertSupportedVersion(version) {
  if (version !== undefined && Number(version) > PROJECT_SETTINGS_VERSION) {
    const error = new Error(
      `不支持的项目设置版本：${String(version)}（当前支持 v1-v${PROJECT_SETTINGS_VERSION}）`,
    );
    error.code = "UNSUPPORTED_PROJECT_SETTINGS_VERSION";
    throw error;
  }
}

function isPlainRecord(value) {
  if (!value || typeof value !== "object" || Array.isArray(value)) return false;
  const prototype = Object.getPrototypeOf(value);
  return prototype === Object.prototype || prototype === null;
}

function mergeJsonRecords(base, override) {
  const left = cloneJsonValue(base);
  const right = isPlainRecord(override) ? override : {};
  return mergeJsonObjects(isPlainRecord(left) ? left : {}, right);
}

function mergeJsonObjects(base, override) {
  const result = isPlainRecord(base) ? { ...base } : {};
  for (const [key, value] of Object.entries(override || {})) {
    if (isUnsafeKey(key) || value === undefined) continue;
    if (isPlainRecord(result[key]) && isPlainRecord(value)) {
      result[key] = mergeJsonObjects(result[key], value);
      continue;
    }
    const cloned = cloneJsonValue(value);
    if (cloned !== undefined) result[key] = cloned;
  }
  return result;
}

function cloneJsonValue(value, seen = new WeakSet()) {
  if (value === null || typeof value === "string" || typeof value === "boolean") {
    return value;
  }
  if (typeof value === "number") return Number.isFinite(value) ? value : undefined;
  if (value === undefined || typeof value !== "object") return undefined;
  if (seen.has(value)) return undefined;
  seen.add(value);
  if (Array.isArray(value)) {
    return value
      .map((item) => cloneJsonValue(item, seen))
      .filter((item) => item !== undefined);
  }
  if (!isPlainRecord(value)) return undefined;
  const result = {};
  for (const [key, item] of Object.entries(value)) {
    if (isUnsafeKey(key)) continue;
    const cloned = cloneJsonValue(item, seen);
    if (cloned !== undefined) result[key] = cloned;
  }
  return result;
}

function isUnsafeKey(key) {
  return key === "__proto__" || key === "prototype" || key === "constructor";
}

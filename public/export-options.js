// Shared export-options boundary for Modern Renderer, legacy Renderer, and
// Worker payloads. Keeping precedence, normalization, and filename expansion
// here prevents a preview and a saved CSV from drifting apart.
import { RESOLVE_TEMPLATE_ID, normalizeResolveTemplateColumns, createResolveExportOptions, IMPORTED_TEMPLATE_ID, normalizeImportedColumns } from "./resolve-export-template.js";

export const EXPORT_COLUMN_DEFINITIONS = Object.freeze([
  Object.freeze({ key: "scene", header: "Scene", enabled: true, label: "场次" }),
  Object.freeze({ key: "shot", header: "Shot", enabled: true, label: "镜号" }),
  Object.freeze({ key: "take", header: "Take", enabled: true, label: "条次" }),
  Object.freeze({ key: "comments", header: "Comments", enabled: true, label: "Comments" }),
  Object.freeze({ key: "takeStatus", header: "Take Status", enabled: false, label: "条次状态" }),
  Object.freeze({ key: "cardNumber", header: "Card Number", enabled: false, label: "卡号" }),
  Object.freeze({ key: "videoCode", header: "Video Code", enabled: false, label: "视频码" }),
  Object.freeze({ key: "sourcePage", header: "Source Page", enabled: false, label: "来源页" }),
]);

export const CUSTOM_EXPORT_OPTIONS = Object.freeze({
  columns: EXPORT_COLUMN_DEFINITIONS.map(({ label: _label, ...column }) => Object.freeze(column)),
  format: Object.freeze({
    encoding: "utf-16le",
    bom: true,
    delimiter: ",",
    lineEnding: "\r\n",
    finalNewline: true,
  }),
  filenameTemplate: "{source}_场记识别.csv",
});

// New projects use Resolve; explicit historical settings retain custom behavior.
export const DEFAULT_EXPORT_OPTIONS = Object.freeze(createResolveExportOptions());

const EXPORT_COLUMN_KEYS = new Set(EXPORT_COLUMN_DEFINITIONS.map((column) => column.key));
const OUTPUT_ENCODINGS = new Set(["utf-8", "utf-16le", "utf-16be"]);
const LINE_ENDINGS = new Set(["\r\n", "\n", "\r"]);
const FILENAME_TOKEN_PATTERN = /\{([a-z][a-z0-9_-]*)\}/gi;

export function normalizeExportOptions(value, fallback = DEFAULT_EXPORT_OPTIONS) {
  const fallbackValue = isRecord(fallback) ? fallback : DEFAULT_EXPORT_OPTIONS;
  const source = isRecord(value) ? value : {};
  const legacy = !source.templateId && Object.keys(source).length > 0;
  const base = legacy ? mergeExportOptions(CUSTOM_EXPORT_OPTIONS, { ...fallbackValue, templateId: "custom" }) : mergeExportOptions(DEFAULT_EXPORT_OPTIONS, fallbackValue);
  if ((legacy || source.templateId === "custom") && fallbackValue === DEFAULT_EXPORT_OPTIONS) Object.assign(base, CUSTOM_EXPORT_OPTIONS, { templateId: "custom" });
  const rawColumns = Array.isArray(source.columns)
    ? source.columns
    : Array.isArray(base.columns) ? base.columns : DEFAULT_EXPORT_OPTIONS.columns;
  const seen = new Set();
  const columns = rawColumns
    .map((column, index) => normalizeColumn(column, index, base.columns))
    .filter((column) => {
      if (!column || seen.has(column.key)) return false;
      seen.add(column.key);
      return true;
    });
  const normalizedColumns = columns.length ? columns : CUSTOM_EXPORT_OPTIONS.columns.map((column) => ({ ...column }));
  if (!normalizedColumns.some((column) => column.enabled)) normalizedColumns[0].enabled = true;

  const rawFormat = isRecord(source.format) ? source.format : {};
  const baseFormat = isRecord(base.format) ? base.format : DEFAULT_EXPORT_OPTIONS.format;
  const encoding = OUTPUT_ENCODINGS.has(rawFormat.encoding)
    ? rawFormat.encoding
    : OUTPUT_ENCODINGS.has(baseFormat.encoding) ? baseFormat.encoding : DEFAULT_EXPORT_OPTIONS.format.encoding;
  const lineEnding = LINE_ENDINGS.has(rawFormat.lineEnding)
    ? rawFormat.lineEnding
    : LINE_ENDINGS.has(rawFormat.newline) ? rawFormat.newline
      : LINE_ENDINGS.has(baseFormat.lineEnding) ? baseFormat.lineEnding : DEFAULT_EXPORT_OPTIONS.format.lineEnding;

  return {
    ...base,
    ...source,
    // Built-in adapters own their field names and mandatory identity columns.
    columns: (source.templateId ?? base.templateId) === IMPORTED_TEMPLATE_ID ? normalizeImportedColumns(rawColumns) : source.templateId === RESOLVE_TEMPLATE_ID || (!Object.hasOwn(source, "templateId") && base.templateId === RESOLVE_TEMPLATE_ID)
      ? normalizeResolveTemplateColumns(rawColumns) : normalizedColumns,
    format: {
      ...baseFormat,
      ...rawFormat,
      encoding,
      bom: typeof rawFormat.bom === "boolean" ? rawFormat.bom : Boolean(baseFormat.bom),
      delimiter: (source.templateId ?? base.templateId) === RESOLVE_TEMPLATE_ID ? "," : safeDelimiter(rawFormat.delimiter ?? baseFormat.delimiter),
      lineEnding,
      finalNewline: typeof rawFormat.finalNewline === "boolean"
        ? rawFormat.finalNewline
        : Boolean(baseFormat.finalNewline),
    },
    filenameTemplate: safeTemplate(source.filenameTemplate ?? base.filenameTemplate),
  };
}

export function mergeExportOptions(base, patch) {
  const left = isRecord(base) ? base : DEFAULT_EXPORT_OPTIONS;
  const right = isRecord(patch) ? patch : {};
  return {
    ...left,
    ...right,
    columns: right.columns ?? left.columns,
    format: { ...(isRecord(left.format) ? left.format : {}), ...(isRecord(right.format) ? right.format : {}) },
  };
}

/** Session > project > system; the source is retained for diagnostics/UI copy. */
export function resolveEffectiveExportOptions({ sessionOverride, projectDefault, systemDefault } = {}) {
  const source = sessionOverride ? "session" : projectDefault ? "project" : "system";
  const selected = sessionOverride || projectDefault || systemDefault || DEFAULT_EXPORT_OPTIONS;
  return { source, options: normalizeExportOptions(selected, systemDefault || DEFAULT_EXPORT_OPTIONS) };
}

export function resolveExportFilename(template, context = {}, clock = new Date()) {
  const fallback = DEFAULT_EXPORT_OPTIONS.filenameTemplate;
  const safeContext = {
    project: context.project,
    source: context.source,
    task: context.task,
    date: context.date,
    time: context.time,
  };
  const date = formatDate(clock);
  const time = formatTime(clock);
  const raw = safeTemplate(template || fallback).replace(FILENAME_TOKEN_PATTERN, (_match, token) => {
    if (token === "date") return sanitizeFilenamePart(safeContext.date || date);
    if (token === "time") return sanitizeFilenamePart(safeContext.time || time);
    return sanitizeFilenamePart(safeContext[token] || "");
  });
  // A template containing only an unknown token must not turn into a vague
  // "slate.csv" name; preserve the documented default filename instead.
  if (!raw.replace(/\.csv$/i, "").trim()) {
    return sanitizeBasename(fallback.replace("{source}", safeContext.source || "slate"));
  }
  const cleaned = sanitizeBasename(raw);
  return cleaned || sanitizeBasename(fallback.replace("{source}", safeContext.source || "slate"));
}

export function sanitizeBasename(value) {
  const normalized = String(value ?? "")
    .replace(/[\\/:*?"<>|]/g, "_")
    .replace(/[\u0000-\u001f\u007f]/g, "_")
    .replace(/\s+/g, " ")
    .trim()
    .replace(/^\.+/, "_");
  return normalized.slice(0, 220) || "slate.csv";
}

function normalizeColumn(value, index, fallbackColumns) {
  if (!isRecord(value)) return null;
  const key = String(value.key || "").trim();
  if (!EXPORT_COLUMN_KEYS.has(key)) return null;
  const fallback = fallbackColumns?.find?.((column) => column.key === key)
    || CUSTOM_EXPORT_OPTIONS.columns[index]
    || CUSTOM_EXPORT_OPTIONS.columns[0];
  const header = String(value.header ?? fallback.header).trim().slice(0, 80);
  return {
    ...value,
    key,
    header: header && !/[\u0000-\u001f\u007f\r\n]/.test(header) ? header : fallback.header,
    enabled: typeof value.enabled === "boolean" ? value.enabled : Boolean(fallback.enabled),
  };
}

function safeDelimiter(value) {
  const delimiter = String(value ?? "");
  return delimiter && delimiter.length <= 4 && !/[\r\n\u0000]/.test(delimiter) ? delimiter : ",";
}

function safeTemplate(value) {
  const template = String(value ?? "").trim().slice(0, 160);
  return template && !/[\r\n\u0000]/.test(template) ? template : DEFAULT_EXPORT_OPTIONS.filenameTemplate;
}

function sanitizeFilenamePart(value) {
  const text = String(value ?? "").trim();
  return text ? sanitizeBasename(text).replace(/\.csv$/i, "") : "";
}

function formatDate(value) {
  const date = value instanceof Date && !Number.isNaN(value.getTime()) ? value : new Date();
  return `${date.getFullYear()}${String(date.getMonth() + 1).padStart(2, "0")}${String(date.getDate()).padStart(2, "0")}`;
}

function formatTime(value) {
  const date = value instanceof Date && !Number.isNaN(value.getTime()) ? value : new Date();
  return `${String(date.getHours()).padStart(2, "0")}${String(date.getMinutes()).padStart(2, "0")}${String(date.getSeconds()).padStart(2, "0")}`;
}

function isRecord(value) {
  return Boolean(value) && typeof value === "object" && !Array.isArray(value);
}

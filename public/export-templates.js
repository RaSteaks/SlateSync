// Shared project export-template library semantics for the Modern workbench,
// the legacy settings form, and Node regression tests. Keeping naming rules,
// editor-dirty comparison, and switch/delete selection in one boundary stops
// the two renderers from drifting apart in what "save a template" means.
// Templates live inside ProjectSettings.exportTemplates; nothing here touches
// persistence — both UIs only stage page drafts and the existing project
// settings save remains the single durable write.
import { IMPORTED_TEMPLATE_ID, RESOLVE_TEMPLATE_ID, createResolveExportOptions } from "./resolve-export-template.js";
import { CUSTOM_EXPORT_OPTIONS, normalizeExportOptions } from "./export-options.js";

export const TEMPLATE_NAME_MAX_LENGTH = 80;
export const DEFAULT_TEMPLATE_NAME = "自定义 CSV";
export const TEMPLATE_COPY_SUFFIX = " · 副本";
export const BUILTIN_TEMPLATE_LABEL = "DaVinci Resolve 21.1 · 内置 CSV";
export const UNSAVED_TEMPLATE_LABEL = "当前配置（未保存）";

/** Trim, strip control characters, and cap the display name; null when empty. */
export function cleanTemplateName(value) {
  const name = String(value ?? "")
    .replace(/[\u0000-\u001f\u007f]/g, "")
    .trim()
    .slice(0, TEMPLATE_NAME_MAX_LENGTH);
  return name || null;
}

export function findExportTemplate(templates, id) {
  if (!Array.isArray(templates) || !id) return null;
  return templates.find((template) => template?.id === id) ?? null;
}

/** The name field only identifies a template inside its own project. */
export function templateNameConflict(name, templates, excludeId = null) {
  const cleaned = cleanTemplateName(name);
  if (!cleaned || !Array.isArray(templates)) return null;
  return templates.find((template) => template?.id !== excludeId && template?.name === cleaned) ?? null;
}

export function validateTemplateName(name, templates, excludeId = null) {
  const cleaned = cleanTemplateName(name);
  if (!cleaned) return { ok: false, message: "请输入模板名称。" };
  if (templateNameConflict(cleaned, templates, excludeId)) {
    return { ok: false, message: "模板名称与现有模板重复，请修改后再保存。" };
  }
  return { ok: true, name: cleaned };
}

/**
 * Default names avoid an immediate duplicate error, while an explicit save of
 * a conflicting name still stays blocked by validateTemplateName. Long bases
 * are shortened first so the numeric suffix can never be truncated away and
 * loop forever on the same candidate.
 */
export function uniqueTemplateName(base, templates) {
  const list = Array.isArray(templates) ? templates : [];
  const requested = cleanTemplateName(base) || DEFAULT_TEMPLATE_NAME;
  if (!list.some((template) => template?.name === requested)) return requested;
  const stem = requested.slice(0, TEMPLATE_NAME_MAX_LENGTH - 6).trimEnd() || DEFAULT_TEMPLATE_NAME;
  for (let n = 2; n < 1000; n++) {
    const candidate = cleanTemplateName(`${stem} ${n}`);
    if (candidate && !list.some((template) => template?.name === candidate)) return candidate;
  }
  return cleanTemplateName(`${stem} ${Date.now().toString(36)}`);
}

export function copyTemplateName(name, templates) {
  return uniqueTemplateName(`${cleanTemplateName(name) || DEFAULT_TEMPLATE_NAME}${TEMPLATE_COPY_SUFFIX}`, templates);
}

/** Imported presets stay imported; everything else edits as a custom CSV. */
export function defaultTemplateIdForOptions(options) {
  return options?.templateId === IMPORTED_TEMPLATE_ID ? IMPORTED_TEMPLATE_ID : "custom";
}

/**
 * Canonical editor content for a new preset. A preset copied from the
 * read-only built-in becomes a custom CSV with the full documented column
 * set, so selecting it afterwards never shows phantom "unsaved" drift from
 * the custom column append.
 */
export function canonicalTemplateSource(options) {
  if (options?.templateId === RESOLVE_TEMPLATE_ID) {
    return normalizeExportOptions({ ...options, templateId: "custom" }, CUSTOM_EXPORT_OPTIONS);
  }
  return options && typeof options === "object" ? options : {};
}

function copyTemplateColumns(options) {
  return (Array.isArray(options?.columns) ? options.columns : []).map((column) => ({
    key: column.key,
    header: column.header,
    enabled: column.enabled !== false,
  }));
}

function copyTemplateFormat(options) {
  return { ...(options?.format && typeof options.format === "object" ? options.format : {}) };
}

/** A template stores schema only: never sample rows, never the library link. */
export function createExportTemplate({ name, options, templateId } = {}) {
  return {
    id: createTemplateId(),
    name: cleanTemplateName(name) || DEFAULT_TEMPLATE_NAME,
    templateId: templateId === IMPORTED_TEMPLATE_ID ? IMPORTED_TEMPLATE_ID : defaultTemplateIdForOptions(options),
    columns: copyTemplateColumns(options),
    format: copyTemplateFormat(options),
    filenameTemplate: String(options?.filenameTemplate ?? "").trim() || "{source}_场记识别.csv",
  };
}

/** Commit the live editor content into an existing template entry. */
export function applyEditorContentToTemplate(template, options) {
  return {
    ...template,
    templateId: defaultTemplateIdForOptions(options),
    columns: copyTemplateColumns(options),
    format: copyTemplateFormat(options),
    filenameTemplate: String(options?.filenameTemplate ?? "").trim() || template.filenameTemplate,
  };
}

/**
 * Selecting a template loads its preset and links the live config through
 * savedTemplateId. Imported presets keep a display name so existing explainer
 * copy keeps working; custom presets historically carry none.
 */
export function exportOptionsFromTemplate(template) {
  return {
    templateId: template.templateId,
    ...(template.templateId === IMPORTED_TEMPLATE_ID ? { templateName: template.name } : {}),
    columns: copyTemplateColumns(template),
    format: copyTemplateFormat(template),
    filenameTemplate: template.filenameTemplate,
    savedTemplateId: template.id,
  };
}

/** The read-only built-in is implicit and never referenced by savedTemplateId. */
export function exportOptionsForBuiltinTemplate() {
  return createResolveExportOptions();
}

/**
 * 删除当前模板后的切换目标：prefer the next entry, else the previous one,
 * else null so the caller falls back to the read-only Resolve built-in.
 * `templates` must be the list before removal.
 */
export function templateAfterDelete(templates, deletedId) {
  if (!Array.isArray(templates)) return null;
  const index = templates.findIndex((template) => template?.id === deletedId);
  if (index < 0) return null;
  return templates[index + 1] ?? templates[index - 1] ?? null;
}

/**
 * Only the persisted preset fields participate in dirty tracking;
 * savedTemplateId is the link itself and templateName is edited separately.
 * Fixed key order keeps the JSON comparison stable across renderers.
 */
export function templateContentOf(options) {
  const source = options && typeof options === "object" ? options : {};
  const format = source.format && typeof source.format === "object" ? source.format : {};
  return {
    templateId: source.templateId ?? "custom",
    columns: copyTemplateColumns(source),
    format: {
      encoding: format.encoding ?? null,
      bom: Boolean(format.bom),
      delimiter: format.delimiter ?? ",",
      lineEnding: format.lineEnding ?? "\r\n",
      finalNewline: Boolean(format.finalNewline),
    },
    filenameTemplate: source.filenameTemplate ?? "",
  };
}

export function sameTemplateContent(left, right) {
  // Compare the same editor projection on both sides; old custom presets may
  // omit newly available disabled fields without representing unsaved edits.
  return JSON.stringify(templateContentOf(normalizeExportOptions(left))) === JSON.stringify(templateContentOf(normalizeExportOptions(right)));
}

export function createTemplateId() {
  const cryptoRef = globalThis.crypto;
  if (cryptoRef && typeof cryptoRef.randomUUID === "function") return cryptoRef.randomUUID();
  // Legacy contexts without crypto.randomUUID still need collision-resistant ids.
  return `tpl-${Date.now().toString(36)}-${Math.random().toString(36).slice(2, 10)}`;
}

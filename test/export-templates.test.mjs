import assert from "node:assert/strict";
import test from "node:test";

import {
  BUILTIN_TEMPLATE_LABEL,
  DEFAULT_TEMPLATE_NAME,
  TEMPLATE_COPY_SUFFIX,
  applyEditorContentToTemplate,
  canonicalTemplateSource,
  cleanTemplateName,
  copyTemplateName,
  createExportTemplate,
  defaultTemplateIdForOptions,
  exportOptionsForBuiltinTemplate,
  exportOptionsFromTemplate,
  findExportTemplate,
  sameTemplateContent,
  templateAfterDelete,
  templateContentOf,
  uniqueTemplateName,
  validateTemplateName,
} from "../public/export-templates.js";
import { CUSTOM_EXPORT_OPTIONS, normalizeExportOptions } from "../public/export-options.js";
import { RESOLVE_TEMPLATE_ID, createResolveExportOptions } from "../public/resolve-export-template.js";

const customTemplate = (overrides = {}) => createExportTemplate({
  name: "自定义模板",
  options: normalizeExportOptions({ ...CUSTOM_EXPORT_OPTIONS, templateId: "custom", filenameTemplate: "a.csv" }),
  templateId: "custom",
  ...overrides,
});

test("template names are trimmed, control characters are stripped and empty names are rejected", () => {
  assert.equal(cleanTemplateName("  场记模板  "), "场记模板");
  assert.equal(cleanTemplateName("bad\u0000\u001fname\u007f"), "badname");
  assert.equal(cleanTemplateName("   "), null);
  assert.equal(cleanTemplateName(null), null);
  const long = "名".repeat(120);
  assert.equal(cleanTemplateName(long).length, 80);
});

test("duplicate template names are blocked for saves but allow the excluded template itself", () => {
  const templates = [customTemplate(), customTemplate({ name: "另一个" })];
  assert.equal(validateTemplateName("自定义模板", templates).ok, false);
  assert.equal(validateTemplateName("", templates).ok, false);
  // Same template keeping its own name stays valid on rename-save.
  assert.equal(validateTemplateName("自定义模板", templates, templates[0].id).ok, true);
  assert.equal(validateTemplateName("另一个", templates, templates[0].id).ok, false);
});

test("unique and copy names avoid collisions without truncating the numeric suffix", () => {
  const base = "名".repeat(78);
  const stem = base.slice(0, 74);
  const templates = [
    customTemplate({ name: base }),
    customTemplate({ name: `${stem} 2` }),
  ];
  const unique = uniqueTemplateName(base, templates);
  assert.equal(unique.length <= 80, true);
  assert.equal(templates.some((template) => template.name === unique), false);
  // The shortening step keeps the whole "N" suffix visible.
  assert.equal(unique, `${stem} 3`);
  assert.equal(uniqueTemplateName(DEFAULT_TEMPLATE_NAME, []), DEFAULT_TEMPLATE_NAME);
  const copy = copyTemplateName("场记模板", templates);
  assert.ok(copy.includes(TEMPLATE_COPY_SUFFIX));
  assert.equal(copyTemplateName("场记模板", [...templates, customTemplate({ name: copy })]), "场记模板 · 副本 2");
});

test("templates store schema only and select round-trips through savedTemplateId", () => {
  const template = customTemplate({ name: "回环模板" });
  assert.equal(template.templateId, "custom");
  assert.equal(template.filenameTemplate, "a.csv");
  assert.equal(Object.keys(template).includes("savedTemplateId"), false);
  const options = normalizeExportOptions(exportOptionsFromTemplate(template));
  assert.equal(options.savedTemplateId, template.id);
  assert.equal(sameTemplateContent(options, template), true);
  // The link itself never participates in content comparison.
  assert.equal(sameTemplateContent(options, { ...template, id: "other" }), true);
});

test("renaming only changes the display name; content edits keep the library link", () => {
  const template = customTemplate();
  const options = normalizeExportOptions(exportOptionsFromTemplate(template));
  const renamed = applyEditorContentToTemplate({ ...template, name: "新名称" }, options);
  assert.equal(renamed.name, "新名称");
  assert.equal(renamed.id, template.id);
  assert.equal(sameTemplateContent(renamed, options), true);
  const edited = applyEditorContentToTemplate(template, normalizeExportOptions({
    ...options,
    format: { ...options.format, delimiter: ";" },
  }));
  assert.equal(edited.format.delimiter, ";");
  assert.equal(edited.id, template.id);
});

test("built-in template copies expand to the full custom column set without phantom drift", () => {
  const builtin = createResolveExportOptions();
  const canonical = canonicalTemplateSource(builtin);
  assert.equal(canonical.templateId, "custom");
  assert.equal(canonical.columns.length, CUSTOM_EXPORT_OPTIONS.columns.length);
  // Selecting the copy appends nothing: reselecting the same template never
  // shows a false "unsaved" difference.
  const once = normalizeExportOptions(exportOptionsFromTemplate(createExportTemplate({ name: "内置副本", options: canonical, templateId: "custom" })));
  const twice = normalizeExportOptions(exportOptionsFromTemplate(createExportTemplate({ name: "内置副本2", options: canonicalTemplateSource(once), templateId: "custom" })));
  assert.equal(sameTemplateContent(once, twice), true);
  // Non-builtin sources pass through unchanged.
  const customOptions = normalizeExportOptions({ ...CUSTOM_EXPORT_OPTIONS, templateId: "custom" });
  assert.equal(canonicalTemplateSource(customOptions), customOptions);
  assert.equal(defaultTemplateIdForOptions(builtin), "custom");
  assert.equal(defaultTemplateIdForOptions({ templateId: "imported-csv-v1" }), "imported-csv-v1");
  // The read-only built-in entry keeps the official registry content.
  assert.equal(exportOptionsForBuiltinTemplate().templateId, RESOLVE_TEMPLATE_ID);
});

test("imported sample column order and headers survive a template round-trip", () => {
  const imported = normalizeExportOptions({
    templateId: "imported-csv-v1",
    templateName: "样表",
    columns: [
      { key: "whatever", header: "自定义列", enabled: true },
      { key: "scene", header: "场次", enabled: true },
      { key: "take", header: "条次", enabled: false },
    ],
    filenameTemplate: "{source}.csv",
  });
  const template = createExportTemplate({ name: "导入样表", options: imported, templateId: "imported-csv-v1" });
  assert.equal(template.templateId, "imported-csv-v1");
  // Imported columns keep sample order and headers; keys are positional.
  assert.deepEqual(template.columns.map((column) => column.key), ["imported:0", "imported:1", "imported:2"]);
  assert.deepEqual(template.columns.map((column) => column.header), ["自定义列", "场次", "条次"]);
  const restored = normalizeExportOptions(exportOptionsFromTemplate(template));
  assert.deepEqual(restored.columns.map((column) => column.key), ["imported:0", "imported:1", "imported:2"]);
  assert.equal(restored.templateName, "导入样表");
});

test("deleting the current template prefers the next entry, then previous, then the built-in", () => {
  const a = customTemplate({ name: "A" });
  const b = customTemplate({ name: "B" });
  const c = customTemplate({ name: "C" });
  assert.equal(templateAfterDelete([a, b, c], a.id)?.id, b.id);
  assert.equal(templateAfterDelete([a, b, c], c.id)?.id, b.id);
  assert.equal(templateAfterDelete([a, b, c], b.id)?.id, c.id);
  assert.equal(templateAfterDelete([a], a.id), null);
  assert.equal(templateAfterDelete([], a.id), null);
  // Callers fall back to the read-only built-in when no entry remains.
  assert.equal(exportOptionsForBuiltinTemplate().templateId, RESOLVE_TEMPLATE_ID);
});

test("content comparison uses a fixed key order across renderers", () => {
  const left = templateContentOf({ format: { encoding: "utf-8", bom: true, delimiter: ",", lineEnding: "\r\n", finalNewline: true }, filenameTemplate: "x.csv", columns: [{ key: "scene", header: "Scene", enabled: true }], templateId: "custom" });
  const right = templateContentOf(createExportTemplate({ name: "n", options: { columns: [{ key: "scene", header: "Scene", enabled: true }], format: { encoding: "utf-8", bom: true, delimiter: ",", lineEnding: "\r\n", finalNewline: true }, filenameTemplate: "x.csv" }, templateId: "custom" }));
  assert.equal(JSON.stringify(left), JSON.stringify(right));
  assert.equal(sameTemplateContent(null, null), true);
});

test("lookup helpers tolerate missing lists and unknown ids", () => {
  const template = customTemplate();
  assert.equal(findExportTemplate([template], template.id), template);
  assert.equal(findExportTemplate([template], "missing"), null);
  assert.equal(findExportTemplate(undefined, template.id), null);
  assert.equal(findExportTemplate([template], ""), null);
  assert.equal(BUILTIN_TEMPLATE_LABEL.includes("DaVinci Resolve"), true);
  assert.equal(typeof DEFAULT_TEMPLATE_NAME, "string");
});

test("historical short custom presets do not become dirty when rendered", () => {
  // Editor projection expands disabled choices without changing the preset.
  const historical = { ...CUSTOM_EXPORT_OPTIONS, templateId: "custom", columns: CUSTOM_EXPORT_OPTIONS.columns.slice(0, 4) };
  assert.equal(sameTemplateContent(historical, normalizeExportOptions(historical)), true);
  assert.equal(sameTemplateContent(historical, { ...historical, filenameTemplate: "changed.csv" }), false);
});

import assert from "node:assert/strict";
import test from "node:test";

import {
  CUSTOM_EXPORT_OPTIONS,
  DEFAULT_EXPORT_OPTIONS,
  normalizeExportOptions,
  resolveEffectiveExportOptions,
  resolveExportFilename,
} from "../public/export-options.js";
import { RESOLVE_METADATA_FIELDS } from "../public/resolve-export-template.js";

test("export options use session, project, then system precedence", () => {
  const project = normalizeExportOptions({ filenameTemplate: "project.csv" });
  const session = normalizeExportOptions({ filenameTemplate: "session.csv" });
  assert.equal(resolveEffectiveExportOptions({ projectDefault: project }).source, "project");
  assert.equal(resolveEffectiveExportOptions({ projectDefault: project }).options.filenameTemplate, "project.csv");
  assert.equal(resolveEffectiveExportOptions({ sessionOverride: session, projectDefault: project }).source, "session");
  assert.equal(resolveEffectiveExportOptions({ sessionOverride: session, projectDefault: project }).options.filenameTemplate, "session.csv");
  assert.equal(resolveEffectiveExportOptions({}).options.filenameTemplate, DEFAULT_EXPORT_OPTIONS.filenameTemplate);
});

test("normalization drops unknown columns and guarantees one enabled column", () => {
  const options = normalizeExportOptions({
    columns: [
      { key: "unknown", header: "bad", enabled: true },
      { key: "sourcePage", header: "页码", enabled: false },
    ],
    format: { encoding: "gbk", delimiter: "\n" },
  });
  assert.deepEqual(options.columns.map((column) => column.key), ["sourcePage"]);
  assert.equal(options.columns[0].enabled, true);
  assert.equal(options.format.encoding, "utf-16le");
  assert.equal(options.format.delimiter, ",");
});

test("custom export exposes every documented Resolve metadata field", () => {
  const options = normalizeExportOptions({
    templateId: "custom",
    columns: [{ key: "scene", header: "Scene", enabled: true }],
  });
  const keys = new Set(options.columns.map((column) => column.key));
  for (const field of RESOLVE_METADATA_FIELDS) assert.equal(keys.has(field.key), true, field.key);
  assert.equal(options.columns.length, CUSTOM_EXPORT_OPTIONS.columns.length);
  assert.equal(options.columns.find((column) => column.key === "fileName")?.enabled, false);
  assert.equal(options.columns.find((column) => column.key === "audioNotes")?.header, "Audio Notes");
});

test("filename expansion is deterministic and remains a basename", () => {
  const clock = new Date(2026, 8, 12, 3, 4, 5);
  assert.equal(
    resolveExportFilename("{project}/{source}_{date}_{time}.csv", {
      project: "片名/../危险",
      source: "A001C001.mov",
    }, clock),
    "片名_.._危险_A001C001.mov_20260912_030405.csv",
  );
  assert.equal(resolveExportFilename("{missing}", { source: "slate" }, clock), "slate_Resolve元数据.csv");
});

test("template links ride through normalization and never leak into worker defaults", () => {
  const options = normalizeExportOptions({
    templateId: "custom",
    savedTemplateId: "tpl-1",
    columns: [{ key: "scene", header: "Scene", enabled: true }],
  });
  assert.equal(options.savedTemplateId, "tpl-1");
  // An absent link stays absent instead of inheriting a stale one.
  const unlinked = normalizeExportOptions({ templateId: "custom", savedTemplateId: undefined });
  assert.equal(unlinked.savedTemplateId, undefined);
  assert.equal(DEFAULT_EXPORT_OPTIONS.savedTemplateId, undefined);
});

// Old invalid delimiters must not reach the encoder.
test("unsupported delimiters migrate to an encodable default", () => {
  for (const delimiter of [";;", '"', "\u0000", "\n"]) {
    assert.equal(normalizeExportOptions({ templateId: "custom", format: { delimiter } }).format.delimiter, ",");
  }
});

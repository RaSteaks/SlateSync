import assert from "node:assert/strict";
import test from "node:test";

import {
  DEFAULT_EXPORT_OPTIONS,
  normalizeExportOptions,
  resolveEffectiveExportOptions,
  resolveExportFilename,
} from "../public/export-options.js";

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

test("filename expansion is deterministic and remains a basename", () => {
  const clock = new Date(2026, 8, 12, 3, 4, 5);
  assert.equal(
    resolveExportFilename("{project}/{source}_{date}_{time}.csv", {
      project: "片名/../危险",
      source: "A001C001.mov",
    }, clock),
    "片名_.._危险_A001C001.mov_20260912_030405.csv",
  );
  assert.equal(resolveExportFilename("{missing}", { source: "slate" }, clock), "slate_场记识别.csv");
});

import assert from "node:assert/strict";
import test from "node:test";

import {
  DEFAULT_PROJECT_SETTINGS,
  normalizeProjectSettings,
  projectSettingsFromWorkflow,
  projectSettingsTaskSnapshot,
  validateProjectSettings,
} from "../lib/project-settings.mjs";
import { RESOLVE_TEMPLATE_ID } from "../public/resolve-export-template.js";

test("project settings derive Resolve defaults from the workflow config", () => {
  const settings = projectSettingsFromWorkflow({
    resolve: {
      fieldFormats: { scene: "XXXX", shot: "XXX", take: "X" },
      comments: { goodTake: "GOOD", holdTake: "HOLD" },
    },
  });

  assert.equal(settings.version, 2);
  assert.deepEqual(settings.resolve, {
    fieldFormats: { scene: "XXXX", shot: "XXX", take: "X" },
    comments: { goodTake: "GOOD", holdTake: "HOLD" },
  });
  assert.equal(settings.providerId, null);
  assert.equal(settings.accuracyMode, "high");
  assert.equal(settings.export.format.encoding, "utf-8");
  assert.equal(settings.export.format.bom, true);
  assert.equal(settings.export.filenameTemplate, "{source}_Resolve元数据.csv");
});

test("normalization keeps project settings independent from mutable defaults", () => {
  const settings = normalizeProjectSettings({
    providerId: "openai",
    modelId: "gpt-vision",
    resolve: { fieldFormats: { scene: "XX" } },
  });

  settings.resolve.fieldFormats.scene = "X";
  assert.equal(DEFAULT_PROJECT_SETTINGS.resolve.fieldFormats.scene, "XXX");
  assert.equal(settings.resolve.fieldFormats.shot, "XX");
  assert.equal(settings.resolve.comments.goodTake, "_OK");
});

test("normalization is idempotent and does not mutate the input payload", () => {
  const input = {
    version: 1,
    providerId: " openai ",
    export: {
      columns: [
        { key: "scene", header: "", enabled: false },
        { key: "scene", header: "重复", enabled: true },
        { key: "shot", header: "Shot\u0000", enabled: false },
      ],
      format: { encoding: "utf-8" },
    },
    futureBranch: { nested: { keep: true } },
  };
  const before = structuredClone(input);
  const normalized = normalizeProjectSettings(input);
  assert.deepEqual(input, before);
  assert.deepEqual(normalizeProjectSettings(normalized), normalized);
  assert.deepEqual(normalized.export.columns.map((column) => column.key), ["scene", "shot"]);
  assert.equal(normalized.export.columns.some((column) => column.enabled), true);
  assert.equal(normalized.export.columns[1].header, "Shot");
});

test("invalid output formats are normalized to safe project defaults", () => {
  const settings = validateProjectSettings({
    resolve: {
      fieldFormats: { scene: "not-a-format", shot: "XXXXXX", take: "" },
      comments: { goodTake: "good\nvalue", holdTake: "HOLD" },
    },
  });

  assert.equal(settings.resolve.fieldFormats.scene, "XXX");
  assert.equal(settings.resolve.fieldFormats.shot, "XXXXXX");
  assert.equal(settings.resolve.fieldFormats.take, "XX");
  assert.equal(settings.resolve.comments.goodTake, "_OK");
  assert.equal(settings.resolve.comments.holdTake, "HOLD");
});

test("v1 settings upgrade preserves current export options and unknown branches", () => {
  const current = normalizeProjectSettings({
    version: 2,
    providerId: "openai",
    export: {
      columns: [{ key: "scene", header: "镜头场次", enabled: true }],
      format: {
        encoding: "utf-8",
        bom: false,
        delimiter: ";",
        lineEnding: "\n",
        finalNewline: false,
      },
      filenameTemplate: "custom.csv",
      futureExportFlag: { enabled: true },
    },
    futureBranch: { nested: { keep: "yes" } },
  });
  const upgraded = normalizeProjectSettings({
    version: 1,
    providerId: "openrouter",
    resolve: { fieldFormats: { scene: "XXXX" } },
  }, current);

  assert.equal(upgraded.version, 2);
  assert.equal(upgraded.providerId, "openrouter");
  assert.deepEqual(upgraded.export, current.export);
  assert.deepEqual(upgraded.futureBranch, { nested: { keep: "yes" } });
});

test("settings reject a future version instead of silently downgrading", () => {
  assert.throws(
    () => normalizeProjectSettings({ version: 3 }),
    (error) => error?.code === "UNSUPPORTED_PROJECT_SETTINGS_VERSION",
  );
});

test("GBK is accepted only as source encoding, never as output settings encoding", () => {
  const settings = normalizeProjectSettings({
    export: { format: { encoding: "gbk" } },
  });
  assert.equal(settings.export.format.encoding, "utf-16le");
});

test("template libraries normalize names, drop corrupt entries and keep the first duplicate", () => {
  const settings = normalizeProjectSettings({
    exportTemplates: [
      {
        id: "tpl-1",
        name: "  场记模板  ",
        templateId: "custom",
        columns: [{ key: "scene", header: "Scene", enabled: true }],
        format: { encoding: "utf-8", delimiter: ";", lineEnding: "\n", finalNewline: false },
        filenameTemplate: "{source}.csv",
      },
      // Same name as tpl-1: only the first occurrence survives.
      { id: "tpl-2", name: "场记模板", templateId: "custom", columns: [{ key: "take", header: "Take", enabled: true }] },
      // Missing name / unknown kind / duplicate id: dropped individually.
      { id: "tpl-3", name: "   ", templateId: "custom", columns: [] },
      { id: "tpl-4", name: "未知类型", templateId: "legacy-x", columns: [] },
      { id: "tpl-1", name: "重复ID", templateId: "custom", columns: [] },
    ],
  });

  assert.deepEqual(settings.exportTemplates.map((template) => template.id), ["tpl-1"]);
  assert.equal(settings.exportTemplates[0].name, "场记模板");
  assert.equal(settings.exportTemplates[0].templateId, "custom");
  assert.equal(settings.exportTemplates[0].filenameTemplate, "{source}.csv");
  assert.equal(settings.exportTemplates[0].format.delimiter, ";");
  assert.equal(settings.exportTemplates[0].columns[0].enabled, true);
});

test("invalid template references are cleaned while the export configuration survives", () => {
  const cleaned = normalizeProjectSettings({
    exportTemplates: [],
    export: { savedTemplateId: "gone", filenameTemplate: "kept.csv" },
  });
  assert.equal(cleaned.export.savedTemplateId, undefined);
  assert.equal(cleaned.export.filenameTemplate, "kept.csv");

  const linked = normalizeProjectSettings({
    exportTemplates: [{
      id: "tpl-ok",
      name: "可用模板",
      templateId: "custom",
      columns: [{ key: "scene", header: "Scene", enabled: true }],
      format: {},
      filenameTemplate: "t.csv",
    }],
    export: { savedTemplateId: "tpl-ok", filenameTemplate: "t.csv" },
  });
  assert.equal(linked.export.savedTemplateId, "tpl-ok");

  // The implicit read-only built-in is never referenced by savedTemplateId.
  const builtinLinked = normalizeProjectSettings({
    exportTemplates: [{
      id: "tpl-ok",
      name: "可用模板",
      templateId: "custom",
      columns: [{ key: "scene", header: "Scene", enabled: true }],
      format: {},
      filenameTemplate: "t.csv",
    }],
    export: { templateId: RESOLVE_TEMPLATE_ID, savedTemplateId: "tpl-ok" },
  });
  assert.equal(builtinLinked.export.savedTemplateId, undefined);
});

test("historical projects stay template-free and normalization is idempotent", () => {
  const legacy = normalizeProjectSettings({ providerId: "openai" });
  assert.equal(Object.hasOwn(legacy, "exportTemplates"), false);

  const withLibrary = normalizeProjectSettings({
    exportTemplates: [{
      id: "tpl-1",
      name: "模板",
      templateId: "custom",
      columns: [{ key: "scene", header: "Scene", enabled: true }],
      format: {},
      filenameTemplate: "t.csv",
    }],
    export: { savedTemplateId: "tpl-1" },
  });
  const again = normalizeProjectSettings(withLibrary);
  assert.deepEqual(again, withLibrary);
  assert.deepEqual(JSON.parse(JSON.stringify(again)), JSON.parse(JSON.stringify(withLibrary)));
});

test("task snapshots keep only the effective export configuration", () => {
  // Stripping project metadata must not change pre-export defaults.
  assert.deepEqual(projectSettingsTaskSnapshot({}), normalizeProjectSettings({}));
  const settings = normalizeProjectSettings({
    exportTemplates: [{
      id: "tpl-1",
      name: "模板",
      templateId: "imported-csv-v1",
      columns: [{ key: "imported:0", header: "列", enabled: true }],
      format: {},
      filenameTemplate: "t.csv",
    }],
    export: { templateId: "imported-csv-v1", savedTemplateId: "tpl-1" },
    futureBranch: { keep: true },
  });
  const snapshot = projectSettingsTaskSnapshot(settings);
  assert.equal(snapshot.exportTemplates, undefined);
  assert.equal(snapshot.export.savedTemplateId, undefined);
  assert.equal(snapshot.export.templateId, "imported-csv-v1");
  assert.equal(snapshot.export.columns.length > 0, true);
  assert.deepEqual(snapshot.futureBranch, { keep: true });
  // Snapshots tolerate raw payloads too.
  assert.equal(projectSettingsTaskSnapshot(null).version, 2);
});

// Old invalid delimiters must not reach the encoder.
test("unsupported delimiters migrate to an encodable default", () => {
  for (const delimiter of [";;", '"', "\u0000", "\n"]) {
    assert.equal(normalizeProjectSettings({ export: { templateId: "custom", format: { delimiter } } }).export.format.delimiter, ",");
  }
});

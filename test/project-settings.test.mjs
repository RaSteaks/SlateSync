import assert from "node:assert/strict";
import test from "node:test";

import {
  DEFAULT_PROJECT_SETTINGS,
  normalizeProjectSettings,
  projectSettingsFromWorkflow,
  validateProjectSettings,
} from "../lib/project-settings.mjs";

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
  assert.equal(settings.export.format.encoding, "utf-16le");
  assert.equal(settings.export.format.bom, true);
  assert.equal(settings.export.filenameTemplate, "{source}_场记识别.csv");
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

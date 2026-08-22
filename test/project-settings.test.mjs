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

  assert.equal(settings.version, 1);
  assert.deepEqual(settings.resolve, {
    fieldFormats: { scene: "XXXX", shot: "XXX", take: "X" },
    comments: { goodTake: "GOOD", holdTake: "HOLD" },
  });
  assert.equal(settings.providerId, null);
  assert.equal(settings.accuracyMode, "high");
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

import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { readFile } from "node:fs/promises";
import test from "node:test";

// The manifest is reviewed evidence, not an auto-update source. This test
// recomputes every file fact and requires the completed two-run stability mark.
const visualRoot = new URL("../.codex/refactor/baseline/visual/", import.meta.url);
const requiredStates = [
  "project-library",
  "workspace-empty",
  "workspace-ready",
  "recognition-progress",
  "result-detail",
  "csv-preview",
  "project-settings",
  "global-settings",
  "new-project-dialog",
  "ocr-setup-dialog",
];
const expectedRoutes = [
  "projects",
  "workspace",
  "workspace",
  "workspace",
  "workspace",
  "workspace",
  "project-settings",
  "global-settings",
  "projects",
  "global-settings",
];

function pngDimensions(bytes) {
  assert.deepEqual([...bytes.subarray(0, 8)], [137, 80, 78, 71, 13, 10, 26, 10]);
  return { width: bytes.readUInt32BE(16), height: bytes.readUInt32BE(20) };
}

test("baseline visual manifest contains stable isolated 1440x900 Renderer captures", async () => {
  const manifest = JSON.parse(await readFile(new URL("manifest.json", visualRoot), "utf8"));
  assert.match(manifest.capturedAt, /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z$/);
  assert.equal(manifest.fixtureId, "synthetic-project-library-v1");
  assert.match(manifest.platform, /^(darwin|linux|win32)-(arm64|x64)$/);
  assert.equal(manifest.electron, "43.3.0");
  assert.equal(manifest.captureCommand, "./node_modules/.bin/electron test-support/baseline/capture-visuals.mjs");
  assert.deepEqual(manifest.viewport, { width: 1440, height: 900, kind: "content" });
  assert.equal(manifest.deviceScaleFactor, 1);
  assert.equal(manifest.appearance, "light");
  assert.equal(manifest.reducedMotion, true);
  assert.equal(manifest.locale, "zh-CN");
  assert.equal(manifest.timezone, "Asia/Shanghai");
  assert.equal(manifest.stability.verifiedAgainstPreviousRun, true);
  assert.equal(manifest.stability.identicalCaptureCount, 10);
  assert.deepEqual(manifest.captures.map(({ state }) => state), requiredStates);
  assert.deepEqual(manifest.captures.map(({ route }) => route), expectedRoutes);

  for (const capture of manifest.captures) {
    assert.equal(capture.fixtureId, manifest.fixtureId);
    const bytes = await readFile(new URL(capture.file, visualRoot));
    assert.equal(bytes.length, capture.bytes, `${capture.state} byte count drift`);
    assert.equal(createHash("sha256").update(bytes).digest("hex"), capture.sha256, `${capture.state} hash drift`);
    assert.deepEqual(pngDimensions(bytes), { width: capture.width, height: capture.height });
    assert.deepEqual({ width: capture.width, height: capture.height }, { width: 1440, height: 900 });
  }
});

import { describe, it, beforeEach, afterEach } from "node:test";
import assert from "node:assert/strict";
import { mkdtemp, rm, writeFile, stat, chmod } from "node:fs/promises";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { createSettingsStore } from "../electron/settings-store.mjs";
import { checkPaddleOcr } from "../lib/ocr/paddleocr.mjs";

describe("settings-store", () => {
  let tempDir;

  beforeEach(async () => {
    tempDir = await mkdtemp(join(tmpdir(), "slatesync-settings-"));
  });

  afterEach(async () => {
    await rm(tempDir, { recursive: true, force: true });
  });

  it("returns defaults when no file exists", async () => {
    const store = createSettingsStore(tempDir);
    assert.deepEqual(await store.load(), {
      // The library root is a machine setting; project data remains in the
      // selected library and is never placed in this settings file.
      libraryPath: "",
      ocrPythonPath: "",
      ocrSetupCompleted: false,
      ocrSetupSkipped: false,
    });
  });

  it("saves and loads OCR settings", async () => {
    const store = createSettingsStore(tempDir);
    await store.save({
      ocrPythonPath: "/venv/bin/python",
      ocrSetupCompleted: true,
    });
    const loaded = await store.load();
    assert.equal(loaded.ocrPythonPath, "/venv/bin/python");
    assert.equal(loaded.ocrSetupCompleted, true);
    assert.equal(loaded.ocrSetupSkipped, false);
  });

  it("sanitizes unknown and non-string fields on load", async () => {
    const store = createSettingsStore(tempDir);
    await writeFile(
      join(tempDir, "settings.json"),
      JSON.stringify({ ocrPythonPath: 42, ocrSetupSkipped: true, junk: "x" }),
    );
    const loaded = await store.load();
    assert.equal(loaded.ocrPythonPath, "");
    assert.equal(loaded.ocrSetupSkipped, true);
    assert.equal("junk" in loaded, false);
  });

  it("handles corrupted JSON gracefully", async () => {
    const store = createSettingsStore(tempDir);
    await writeFile(join(tempDir, "settings.json"), "not json{{{");
    assert.equal((await store.load()).ocrPythonPath, "");
  });

  it("sets restrictive file permissions", async () => {
    const store = createSettingsStore(tempDir);
    await store.save({ ocrPythonPath: "/venv/bin/python" });
    const fileStat = await stat(join(tempDir, "settings.json"));
    assert.equal(fileStat.mode & 0o777, 0o600);
  });
});

describe("checkPaddleOcr", () => {
  it("parses the runner --check sentinel", { skip: process.platform === "win32" }, async () => {
    const tempDir = await mkdtemp(join(tmpdir(), "slatesync-ocr-check-"));
    const fakePython = join(tempDir, "python");
    await writeFile(
      fakePython,
      '#!/bin/sh\necho \'__SLATESYNC_OCR_JSON__{"ok":true,"paddleVersion":"3.3.1","paddleOcrVersion":"3.7.0"}\'\n',
    );
    await chmod(fakePython, 0o755);

    const result = await checkPaddleOcr({ pythonPath: fakePython, timeoutMs: 5000 });
    await rm(tempDir, { recursive: true, force: true });

    assert.equal(result.ok, true);
    assert.equal(result.paddleVersion, "3.3.1");
    assert.equal(result.paddleOcrVersion, "3.7.0");
  });

  it("reports a spawn failure for a missing interpreter", async () => {
    const result = await checkPaddleOcr({
      pythonPath: "/nonexistent/python-slatesync",
      timeoutMs: 5000,
    });
    assert.equal(result.ok, false);
    assert.equal(result.error.code, "spawn_failed");
  });
});

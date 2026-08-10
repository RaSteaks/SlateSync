import { describe, it, beforeEach, afterEach } from "node:test";
import assert from "node:assert/strict";
import { mkdtemp, rm, readFile, stat } from "node:fs/promises";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { createKeyStore } from "../lib/key-store.mjs";

describe("electron key-store", () => {
  let tempDir;

  beforeEach(async () => {
    tempDir = await mkdtemp(join(tmpdir(), "slatesync-test-"));
  });

  afterEach(async () => {
    await rm(tempDir, { recursive: true, force: true });
  });

  it("returns empty map when no file exists", async () => {
    const store = createKeyStore(tempDir);
    const keys = await store.load();
    assert.equal(keys.size, 0);
  });

  it("saves and loads provider keys", async () => {
    const store = createKeyStore(tempDir);
    const keys = new Map([
      ["openai", "sk-test-openai"],
      ["dashscope", "sk-test-dashscope"],
    ]);
    await store.save(keys);

    const loaded = await store.load();
    assert.equal(loaded.get("openai"), "sk-test-openai");
    assert.equal(loaded.get("dashscope"), "sk-test-dashscope");
    assert.equal(loaded.size, 2);
  });

  it("overwrites existing keys on save", async () => {
    const store = createKeyStore(tempDir);
    await store.save(new Map([["openai", "sk-old"]]));
    await store.save(new Map([["openai", "sk-new"]]));

    const loaded = await store.load();
    assert.equal(loaded.get("openai"), "sk-new");
    assert.equal(loaded.size, 1);
  });

  it("handles empty map save", async () => {
    const store = createKeyStore(tempDir);
    await store.save(new Map([["openai", "sk-test"]]));
    await store.save(new Map());

    const loaded = await store.load();
    assert.equal(loaded.size, 0);
  });

  it("sets restrictive file permissions", async () => {
    const store = createKeyStore(tempDir);
    await store.save(new Map([["openai", "sk-test"]]));

    const filePath = join(tempDir, "provider-keys.json");
    const fileStat = await stat(filePath);
    // Check owner-only read/write (0o600)
    const mode = fileStat.mode & 0o777;
    assert.equal(mode, 0o600);
  });

  it("ignores empty or non-string values on load", async () => {
    const store = createKeyStore(tempDir);
    // Manually write a file with mixed valid/invalid entries
    const { writeFile } = await import("node:fs/promises");
    await writeFile(
      join(tempDir, "provider-keys.json"),
      JSON.stringify({
        openai: "sk-valid",
        empty: "",
        whitespace: "  ",
        number: 42,
        null: null,
      }),
    );

    const loaded = await store.load();
    assert.equal(loaded.get("openai"), "sk-valid");
    assert.equal(loaded.size, 1);
  });

  it("handles corrupted JSON gracefully", async () => {
    const store = createKeyStore(tempDir);
    const { writeFile } = await import("node:fs/promises");
    await writeFile(join(tempDir, "provider-keys.json"), "not json{{{");

    const loaded = await store.load();
    assert.equal(loaded.size, 0);
  });
});

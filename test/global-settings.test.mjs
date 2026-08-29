import assert from "node:assert/strict";
import { mkdtemp, readFile, rm, stat, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";
import {
  GLOBAL_SETTING_DEFAULTS,
  GLOBAL_SETTING_KEYS,
  applyGlobalConfig,
  normalizeGlobalSettingsPatch,
  normalizeOcrRoutingPatch,
  resolveGlobalSettingValues,
  sanitizeGlobalConfig,
} from "../electron/global-settings.mjs";
import { createGlobalConfigStore } from "../electron/global-config-store.mjs";

const envExampleUrl = new URL("../.env.example", import.meta.url);

test("Global Settings covers every non-secret .env.example variable", async () => {
  const source = await readFile(envExampleUrl, "utf8");
  const exampleKeys = [...source.matchAll(/^([A-Z][A-Z0-9_]*)=/gm)].map((match) => match[1]);
  const secretKeys = new Set(exampleKeys.filter((key) => key.endsWith("_API_KEY")));
  const nonSecretKeys = exampleKeys.filter((key) => !secretKeys.has(key));

  assert.equal(new Set(GLOBAL_SETTING_KEYS).size, GLOBAL_SETTING_KEYS.length);
  assert.deepEqual([...new Set(GLOBAL_SETTING_KEYS)].sort(), [...new Set(nonSecretKeys)].sort());
  assert.deepEqual(Object.keys(GLOBAL_SETTING_DEFAULTS).sort(), [...new Set(nonSecretKeys)].sort());
});

test("Global Settings validates patches and only overlays approved keys", () => {
  assert.deepEqual(
    normalizeGlobalSettingsPatch({
      OPENAI_BASE_URL: "https://api.example.test/v1/",
      OPENAI_COMPATIBLE_API_MODE: "RESPONSES",
      MAX_BODY_MB: "120",
      PADDLEOCR_MIN_CONFIDENCE: "0.25",
      PADDLEOCR_PYTHON: null,
    }),
    {
      OPENAI_BASE_URL: "https://api.example.test/v1",
      OPENAI_COMPATIBLE_API_MODE: "responses",
      MAX_BODY_MB: "120",
      PADDLEOCR_MIN_CONFIDENCE: "0.25",
      PADDLEOCR_PYTHON: "",
    },
  );
  assert.throws(() => normalizeGlobalSettingsPatch({ UNKNOWN_SETTING: "x" }), /不支持的全局配置项/);
  assert.throws(() => normalizeGlobalSettingsPatch({ OPENAI_BASE_URL: "file:///tmp/provider" }), /http|https/);
  assert.throws(() => normalizeGlobalSettingsPatch({ MAX_BODY_MB: "201" }), /20–200/);
  assert.throws(() => normalizeGlobalSettingsPatch({ PADDLEOCR_PROFILE: "turbo" }), /fast、balanced、accurate/);
  assert.equal(normalizeGlobalSettingsPatch({ VISIONOCR_TIMEOUT_MS: "1800000" }).VISIONOCR_TIMEOUT_MS, "1800000");
  assert.throws(() => normalizeGlobalSettingsPatch({ VISIONOCR_TIMEOUT_MS: "1800001" }), /10000–1800000/);
  assert.throws(() => normalizeGlobalSettingsPatch({ MAX_BODY_MB: 120 }), /必须是文本值/);

  const env = applyGlobalConfig(
    { OPENAI_BASE_URL: "https://from-env.test/v1", MAX_BODY_MB: "80" },
    { OPENAI_BASE_URL: "https://from-settings.test/v1", MAX_BODY_MB: "140", OPENAI_API_KEY: "must-not-apply" },
  );
  assert.equal(env.OPENAI_BASE_URL, "https://from-settings.test/v1");
  assert.equal(env.MAX_BODY_MB, "140");
  assert.equal(env.OPENAI_API_KEY, undefined);
  assert.equal(resolveGlobalSettingValues({}).MAX_BODY_MB, "80");
  assert.equal(sanitizeGlobalConfig({ MAX_BODY_MB: "100", OPENAI_BASE_URL: "file:///tmp/no" }).MAX_BODY_MB, "100");
  assert.equal(sanitizeGlobalConfig({ MAX_BODY_MB: "999", OPENAI_BASE_URL: "file:///tmp/no" }).MAX_BODY_MB, undefined);
});

test("explicit OCR enablement clears the competing engine route", () => {
  assert.deepEqual(
    normalizeOcrRoutingPatch({ PADDLEOCR_ENABLED: "true" }),
    {
      PADDLEOCR_ENABLED: "true",
      VISIONOCR_ENABLED: "false",
      VISIONOCR_REQUIRED: "false",
    },
  );
  assert.deepEqual(
    normalizeOcrRoutingPatch({ VISIONOCR_ENABLED: "true" }),
    {
      VISIONOCR_ENABLED: "true",
      PADDLEOCR_ENABLED: "false",
      PADDLEOCR_REQUIRED: "false",
    },
  );
});

test("global-config.json is versioned, private, atomic, and resilient to bad input", async () => {
  const root = await mkdtemp(join(tmpdir(), "slatesync-global-config-"));
  try {
    const store = createGlobalConfigStore(root);
    const saved = await store.save({
      OPENAI_BASE_URL: "https://api.example.test/v1",
      MAX_BODY_MB: "120",
      OPENAI_API_KEY: "should-never-be-stored",
      UNKNOWN_SETTING: "should-never-be-stored",
    });
    assert.deepEqual(saved, {
      version: 1,
      values: {
        OPENAI_BASE_URL: "https://api.example.test/v1",
        MAX_BODY_MB: "120",
      },
    });
    assert.deepEqual(await store.load(), saved);
    assert.equal((await stat(join(root, "global-config.json"))).mode & 0o777, 0o600);

    await writeFile(
      join(root, "global-config.json"),
      JSON.stringify({ version: 1, values: { MAX_BODY_MB: "100", OPENAI_BASE_URL: "file:///bad", PADDLEOCR_PROFILE: "bad" } }),
    );
    assert.deepEqual(await store.load(), { version: 1, values: { MAX_BODY_MB: "100" } });

    await writeFile(join(root, "global-config.json"), "not-json{{{");
    assert.deepEqual(await store.load(), { version: 1, values: {} });
  } finally {
    await rm(root, { recursive: true, force: true });
  }
});

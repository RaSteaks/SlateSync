import assert from "node:assert/strict";
import test from "node:test";
import {
  DEFAULT_WORKFLOW_CONFIG,
  MODELS,
  normalizeWorkflowConfig,
  publicConfig,
  resolveModel,
  resolveProvider,
} from "../lib/config.mjs";
import { formatSlateResultFields } from "../lib/schema.mjs";
import { describeProviderModel } from "../lib/model-catalog.mjs";

test("workflow config defaults to four directory levels and XXX/XX/XX", () => {
  assert.deepEqual(normalizeWorkflowConfig({}), DEFAULT_WORKFLOW_CONFIG);
  assert.deepEqual(publicConfig({}).workflow, DEFAULT_WORKFLOW_CONFIG);
});

test("workflow config accepts scan depth and fixed-width X templates", () => {
  assert.deepEqual(
    normalizeWorkflowConfig({
      slate: { maxDirectoryDepth: 6 },
      resolve: {
        fieldFormats: { scene: "XXXX", shot: "XXX", take: "X" },
      },
    }),
    {
      slate: { maxDirectoryDepth: 6 },
      resolve: {
        fieldFormats: { scene: "XXXX", shot: "XXX", take: "X" },
      },
    },
  );
});

test("workflow config rejects unsafe depth and non-X field formats", () => {
  assert.throws(
    () => normalizeWorkflowConfig({ slate: { maxDirectoryDepth: 0 } }),
    /1–12/,
  );
  assert.throws(
    () =>
      normalizeWorkflowConfig({
        resolve: { fieldFormats: { scene: "000" } },
      }),
    /1–6 个 X/,
  );
});

test("recognition results follow configured field widths before reaching the browser", () => {
  const result = formatSlateResultFields(
    {
      records: [{ scene: "037", shot: "02", take: "09" }],
      warnings: [],
    },
    { scene: "XXXX", shot: "XXX", take: "X" },
  );
  assert.deepEqual(result.records[0], {
    scene: "0037",
    shot: "002",
    take: "9",
  });
});

test("DashScope provider resolves with BaiLian defaults and fixed models", () => {
  const provider = resolveProvider("dashscope");
  assert.equal(provider.label, "阿里云百炼（DashScope）");
  assert.equal(provider.defaultBaseUrl, "https://dashscope.aliyuncs.com/compatible-mode/v1");
  assert.equal(provider.transport, "chat-completions");
  assert.equal(provider.chatJsonMode, "json_schema");
  assert.equal(provider.supportsDirectPdf, false);
  assert.deepEqual(provider.requiredEnv, ["DASHSCOPE_API_KEY"]);

  const fixed = MODELS.filter((model) =>
    model.providers.includes("dashscope"),
  );
  assert.deepEqual(
    fixed.map((model) => model.id),
    [
      "qwen3.8-max",
      "qwen3.7-max",
      "qwen-vl-max-latest",
      "qwen3-vl-plus-latest",
      "qwen-vl-plus-latest",
    ],
  );

  const resolved = resolveModel("dashscope", "qwen-vl-max-latest");
  assert.equal(resolved.apiId, "qwen-vl-max-latest");
  assert.equal(resolved.label, "Qwen VL Max");

  const flagship = resolveModel("dashscope", "qwen3.8-max");
  assert.equal(flagship.apiId, "qwen3.8-max");
  assert.equal(flagship.qualityScore, 93);
});

test("public config exposes DashScope readiness and no secret values", () => {
  const configured = publicConfig({ DASHSCOPE_API_KEY: "sk-test" });
  const dashscope = configured.providers.find(
    (provider) => provider.id === "dashscope",
  );
  assert.equal(dashscope.configured, true);
  assert.equal("DASHSCOPE_API_KEY" in configured, false);

  const unconfigured = publicConfig({});
  const missing = unconfigured.providers.find(
    (provider) => provider.id === "dashscope",
  );
  assert.equal(missing.configured, false);
});

test("DashScope discovery keeps multimodal flagships without modality declarations", () => {
  const flagships = [
    "qwen3.8-max",
    "qwen3.7-max",
    "qwen3.7-max-2026-06-08",
    "qwen-vl-max-latest",
  ];
  for (const apiId of flagships) {
    const descriptor = describeProviderModel("dashscope", { id: apiId });
    assert.ok(descriptor, `${apiId} 应通过白名单`);
  }

  const textOnly = describeProviderModel("dashscope", {
    id: "qwen3.7-plus",
  });
  assert.equal(textOnly, null);
});

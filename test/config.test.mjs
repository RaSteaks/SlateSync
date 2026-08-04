import assert from "node:assert/strict";
import test from "node:test";
import {
  DEFAULT_WORKFLOW_CONFIG,
  normalizeWorkflowConfig,
  publicConfig,
} from "../lib/config.mjs";
import { formatSlateResultFields } from "../lib/schema.mjs";

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

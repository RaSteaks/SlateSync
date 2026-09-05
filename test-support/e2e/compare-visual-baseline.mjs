#!/usr/bin/env node

import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { readFile, writeFile } from "node:fs/promises";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const root = resolve(dirname(fileURLToPath(import.meta.url)), "../..");
const generatedRoot = join(root, "test-results", "refactor", "IP-03-08");
const firstRoot = resolve(process.argv[2] || join(generatedRoot, "visual-run-1"));
const secondRoot = resolve(process.argv[3] || join(generatedRoot, "visual-run-2"));
const first = JSON.parse(await readFile(join(firstRoot, "manifest.json"), "utf8"));
const second = JSON.parse(await readFile(join(secondRoot, "manifest.json"), "utf8"));
assert.deepEqual(second.viewportStates.map((item) => item.name), first.viewportStates.map((item) => item.name));
const comparisons = [];
for (const item of first.viewportStates) {
  const firstBytes = await readFile(join(firstRoot, item.name));
  const secondBytes = await readFile(join(secondRoot, item.name));
  const firstHash = createHash("sha256").update(firstBytes).digest("hex");
  const secondHash = createHash("sha256").update(secondBytes).digest("hex");
  assert.equal(firstHash, secondHash, `visual baseline drift: ${item.name}`);
  comparisons.push({ name: item.name, bytes: firstBytes.byteLength, sha256: firstHash, identical: true });
}
// The comparison is generated test output. Curated review conclusions belong
// in Markdown summaries rather than a copied raw JSON result.
const evidencePath = resolve(process.argv[4] || join(generatedRoot, "visual-stability.json"));
await writeFile(evidencePath, `${JSON.stringify({ firstRoot, secondRoot, comparisons }, null, 2)}\n`, "utf8");
process.stdout.write(`VISUAL_BASELINE_STABLE_OK ${comparisons.length} ${evidencePath}\n`);

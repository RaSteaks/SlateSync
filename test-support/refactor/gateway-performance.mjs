#!/usr/bin/env node

// This benchmark measures only local Promise/Result/adapter overhead. It
// never opens Electron, Main services, a Worker, a database, or a network
// request, so it cannot change production state. Generated measurements stay
// under ignored test-results instead of becoming repository evidence files.
import { mkdir, writeFile } from "node:fs/promises";
import { dirname, resolve } from "node:path";
import { performance } from "node:perf_hooks";
import { fileURLToPath } from "node:url";
import { createSlateSyncApi } from "../../out/preload/index.cjs";

const root = resolve(fileURLToPath(new URL("../..", import.meta.url)));
const calls = [];
const transport = {
  invoke(channel, payload) {
    calls.push({ channel, payload });
    return Promise.resolve({ ready: true });
  },
  on() {},
  removeListener() {},
};
const api = createSlateSyncApi(transport);
globalThis.slateSync = api;
const { fetchConfig } = await import("../../public/electron-bridge.js");

const warmup = 50;
const samples = 1_000;
for (let index = 0; index < warmup; index += 1) await transport.invoke("get-config");
for (let index = 0; index < warmup; index += 1) await api.app.getConfig();
for (let index = 0; index < warmup; index += 1) await fetchConfig();

async function measure(operation) {
  const values = [];
  for (let index = 0; index < samples; index += 1) {
    const startedAt = performance.now();
    await operation();
    values.push(performance.now() - startedAt);
  }
  values.sort((left, right) => left - right);
  return {
    medianMs: values[Math.floor(values.length / 2)],
    p95Ms: values[Math.floor(values.length * 0.95)],
  };
}

const raw = await measure(() => transport.invoke("get-config"));
const typed = await measure(() => api.app.getConfig());
const legacyAdapter = await measure(() => fetchConfig());
const evidence = {
  methodology: "1,000 sequential local resolved calls after 50 warmups; performance.now around each Promise.",
  samples,
  raw,
  typed,
  legacyAdapter,
  typedOverheadMedianMs: typed.medianMs - raw.medianMs,
  adapterOverheadMedianMs: legacyAdapter.medianMs - raw.medianMs,
  transportCalls: calls.length,
};
const output = resolve(root, "test-results/refactor/IP-02/performance.json");
await mkdir(dirname(output), { recursive: true });
await writeFile(output, JSON.stringify(evidence, null, 2) + "\n", "utf8");
console.log(JSON.stringify(evidence));

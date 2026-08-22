import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";
import { recognizeSlate } from "../lib/ai-client.mjs";
import { normalizeSlateResult } from "../lib/schema.mjs";
import { recognizeApi } from "../public/electron-bridge.js";

// These tests inject provider responses and disable local OCR so the frozen
// recognition contract never depends on credentials, network, or model drift.
const fixtureRoot = new URL("./fixtures/baseline/recognition/", import.meta.url);
const imageDataUrl = "data:image/png;base64,AA==";

async function fixture(name) {
  return JSON.parse(await readFile(new URL(name, fixtureRoot), "utf8"));
}

function env(overrides = {}) {
  return {
    OPENAI_API_KEY: "synthetic-key",
    PADDLEOCR_ENABLED: "false",
    VISIONOCR_ENABLED: "false",
    ...overrides,
  };
}

function jsonResponse(value, status = 200) {
  return new Response(JSON.stringify(value), {
    status,
    headers: { "Content-Type": "application/json" },
  });
}

function modelResponse(records = [], warnings = []) {
  return jsonResponse({
    output_text: JSON.stringify({ sheetTitle: "synthetic", records, warnings }),
  });
}

function deferred() {
  let resolve;
  const promise = new Promise((settle) => {
    resolve = settle;
  });
  return { promise, resolve };
}

test("baseline recognition normalization preserves current field semantics", async () => {
  const data = await fixture("normalization.json");
  const result = normalizeSlateResult(data.input);
  assert.deepEqual(result.records.map((record) => record.scene), data.expected.scenes);
  assert.deepEqual(result.records.map((record) => record.shot), data.expected.shots);
  assert.deepEqual(result.records.map((record) => record.take), data.expected.takes);
  assert.deepEqual(result.records.map((record) => record.takeStatus), data.expected.statuses);
  assert.deepEqual(result.warnings, data.expected.warnings);
});

test("baseline page recognition retains input order, source pages, inheritance, and progress", async () => {
  const data = await fixture("pages.json");
  const progress = [];
  const requests = [];
  const pages = new Map(data.pages.map((page) => [page.pageNumber, page]));
  const gates = new Map(data.pages.map((page) => [page.pageNumber, deferred()]));
  const started = new Map(data.pages.map((page) => [page.pageNumber, deferred()]));
  const completionOrder = [];
  // Controlled response promises prove ordering without making wall-clock
  // scheduling part of the compatibility contract.
  const recognition = recognizeSlate(
    {
      providerId: "openai",
      modelId: "openai/gpt-4o-mini",
      imageDataUrls: [imageDataUrl, imageDataUrl, imageDataUrl],
      filename: "baseline-pages.png",
      accuracyMode: "standard",
    },
    {
      env: env(),
      onProgress: (event) => progress.push(event),
      fetchImpl: async (_url, request) => {
        const body = JSON.parse(request.body);
        requests.push(body);
        const page = Number(JSON.stringify(body).match(/第 (\d+)\/3 页/)?.[1] || requests.length);
        started.get(page).resolve();
        const response = await gates.get(page).promise;
        completionOrder.push(page);
        return response;
      },
    },
  );

  await Promise.all([started.get(1).promise, started.get(2).promise]);
  gates.get(2).resolve(modelResponse(pages.get(2).records));
  await started.get(3).promise;
  gates.get(3).resolve(modelResponse(pages.get(3).records));
  gates.get(1).resolve(modelResponse(pages.get(1).records));
  const result = await recognition;

  assert.equal(result.pageCount, 3);
  assert.deepEqual(result.result.records.map((record) => record.sourcePage), data.expected.sourcePages);
  assert.deepEqual(result.result.records.map((record) => record.videoCode), ["C001", "C002"]);
  assert.equal(result.result.records[1].scene, "001");
  assert.equal(result.result.records[1].shot, "01");
  assert.ok(result.result.warnings.some((warning) => warning.includes(data.expected.warningIncludes[0])));
  assert.ok(requests.length === 3);
  assert.deepEqual(completionOrder, data.expected.completionOrder);
  assert.deepEqual(progress.map((event) => event.phase), data.expected.progressPhases);
  assert.ok(progress.every((event) => Number.isFinite(event.percent) && event.percent >= 0 && event.percent <= 100));
  assert.ok(progress.every((event, index) => index === 0 || event.percent >= progress[index - 1].percent));
});

test("baseline page concurrency defaults to two without depending on timing", async () => {
  let active = 0;
  let maxActive = 0;
  let calls = 0;
  const result = await recognizeSlate(
    {
      providerId: "openai",
      modelId: "openai/gpt-4o-mini",
      imageDataUrls: Array.from({ length: 5 }, () => imageDataUrl),
      filename: "baseline-concurrency.png",
      accuracyMode: "standard",
    },
    {
      env: env(),
      fetchImpl: async () => {
        calls += 1;
        active += 1;
        maxActive = Math.max(maxActive, active);
        await Promise.resolve();
        active -= 1;
        return modelResponse();
      },
    },
  );
  assert.equal(calls, 5);
  assert.equal(maxActive, 2);
  assert.equal(result.pageCount, 5);
});

test("baseline page concurrency accepts a valid override without timing assertions", async () => {
  let active = 0;
  let maxActive = 0;
  let calls = 0;
  let pending = [];
  const result = await recognizeSlate(
    {
      providerId: "openai",
      modelId: "openai/gpt-4o-mini",
      imageDataUrls: Array.from({ length: 6 }, () => imageDataUrl),
      filename: "baseline-concurrency-override.png",
      accuracyMode: "standard",
    },
    {
      env: env({ MODEL_PAGE_CONCURRENCY: "3" }),
      fetchImpl: async () => {
        calls += 1;
        active += 1;
        maxActive = Math.max(maxActive, active);
        const gate = deferred();
        pending.push(() => {
          active -= 1;
          gate.resolve(modelResponse());
        });
        if (pending.length === 3) {
          const batch = pending;
          pending = [];
          queueMicrotask(() => batch.forEach((release) => release()));
        }
        return gate.promise;
      },
    },
  );
  assert.equal(calls, 6);
  assert.equal(maxActive, 3);
  assert.equal(result.pageCount, 6);
});

test("baseline timeout AbortError retries exactly once by default", async () => {
  const data = await fixture("timeout.json");
  let calls = 0;
  await recognizeSlate(
    {
      providerId: "openai",
      modelId: "openai/gpt-4o-mini",
      imageDataUrl,
      accuracyMode: "standard",
    },
    {
      env: env(),
      fetchImpl: async () => {
        calls += 1;
        if (calls === 1) throw new DOMException("The operation was aborted due to timeout", "AbortError");
        return modelResponse();
      },
    },
  );
  assert.equal(calls, data.successAfterAttempts);
});

test("baseline exhausted timeout and non-timeout failures retain current errors", async () => {
  const data = await fixture("timeout.json");
  let timeoutCalls = 0;
  await assert.rejects(
    recognizeSlate(
      { providerId: "openai", modelId: "openai/gpt-4o-mini", imageDataUrl, accuracyMode: "standard" },
      {
        env: env(),
        fetchImpl: async () => {
          timeoutCalls += 1;
          throw new DOMException("The operation was aborted due to timeout", "AbortError");
        },
      },
    ),
    (error) => error.status === data.exhaustedStatus && error.message.includes(data.exhaustedMessageIncludes),
  );
  assert.equal(timeoutCalls, 2);

  let networkCalls = 0;
  await assert.rejects(
    recognizeSlate(
      { providerId: "openai", modelId: "openai/gpt-4o-mini", imageDataUrl, accuracyMode: "standard" },
      {
        env: env(),
        fetchImpl: async () => {
          networkCalls += 1;
          throw new Error("synthetic connection failure");
        },
      },
    ),
    (error) => error.status === 502 && /无法连接模型服务/.test(error.message),
  );
  assert.equal(networkCalls, 1);
});

test("baseline preload cleanup has no public cancellation method", async () => {
  const events = [];
  const previous = globalThis.electronAPI;
  globalThis.electronAPI = {
    onRecognitionProgress(callback) {
      events.push("on");
      callback({ phase: "starting", percent: 2 });
    },
    removeRecognitionProgressListener() {
      events.push("off");
    },
    recognize: async () => ({ ok: true }),
  };
  try {
    await recognizeApi("{}", () => {});
    assert.deepEqual(events, ["on", "off"]);
    assert.equal("cancelRecognition" in globalThis.electronAPI, false);
  } finally {
    if (previous === undefined) delete globalThis.electronAPI;
    else globalThis.electronAPI = previous;
  }
});

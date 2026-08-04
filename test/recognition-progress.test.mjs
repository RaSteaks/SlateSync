import test from "node:test";
import assert from "node:assert/strict";
import { recognizeSlate } from "../lib/ai-client.mjs";
import {
  parseRecognitionNdjson,
  readRecognitionResponse,
} from "../public/recognition-stream.js";

const imageDataUrl = "data:image/jpeg;base64,ZmFrZS1pbWFnZQ==";

test("NDJSON recognition stream survives arbitrary network chunk boundaries", async () => {
  const events = [
    { type: "progress", phase: "ocr", percent: 12, message: "OCR" },
    { type: "progress", phase: "primary", percent: 55, message: "模型" },
    { type: "result", data: { result: { records: [{ videoCode: "C001" }] } } },
  ];
  const encoded = new TextEncoder().encode(
    events.map((event) => JSON.stringify(event)).join("\n") + "\n",
  );
  const splitAt = [7, 29, encoded.length - 11];
  const chunks = [];
  let previous = 0;
  for (const end of splitAt) {
    chunks.push(encoded.slice(previous, end));
    previous = end;
  }
  chunks.push(encoded.slice(previous));

  const response = new Response(
    new ReadableStream({
      start(controller) {
        for (const chunk of chunks) controller.enqueue(chunk);
        controller.close();
      },
    }),
    { headers: { "Content-Type": "application/x-ndjson" } },
  );
  const progress = [];
  const result = await readRecognitionResponse(response, (event) => {
    progress.push(event);
  });

  assert.deepEqual(progress.map((event) => event.percent), [12, 55]);
  assert.equal(result.result.records[0].videoCode, "C001");
});

test("recognition stream surfaces server and malformed-event errors", async () => {
  await assert.rejects(
    readRecognitionResponse(
      new Response('{"error":"API Key 未配置"}', {
        status: 400,
        headers: { "Content-Type": "application/json" },
      }),
    ),
    /API Key 未配置/,
  );
  assert.throws(
    () => parseRecognitionNdjson('{"type":"error","error":"模型超时"}\n'),
    /模型超时/,
  );
  assert.throws(
    () => parseRecognitionNdjson("not-json\n"),
    /无法解析的进度数据/,
  );
});

test("recognition reports monotonic OCR, page and merge progress", async () => {
  const progress = [];
  const result = await recognizeSlate(
    {
      providerId: "openai",
      modelId: "openai/gpt-4o-mini",
      imageDataGroups: [[imageDataUrl], [imageDataUrl]],
      filename: "two-pages.pdf",
      accuracyMode: "standard",
    },
    {
      env: { OPENAI_API_KEY: "test-key", PADDLEOCR_ENABLED: "true" },
      onProgress: (event) => progress.push(event),
      ocrImpl: async (_groups, options) => {
        options.onProgress({
          stage: "view-complete",
          pageNumber: 1,
          viewIndex: 0,
          completedViews: 1,
          totalViews: 2,
        });
        options.onProgress({
          stage: "view-complete",
          pageNumber: 2,
          viewIndex: 0,
          completedViews: 2,
          totalViews: 2,
        });
        return {
          enabled: true,
          available: true,
          used: true,
          id: "paddleocr",
          modelVersion: "PP-OCRv5",
          pages: [],
          durationMs: 25,
          warning: null,
        };
      },
      fetchImpl: async () => modelResponse({ records: [] }),
    },
  );

  const phases = progress.map((event) => event.phase);
  assert.equal(phases[0], "starting");
  assert.ok(phases.includes("ocr"));
  assert.ok(phases.includes("primary"));
  assert.equal(phases.filter((phase) => phase === "page-complete").length, 2);
  assert.ok(phases.includes("merge"));
  assert.equal(phases.at(-1), "complete");
  assert.equal(progress.at(-1).percent, 100);
  assert.deepEqual(
    progress.map((event) => event.percent),
    progress.map((event) => event.percent).toSorted((left, right) => left - right),
  );
  assert.equal(result.pageCount, 2);
});

test("high-accuracy progress exposes audit and targeted conflict review", async () => {
  const progress = [];
  let call = 0;
  const primaryRecord = {
    cardNumber: "A001",
    videoCode: "C001",
    scene: "12",
    shot: "1",
    take: "1",
    takeStatus: "过",
    description: null,
    comments: null,
    shotSize: null,
    cameraPosition: null,
    confidence: "high",
  };
  await recognizeSlate(
    {
      providerId: "openai",
      modelId: "openai/gpt-4o-mini",
      imageDataUrl,
      filename: "one-page.jpg",
      accuracyMode: "high",
    },
    {
      env: { OPENAI_API_KEY: "test-key" },
      onProgress: (event) => progress.push(event),
      fetchImpl: async () => {
        call += 1;
        const record = call === 2
          ? { ...primaryRecord, shot: "2" }
          : primaryRecord;
        return modelResponse({ records: [record] });
      },
    },
  );

  assert.equal(call, 3);
  assert.ok(progress.some((event) => event.phase === "audit"));
  assert.ok(progress.some((event) => event.phase === "review"));
  assert.equal(progress.at(-1).phase, "complete");
});

function modelResponse({ records }) {
  return new Response(
    JSON.stringify({
      output: [
        {
          type: "message",
          content: [
            {
              type: "output_text",
              text: JSON.stringify({
                sheetTitle: "progress test",
                records,
                warnings: [],
              }),
            },
          ],
        },
      ],
      usage: { input_tokens: 1, output_tokens: 1 },
    }),
    { status: 200, headers: { "Content-Type": "application/json" } },
  );
}

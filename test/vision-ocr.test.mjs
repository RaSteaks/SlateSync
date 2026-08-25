import test from "node:test";
import assert from "node:assert/strict";
import { resolveOcrEngine } from "../lib/ai-client.mjs";
import { summarizeOcrResult } from "../lib/ocr/paddleocr.mjs";
import {
  clearVisionOcrCache,
  runVisionOcrForPages,
  visionOcrPublicConfig,
} from "../lib/ocr/vision.mjs";

const imageDataUrl = "data:image/jpeg;base64,ZmFrZS1pbWFnZQ==";
const secondImageDataUrl = "data:image/jpeg;base64,c2Vjb25kLWltYWdl";

function rawVisionResult() {
  return {
    ok: true,
    engine: "Vision",
    modelVersion: "macOS-Vision",
    language: "zh-Hans",
    recognitionLevel: "accurate",
    durationMs: 42,
    pages: [
      {
        pageNumber: 1,
        views: [
          {
            viewIndex: 0,
            viewType: "full",
            width: 1200,
            height: 800,
            durationMs: 40,
            truncated: false,
            blocks: [
              {
                order: 0,
                text: "068",
                confidence: 0.98,
                bbox: [100, 200, 160, 240],
                bboxNormalized: [0.08333, 0.25, 0.13333, 0.3],
              },
              {
                order: 1,
                text: "第 1 场",
                confidence: 0.92,
                bbox: [10, 20, 120, 60],
                bboxNormalized: [0.00833, 0.025, 0.1, 0.075],
              },
              {
                order: 2,
                text: "景别",
                confidence: 0.88,
                bbox: [30, 40, 90, 80],
                bboxNormalized: [0.025, 0.05, 0.075, 0.1],
              },
            ],
          },
        ],
      },
    ],
  };
}

test("Vision runner normalizes page evidence and caches identical image groups", async () => {
  clearVisionOcrCache();
  let calls = 0;
  let receivedPayload = null;
  const runnerProgress = [];
  const execute = async (payload, options) => {
    calls += 1;
    receivedPayload = payload;
    options.onProgress({
      stage: "view-complete",
      pageNumber: 1,
      viewIndex: 0,
      completedViews: 1,
      totalViews: 1,
    });
    return rawVisionResult();
  };
  const env = { VISIONOCR_ENABLED: "true" };

  const first = await runVisionOcrForPages([[imageDataUrl]], {
    env,
    execute,
    onProgress: (progress) => runnerProgress.push(progress),
  });
  const second = await runVisionOcrForPages([[imageDataUrl]], {
    env,
    execute,
    onProgress: (progress) => runnerProgress.push(progress),
  });

  assert.equal(calls, 1);
  assert.equal(receivedPayload.language, "zh-Hans");
  assert.equal(receivedPayload.recognitionLevel, "accurate");
  assert.equal(receivedPayload.usesLanguageCorrection, true);
  assert.equal(receivedPayload.pages[0].pageNumber, 1);
  assert.deepEqual(receivedPayload.pages[0].images, [imageDataUrl]);
  assert.equal(first.used, true);
  assert.equal(first.id, "vision");
  assert.equal(first.pages[0].views[0].blocks[0].text, "068");
  assert.deepEqual(
    first.pages[0].views[0].blocks[0].bboxNormalized,
    [0.08333, 0.25, 0.13333, 0.3],
  );
  assert.equal(second.cacheHit, true);
  assert.equal(summarizeOcrResult(second).blockCount, 3);
  assert.equal(summarizeOcrResult(second).engine, "vision");
  assert.deepEqual(
    runnerProgress.map((progress) => progress.stage),
    ["view-complete", "cache-hit"],
  );
});

test("Vision cache separates page/view grouping and output settings", async () => {
  clearVisionOcrCache();
  let calls = 0;
  const execute = async (payload) => {
    calls += 1;
    return {
      ok: true,
      pages: payload.pages.map((page) => ({
        pageNumber: page.pageNumber,
        views: [],
      })),
    };
  };
  const baseOptions = {
    env: { VISIONOCR_ENABLED: "true" },
    execute,
  };

  const onePage = await runVisionOcrForPages(
    [[imageDataUrl, secondImageDataUrl]],
    baseOptions,
  );
  const twoPages = await runVisionOcrForPages(
    [[imageDataUrl], [secondImageDataUrl]],
    baseOptions,
  );
  await runVisionOcrForPages([[imageDataUrl], [secondImageDataUrl]], {
    ...baseOptions,
    env: {
      VISIONOCR_ENABLED: "true",
      VISIONOCR_MIN_CONFIDENCE: "0.9",
    },
  });
  await runVisionOcrForPages([[imageDataUrl], [secondImageDataUrl]], {
    ...baseOptions,
    env: {
      VISIONOCR_ENABLED: "true",
      VISIONOCR_LANGUAGE: "en-US",
    },
  });

  assert.equal(onePage.pages.length, 1);
  assert.equal(twoPages.pages.length, 2);
  assert.equal(twoPages.cacheHit, false);
  assert.equal(calls, 4);
});

test("Vision config honours explicit enable and disable flags", () => {
  const enabled = visionOcrPublicConfig(
    { VISIONOCR_ENABLED: "true" },
    { autoEnable: false },
  );
  assert.equal(enabled.enabled, true);
  assert.equal(enabled.id, "vision");
  assert.equal(enabled.recognitionLevel, "accurate");
  assert.equal(enabled.language, "zh-Hans");
  assert.equal(enabled.usesLanguageCorrection, true);
  assert.equal(enabled.required, false);

  const disabled = visionOcrPublicConfig(
    { VISIONOCR_ENABLED: "false" },
    { autoEnable: false },
  );
  assert.equal(disabled.enabled, false);

  const fast = visionOcrPublicConfig(
    {
      VISIONOCR_ENABLED: "true",
      VISIONOCR_RECOGNITION_LEVEL: "fast",
      VISIONOCR_LANGUAGE: "zh-Hans,en-US",
      VISIONOCR_MIN_CONFIDENCE: "0.3",
      VISIONOCR_USE_LANGUAGE_CORRECTION: "false",
    },
    { autoEnable: false },
  );
  assert.equal(fast.recognitionLevel, "fast");
  assert.equal(fast.language, "zh-Hans,en-US");
  assert.equal(fast.usesLanguageCorrection, false);
  assert.equal(fast.minimumConfidence, 0.3);

  const required = visionOcrPublicConfig(
    { VISIONOCR_ENABLED: "true", VISIONOCR_REQUIRED: "true" },
    { autoEnable: false },
  );
  assert.equal(required.required, true);
});

test("optional Vision failure degrades to multimodal-only recognition", async () => {
  clearVisionOcrCache();
  const execute = async () => {
    throw new Error("binary unavailable");
  };
  const result = await runVisionOcrForPages([[imageDataUrl]], {
    env: { VISIONOCR_ENABLED: "true" },
    execute,
  });
  assert.equal(result.used, false);
  assert.equal(result.available, false);
  assert.match(result.warning, /已降级为纯多模态识别/);
});

test("Vision OCR cancellation is terminal instead of falling back to the model", async () => {
  clearVisionOcrCache();
  const controller = new AbortController();
  let receivedSignal = null;
  let signalStarted;
  const started = new Promise((resolve) => { signalStarted = resolve; });
  const ocr = runVisionOcrForPages([[imageDataUrl]], {
    env: { VISIONOCR_ENABLED: "true" },
    cache: false,
    signal: controller.signal,
    execute: async (_payload, options) => new Promise((_resolve, reject) => {
      receivedSignal = options.signal;
      signalStarted();
      options.signal.addEventListener("abort", () => reject(options.signal.reason), { once: true });
    }),
  });

  await started;
  controller.abort();
  await assert.rejects(
    ocr,
    (error) => error.code === "RECOGNITION_CANCELED" && error.message === "识别已停止",
  );
  assert.equal(receivedSignal, controller.signal);
});

test("required Vision failure rejects the recognition request", async () => {
  clearVisionOcrCache();
  const execute = async () => {
    throw new Error("binary unavailable");
  };
  await assert.rejects(
    runVisionOcrForPages([[imageDataUrl]], {
      env: { VISIONOCR_ENABLED: "true", VISIONOCR_REQUIRED: "true" },
      execute,
    }),
    (error) => error.status === 503 && /已降级为纯多模态识别/.test(error.message),
  );
});

test("disabled Vision engine returns an unused result without spawning", async () => {
  let spawned = false;
  const result = await runVisionOcrForPages([[imageDataUrl]], {
    env: { VISIONOCR_ENABLED: "false" },
    execute: async () => {
      spawned = true;
      return rawVisionResult();
    },
  });
  assert.equal(spawned, false);
  assert.equal(result.used, false);
});

test("resolveOcrEngine honours explicit flags and injected implementations", () => {
  const customImpl = async () => ({ id: "custom" });
  const injected = resolveOcrEngine({}, { ocrImpl: customImpl });
  assert.equal(injected.impl, customImpl);
  assert.equal(injected.meta.id, "custom");

  const vision = resolveOcrEngine({ VISIONOCR_ENABLED: "true" });
  assert.equal(vision.meta.id, "vision");

  const paddle = resolveOcrEngine({ PADDLEOCR_ENABLED: "true" });
  assert.equal(paddle.meta.id, "paddleocr");

  const bothExplicit = resolveOcrEngine({
    VISIONOCR_ENABLED: "true",
    PADDLEOCR_ENABLED: "true",
  });
  assert.equal(bothExplicit.meta.id, "vision");

  const visionDisabled = resolveOcrEngine({
    VISIONOCR_ENABLED: "false",
    PADDLEOCR_ENABLED: "true",
  });
  assert.equal(visionDisabled.meta.id, "paddleocr");

  const requiredVision = resolveOcrEngine({
    VISIONOCR_REQUIRED: "true",
    PADDLEOCR_ENABLED: "true",
  });
  assert.equal(requiredVision.meta.id, "vision");
  const requiredPaddle = resolveOcrEngine({
    PADDLEOCR_REQUIRED: "true",
  });
  assert.equal(requiredPaddle.meta.id, "paddleocr");

  const auto = resolveOcrEngine({});
  assert.ok(["vision", "paddleocr"].includes(auto.meta.id));
});

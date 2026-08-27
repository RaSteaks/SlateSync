import test from "node:test";
import assert from "node:assert/strict";
import { recognizeSlate } from "../lib/ai-client.mjs";
import { createSessionCapture } from "../lib/diagnostics.mjs";
import { publicConfig } from "../lib/config.mjs";
import {
  clearPaddleOcrCache,
  formatOcrEvidence,
  paddleOcrPublicConfig,
  runPaddleOcrForPages,
  summarizeOcrResult,
} from "../lib/ocr/paddleocr.mjs";

const imageDataUrl = "data:image/jpeg;base64,ZmFrZS1pbWFnZQ==";
const secondImageDataUrl = "data:image/jpeg;base64,c2Vjb25kLWltYWdl";

test("PaddleOCR runner normalizes page evidence and caches identical image groups", async () => {
  clearPaddleOcrCache();
  let calls = 0;
  const runnerProgress = [];
  const execute = async (_payload, options) => {
    calls += 1;
    options.onProgress({
      stage: "view-complete",
      pageNumber: 1,
      viewIndex: 0,
      completedViews: 1,
      totalViews: 1,
    });
    return rawOcrResult();
  };
  const env = {
    PADDLEOCR_ENABLED: "true",
    PADDLEOCR_MODEL_VERSION: "PP-OCRv5",
  };

  const first = await runPaddleOcrForPages([[imageDataUrl]], {
    env,
    execute,
    onProgress: (progress) => runnerProgress.push(progress),
  });
  const second = await runPaddleOcrForPages([[imageDataUrl]], {
    env,
    execute,
    onProgress: (progress) => runnerProgress.push(progress),
  });

  assert.equal(calls, 1);
  assert.equal(first.used, true);
  assert.equal(first.pages[0].views[0].blocks[0].text, "068");
  assert.equal(second.cacheHit, true);
  assert.equal(summarizeOcrResult(second).blockCount, 3);
  assert.deepEqual(
    runnerProgress.map((progress) => progress.stage),
    ["view-complete", "cache-hit"],
  );
  assert.equal(runnerProgress.at(-1).cacheHit, true);
});

test("OCR cache separates page/view grouping and output settings", async () => {
  clearPaddleOcrCache();
  let calls = 0;
  const execute = async (payload) => {
    calls += 1;
    return {
      ok: true,
      modelVersion: payload.modelVersion,
      pages: payload.pages.map((page) => ({
        pageNumber: page.pageNumber,
        views: [],
      })),
    };
  };
  const baseOptions = {
    env: { PADDLEOCR_ENABLED: "true" },
    execute,
  };

  const onePage = await runPaddleOcrForPages(
    [[imageDataUrl, secondImageDataUrl]],
    baseOptions,
  );
  const twoPages = await runPaddleOcrForPages(
    [[imageDataUrl], [secondImageDataUrl]],
    baseOptions,
  );
  await runPaddleOcrForPages([[imageDataUrl], [secondImageDataUrl]], {
    ...baseOptions,
    env: {
      PADDLEOCR_ENABLED: "true",
      PADDLEOCR_MIN_CONFIDENCE: "0.9",
    },
  });
  await runPaddleOcrForPages([[imageDataUrl], [secondImageDataUrl]], {
    ...baseOptions,
    env: {
      PADDLEOCR_ENABLED: "true",
      PADDLEOCR_PROFILE: "accurate",
    },
  });

  assert.equal(onePage.pages.length, 1);
  assert.equal(twoPages.pages.length, 2);
  assert.equal(twoPages.cacheHit, false);
  assert.equal(calls, 4);
});

test("PP-OCRv5 profiles select speed and accuracy models safely", () => {
  const balanced = paddleOcrPublicConfig(
    { PADDLEOCR_ENABLED: "true" },
    { autoEnable: false },
  );
  const fast = paddleOcrPublicConfig(
    { PADDLEOCR_ENABLED: "true", PADDLEOCR_PROFILE: "fast" },
    { autoEnable: false },
  );
  const accurate = paddleOcrPublicConfig(
    { PADDLEOCR_ENABLED: "true", PADDLEOCR_PROFILE: "accurate" },
    { autoEnable: false },
  );
  const legacy = paddleOcrPublicConfig(
    { PADDLEOCR_ENABLED: "true", PADDLEOCR_MODEL_VERSION: "PP-OCRv4" },
    { autoEnable: false },
  );

  assert.deepEqual(
    [balanced.profile, balanced.detectionModel, balanced.recognitionModel, balanced.recognitionBatchSize],
    ["balanced", "PP-OCRv5_mobile_det", "PP-OCRv5_server_rec", 8],
  );
  assert.deepEqual(
    [fast.detectionModel, fast.recognitionModel, fast.recognitionBatchSize],
    ["PP-OCRv5_mobile_det", "PP-OCRv5_mobile_rec", 16],
  );
  assert.deepEqual(
    [accurate.detectionModel, accurate.recognitionModel, accurate.recognitionBatchSize],
    ["PP-OCRv5_server_det", "PP-OCRv5_server_rec", 4],
  );
  assert.equal(legacy.profile, "accurate");
  assert.equal(legacy.detectionModel, "");
  assert.equal(legacy.recognitionModel, "");
});

test("automatic OCR timeout scales with the number of views", async () => {
  let capturedPayload;
  let capturedOptions;
  const groups = Array.from({ length: 20 }, () => [
    imageDataUrl,
    secondImageDataUrl,
    imageDataUrl,
  ]);
  await runPaddleOcrForPages(groups, {
    env: {
      PADDLEOCR_ENABLED: "true",
      PADDLEOCR_TIMEOUT_MS: "auto",
      PADDLE_PDX_CACHE_HOME: "/tmp/slatesync-paddlex-cache",
    },
    cache: false,
    execute: async (payload, options) => {
      capturedPayload = payload;
      capturedOptions = options;
      return {
        ok: true,
        modelVersion: payload.modelVersion,
        pages: payload.pages.map((page) => ({
          pageNumber: page.pageNumber,
          views: [],
        })),
      };
    },
  });

  assert.equal(capturedPayload.maxBlocksPerView, 0);
  assert.equal(capturedOptions.timeoutMs, 47 * 60 * 1000);
  assert.equal(capturedOptions.env.PADDLE_PDX_CACHE_HOME, "/tmp/slatesync-paddlex-cache");
});

test("OCR evidence keeps all full-page text while core mode focuses short field evidence", () => {
  const page = rawOcrResult().pages[0];
  const full = formatOcrEvidence(page, { mode: "full", engine: "vision" });
  const core = formatOcrEvidence(page, { mode: "core", engine: "vision" });

  assert.match(full, /<ocr_evidence>/);
  assert.match(full, /engine=vision page=1 mode=full/);
  assert.match(full, /text="人物走进房间并坐下"/);
  assert.match(full, /box=\[0\.1000,0\.2000,0\.2000,0\.2400\]/);
  assert.doesNotMatch(core, /人物走进房间并坐下/);
  assert.match(core, /text="068"/);
  assert.match(core, /text="C015"/);
});

test("optional PaddleOCR failure degrades cleanly and required mode blocks", async () => {
  const execute = async () => {
    throw new Error("module not installed");
  };
  const optional = await runPaddleOcrForPages([[imageDataUrl]], {
    env: { PADDLEOCR_ENABLED: "true" },
    execute,
    cache: false,
  });
  assert.equal(optional.used, false);
  assert.match(optional.warning, /已降级为纯多模态识别/);

  await assert.rejects(
    runPaddleOcrForPages([[imageDataUrl]], {
      env: {
        PADDLEOCR_ENABLED: "true",
        PADDLEOCR_REQUIRED: "true",
      },
      execute,
      cache: false,
    }),
    /PaddleOCR 不可用/,
  );
});

test("PaddleOCR cancellation is terminal instead of falling back to the model", async () => {
  clearPaddleOcrCache();
  const controller = new AbortController();
  let receivedSignal = null;
  let signalStarted;
  const started = new Promise((resolve) => { signalStarted = resolve; });
  const ocr = runPaddleOcrForPages([[imageDataUrl]], {
    env: { PADDLEOCR_ENABLED: "true" },
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

test("multimodal recognition receives OCR text, confidence and coordinates", async () => {
  let captured;
  const diagnosticCapture = createSessionCapture();
  const fetchImpl = async (url, request) => {
    captured = { url, body: JSON.parse(request.body) };
    return jsonResponse({
      output: [
        {
          type: "message",
          content: [
            {
              type: "output_text",
              text: JSON.stringify({
                sheetTitle: "OCR test",
                records: [],
                warnings: [],
              }),
            },
          ],
        },
      ],
      usage: { input_tokens: 10, output_tokens: 10 },
    });
  };
  const ocrImpl = async () => ({
    enabled: true,
    available: true,
    used: true,
    id: "paddleocr",
    modelVersion: "PP-OCRv5",
    device: "cpu",
    durationMs: 120,
    pages: rawOcrResult().pages,
    warning: null,
  });

  const result = await recognizeSlate(
    {
      providerId: "openai",
      modelId: "openai/gpt-4o-mini",
      imageDataUrl,
      filename: "slate.jpg",
    },
    {
      env: { OPENAI_API_KEY: "test-key", PADDLEOCR_ENABLED: "true" },
      fetchImpl,
      ocrImpl,
      capture: diagnosticCapture,
    },
  );

  const userText = captured.body.input[1].content[0].text;
  assert.match(userText, /<ocr_evidence>/);
  assert.match(userText, /q=0\.980/);
  assert.match(userText, /text="068"/);
  assert.equal(result.ocr.used, true);
  assert.equal(result.ocr.blockCount, 3);
  const diagnosticStage = diagnosticCapture.session.pages[0].stages[0];
  // Evidence is retained once at the stage boundary, not duplicated inside
  // the sanitized request snapshot persisted to SQLite and JSON.
  assert.match(diagnosticStage.ocrEvidence, /<ocr_evidence>/);
  assert.equal(Object.hasOwn(diagnosticStage.request, "ocrEvidence"), false);
});

test("legacy raw PDF input is rejected before any provider request", async () => {
  let providerCalled = false;
  await assert.rejects(
    recognizeSlate(
      {
        providerId: "openai",
        modelId: "openai/gpt-4o-mini",
        pdfDataUrl: "data:application/pdf;base64,JVBERi0xLjQK",
      },
      {
        env: {
          OPENAI_API_KEY: "test-key",
          PADDLEOCR_ENABLED: "true",
        },
        fetchImpl: async () => {
          providerCalled = true;
          throw new Error("provider should not be called");
        },
      },
    ),
    (error) => error.status === 400 && /原始 PDF 直传已停用/.test(error.message),
  );
  assert.equal(providerCalled, false);

  await assert.rejects(
    recognizeSlate(
      {
        providerId: "openai",
        modelId: "openai/gpt-4o-mini",
        imageDataGroups: [[imageDataUrl]],
      },
      {
        env: { OPENAI_API_KEY: "test-key" },
        // Zero OCR blocks are also invalid in strict mode; do not silently
        // turn an empty required result into a page-image-only request.
        ocrMeta: { id: "vision", label: "Vision OCR", required: true },
        ocrImpl: async () => ({
          id: "vision",
          enabled: true,
          available: true,
          used: true,
          pages: [{ pageNumber: 1, views: [] }],
        }),
        fetchImpl: async () => {
          providerCalled = true;
          throw new Error("provider should not be called");
        },
      },
    ),
    (error) => error.status === 503 && /没有返回有效结果/.test(error.message),
  );
  assert.equal(providerCalled, false);
});

test("optional OCR failure falls back to page images with a precision warning", async () => {
  let captured;
  const diagnosticCapture = createSessionCapture();
  const progressEvents = [];
  const result = await recognizeSlate(
    {
      providerId: "openai",
      modelId: "openai/gpt-4o-mini",
      imageDataGroups: [[imageDataUrl]],
    },
    {
      env: {
        OPENAI_API_KEY: "test-key",
        PADDLEOCR_ENABLED: "true",
      },
      // Exercise the outer orchestration fallback, not only a runner's own
      // optional-failure normalization.
      ocrImpl: async () => {
        throw new Error("OCR worker crashed");
      },
      fetchImpl: async (_url, request) => {
        captured = JSON.parse(request.body);
        return jsonResponse({
          output_text: JSON.stringify({
            sheetTitle: "OCR fallback",
            records: [],
            warnings: [],
          }),
          usage: { input_tokens: 10, output_tokens: 10 },
        });
      },
      capture: diagnosticCapture,
      onProgress: (event) => progressEvents.push(event),
    },
  );

  assert.equal(result.ocr.used, false);
  assert.equal(
    result.ocr.warning,
    "本地 OCR 不可用，已改用页面图片直接识别；识别精度可能下降。",
  );
  assert.equal(diagnosticCapture.session.ocr.summary.warning, result.ocr.warning);
  assert.ok(progressEvents.some((event) => event.warning === result.ocr.warning));
  assert.match(result.result.warnings[0], /本地 OCR 不可用/);
  assert.match(result.result.warnings[0], /识别精度可能下降/);
  assert.equal(captured.input[1].content[1].type, "input_image");
});

test("required OCR failure stops before the provider and explains how to repair it", async () => {
  let providerCalled = false;
  await assert.rejects(
    recognizeSlate(
      {
        providerId: "openai",
        modelId: "openai/gpt-4o-mini",
        imageDataGroups: [[imageDataUrl]],
      },
      {
        env: { OPENAI_API_KEY: "test-key" },
        // Inject a failing required engine to exercise the orchestration
        // boundary that wraps installation/path guidance for strict mode.
        ocrMeta: { id: "vision", label: "Vision OCR", required: true },
        ocrImpl: async () => {
          throw new Error("Vision OCR worker unavailable");
        },
        fetchImpl: async () => {
          providerCalled = true;
          throw new Error("provider should not be called");
        },
      },
    ),
    (error) =>
      error.status === 503 &&
      /VISIONOCR_REQUIRED/.test(error.message) &&
      /安装、路径或配置/.test(error.message),
  );
  assert.equal(providerCalled, false);
});

test("public config exposes OCR readiness without leaking its Python path", () => {
  const config = publicConfig({
    PADDLEOCR_ENABLED: "true",
    PADDLEOCR_PYTHON: "/private/secret/python",
  });
  assert.equal(config.ocr.enabled, true);
  assert.equal(config.ocr.pythonPath, undefined);
  assert.equal(config.ocrSelection.id, "paddleocr");
  assert.equal(config.ocrSelection.mode, "explicit");
  assert.match(config.ocrSelection.reason, /PADDLEOCR_ENABLED/);
  assert.equal(JSON.stringify(config).includes("/private/secret"), false);
});

function rawOcrResult() {
  return {
    ok: true,
    modelVersion: "PP-OCRv5",
    durationMs: 120,
    pages: [
      {
        pageNumber: 1,
        views: [
          {
            viewIndex: 0,
            viewType: "full",
            width: 1000,
            height: 2000,
            durationMs: 100,
            blocks: [
              block(0, "068", 0.98, [0.1, 0.2, 0.2, 0.24]),
              block(1, "C015", 0.94, [0.4, 0.2, 0.5, 0.24]),
              block(2, "人物走进房间并坐下", 0.88, [0.6, 0.2, 0.9, 0.24]),
            ],
          },
        ],
      },
    ],
  };
}

function block(order, text, confidence, bboxNormalized) {
  return {
    order,
    text,
    confidence,
    bbox: bboxNormalized.map((value) => Math.round(value * 1000)),
    bboxNormalized,
  };
}

function jsonResponse(value, status = 200) {
  return {
    ok: status >= 200 && status < 300,
    status,
    text: async () => JSON.stringify(value),
  };
}

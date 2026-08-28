import { describe, it } from "node:test";
import assert from "node:assert/strict";
import { registerIpcHandlers } from "../electron/ipc-handlers.mjs";

function createMockIpcMain({ senderDestroyed = false } = {}) {
  const handlers = new Map();
  let sends = 0;
  return {
    handle(channel, handler) {
      handlers.set(channel, handler);
    },
    async invoke(channel, body) {
      const handler = handlers.get(channel);
      if (!handler) throw new Error(`No handler for ${channel}`);
      return handler({
        sender: {
          isDestroyed: () => senderDestroyed,
          send: () => { sends += 1; },
        },
      }, body);
    },
    get sends() {
      return sends;
    },
  };
}

function createLogger() {
  const entries = { info: [], warn: [], error: [] };
  return {
    entries,
    info(category, message, meta) { entries.info.push({ category, message, meta }); },
    warn(category, message, meta) { entries.warn.push({ category, message, meta }); },
    error(category, message, meta) { entries.error.push({ category, message, meta }); },
  };
}

function createContext(overrides = {}) {
  return {
    workflowConfig: {},
    runtimeProviderKeys: new Map(),
    runtimeEnv: () => ({}) ,
    recognitionLimiter: { acquire: () => () => {} },
    settings: { maxBodyBytes: 80 * 1024 * 1024 },
    projectRuntime: {
      get: async (projectId) => ({
        project: {
          id: projectId,
          settings: {
            providerId: "openai-compatible",
            modelId: "local-vision",
            accuracyMode: "standard",
            customPrompt: "",
            resolve: {
              fieldFormats: { scene: "XXX", shot: "XX", take: "XX" },
              comments: { goodTake: "_OK", holdTake: "_KP" },
            },
          },
        },
        scenarioStore: null,
        diagnostics: null,
        taskStore: { saveTask: async () => "task-1" },
      }),
    },
    ...overrides,
  };
}

const request = {
  projectId: "project-logging",
  provider: "openai-compatible",
  model: "local-vision",
  filename: "day-01.png",
  pageCount: 2,
  imageDataGroups: [["data:image/png;base64,one"], ["data:image/png;base64,two"]],
};

function completedResult() {
  return {
    provider: "openai-compatible",
    model: "local-vision",
    inputMode: "images",
    durationMs: 1820,
    pageCount: 2,
    accuracyMode: "standard",
    result: { sheetTitle: "Day 01", records: [{ cardNumber: "A001" }], warnings: [] },
    usage: { inputTokens: 10, outputTokens: 8 },
    ocr: null,
    scenario: null,
  };
}

describe("recognition logging tee", () => {
  it("logs start, every progress event, and completion even when the sender is destroyed", async () => {
    const logger = createLogger();
    const ipcMain = createMockIpcMain({ senderDestroyed: true });
    registerIpcHandlers(ipcMain, createContext({
      logger,
      recognize: async (_input, options) => {
        options.onProgress({ phase: "primary", percent: 45, message: "正在主识别第 1/2 页", completed: 1, total: 2, pageNumber: 1 });
        options.onProgress({ phase: "audit", percent: 75, message: "查漏中", completed: 1, total: 2, warning: "本地 OCR 不可用" });
        return completedResult();
      },
    }));

    const result = await ipcMain.invoke("recognize", request);

    assert.equal(result.taskId, "task-1");
    assert.equal(ipcMain.sends, 0, "destroyed renderer must not receive progress IPC");
    assert.equal(logger.entries.info.length, 3, "start + two progress events + completion are all informational except the warning");
    assert.match(logger.entries.info[0].message, /识别开始/);
    assert.deepEqual(logger.entries.info[1].meta, {
      phase: "primary",
      percent: 45,
      completed: 1,
      total: 2,
      completedViews: undefined,
      totalViews: undefined,
      viewIndex: undefined,
      pageNumber: 1,
      cacheHit: undefined,
    });
    assert.equal(logger.entries.warn.length, 1);
    assert.match(logger.entries.warn[0].message, /75%.*查漏中.*本地 OCR 不可用/);
    assert.match(logger.entries.info[2].message, /识别完成.*1 条记录/);
    assert.equal(logger.entries.info[2].meta.durationMs, 1820);
  });

  it("records cancellation as a warning and provider failures as errors", async () => {
    const canceledLogger = createLogger();
    const canceledIpc = createMockIpcMain();
    const canceled = new Error("识别已停止");
    canceled.code = "RECOGNITION_CANCELED";
    registerIpcHandlers(canceledIpc, createContext({
      logger: canceledLogger,
      recognize: async () => { throw canceled; },
    }));
    await assert.rejects(() => canceledIpc.invoke("recognize", request), { code: "RECOGNITION_CANCELED" });
    assert.equal(canceledLogger.entries.warn.length, 1);
    assert.match(canceledLogger.entries.warn[0].message, /识别已停止/);
    assert.equal(canceledLogger.entries.error.length, 0);

    const failedLogger = createLogger();
    const failedIpc = createMockIpcMain();
    registerIpcHandlers(failedIpc, createContext({
      logger: failedLogger,
      recognize: async () => { throw new Error("模型返回的数据不包含 records 数组"); },
    }));
    await assert.rejects(() => failedIpc.invoke("recognize", request), /不包含 records 数组/);
    assert.equal(failedLogger.entries.error.length, 1);
    assert.match(failedLogger.entries.error[0].message, /识别失败.*records 数组/);
  });
});

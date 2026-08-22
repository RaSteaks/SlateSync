import assert from "node:assert/strict";
import test from "node:test";

import { registerIpcHandlers } from "../../../electron/ipc-handlers.mjs";

const projectSettings = Object.freeze({
  version: 1,
  providerId: "openai",
  modelId: "gpt-5-mini",
  accuracyMode: "standard",
  scenarioId: null,
  customPrompt: "",
  resolve: {
    fieldFormats: { scene: "{scene}", shot: "{shot}", take: "{take}" },
    comments: { goodTake: "过", holdTake: "保" },
  },
});

function createRecognitionHandler(onProgress) {
  const handlers = new Map();
  const ipcMain = {
    handle(channel, handler) {
      handlers.set(channel, handler);
    },
  };
  registerIpcHandlers(ipcMain, {
    getWorkflowConfig: async () => ({
      scenario: { matching: { threshold: 0.8, ambiguityMargin: 0.05 } },
      resolve: projectSettings.resolve,
    }),
    runtimeProviderKeys: new Map(),
    runtimeEnv: () => ({}),
    recognitionLimiter: { acquire: () => () => {} },
    settings: { maxBodyBytes: 1_000_000 },
    runtimeSettings: {},
    projectRuntime: {
      get: async () => ({
        project: { id: "project-1", settings: projectSettings },
        scenarioStore: null,
        diagnostics: null,
        taskStore: null,
      }),
    },
    recognize: async (_input, options) => {
      options.onProgress(onProgress);
      return {
        provider: "openai",
        model: "gpt-5-mini",
        inputMode: "images",
        durationMs: 1,
        pageCount: 1,
        accuracyMode: "standard",
        usage: null,
        ocr: null,
        scenario: null,
        result: { sheetTitle: null, records: [], warnings: [] },
      };
    },
  });
  const handler = handlers.get("recognize");
  assert.equal(typeof handler, "function");
  return handler;
}

test("production recognition handler never sends progress to a destroyed Renderer", async () => {
  const progress = { type: "progress", phase: "recognition", percent: 50 };
  const handler = createRecognitionHandler(progress);
  let sendCount = 0;

  // The sender's destruction check is the Main-side ownership boundary; this
  // regression test invokes the production handler rather than duplicating it.
  const result = await handler({
    sender: {
      isDestroyed: () => true,
      send: () => { sendCount += 1; },
    },
  }, { projectId: "project-1", imageDataUrl: "data:image/png;base64,AA==" });

  assert.equal(sendCount, 0);
  assert.equal(result.projectId, "project-1");
});

test("production recognition handler forwards progress while the Renderer lives", async () => {
  const progress = { type: "progress", phase: "recognition", percent: 50 };
  const handler = createRecognitionHandler(progress);
  const sent = [];

  await handler({
    sender: {
      isDestroyed: () => false,
      send: (...args) => sent.push(args),
    },
  }, { projectId: "project-1", imageDataUrl: "data:image/png;base64,AA==" });

  assert.deepEqual(sent, [["recognition-progress", progress]]);
});

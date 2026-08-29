import { describe, it } from "node:test";
import assert from "node:assert/strict";
import { registerIpcHandlers } from "../electron/ipc-handlers.mjs";

function createMockIpcMain() {
  const handlers = new Map();
  return {
    handle(channel, handler) {
      handlers.set(channel, handler);
    },
    async invoke(channel, ...args) {
      const handler = handlers.get(channel);
      if (!handler) throw new Error(`No handler for ${channel}`);
      const mockEvent = {
        sender: {
          isDestroyed: () => false,
          send: () => {},
        },
      };
      return handler(mockEvent, ...args);
    },
    handlers,
  };
}

function createMockContext(overrides = {}) {
  return {
    workflowConfig: {
      resolve: {
        fieldFormats: { scene: "XXX", shot: "XX", take: "XX" },
      },
    },
    runtimeProviderKeys: new Map(),
    runtimeEnv: () => ({ ...process.env }),
    recognitionLimiter: {
      acquire: () => () => {},
      active: 0,
      limit: 1,
    },
    settings: { maxBodyBytes: 80 * 1024 * 1024 },
    keyStore: null,
    fileDialogs: null,
    slateScanner: null,
    settingsStore: null,
    runtimeSettings: { ocrPythonPath: "", ocrSetupCompleted: false, ocrSetupSkipped: false },
    ...overrides,
  };
}

describe("electron IPC handlers", () => {
  it("registers all expected channels", () => {
    const ipcMain = createMockIpcMain();
    registerIpcHandlers(ipcMain, createMockContext());

    const expectedChannels = [
      "get-config",
      "get-global-settings",
      "save-global-settings",
      "list-projects",
      "get-library-info",
      "import-project-library",
      "export-project-library",
      "change-library-location",
      "rename-library",
      "create-project",
      "load-project",
      "update-project",
      "archive-project",
      "restore-project",
      "delete-project",
      "save-provider-key",
      "get-models",
      "check-compatible-json-schema",
      "recognize",
      "cancel-recognition",
      "save-file",
      "select-directory",
      "scan-slate-directory",
      "list-tasks",
      "load-task",
      "save-task",
      "delete-task",
      "list-scenarios",
      "load-scenario",
      "import-scenario",
      "get-ocr-settings",
      "save-ocr-settings",
      "check-ocr",
      "check-vision-ocr",
      "logs-read",
      "logs-open-directory",
    ];
    for (const channel of expectedChannels) {
      assert.ok(
        ipcMain.handlers.has(channel),
        `Missing handler for ${channel}`,
      );
    }
  });

  it("get-config returns public config with upload limits", async () => {
    const ipcMain = createMockIpcMain();
    registerIpcHandlers(ipcMain, createMockContext());

    const config = await ipcMain.invoke("get-config");
    assert.ok(Array.isArray(config.providers));
    assert.ok(Array.isArray(config.models));
    assert.ok(config.upload);
    assert.equal(typeof config.upload.maxRequestBytes, "number");
    assert.ok(config.workflow);
  });

  it("checks compatible JSON Schema through an injected capability probe", async () => {
    const calls = [];
    const ipcMain = createMockIpcMain();
    registerIpcHandlers(ipcMain, createMockContext({
      runtimeEnv: () => ({ OPENAI_COMPATIBLE_MODEL: "local-vision" }),
      checkJsonSchema: async ({ env }) => {
        calls.push(env.OPENAI_COMPATIBLE_MODEL);
        return {
          supported: true,
          model: env.OPENAI_COMPATIBLE_MODEL,
          transport: "chat-completions",
          status: 200,
          checkedAt: "2026-08-26T00:00:00.000Z",
          message: "ok",
        };
      },
    }));

    assert.deepEqual(
      await ipcMain.invoke("check-compatible-json-schema"),
      {
        supported: true,
        model: "local-vision",
        transport: "chat-completions",
        status: 200,
        checkedAt: "2026-08-26T00:00:00.000Z",
        message: "ok",
      },
    );
    assert.deepEqual(calls, ["local-vision"]);
  });

  it("checks Vision OCR through the injected Main-side bridge probe", async () => {
    const calls = [];
    const ipcMain = createMockIpcMain();
    registerIpcHandlers(ipcMain, createMockContext({
      runtimeEnv: () => ({ VISIONOCR_BINARY: "/synthetic/vision-ocr" }),
      checkVision: async ({ env }) => {
        calls.push(env.VISIONOCR_BINARY);
        return {
          ok: true,
          engine: "Vision",
          modelVersion: "macOS-Vision",
          systemVersion: "15.0",
        };
      },
    }));

    assert.deepEqual(await ipcMain.invoke("check-vision-ocr"), {
      ok: true,
      engine: "Vision",
      modelVersion: "macOS-Vision",
      systemVersion: "15.0",
    });
    assert.deepEqual(calls, ["/synthetic/vision-ocr"]);
  });

  it("reads local logs through the additive filtered IPC handler", async () => {
    const calls = [];
    const ipcMain = createMockIpcMain();
    registerIpcHandlers(ipcMain, createMockContext({
      logger: {
        readEntries: async (request) => {
          calls.push(request);
          return { entries: [{ timestamp: "2026-08-26 10:00:00.000", level: "warn", category: "recognition", message: "OCR 降级" }], hasMore: false };
        },
      },
    }));

    assert.deepEqual(await ipcMain.invoke("logs-read", {
      limit: 25,
      level: "warn",
      category: "recognition",
    }), {
      entries: [{ timestamp: "2026-08-26 10:00:00.000", level: "warn", category: "recognition", message: "OCR 降级" }],
      hasMore: false,
    });
    assert.deepEqual(calls, [{ limit: 25, level: "warn", category: "recognition" }]);
  });

  it("opens the Main-owned local log directory through the injected OS action", async () => {
    const calls = [];
    const ipcMain = createMockIpcMain();
    registerIpcHandlers(ipcMain, createMockContext({
      logger: { logsDir: "/synthetic/user-data/logs" },
      openLogDirectory: async (logsDir) => {
        calls.push(logsDir);
        return { opened: true };
      },
    }));

    assert.deepEqual(await ipcMain.invoke("logs-open-directory"), { opened: true });
    assert.deepEqual(calls, ["/synthetic/user-data/logs"]);
  });

  it("dispatches Project Library transfer actions", async () => {
    const calls = [];
    const ipcMain = createMockIpcMain();
    registerIpcHandlers(ipcMain, createMockContext({
      libraryActions: {
        importLibrary: async () => {
          calls.push("import");
          return { canceled: true };
        },
        exportLibrary: async () => {
          calls.push("export");
          return { canceled: false, library: { path: "/export" } };
        },
        changeLocation: async () => {
          calls.push("location");
          return { canceled: true };
        },
        renameLibrary: async (name) => {
          calls.push(`rename:${name}`);
          return { canceled: false, restartRequired: true, library: { path: "/renamed" } };
        },
      },
    }));

    assert.deepEqual(await ipcMain.invoke("import-project-library"), {
      canceled: true,
    });
    assert.equal(
      (await ipcMain.invoke("export-project-library")).library.path,
      "/export",
    );
    assert.deepEqual(await ipcMain.invoke("change-library-location"), {
      canceled: true,
    });
    assert.deepEqual(await ipcMain.invoke("rename-library", { name: "新名称" }), {
      canceled: false,
      restartRequired: true,
      library: { path: "/renamed" },
    });
    assert.deepEqual(calls, ["import", "export", "location", "rename:新名称"]);
  });

  it("does not export while a project is being created", async () => {
    let releaseCreate;
    let signalCreateStarted;
    const createStarted = new Promise((resolve) => {
      signalCreateStarted = resolve;
    });
    const createGate = new Promise((resolve) => {
      releaseCreate = resolve;
    });
    let exportCalls = 0;
    const ipcMain = createMockIpcMain();
    registerIpcHandlers(ipcMain, createMockContext({
      projectLibrary: {
        createProject: async () => {
          signalCreateStarted();
          await createGate;
          return { id: "project-new", name: "新项目" };
        },
      },
      libraryActions: {
        exportLibrary: async () => {
          exportCalls += 1;
          return { canceled: false };
        },
      },
    }));

    const creating = ipcMain.invoke("create-project", { name: "新项目" });
    await createStarted;
    await assert.rejects(
      () => ipcMain.invoke("export-project-library"),
      /仍有任务正在写入/,
    );
    assert.equal(exportCalls, 0);
    releaseCreate();
    assert.equal((await creating).id, "project-new");
  });

  it("dispatches scenario Profile operations through IPC", async () => {
    const projectId = "project-scenarios";
    const scenarioStore = {
      listProfiles: async () => [{ id: "scenario-0123456789abcdef" }],
      getProfile: async (id) => ({ id }),
      importProfile: async (profile) => ({ ...profile, imported: true }),
    };
    const projectRuntime = {
      get: async (requestedId) => {
        assert.equal(requestedId, projectId);
        return { project: { id: projectId }, scenarioStore };
      },
    };
    const ipcMain = createMockIpcMain();
    registerIpcHandlers(ipcMain, createMockContext({ projectRuntime }));

    assert.deepEqual(await ipcMain.invoke("list-scenarios", { projectId }), [
      { id: "scenario-0123456789abcdef" },
    ]);
    assert.deepEqual(
      await ipcMain.invoke("load-scenario", {
        projectId,
        id: "scenario-0123456789abcdef",
      }),
      { id: "scenario-0123456789abcdef" },
    );
    assert.deepEqual(
      await ipcMain.invoke("import-scenario", {
        projectId,
        profile: { label: "Imported" },
      }),
      { label: "Imported", imported: true },
    );
  });

  it("closes a project runtime before deleting its library entry", async () => {
    const calls = [];
    const projectId = "project-delete";
    const ipcMain = createMockIpcMain();
    registerIpcHandlers(ipcMain, createMockContext({
      projectLibrary: {
        deleteProject: async (id) => {
          calls.push(`delete:${id}`);
          return { deleted: id };
        },
      },
      projectRuntime: {
        closeProject: async (id) => calls.push(`close:${id}`),
      },
    }));

    assert.deepEqual(await ipcMain.invoke("delete-project", { id: projectId }), { deleted: projectId });
    assert.deepEqual(calls, [`close:${projectId}`, `delete:${projectId}`]);
  });

  it("drains active project reads and rejects new reads while deleting", async () => {
    const projectId = "project-delete-read-race";
    let releaseRead;
    let signalReadStarted;
    const readStarted = new Promise((resolve) => { signalReadStarted = resolve; });
    const readGate = new Promise((resolve) => { releaseRead = resolve; });
    const calls = [];
    const ipcMain = createMockIpcMain();
    registerIpcHandlers(ipcMain, createMockContext({
      projectLibrary: {
        deleteProject: async (id) => {
          calls.push(`delete:${id}`);
          return { deleted: id };
        },
      },
      projectRuntime: {
        get: async () => ({
          project: { id: projectId },
          taskStore: {
            listTasks: async () => {
              signalReadStarted();
              await readGate;
              return [];
            },
          },
        }),
        closeProject: async (id) => calls.push(`close:${id}`),
      },
    }));

    const reading = ipcMain.invoke("list-tasks", { projectId });
    await readStarted;
    const deletion = ipcMain.invoke("delete-project", { id: projectId });
    await assert.rejects(
      () => ipcMain.invoke("load-task", { projectId, id: "task-1" }),
      /项目正在归档或删除/,
    );
    assert.deepEqual(calls, []);
    releaseRead();
    await reading;
    assert.deepEqual(await deletion, { deleted: projectId });
    assert.deepEqual(calls, [`close:${projectId}`, `delete:${projectId}`]);
  });

  it("waits for an active recognition to release its leases before confirming cancellation", async () => {
    let signalStarted;
    const started = new Promise((resolve) => { signalStarted = resolve; });
    let signalAborted;
    const aborted = new Promise((resolve) => { signalAborted = resolve; });
    let releaseRecognition;
    const recognitionGate = new Promise((resolve) => { releaseRecognition = resolve; });
    const lifecycle = [];
    const project = {
      id: "project-cancel",
      settings: {
        accuracyMode: "standard",
        resolve: {
          fieldFormats: { scene: "XXX", shot: "XX", take: "XX" },
          comments: { goodTake: "_OK", holdTake: "_KP" },
        },
      },
    };
    const ipcMain = createMockIpcMain();
    registerIpcHandlers(ipcMain, createMockContext({
      recognitionLimiter: {
        acquire: () => {
          lifecycle.push("acquire");
          return () => lifecycle.push("release");
        },
      },
      projectLibrary: { touchProjectActivity: async () => {} },
      projectRuntime: {
        get: async () => ({ project, scenarioStore: null, diagnostics: null, taskStore: null }),
      },
      recognize: async (_input, { signal }) => new Promise((_resolve, reject) => {
        signalStarted();
        signal.addEventListener("abort", () => {
          signalAborted();
          recognitionGate.then(() => {
            const error = new Error("识别已停止");
            error.code = "RECOGNITION_CANCELED";
            reject(error);
          });
        }, { once: true });
      }),
    }));

    const recognition = ipcMain.invoke("recognize", { projectId: project.id, provider: "openai", model: "test-model", filename: "slate.png" });
    await started;
    const rejection = assert.rejects(() => recognition, /识别已停止/);
    const cancelling = ipcMain.invoke("cancel-recognition", { projectId: project.id });
    await aborted;
    let cancellationSettled = false;
    void cancelling.then(() => { cancellationSettled = true; });
    await Promise.resolve();
    assert.equal(cancellationSettled, false);
    assert.deepEqual(lifecycle, ["acquire"]);
    releaseRecognition();
    await rejection;
    assert.deepEqual(await cancelling, { canceled: true });
    assert.deepEqual(lifecycle, ["acquire", "release"]);
    assert.deepEqual(await ipcMain.invoke("cancel-recognition", { projectId: project.id }), { canceled: false });
  });

  it("rejects legacy PDF-only recognition in Main before invoking the model", async () => {
    const project = {
      id: "project-legacy-pdf",
      settings: {
        accuracyMode: "standard",
        resolve: {
          fieldFormats: { scene: "XXX", shot: "XX", take: "XX" },
          comments: { goodTake: "_OK", holdTake: "_KP" },
        },
      },
    };
    let recognizeCalls = 0;
    const ipcMain = createMockIpcMain();
    registerIpcHandlers(ipcMain, createMockContext({
      projectRuntime: {
        get: async () => ({ project, scenarioStore: null, diagnostics: null, taskStore: null }),
      },
      recognize: async () => {
        recognizeCalls += 1;
        throw new Error("model must not be called");
      },
    }));

    // The Main boundary is the last compatibility gate before provider code;
    // legacy raw PDF input must fail locally with zero model invocations.
    await assert.rejects(
      () => ipcMain.invoke("recognize", {
        projectId: project.id,
        provider: "openai",
        model: "test-model",
        pdfDataUrl: "data:application/pdf;base64,JVBERi0xLjQK",
      }),
      (error) => error.status === 400 && /逐页图片/.test(error.message),
    );
    assert.equal(recognizeCalls, 0);
  });

  it("save-provider-key rejects unknown provider", async () => {
    const ipcMain = createMockIpcMain();
    registerIpcHandlers(ipcMain, createMockContext());

    await assert.rejects(
      () => ipcMain.invoke("save-provider-key", { provider: "unknown" }),
      { message: "未知 API 服务商" },
    );
  });

  it("save-provider-key supports openai-compatible when its endpoint and model are present", async () => {
    const runtimeProviderKeys = new Map();
    const ipcMain = createMockIpcMain();
    registerIpcHandlers(ipcMain, createMockContext({
      runtimeProviderKeys,
      runtimeEnv: () => ({
        OPENAI_COMPATIBLE_BASE_URL: "https://local.example/v1",
        OPENAI_COMPATIBLE_MODEL: "local-vision",
      }),
    }));

    const result = await ipcMain.invoke("save-provider-key", {
      provider: "openai-compatible",
      apiKey: "sk-test",
    });
    assert.deepEqual(result, { provider: "openai-compatible", configured: true });
  });

  it("global settings persist validated non-secret overrides and refresh runtime settings", async () => {
    const runtimeGlobalConfig = { MAX_BODY_MB: "80" };
    const saves = [];
    let refreshCount = 0;
    const ipcMain = createMockIpcMain();
    registerIpcHandlers(ipcMain, createMockContext({
      runtimeGlobalConfig,
      globalConfigStore: {
        save: async (values) => {
          const saved = { version: 1, values: { ...values } };
          saves.push(saved);
          return saved;
        },
      },
      runtimeEnv: () => ({
        MAX_BODY_MB: runtimeGlobalConfig.MAX_BODY_MB || "80",
        SLATESYNC_CONFIG_PATH: runtimeGlobalConfig.SLATESYNC_CONFIG_PATH || "slatesync.config.json",
      }),
      refreshRuntimeSettings: () => { refreshCount += 1; },
    }));

    const initial = await ipcMain.invoke("get-global-settings");
    assert.equal(initial.values.MAX_BODY_MB, "80");
    assert.deepEqual(initial.overrides, ["MAX_BODY_MB"]);

    await assert.rejects(
      () => ipcMain.invoke("save-global-settings", { values: { OPENAI_API_KEY: "secret" } }),
      /不支持的全局配置项/,
    );

    const saved = await ipcMain.invoke("save-global-settings", {
      values: { MAX_BODY_MB: "120", OPENAI_BASE_URL: "https://local.example/v1" },
    });
    assert.equal(saved.values.MAX_BODY_MB, "120");
    assert.deepEqual(saved.overrides, ["OPENAI_BASE_URL", "MAX_BODY_MB"]);
    assert.equal(saved.restartRequired, false);
    assert.deepEqual(saves.at(-1).values, { MAX_BODY_MB: "120", OPENAI_BASE_URL: "https://local.example/v1" });

    const pathChange = await ipcMain.invoke("save-global-settings", {
      values: { SLATESYNC_CONFIG_PATH: "custom.config.json" },
    });
    assert.equal(pathChange.restartRequired, true);

    const cleared = await ipcMain.invoke("save-global-settings", { values: { MAX_BODY_MB: "" } });
    assert.equal(cleared.values.MAX_BODY_MB, "80");
    assert.equal(cleared.overrides.includes("MAX_BODY_MB"), false);
    assert.ok(refreshCount >= 3);
  });

  it("global OCR path changes clear a stale first-run completion marker", async () => {
    const runtimeGlobalConfig = { PADDLEOCR_PYTHON: "/old/bin/python" };
    const runtimeSettings = {
      ocrPythonPath: "/old/bin/python",
      ocrSetupCompleted: true,
      ocrSetupSkipped: false,
    };
    const ipcMain = createMockIpcMain();
    registerIpcHandlers(ipcMain, createMockContext({
      runtimeGlobalConfig,
      runtimeSettings,
      settingsStore: { save: async () => {} },
      globalConfigStore: {
        save: async (values) => ({ version: 1, values: { ...values } }),
      },
      runtimeEnv: () => ({ PADDLEOCR_PYTHON: runtimeGlobalConfig.PADDLEOCR_PYTHON }),
    }));

    await ipcMain.invoke("save-global-settings", {
      values: { PADDLEOCR_PYTHON: "" },
    });

    assert.equal(runtimeSettings.ocrPythonPath, "");
    assert.equal(runtimeSettings.ocrSetupCompleted, false);
    assert.equal(runtimeSettings.ocrSetupSkipped, false);
  });

  it("saving PaddleOCR enablement clears a stale Vision route", async () => {
    const runtimeGlobalConfig = {
      VISIONOCR_ENABLED: "true",
      VISIONOCR_REQUIRED: "true",
      PADDLEOCR_ENABLED: "auto",
    };
    const ipcMain = createMockIpcMain();
    registerIpcHandlers(ipcMain, createMockContext({
      runtimeGlobalConfig,
      runtimeEnv: () => ({ ...runtimeGlobalConfig }),
      globalConfigStore: {
        save: async (values) => ({ version: 1, values: { ...values } }),
      },
    }));

    const saved = await ipcMain.invoke("save-global-settings", {
      values: { PADDLEOCR_ENABLED: "true" },
    });

    assert.equal(runtimeGlobalConfig.PADDLEOCR_ENABLED, "true");
    assert.equal(runtimeGlobalConfig.VISIONOCR_ENABLED, "false");
    assert.equal(runtimeGlobalConfig.VISIONOCR_REQUIRED, "false");
    assert.equal(saved.values.PADDLEOCR_ENABLED, "true");
    assert.equal(saved.values.VISIONOCR_ENABLED, "false");
    assert.equal(saved.values.VISIONOCR_REQUIRED, "false");
  });

  it("save-provider-key stores and clears keys", async () => {
    const savedKeys = [];
    const keyStore = {
      save: async (keys) => savedKeys.push(Object.fromEntries(keys)),
    };
    const runtimeProviderKeys = new Map();
    const ipcMain = createMockIpcMain();
    registerIpcHandlers(
      ipcMain,
      createMockContext({ runtimeProviderKeys, keyStore }),
    );

    // Set a key
    const setResult = await ipcMain.invoke("save-provider-key", {
      provider: "openai",
      apiKey: "sk-test-key",
    });
    assert.equal(setResult.provider, "openai");
    assert.equal(setResult.configured, true);
    assert.equal(runtimeProviderKeys.get("openai"), "sk-test-key");
    assert.equal(savedKeys.length, 1);

    // Clear the key
    const clearResult = await ipcMain.invoke("save-provider-key", {
      provider: "openai",
      apiKey: "",
    });
    assert.equal(clearResult.provider, "openai");
    assert.equal(runtimeProviderKeys.has("openai"), false);
    assert.equal(savedKeys.length, 2);
  });

  it("save-file throws when fileDialogs not available", async () => {
    const ipcMain = createMockIpcMain();
    registerIpcHandlers(ipcMain, createMockContext({ fileDialogs: null }));

    await assert.rejects(
      () =>
        ipcMain.invoke("save-file", {
          defaultFilename: "test.csv",
          data: [1, 2, 3],
        }),
      { message: "文件对话框不可用" },
    );
  });

  it("scan-slate-directory throws when slateScanner not available", async () => {
    const ipcMain = createMockIpcMain();
    registerIpcHandlers(ipcMain, createMockContext({ slateScanner: null }));

    await assert.rejects(
      () =>
        ipcMain.invoke("scan-slate-directory", {
          dirPath: "/tmp",
          expectedKeys: ["A001C001"],
          maxDepth: 4,
        }),
      { message: "目录扫描不可用" },
    );
  });

  it("save-task updates an existing task without replacing it", async () => {
    const projectId = "project-tasks";
    const calls = [];
    const taskStore = {
      updateTask: async (id, patch) => {
        calls.push({ id, patch });
        return id;
      },
      saveTask: async () => assert.fail("existing task must be updated"),
    };
    const projectRuntime = {
      get: async (requestedId) => {
        assert.equal(requestedId, projectId);
        return { project: { id: projectId }, taskStore };
      },
    };
    const ipcMain = createMockIpcMain();
    registerIpcHandlers(ipcMain, createMockContext({ projectRuntime }));

    const patch = {
      id: "task-123",
      editedRecords: [{ scene: "001", shot: "01", take: "01" }],
      status: "edited",
    };
    assert.equal(
      await ipcMain.invoke("save-task", { projectId, task: patch }),
      "task-123",
    );
    assert.deepEqual(calls, [{
      id: "task-123",
      patch: { ...patch, projectId },
    }]);
  });

  it("completes an existing draft instead of creating a second task", async () => {
    const project = {
      id: "project-draft-completion",
      settings: {
        accuracyMode: "high",
        resolve: {
          fieldFormats: { scene: "XXX", shot: "XX", take: "XX" },
          comments: { goodTake: "_OK", holdTake: "_KP" },
        },
      },
    };
    const updates = [];
    const persisted = new Map([[
      "draft-task-1",
      { id: "draft-task-1", status: "draft", resolveCsvFilename: "timeline.csv" },
    ]]);
    const taskStore = {
      updateTask: async (id, patch) => {
        updates.push({ id, patch });
        persisted.set(id, { ...persisted.get(id), ...patch, id });
        return id;
      },
      saveTask: async () => assert.fail("a persisted draft must not be duplicated"),
    };
    const projectRuntime = {
      get: async () => ({ project, scenarioStore: null, diagnostics: null, taskStore }),
    };
    const recognize = async () => ({
      provider: "openai",
      model: "test-model",
      pageCount: 1,
      accuracyMode: "high",
      result: { records: [{ scene: "001", shot: "01", take: "01" }] },
      usage: null,
      durationMs: 1,
      ocr: null,
      scenario: null,
    });
    const ipcMain = createMockIpcMain();
    registerIpcHandlers(ipcMain, createMockContext({ projectRuntime, recognize }));

    const result = await ipcMain.invoke("recognize", {
      projectId: project.id,
      taskId: "draft-task-1",
      provider: "openai",
      model: "test-model",
      filename: "slate.png",
    });

    assert.equal(result.taskId, "draft-task-1");
    assert.equal(updates.length, 1);
    assert.equal(updates[0].id, "draft-task-1");
    assert.equal(updates[0].patch.status, "completed");
    assert.equal(updates[0].patch.filename, "slate.png");
    assert.equal(updates[0].patch.result.records.length, 1);
    assert.deepEqual(updates[0].patch.editedRecords, updates[0].patch.result.records);
    assert.equal(persisted.size, 1);
    assert.equal(persisted.get("draft-task-1").status, "completed");
    assert.equal(persisted.get("draft-task-1").resolveCsvFilename, "timeline.csv");
  });

  it("blocks project archival until an in-flight recognition finishes", async () => {
    let signalStarted;
    let finishRecognition;
    const started = new Promise((resolve) => {
      signalStarted = resolve;
    });
    const recognitionGate = new Promise((resolve) => {
      finishRecognition = resolve;
    });
    const archived = [];
    const project = {
      id: "project-active",
      settings: {
        accuracyMode: "high",
        resolve: {
          fieldFormats: { scene: "XXX", shot: "XX", take: "XX" },
          comments: { goodTake: "_OK", holdTake: "_KP" },
        },
      },
    };
    const projectLibrary = {
      archiveProject: async (id) => {
        archived.push(id);
        return { ...project, archivedAt: new Date().toISOString() };
      },
      touchProjectActivity: async () => {},
    };
    const projectRuntime = {
      get: async () => ({
        project,
        scenarioStore: null,
        diagnostics: { saveSession: async () => "diagnostic-1" },
        taskStore: { saveTask: async () => "task-1" },
      }),
    };
    const recognize = async () => {
      signalStarted();
      await recognitionGate;
      return {
        provider: "openai",
        model: "test-model",
        pageCount: 1,
        accuracyMode: "high",
        result: { records: [] },
        usage: null,
        durationMs: 1,
        ocr: null,
        scenario: null,
      };
    };
    const ipcMain = createMockIpcMain();
    registerIpcHandlers(ipcMain, createMockContext({
      projectLibrary,
      projectRuntime,
      recognize,
    }));

    const recognition = ipcMain.invoke("recognize", {
      projectId: project.id,
      provider: "openai",
      model: "test-model",
      filename: "slate.png",
    });
    await started;

    await assert.rejects(
      () => ipcMain.invoke("archive-project", { id: project.id }),
      { message: "项目正在写入数据，完成后才能归档" },
    );
    assert.deepEqual(archived, []);

    finishRecognition();
    const result = await recognition;
    assert.equal(result.projectId, project.id);
    assert.deepEqual(result.projectSettingsSnapshot.resolve, project.settings.resolve);

    await ipcMain.invoke("archive-project", { id: project.id });
    assert.deepEqual(archived, [project.id]);
  });

  it("rejects recognition while the project is being archived", async () => {
    let signalArchiveStarted;
    let finishArchive;
    const archiveStarted = new Promise((resolve) => {
      signalArchiveStarted = resolve;
    });
    const archiveGate = new Promise((resolve) => {
      finishArchive = resolve;
    });
    let recognizeCalls = 0;
    let diagnosticWrites = 0;
    const project = {
      id: "project-archiving",
      settings: {
        accuracyMode: "high",
        resolve: {
          fieldFormats: { scene: "XXX", shot: "XX", take: "XX" },
          comments: { goodTake: "_OK", holdTake: "_KP" },
        },
      },
    };
    const projectLibrary = {
      archiveProject: async () => {
        signalArchiveStarted();
        await archiveGate;
        return { ...project, archivedAt: new Date().toISOString() };
      },
    };
    const projectRuntime = {
      get: async () => ({
        project,
        scenarioStore: null,
        diagnostics: {
          saveSession: async () => {
            diagnosticWrites += 1;
          },
        },
        taskStore: { saveTask: async () => "task-1" },
      }),
    };
    const ipcMain = createMockIpcMain();
    registerIpcHandlers(ipcMain, createMockContext({
      projectLibrary,
      projectRuntime,
      recognize: async () => {
        recognizeCalls += 1;
      },
    }));

    const archive = ipcMain.invoke("archive-project", { id: project.id });
    await archiveStarted;
    await assert.rejects(
      () => ipcMain.invoke("recognize", {
        projectId: project.id,
        provider: "openai",
        model: "test-model",
        filename: "slate.png",
      }),
      { message: "项目正在归档，无法写入数据" },
    );
    assert.equal(recognizeCalls, 0);
    assert.equal(diagnosticWrites, 0);

    finishArchive();
    await archive;
  });

  it("uses one project write lease for task saves and refreshes activity", async () => {
    let signalSaveStarted;
    let finishSave;
    const saveStarted = new Promise((resolve) => {
      signalSaveStarted = resolve;
    });
    const saveGate = new Promise((resolve) => {
      finishSave = resolve;
    });
    const archived = [];
    const activity = [];
    const deleted = [];
    const project = { id: "project-saving", settings: {} };
    const projectLibrary = {
      archiveProject: async (id) => {
        archived.push(id);
        return { ...project, archivedAt: new Date().toISOString() };
      },
      touchProjectActivity: async (id) => activity.push(id),
    };
    const projectRuntime = {
      get: async () => ({
        project,
        taskStore: {
          updateTask: async () => {
            signalSaveStarted();
            await saveGate;
            return "task-1";
          },
          deleteTask: async (id) => deleted.push(id),
        },
      }),
    };
    const ipcMain = createMockIpcMain();
    registerIpcHandlers(ipcMain, createMockContext({
      projectLibrary,
      projectRuntime,
    }));

    const save = ipcMain.invoke("save-task", {
      projectId: project.id,
      task: { id: "task-1", status: "edited" },
    });
    await saveStarted;
    await assert.rejects(
      () => ipcMain.invoke("archive-project", { id: project.id }),
      { message: "项目正在写入数据，完成后才能归档" },
    );

    finishSave();
    assert.equal(await save, "task-1");
    assert.deepEqual(activity, [project.id]);
    assert.deepEqual(
      await ipcMain.invoke("delete-task", {
        projectId: project.id,
        id: "task-1",
      }),
      { deleted: "task-1" },
    );
    assert.deepEqual(deleted, ["task-1"]);
    assert.deepEqual(activity, [project.id, project.id]);
    await ipcMain.invoke("archive-project", { id: project.id });
    assert.deepEqual(archived, [project.id]);
  });

  it("keeps task provider, model, and empty prompt while applying project rules", async () => {
    let receivedInput;
    const activity = [];
    const project = {
      id: "project-recognition-defaults",
      settings: {
        providerId: "project-provider",
        modelId: "project-model",
        customPrompt: "project prompt",
        accuracyMode: "standard",
        scenarioId: "scenario-project",
        resolve: {
          fieldFormats: { scene: "XXXX", shot: "XXX", take: "XX" },
          comments: { goodTake: "GOOD", holdTake: "HOLD" },
        },
      },
    };
    const projectLibrary = {
      touchProjectActivity: async (id) => activity.push(id),
    };
    const projectRuntime = {
      get: async () => ({
        project,
        scenarioStore: null,
        diagnostics: null,
        taskStore: { saveTask: async () => "task-defaults" },
      }),
    };
    const ipcMain = createMockIpcMain();
    registerIpcHandlers(ipcMain, createMockContext({
      projectLibrary,
      projectRuntime,
      recognize: async (input) => {
        receivedInput = input;
        return {
          provider: input.providerId,
          model: input.modelId,
          pageCount: 1,
          accuracyMode: input.accuracyMode,
          result: { records: [] },
          usage: null,
          durationMs: 1,
          ocr: null,
          scenario: null,
        };
      },
    }));

    await ipcMain.invoke("recognize", {
      projectId: project.id,
      provider: "recent-provider",
      model: "recent-model",
      // A stale or crafted task-level value cannot override the project mode.
      accuracyMode: "high",
      customPrompt: "",
      filename: "slate.png",
    });

    assert.equal(receivedInput.providerId, "recent-provider");
    assert.equal(receivedInput.modelId, "recent-model");
    assert.equal(receivedInput.customPrompt, "");
    assert.equal(receivedInput.accuracyMode, "standard");
    assert.equal(receivedInput.scenarioId, "scenario-project");
    assert.deepEqual(receivedInput.fieldFormats, project.settings.resolve.fieldFormats);
    assert.deepEqual(activity, [project.id]);
  });

  it("get-ocr-settings returns the persisted OCR settings", async () => {
    const ipcMain = createMockIpcMain();
    registerIpcHandlers(
      ipcMain,
      createMockContext({
        runtimeSettings: {
          ocrPythonPath: "/venv/bin/python",
          ocrSetupCompleted: true,
          ocrSetupSkipped: false,
        },
      }),
    );

    const settings = await ipcMain.invoke("get-ocr-settings");
    assert.deepEqual(settings, {
      pythonPath: "/venv/bin/python",
      setupCompleted: true,
      setupSkipped: false,
    });
  });

  it("save-ocr-settings persists a python path and marks setup complete", async () => {
    const saved = [];
    const settingsStore = {
      save: async (settings) => {
        saved.push(settings);
      },
    };
    const runtimeSettings = {
      ocrPythonPath: "",
      ocrSetupCompleted: false,
      ocrSetupSkipped: false,
    };
    const checkOcr = async ({ pythonPath }) => ({
      ok: true,
      pythonPath,
    });
    const ipcMain = createMockIpcMain();
    registerIpcHandlers(
      ipcMain,
      createMockContext({ settingsStore, runtimeSettings, checkOcr }),
    );

    const result = await ipcMain.invoke("save-ocr-settings", {
      pythonPath: "/venv/bin/python",
    });
    assert.equal(result.pythonPath, "/venv/bin/python");
    assert.equal(result.setupCompleted, true);
    assert.equal(result.setupSkipped, false);
    assert.equal(runtimeSettings.ocrPythonPath, "/venv/bin/python");
    assert.equal(saved.length, 1);
  });

  it("rejects an OCR path when validation fails without persisting it", async () => {
    const saved = [];
    const settingsStore = { save: async (settings) => saved.push(settings) };
    const runtimeSettings = {
      ocrPythonPath: "",
      ocrSetupCompleted: false,
      ocrSetupSkipped: false,
    };
    const checkOcr = async () => ({
      ok: false,
      error: { code: "spawn_failed", message: "无法启动 Python" },
    });
    const ipcMain = createMockIpcMain();
    registerIpcHandlers(
      ipcMain,
      createMockContext({ settingsStore, runtimeSettings, checkOcr }),
    );

    await assert.rejects(
      () =>
        ipcMain.invoke("save-ocr-settings", {
          pythonPath: "/missing/python",
        }),
      { message: "无法启动 Python" },
    );
    assert.deepEqual(runtimeSettings, {
      ocrPythonPath: "",
      ocrSetupCompleted: false,
      ocrSetupSkipped: false,
    });
    assert.equal(saved.length, 0);
  });

  it("save-ocr-settings skip marks setup skipped without a path", async () => {
    const runtimeSettings = {
      ocrPythonPath: "",
      ocrSetupCompleted: false,
      ocrSetupSkipped: false,
    };
    const ipcMain = createMockIpcMain();
    registerIpcHandlers(
      ipcMain,
      createMockContext({
        settingsStore: { save: async () => {} },
        runtimeSettings,
      }),
    );

    const result = await ipcMain.invoke("save-ocr-settings", { skip: true });
    assert.equal(result.setupSkipped, true);
    assert.equal(runtimeSettings.ocrSetupSkipped, true);
    assert.equal(runtimeSettings.ocrPythonPath, "");
  });
});

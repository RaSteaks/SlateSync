import { afterEach, beforeEach, describe, it } from "node:test";
import assert from "node:assert/strict";
import {
  archiveProjectApi,
  changeLibraryLocationApi,
  checkCompatibleJsonSchemaApi,
  checkOcrApi,
  cancelPaddleOcrInstallApi,
  createProjectApi,
  deleteTaskApi,
  downloadFileApi,
  exportProjectApi,
  exportProjectLibraryApi,
  fetchConfig,
  fetchModelsApi,
  getGlobalSettingsApi,
  getLibraryInfoApi,
  getOcrSettingsApi,
  importProjectLibraryApi,
  importProjectApi,
  importScenarioApi,
  installPaddleOcrApi,
  listProjectsApi,
  listScenariosApi,
  listTasksApi,
  loadProjectApi,
  loadScenarioApi,
  loadTaskApi,
  onPaddleOcrInstallProgressApi,
  pickDirectoryApi,
  recognizeApi,
  restoreProjectApi,
  saveOcrSettingsApi,
  saveGlobalSettingsApi,
  saveProviderKeyApi,
  saveTaskApi,
  scanSlateDirectoryApi,
  updateProjectApi,
} from "../public/electron-bridge.js";

function success(data) {
  return Promise.resolve({ ok: true, data });
}

function makeGateway(calls, progress) {
  const operation = (name) => (...args) => {
    const data = { name, args };
    calls.push(data);
    return success(data);
  };
  return {
    app: { getConfig: operation("app.getConfig") },
    projects: {
      list: operation("projects.list"),
      getLibraryInfo: operation("projects.getLibraryInfo"),
      importProject: operation("projects.importProject"),
      exportProject: operation("projects.exportProject"),
      importLibrary: operation("projects.importLibrary"),
      exportLibrary: operation("projects.exportLibrary"),
      changeLibraryLocation: operation("projects.changeLibraryLocation"),
      create: operation("projects.create"),
      load: operation("projects.load"),
      update: operation("projects.update"),
      archive: operation("projects.archive"),
      restore: operation("projects.restore"),
      listScenarios: operation("projects.listScenarios"),
      loadScenario: operation("projects.loadScenario"),
      importScenario: operation("projects.importScenario"),
    },
    tasks: {
      list: operation("tasks.list"),
      load: operation("tasks.load"),
      save: operation("tasks.save"),
      delete: operation("tasks.delete"),
    },
    recognition: {
      getModels: operation("recognition.getModels"),
      run: operation("recognition.run"),
      onProgress(listener) {
        progress.listener = listener;
        progress.subscriptions += 1;
        let active = true;
        return () => {
          if (!active) return;
          active = false;
          progress.unsubscriptions += 1;
          if (progress.listener === listener) progress.listener = null;
        };
      },
    },
    files: {
      save: operation("files.save"),
      selectDirectory: operation("files.selectDirectory"),
      scanSlateDirectory: operation("files.scanSlateDirectory"),
    },
    settings: {
      saveProviderKey: operation("settings.saveProviderKey"),
      getGlobalSettings: operation("settings.getGlobalSettings"),
      saveGlobalSettings: operation("settings.saveGlobalSettings"),
      getOcrSettings: operation("settings.getOcrSettings"),
      saveOcrSettings: operation("settings.saveOcrSettings"),
      checkOcr: operation("settings.checkOcr"),
      installPaddleOcr: operation("settings.installPaddleOcr"),
      cancelPaddleOcrInstall: operation("settings.cancelPaddleOcrInstall"),
      onPaddleOcrInstallProgress(listener) {
        progress.installListener = listener;
        progress.installSubscriptions += 1;
        let active = true;
        return () => {
          if (!active) return;
          active = false;
          progress.installUnsubscriptions += 1;
          if (progress.installListener === listener) progress.installListener = null;
        };
      },
      checkCompatibleJsonSchema: operation("settings.checkCompatibleJsonSchema"),
    },
  };
}

describe("electron renderer bridge", () => {
  let originalSlateSync;

  beforeEach(() => {
    originalSlateSync = globalThis.slateSync;
    delete globalThis.slateSync;
  });

  afterEach(() => {
    if (originalSlateSync === undefined) delete globalThis.slateSync;
    else globalThis.slateSync = originalSlateSync;
  });

  it("fails clearly when the sole preload gateway is unavailable", async () => {
    await assert.rejects(() => fetchConfig(), /preload bridge is unavailable/);
  });

  it("explains how to recover from a stale Preload for global settings", async () => {
    globalThis.slateSync = { settings: {} };
    await assert.rejects(
      () => getGlobalSettingsApi(),
      /Renderer 与 Preload 版本不一致.*完全退出 SlateSync.*不要只刷新窗口/,
    );
  });

  it("maps all 34 legacy operations to exact typed requests and raw results", async () => {
    const calls = [];
    const progress = { listener: null, subscriptions: 0, unsubscriptions: 0 };
    globalThis.slateSync = makeGateway(calls, progress);
    const project = { id: "project-1", name: "Demo" };
    const profile = { schemaVersion: 1, label: "Profile" };
    const task = { id: "task-1", status: "edited" };

    const invocations = [
      [fetchConfig, [], "app.getConfig", []],
      [listProjectsApi, [], "projects.list", []],
      [getLibraryInfoApi, [], "projects.getLibraryInfo", []],
      [importProjectApi, [], "projects.importProject", []],
      [exportProjectApi, ["project-1"], "projects.exportProject", [{ id: "project-1" }]],
      [importProjectLibraryApi, [], "projects.importLibrary", []],
      [exportProjectLibraryApi, [], "projects.exportLibrary", []],
      [changeLibraryLocationApi, [], "projects.changeLibraryLocation", []],
      [createProjectApi, [project], "projects.create", [project]],
      [loadProjectApi, ["project-1"], "projects.load", [{ id: "project-1" }]],
      [updateProjectApi, [project], "projects.update", [project]],
      [archiveProjectApi, ["project-1"], "projects.archive", [{ id: "project-1" }]],
      [restoreProjectApi, ["project-1"], "projects.restore", [{ id: "project-1" }]],
      [listScenariosApi, ["project-1"], "projects.listScenarios", [{ projectId: "project-1" }]],
      [loadScenarioApi, ["scenario-1", "project-1"], "projects.loadScenario", [{ id: "scenario-1", projectId: "project-1" }]],
      [importScenarioApi, [profile, "project-1"], "projects.importScenario", [{ profile, projectId: "project-1" }]],
      [listTasksApi, ["project-1"], "tasks.list", [{ projectId: "project-1" }]],
      [loadTaskApi, ["task-1", "project-1"], "tasks.load", [{ id: "task-1", projectId: "project-1" }]],
      [saveTaskApi, [task, "project-1"], "tasks.save", [{ task, projectId: "project-1" }]],
      [deleteTaskApi, ["task-1", "project-1"], "tasks.delete", [{ id: "task-1", projectId: "project-1" }]],
      [fetchModelsApi, ["openai", true], "recognition.getModels", [{ providerId: "openai", forceRefresh: true }]],
      [pickDirectoryApi, [], "files.selectDirectory", []],
      [scanSlateDirectoryApi, ["/synthetic", ["A:1:1"], 4], "files.scanSlateDirectory", [{ dirPath: "/synthetic", expectedKeys: ["A:1:1"], maxDepth: 4 }]],
      [saveProviderKeyApi, ["openai", "synthetic-key"], "settings.saveProviderKey", [{ provider: "openai", apiKey: "synthetic-key" }]],
      [getGlobalSettingsApi, [], "settings.getGlobalSettings", []],
      [saveGlobalSettingsApi, [{ values: { MAX_BODY_MB: "100" } }], "settings.saveGlobalSettings", [{ values: { MAX_BODY_MB: "100" } }]],
      [getOcrSettingsApi, [], "settings.getOcrSettings", []],
      [saveOcrSettingsApi, [{ skip: true }], "settings.saveOcrSettings", [{ skip: true }]],
      [checkOcrApi, ["python3"], "settings.checkOcr", [{ pythonPath: "python3" }]],
      [installPaddleOcrApi, [], "settings.installPaddleOcr", []],
      [cancelPaddleOcrInstallApi, [], "settings.cancelPaddleOcrInstall", []],
      [checkCompatibleJsonSchemaApi, [], "settings.checkCompatibleJsonSchema", []],
    ];

    for (const [fn, args, name, expectedArgs] of invocations) {
      const raw = await fn(...args);
      assert.deepEqual(raw, { name, args: expectedArgs });
    }

    const recognition = await recognizeApi(
      JSON.stringify({ projectId: "project-1" }),
      () => {},
    );
    assert.deepEqual(recognition, {
      name: "recognition.run",
      args: [{ projectId: "project-1" }],
    });

    const binary = new Uint8Array([1, 2, 3]).buffer;
    const saved = await downloadFileApi(binary, "demo.csv");
    assert.equal(saved.name, "files.save");
    assert.equal(saved.args[0].defaultFilename, "demo.csv");
    assert.equal(saved.args[0].data, binary);
    assert.equal(calls.length, 34);
  });

  it("preserves the full-buffer identity and copies only an exact subview", async () => {
    const received = [];
    globalThis.slateSync = {
      files: {
        save: async (request) => {
          received.push(request.data);
          return { ok: true, data: { saved: true } };
        },
      },
    };

    const buffer = new Uint8Array([1, 2, 3]).buffer;
    await downloadFileApi(buffer, "buffer.csv");
    assert.equal(received[0], buffer);

    const fullView = new Uint8Array(buffer);
    await downloadFileApi(fullView, "view.csv");
    assert.equal(received[1], buffer);

    const backing = new Uint8Array([9, 8, 7, 6, 5]);
    await downloadFileApi(backing.subarray(1, 4), "subview.csv");
    assert.notEqual(received[2], backing.buffer);
    assert.deepEqual([...new Uint8Array(received[2])], [8, 7, 6]);
  });

  it("keeps the Legacy PaddleOCR progress subscription idempotent", () => {
    const calls = [];
    const progress = {
      listener: null,
      subscriptions: 0,
      unsubscriptions: 0,
      installListener: null,
      installSubscriptions: 0,
      installUnsubscriptions: 0,
    };
    globalThis.slateSync = makeGateway(calls, progress);
    const received = [];
    const unsubscribe = onPaddleOcrInstallProgressApi((event) => received.push(event));

    progress.installListener({ stage: "verify", percent: 90, message: "验证中" });
    unsubscribe();
    unsubscribe();
    progress.installListener?.({ stage: "completed", percent: 100, message: "late" });

    assert.deepEqual(received, [{ stage: "verify", percent: 90, message: "验证中" }]);
    assert.equal(progress.installSubscriptions, 1);
    assert.equal(progress.installUnsubscriptions, 1);
  });

  it("always removes progress listeners after success and failure", async () => {
    const events = [];
    let listener = null;
    let response = { ok: true, data: { result: { records: [] } } };
    globalThis.slateSync = {
      recognition: {
        onProgress(next) {
          listener = next;
          events.push("subscribed");
          let active = true;
          return () => {
            if (!active) return;
            active = false;
            listener = null;
            events.push("unsubscribed");
          };
        },
        run: async () => response,
      },
    };

    const progress = [];
    const first = recognizeApi("{}", (event) => progress.push(event));
    listener({ phase: "recognition", percent: 50 });
    await first;
    assert.equal(listener, null);

    response = {
      ok: false,
      error: { code: "HTTP_504", message: "识别超时", retryable: true },
    };
    await assert.rejects(() => recognizeApi("{}", () => {}), /识别超时/);
    assert.equal(listener, null);
    assert.deepEqual(progress, [{ phase: "recognition", percent: 50 }]);
    assert.deepEqual(events, ["subscribed", "unsubscribed", "subscribed", "unsubscribed"]);
  });

  it("reconstructs the complete compatibility error matrix", async () => {
    const cases = [
      { code: "UNKNOWN", message: "项目名称不能为空", retryable: false },
      { code: "ENOENT", message: "任务不存在", retryable: false },
      { code: "PROJECT_BUSY", message: "项目正在归档，无法写入数据", retryable: false },
      { code: "LIBRARY_BUSY", message: "项目库仍有任务正在写入", retryable: false },
      { code: "HTTP_503", message: "服务暂时不可用", retryable: true, status: 503 },
      { code: "HTTP_504", message: "读取模型列表超时", retryable: true, status: 504 },
      { code: "UNKNOWN", message: "文件对话框不可用", retryable: false },
      { code: "UNKNOWN", message: "未知错误", retryable: false },
    ];

    for (const expected of cases) {
      globalThis.slateSync = {
        app: { getConfig: async () => ({ ok: false, error: expected }) },
      };
      await assert.rejects(
        () => fetchConfig(),
        (error) => {
          assert.equal(error.message, expected.message);
          assert.equal(error.code, expected.code);
          assert.equal(error.retryable, expected.retryable);
          assert.equal(error.status, expected.status);
          return true;
        },
      );
    }
  });
});

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
    ...overrides,
  };
}

describe("electron IPC handlers", () => {
  it("registers all expected channels", () => {
    const ipcMain = createMockIpcMain();
    registerIpcHandlers(ipcMain, createMockContext());

    const expectedChannels = [
      "get-config",
      "save-provider-key",
      "get-models",
      "recognize",
      "save-file",
      "select-directory",
      "scan-slate-directory",
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

  it("save-provider-key rejects unknown provider", async () => {
    const ipcMain = createMockIpcMain();
    registerIpcHandlers(ipcMain, createMockContext());

    await assert.rejects(
      () => ipcMain.invoke("save-provider-key", { provider: "unknown" }),
      { message: "未知 API 服务商" },
    );
  });

  it("save-provider-key rejects openai-compatible", async () => {
    const ipcMain = createMockIpcMain();
    registerIpcHandlers(ipcMain, createMockContext());

    await assert.rejects(
      () =>
        ipcMain.invoke("save-provider-key", {
          provider: "openai-compatible",
          apiKey: "sk-test",
        }),
      { message: "OpenAI 兼容 API 需通过环境变量配置" },
    );
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
});

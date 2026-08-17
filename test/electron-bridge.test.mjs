import { afterEach, beforeEach, describe, it } from "node:test";
import assert from "node:assert/strict";
import {
  downloadFileApi,
  fetchConfig,
  recognizeApi,
  saveProviderKeyApi,
} from "../public/electron-bridge.js";

describe("electron renderer bridge", () => {
  let originalElectronAPI;

  beforeEach(() => {
    originalElectronAPI = globalThis.electronAPI;
  });

  afterEach(() => {
    if (originalElectronAPI === undefined) {
      delete globalThis.electronAPI;
    } else {
      globalThis.electronAPI = originalElectronAPI;
    }
  });

  it("fails clearly when the preload bridge is unavailable", async () => {
    delete globalThis.electronAPI;
    await assert.rejects(() => fetchConfig(), /preload bridge is unavailable/);
  });

  it("delegates configuration and key persistence through preload", async () => {
    const config = { providers: [], models: [] };
    globalThis.electronAPI = {
      getConfig: async () => config,
      saveProviderKey: async (provider, apiKey) => ({
        provider,
        configured: Boolean(apiKey),
      }),
    };

    assert.deepEqual(await fetchConfig(), config);
    assert.deepEqual(await saveProviderKeyApi("openai", "sk-test"), {
      provider: "openai",
      configured: true,
    });
  });

  it("converts file bytes to an IPC-safe array", async () => {
    globalThis.electronAPI = {
      saveFile: async (filename, data) => ({ filename, data }),
    };

    assert.deepEqual(
      await downloadFileApi(new Uint8Array([104, 105]), "test.csv"),
      { filename: "test.csv", data: [104, 105] },
    );
  });

  it("registers and always removes recognition progress listeners", async () => {
    const events = [];
    globalThis.electronAPI = {
      onRecognitionProgress: (callback) => {
        events.push("registered");
        callback({ phase: "recognition", percent: 50 });
      },
      recognize: async (body) => ({ body }),
      removeRecognitionProgressListener: () => events.push("removed"),
    };

    const progress = [];
    const result = await recognizeApi(
      JSON.stringify({ projectId: "project-1" }),
      (event) => progress.push(event),
    );

    assert.deepEqual(result, { body: { projectId: "project-1" } });
    assert.deepEqual(progress, [{ phase: "recognition", percent: 50 }]);
    assert.deepEqual(events, ["registered", "removed"]);
  });
});

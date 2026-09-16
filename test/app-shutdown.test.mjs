import test from "node:test";
import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { EventEmitter } from "node:events";

// Evaluate only the real lifecycle wiring against an event emitter. This tests
// Electron's veto/quit ordering without importing Electron or opening a window.
test("a renderer quit veto keeps storage usable; accepted quit awaits durable shutdown once", async () => {
  const source = await readFile(new URL("../electron/main.mjs", import.meta.url), "utf8");
  const wiring = source.slice(source.indexOf('app.on("before-quit",'));
  const events = [];
  let veto = true;
  let finishStorage;
  const storageGate = new Promise((resolve) => { finishStorage = resolve; });
  let didExit;
  const exited = new Promise((resolve) => { didExit = resolve; });
  const app = new EventEmitter();
  app.quit = () => {
    app.emit("before-quit");
    if (veto) return; // Models a dirty Renderer's beforeunload protection.
    let prevented = false;
    app.emit("will-quit", { preventDefault: () => { prevented = true; } });
    if (!prevented) { events.push("exit"); didExit(); }
  };
  const install = new Function("app", "ipcLifecycle", "storageClient", "appLogger", "paddleOcrInstaller", "closePaddleOcrWorker", `
    let pendingLibraryActivation = null;
    let paddleOcrExitCleanupComplete = false;
    let paddleOcrExitCleanupPromise = null;
    const PADDLEOCR_EXIT_SHUTDOWN_TIMEOUT_MS = 2000;
    ${wiring}
  `);
  install(app,
    { cancelRecognitions: () => events.push("cancel"), shutdown: async () => events.push("stop-admission") },
    { close: async () => { events.push("storage-start"); await storageGate; events.push("storage-durable"); } },
    { info: () => {}, close: async () => events.push("logger-close") },
    { cancel: () => {} }, async () => events.push("ocr-stop"));
  app.quit();
  assert.deepEqual(events, ["cancel"]);
  veto = false;
  app.quit();
  await new Promise((resolve) => setImmediate(resolve));
  assert.ok(events.includes("storage-start"));
  assert.ok(!events.includes("exit"));
  app.quit(); // Repeated quit requests must not duplicate cleanup.
  finishStorage();
  await exited;
  assert.equal(events.filter((value) => value === "storage-start").length, 1);
  assert.ok(events.indexOf("storage-durable") < events.indexOf("logger-close"));
  assert.ok(events.indexOf("logger-close") < events.indexOf("exit"));
});

// Exercise the actual activation and veto callbacks with synthetic paths only.
for (const renamed of [false, true]) {
  test(`library activation defers relaunch and restores current path on veto (rename=${renamed})`, async () => {
    const source = await readFile(new URL("../electron/main.mjs", import.meta.url), "utf8");
    const activation = source.slice(source.indexOf("  async function activateLibrary("), source.indexOf("\n  ipcLifecycle = registerIpcHandlers"));
    const veto = source.slice(source.indexOf('  mainWindow.webContents.on("will-prevent-unload"'), source.indexOf("\n\n  // Apply the same boundary"));
    const events = [];
    const currentPath = renamed ? "/tmp/synthetic-renamed" : "/tmp/synthetic-source";
    const webContents = new EventEmitter();
    const state = { libraryPath: "/tmp/synthetic-source" };
    const setup = new Function("mainWindow", "app", "settingsStore", "runtimeSettings", "projectLibrary", "ipcLifecycle", `
      let pendingLibraryActivation = null;
      let libraryRoot = runtimeSettings.libraryPath;
      const resolve = (path) => path;
      const appLogger = null;
      ${activation}
      ${veto}
      return { activateLibrary, pending: () => pendingLibraryActivation };
    `);
    const fixture = setup({ webContents }, { quit: () => events.push("quit"), relaunch: () => events.push("relaunch") },
      { save: async (value) => { events.push("save"); return value; } }, state,
      { getLibraryInfo: async () => ({ path: currentPath }) },
      { cancelLibraryTransfer: () => events.push("unlock") });
    await fixture.activateLibrary("/tmp/synthetic-destination");
    await new Promise((resolve) => setImmediate(resolve));
    assert.deepEqual(events, ["quit"]);
    assert.equal(state.libraryPath, "/tmp/synthetic-source");
    webContents.emit("will-prevent-unload");
    await new Promise((resolve) => setImmediate(resolve));
    assert.equal(fixture.pending(), null);
    assert.equal(state.libraryPath, currentPath);
    assert.deepEqual(events, ["quit", "save", "unlock"]);
    await fixture.activateLibrary("/tmp/synthetic-destination");
    await fixture.pending().commit();
    assert.equal(state.libraryPath, "/tmp/synthetic-destination");
    assert.equal(events.at(-1), "relaunch");
  });
}

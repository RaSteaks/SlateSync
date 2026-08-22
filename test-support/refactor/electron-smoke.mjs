#!/usr/bin/env node

// Production Electron smoke controller. Every run starts the real composition
// root with an isolated profile and Project Library, observes the real window
// through Chromium's debugging protocol, and restores Node's native ABI before
// returning control to the caller. No production test hook or IPC channel is
// added for this evidence.
import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { once } from "node:events";
import {
  access,
  mkdir,
  mkdtemp,
  readdir,
  rename,
  rm,
  stat,
  writeFile,
} from "node:fs/promises";
import { createServer } from "node:net";
import { tmpdir } from "node:os";
import { dirname, join, relative, resolve } from "node:path";
import { createRequire } from "node:module";
import { pathToFileURL, fileURLToPath } from "node:url";

const require = createRequire(import.meta.url);
const electronBinary = require("electron");
const root = resolve(dirname(fileURLToPath(import.meta.url)), "../..");
const mainPath = join(root, "electron", "main.mjs");
const modernIndex = join(root, "out", "renderer", "index.html");
const evidenceRoot = join(root, ".codex", "refactor", "evidence", "IP-03-08");
const isPackagedSmoke = process.argv.includes("--packaged");
const runTimeoutMs = 25_000;

function delay(milliseconds) {
  return new Promise((resolvePromise) => setTimeout(resolvePromise, milliseconds));
}

async function availablePort() {
  const server = createServer();
  server.unref();
  server.listen(0, "127.0.0.1");
  await once(server, "listening");
  const address = server.address();
  assert(address && typeof address === "object", "debug port must be allocated");
  const port = address.port;
  server.close();
  await once(server, "close");
  return port;
}

async function waitForValue(read, description, timeoutMs = runTimeoutMs) {
  const deadline = Date.now() + timeoutMs;
  let lastError = null;
  while (Date.now() < deadline) {
    try {
      const value = await read();
      if (value) return value;
    } catch (error) {
      lastError = error;
    }
    await delay(100);
  }
  throw new Error(`${description} did not become ready within ${timeoutMs}ms${lastError ? `: ${lastError.message}` : ""}`);
}

class DevToolsSession {
  constructor(url) {
    this.socket = new WebSocket(url);
    this.nextId = 1;
    this.pending = new Map();
  }

  async open() {
    await new Promise((resolvePromise, reject) => {
      this.socket.addEventListener("open", resolvePromise, { once: true });
      this.socket.addEventListener("error", () => reject(new Error("DevTools WebSocket failed to open")), { once: true });
    });
    this.socket.addEventListener("message", (event) => {
      const message = JSON.parse(String(event.data));
      if (!message.id) return;
      const pending = this.pending.get(message.id);
      if (!pending) return;
      this.pending.delete(message.id);
      if (message.error) pending.reject(new Error(message.error.message));
      else pending.resolve(message.result);
    });
    this.socket.addEventListener("close", () => {
      for (const pending of this.pending.values()) {
        pending.reject(new Error("DevTools WebSocket closed"));
      }
      this.pending.clear();
    });
  }

  send(method, params = {}) {
    const id = this.nextId;
    this.nextId += 1;
    return new Promise((resolvePromise, reject) => {
      this.pending.set(id, { resolve: resolvePromise, reject });
      this.socket.send(JSON.stringify({ id, method, params }));
    });
  }

  async evaluate(source) {
    const response = await this.send("Runtime.evaluate", {
      expression: `(async () => { ${source} })()`,
      awaitPromise: true,
      returnByValue: true,
    });
    if (response.exceptionDetails) {
      throw new Error(response.exceptionDetails.exception?.description || response.exceptionDetails.text);
    }
    return response.result.value;
  }

  close() {
    this.socket.close();
  }
}

async function browserTarget(port) {
  return waitForValue(async () => {
    const response = await fetch(`http://127.0.0.1:${port}/json/list`);
    if (!response.ok) return null;
    const targets = await response.json();
    const pages = targets.filter((target) => target.type === "page");
    return pages.length === 1 && pages[0].webSocketDebuggerUrl ? pages[0] : null;
  }, "the single production Renderer target");
}

async function stopChild(child) {
  if (child.exitCode !== null || child.signalCode !== null) return;
  child.kill("SIGTERM");
  await Promise.race([
    once(child, "close"),
    delay(2_000).then(() => {
      if (child.exitCode === null && child.signalCode === null) child.kill("SIGKILL");
    }),
  ]);
}

async function fileExists(path) {
  try {
    await access(path);
    return true;
  } catch {
    return false;
  }
}

function packagedExecutable() {
  const candidates = [
    join(root, "dist", `mac-${process.arch}`, "SlateSync.app", "Contents", "MacOS", "SlateSync"),
    join(root, "dist", "mac", "SlateSync.app", "Contents", "MacOS", "SlateSync"),
  ];
  return candidates.find((candidate) => require("node:fs").existsSync(candidate)) || candidates[0];
}

async function runProduction({ label, expectedMode, legacyRequested = false, packaged = false }) {
  const tempRoot = await mkdtemp(join(tmpdir(), `slatesync-${label}-`));
  const userData = join(tempRoot, "user-data");
  const libraryPath = join(tempRoot, "Smoke Library.slatesync-library");
  const outsidePath = join(tempRoot, "outside.html");
  await mkdir(userData, { recursive: true });
  await writeFile(join(userData, "settings.json"), JSON.stringify({
    libraryPath,
    ocrPythonPath: "",
    ocrSetupCompleted: false,
    ocrSetupSkipped: true,
  }, null, 2), "utf8");
  await writeFile(outsidePath, "<!doctype html><title>outside</title>", "utf8");

  const port = await availablePort();
  const executable = packaged ? packagedExecutable() : electronBinary;
  if (packaged) await access(executable);
  const args = [
    `--remote-debugging-port=${port}`,
    `--user-data-dir=${userData}`,
    ...(packaged ? [] : [mainPath]),
    ...(legacyRequested ? ["--slatesync-renderer=legacy"] : []),
  ];
  const child = spawn(executable, args, {
    cwd: root,
    // Empty keys take precedence over a developer .env so startup evidence
    // cannot contact a provider or reveal whether a real key is configured.
    env: {
      ...process.env,
      ELECTRON_ENABLE_LOGGING: "1",
      OPENAI_API_KEY: "",
      OPENROUTER_API_KEY: "",
      TOKENPLAN_API_KEY: "",
      DASHSCOPE_API_KEY: "",
      OPENAI_COMPATIBLE_API_KEY: "",
    },
    stdio: ["ignore", "pipe", "pipe"],
  });
  let output = "";
  const collect = (chunk) => {
    output = `${output}${chunk}`.slice(-200_000);
  };
  child.stdout.on("data", collect);
  child.stderr.on("data", collect);

  let session = null;
  try {
    const target = await browserTarget(port).catch((error) => {
      throw new Error(`${error.message}\nElectron output:\n${output}`);
    });
    session = new DevToolsSession(target.webSocketDebuggerUrl);
    await session.open();
    await session.send("Runtime.enable");
    const marker = expectedMode === "modern" ? "[data-testid=modern-shell]" : "#workspace";
    let state;
    try {
      state = await waitForValue(async () => session.evaluate(`
        const marker = document.querySelector(${JSON.stringify(marker)});
        const legacyReady = ${JSON.stringify(expectedMode)} !== "legacy"
          || (document.querySelector("#app-nav")?.hidden === false
            && document.querySelector("#project-home-page")?.hidden === false);
        if (!marker || !globalThis.slateSync || !legacyReady) return null;
        await document.fonts.ready;
        await new Promise((resolve) => requestAnimationFrame(() => requestAnimationFrame(resolve)));
        // The legacy workspace is intentionally hidden until a project is
        // selected. Its presence identifies the legacy document; body layout is
        // the comparable paint-ready surface for both startup modes.
        const rect = document.body.getBoundingClientRect();
        if (rect.width <= 0 || rect.height <= 0) return null;
        const library = await globalThis.slateSync.projects.getLibraryInfo();
        return {
          href: location.href,
          title: document.title,
          namespaceKeys: Object.keys(globalThis.slateSync).sort(),
          hasGenericInvoke: typeof globalThis.slateSync.invoke !== "undefined",
          forbiddenGlobals: {
            electronAPI: typeof globalThis.electronAPI,
            require: typeof globalThis.require,
            process: typeof globalThis.process,
          },
          library,
          markerReadyMs: performance.now(),
          firstContentfulPaintMs: performance.getEntriesByName("first-contentful-paint")[0]?.startTime ?? null,
          markerRect: { width: rect.width, height: rect.height },
        };
      `), `${label} Renderer and typed Preload`);
    } catch (error) {
      const diagnostics = await session.evaluate(`
        return {
          href: location.href,
          readyState: document.readyState,
          markerPresent: Boolean(document.querySelector(${JSON.stringify(marker)})),
          bodyRect: document.body ? document.body.getBoundingClientRect().toJSON() : null,
          slateSyncType: typeof globalThis.slateSync,
          electronApiType: typeof globalThis.electronAPI,
        };
      `).catch((diagnosticError) => ({ diagnosticError: diagnosticError.message }));
      throw new Error(`${error.message}\nRenderer diagnostics: ${JSON.stringify(diagnostics)}\nElectron output:\n${output}`);
    }

    const expectedRoot = expectedMode === "modern" && !packaged
      ? join(root, "out", "renderer")
      : packaged
        ? null
        : join(root, "public");
    const selectedPath = fileURLToPath(state.href);
    if (expectedRoot) {
      const selectedRelative = relative(expectedRoot, selectedPath);
      assert(!selectedRelative.startsWith("..") && selectedRelative !== "", `${label} must load inside ${expectedRoot}`);
    }
    assert.deepEqual(state.namespaceKeys, ["app", "files", "projects", "recognition", "settings", "tasks"]);
    assert.equal(state.hasGenericInvoke, false);
    assert.deepEqual(state.forbiddenGlobals, { electronAPI: "undefined", require: "undefined", process: "undefined" });
    assert.equal(state.library.ok, true, `${label} Project Library IPC must succeed`);
    assert.equal(resolve(state.library.data.path), resolve(libraryPath));

    const missingProject = await session.evaluate(`
      return globalThis.slateSync.projects.load({ id: "project-does-not-exist" });
    `);
    assert.equal(missingProject.ok, false);
    assert.deepEqual(Object.keys(missingProject.error).sort(), ["code", "message", "retryable"]);
    assert.equal(missingProject.error.retryable, false);
    assert(!missingProject.error.message.includes(tempRoot), "mapped IPC error must not expose the temporary profile");

    const denial = await session.evaluate(`
      const before = location.href;
      const opened = window.open("https://example.invalid/slatesync-smoke");
      location.assign("https://example.invalid/slatesync-smoke");
      await new Promise((resolve) => setTimeout(resolve, 100));
      const afterExternal = location.href;
      location.assign(${JSON.stringify(pathToFileURL(outsidePath).href)});
      await new Promise((resolve) => setTimeout(resolve, 100));
      return { before, afterExternal, afterFile: location.href, opened: opened === null };
    `);
    assert.deepEqual(denial, {
      before: state.href,
      afterExternal: state.href,
      afterFile: state.href,
      opened: true,
    });

    let pdfVersion = null;
    if (expectedMode === "legacy") {
      pdfVersion = await session.evaluate(`
        const module = await import("./vendor/pdfjs/pdf.mjs");
        return module.version;
      `);
      assert.match(pdfVersion, /^\d+\.\d+\.\d+$/);
    }

    const files = await readdir(libraryPath);
    // Production's frozen database filenames use the .sqlite suffix; opening
    // getLibraryInfo above proves the Electron-ABI native binding is usable.
    assert(files.some((name) => name.endsWith(".sqlite")), `${label} must initialize native SQLite`);
    assert(files.includes("library.json"), `${label} must initialize the Project Library manifest`);
    assert(output.includes(`Loaded ${expectedMode} renderer`) || output.includes("Loaded legacy renderer fallback"), `${label} selection log missing:\n${output}`);

    return {
      label,
      packaged,
      expectedMode,
      legacyRequested,
      href: state.href,
      namespaceKeys: state.namespaceKeys,
      markerReadyMs: state.markerReadyMs,
      firstContentfulPaintMs: state.firstContentfulPaintMs,
      markerRect: state.markerRect,
      projectLibraryFiles: files.sort(),
      missingProjectError: missingProject.error,
      pdfVersion,
      deniedNavigation: denial,
      selectedLog: output.split("\n").find((line) => line.includes("Loaded ") && line.includes("renderer")) || null,
    };
  } finally {
    session?.close();
    await stopChild(child);
    await rm(tempRoot, { recursive: true, force: true });
  }
}

async function captureRejectedInvokeFacts() {
  const tempRoot = await mkdtemp(join(tmpdir(), "slatesync-ipc-error-facts-"));
  const entryPath = join(tempRoot, "main.mjs");
  const preloadPath = join(tempRoot, "preload.cjs");
  const pagePath = join(tempRoot, "index.html");
  await writeFile(pagePath, "<!doctype html><title>IPC error facts</title>", "utf8");
  await writeFile(preloadPath, `
const { ipcRenderer } = require("electron");
ipcRenderer.invoke("slatesync-error-fact").catch((error) => {
  const message = typeof error?.message === "string" ? error.message : "";
  ipcRenderer.send("slatesync-error-fact-result", {
    name: error?.name,
    ownKeys: error && typeof error === "object" ? Object.keys(error).sort() : [],
    hasTransportPrefix: message.includes("Error invoking remote method"),
    hasOriginalMessage: message.includes("controlled probe failure"),
    codeType: typeof error?.code,
    statusType: typeof error?.status,
    retryableType: typeof error?.retryable,
    stackType: typeof error?.stack,
  });
});
`, "utf8");
  await writeFile(entryPath, `
import { app, BrowserWindow, ipcMain } from "electron";
import { join } from "node:path";
const root = ${JSON.stringify(tempRoot)};
ipcMain.handle("slatesync-error-fact", () => {
  const error = new Error("controlled probe failure");
  error.code = "PROJECT_BUSY";
  error.status = 503;
  error.retryable = true;
  throw error;
});
ipcMain.once("slatesync-error-fact-result", (_event, facts) => {
  process.stdout.write("IP0102_REJECTED_INVOKE_FACT " + JSON.stringify(facts) + "\\n");
  app.quit();
});
app.whenReady().then(async () => {
  const window = new BrowserWindow({
    show: false,
    webPreferences: {
      contextIsolation: true,
      nodeIntegration: false,
      sandbox: true,
      preload: join(root, "preload.cjs"),
    },
  });
  await window.loadFile(join(root, "index.html"));
});
`, "utf8");

  let output = "";
  const child = spawn(electronBinary, [entryPath, `--user-data-dir=${join(tempRoot, "profile")}`], {
    cwd: root,
    stdio: ["ignore", "pipe", "pipe"],
  });
  child.stdout.on("data", (chunk) => { output += chunk; });
  child.stderr.on("data", (chunk) => { output += chunk; });
  try {
    const closed = once(child, "close");
    const result = await Promise.race([
      closed,
      delay(runTimeoutMs).then(async () => {
        await stopChild(child);
        throw new Error(`Electron rejected-invoke probe timed out:\n${output}`);
      }),
    ]);
    // Keep the OS signal in the failure evidence; Electron reports a null
    // exit code when the probe is terminated before it can serialize IPC
    // facts, which is otherwise indistinguishable from a clean app.quit().
    assert.equal(result[0], 0, `Electron rejected-invoke probe failed (signal=${result[1] ?? "none"}):\n${output}`);
    const line = output.split("\n").find((candidate) => candidate.startsWith("IP0102_REJECTED_INVOKE_FACT "));
    assert(line, `Electron rejected-invoke fact marker missing:\n${output}`);
    const facts = JSON.parse(line.slice("IP0102_REJECTED_INVOKE_FACT ".length));
    assert.equal(facts.hasTransportPrefix, true);
    assert.equal(facts.hasOriginalMessage, true);
    // Electron currently serializes the rejection message/stack but strips
    // custom Error fields. The typed gateway must therefore never promise
    // recovery of a code/status that did not cross the process boundary.
    assert.equal(facts.codeType, "undefined");
    assert.equal(facts.statusType, "undefined");
    assert.equal(facts.retryableType, "undefined");
    await mkdir(join(root, ".codex", "refactor", "evidence", "IP-02"), { recursive: true });
    await writeFile(
      join(root, ".codex", "refactor", "evidence", "IP-02", "electron-rejected-invoke.json"),
      `${JSON.stringify({ generatedAt: new Date().toISOString(), facts }, null, 2)}\n`,
      "utf8",
    );
    return facts;
  } finally {
    await stopChild(child);
    await rm(tempRoot, { recursive: true, force: true });
  }
}

async function withModernEntryState(stateName, run) {
  if (stateName === "present") return run();
  const backupPath = `${modernIndex}.slatesync-smoke-${process.pid}`;
  assert.equal(await fileExists(backupPath), false, `stale smoke backup exists: ${backupPath}`);
  await rename(modernIndex, backupPath);
  try {
    if (stateName === "directory") await mkdir(modernIndex);
    return await run();
  } finally {
    if (await fileExists(modernIndex)) {
      const metadata = await stat(modernIndex);
      assert(metadata.isDirectory(), "smoke must never overwrite a generated modern entry");
      await rm(modernIndex, { recursive: true });
    }
    await rename(backupPath, modernIndex);
  }
}

async function restoreNodeAbi() {
  // Electron smoke owns the temporary ABI switch made by its npm pre-hook.
  // Restoring in this controller's outer finally also covers failed windows.
  const child = spawn("npm", ["run", "rebuild:native:node"], {
    cwd: root,
    stdio: "inherit",
  });
  const [code] = await once(child, "close");
  if (code !== 0) throw new Error(`failed to restore Node native ABI (exit ${code})`);
}

let completed = false;
try {
  const runs = [];
  if (isPackagedSmoke) {
    runs.push(await runProduction({
      label: "packaged-modern-default",
      expectedMode: "modern",
      packaged: true,
    }));
  } else {
    await captureRejectedInvokeFacts();
    const repeatCount = process.env.SLATESYNC_SMOKE_PERF === "1" ? 5 : 1;
    for (let repeat = 1; repeat <= repeatCount; repeat += 1) {
      runs.push({ repeat, ...(await runProduction({ label: `modern-default-${repeat}`, expectedMode: "modern" })) });
      runs.push({ repeat, ...(await runProduction({ label: `legacy-explicit-${repeat}`, expectedMode: "legacy", legacyRequested: true })) });
    }
    if (repeatCount === 1) {
      runs.push(await withModernEntryState("missing", () => runProduction({
        label: "modern-missing",
        expectedMode: "legacy",
      })));
      runs.push(await withModernEntryState("directory", () => runProduction({
        label: "modern-load-failure",
        expectedMode: "legacy",
      })));
    }
  }

  const median = (values) => {
    const sorted = values.filter(Number.isFinite).sort((left, right) => left - right);
    return sorted.length ? sorted[Math.floor(sorted.length / 2)] : null;
  };
  const comparable = runs.filter((run) => run.expectedMode === "legacy" || run.expectedMode === "modern");
  const evidence = {
    generatedAt: new Date().toISOString(),
    methodology: "Production electron/main.mjs and the compiled typed out/preload/index.cjs; isolated profile/library; one real BrowserWindow; the mode marker exists and the visible body has non-zero layout after document.fonts.ready and two animation frames. Legacy readiness additionally requires completed app navigation/project-library rendering. markerReadyMs is measured from navigation start by the Renderer performance clock.",
    runs,
    medianMarkerReadyMs: Object.fromEntries(["legacy", "modern"].map((mode) => [
      mode,
      median(comparable.filter((run) => run.expectedMode === mode).map((run) => run.markerReadyMs)),
    ])),
  };
  await mkdir(evidenceRoot, { recursive: true });
  const evidencePath = isPackagedSmoke
    ? join(evidenceRoot, "packaged-smoke.json")
    : process.env.SLATESYNC_SMOKE_PERF_OUTPUT || join(evidenceRoot, "production-smoke.json");
  await writeFile(evidencePath, `${JSON.stringify(evidence, null, 2)}\n`, "utf8");
  completed = true;
  process.stdout.write(`IP0102_PRODUCTION_ELECTRON_SMOKE_OK ${isPackagedSmoke ? "packaged" : "development"}\n`);
} finally {
  await restoreNodeAbi();
}

assert(completed, "production Electron smoke must complete before reporting success");

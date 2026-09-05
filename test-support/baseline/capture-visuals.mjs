#!/usr/bin/env node

// The harness renders unchanged production HTML/CSS/JavaScript with one
// synthetic preload. Runtime state and comparison output stay in ignored
// locations; only the executable PNG baseline and manifest are retained.
import { app, BrowserWindow, nativeTheme, screen } from "electron";
import { createHash } from "node:crypto";
import { mkdirSync, mkdtempSync } from "node:fs";
import {
  copyFile,
  mkdir,
  readFile,
  rm,
  writeFile,
} from "node:fs/promises";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), "../..");
const outputDir = join(ROOT, ".codex", "refactor", "baseline", "visual");
const evidenceDir = join(ROOT, "test-results", "refactor", "IP-00", "visual");
const captureCommand = "./node_modules/.bin/electron test-support/baseline/capture-visuals.mjs";
const baselineCommit = "c7dafa4d972e5eb7be61f00e2b546d6826e70c87";
const fixtureId = "synthetic-project-library-v1";
const appReadyTimeoutMs = 15_000;
const stateTimeoutMs = 15_000;
const requiredStates = [
  ["project-library", "projects"],
  ["workspace-empty", "workspace"],
  ["workspace-ready", "workspace"],
  ["recognition-progress", "workspace"],
  ["result-detail", "workspace"],
  ["csv-preview", "workspace"],
  ["project-settings", "project-settings"],
  ["global-settings", "global-settings"],
  ["new-project-dialog", "projects"],
  ["ocr-setup-dialog", "global-settings"],
];

process.env.TZ = "Asia/Shanghai";
app.commandLine.appendSwitch("force-device-scale-factor", "1");
app.commandLine.appendSwitch("lang", "zh-CN");
app.commandLine.appendSwitch("force-prefers-reduced-motion", "reduce");

async function withTimeout(promise, timeoutMs, label) {
  let timeout;
  const watchdog = new Promise((_, reject) => {
    timeout = setTimeout(() => reject(new Error(`${label} timed out after ${timeoutMs}ms`)), timeoutMs);
  });
  try {
    return await Promise.race([promise, watchdog]);
  } finally {
    clearTimeout(timeout);
  }
}

async function writeJson(path, value) {
  await writeFile(path, `${JSON.stringify(value, null, 2)}\n`, "utf8");
}

function fixtureProject() {
  return {
    id: "project-default",
    name: "Baseline Project",
    description: "Synthetic visual baseline",
    relativePath: "Projects/project-default",
    directoryPath: "/synthetic/library/Projects/project-default",
    archivedAt: null,
    createdAt: "2026-01-01T00:00:00.000Z",
    updatedAt: "2026-01-01T00:01:00.000Z",
    taskCount: 1,
    latestTaskAt: "2026-01-01T00:01:00.000Z",
    canArchive: false,
    settings: {
      version: 1,
      providerId: "openai",
      modelId: "openai/gpt-5.6-luna",
      accuracyMode: "high",
      scenarioId: null,
      customPrompt: "Synthetic production day: Day 01",
      resolve: {
        fieldFormats: { scene: "XXX", shot: "XX", take: "XX" },
        comments: { goodTake: "_OK", holdTake: "_KP" },
      },
    },
    lastRecognitionDefaults: {
      providerId: "openai",
      modelId: "openai/gpt-5.6-luna",
      customPrompt: "Synthetic production day: Day 01",
    },
  };
}

function fixtureTaskDetail() {
  const project = fixtureProject();
  return {
    id: "baseline-task-001",
    projectId: project.id,
    projectSettingsSnapshot: project.settings,
    filename: "synthetic-slate.pdf",
    fileType: "application/pdf",
    fileSize: 24680,
    pageCount: 2,
    status: "completed",
    provider: "openai",
    model: "openai/gpt-5.6-luna",
    scenarioId: null,
    createdAt: "2026-01-01T00:00:00.000Z",
    updatedAt: "2026-01-01T00:01:00.000Z",
    result: {
      sheetTitle: "Day 01",
      records: [
        { id: "record-1", cardNumber: "A001", videoCode: "C001", scene: "001", shot: "01", take: "01", takeStatus: "过", description: "主镜头", comments: "人工复核", shotSize: "中景", cameraPosition: null, confidence: "high" },
        { id: "record-2", cardNumber: "A001", videoCode: "C002", scene: "001", shot: "01", take: "02", takeStatus: "保", description: "补拍", comments: null, shotSize: "近景", cameraPosition: null, confidence: "medium" },
        { id: "record-3", cardNumber: "A001", videoCode: "C003", scene: null, shot: null, take: null, takeStatus: "废条", description: null, comments: null, shotSize: null, cameraPosition: null, confidence: "low" },
      ],
      warnings: ["C003 的场次、镜、次需要人工核对。"],
    },
    editedRecords: null,
    resolveCsvFilename: "timeline.csv",
    resolveCsvTable: {
      headers: ["File Name", "Scene", "Shot", "Take", "Comments"],
      rows: [
        ["A001C001.mov", "001", "01", "01", "_OK"],
        ["A001C002.mov", "001", "01", "02", "_KP"],
        ["A001C999.mov", "", "", "", ""],
      ],
      format: { encoding: "utf-8", delimiter: ",", newline: "\n", bom: false },
    },
    resolveCsvEdits: { "0:1": "002" },
    slateMetadata: [],
    slateWarnings: [],
    missingMetadataKeys: ["A001C003"],
    slateDirectoryName: "Day 01",
  };
}

function taskSummary(task) {
  return {
    id: task.id,
    projectId: task.projectId,
    filename: task.filename,
    pageCount: task.pageCount,
    status: task.status,
    provider: task.provider,
    model: task.model,
    scenarioId: task.scenarioId,
    recordCount: task.result.records.length,
    createdAt: task.createdAt,
    updatedAt: task.updatedAt,
  };
}

function preloadSource() {
  const project = fixtureProject();
  const task = fixtureTaskDetail();
  const archived = {
    ...project,
    id: "project-archived",
    name: "Archived Project",
    description: "Synthetic archived reference",
    archivedAt: "2026-01-02T00:00:00.000Z",
    canArchive: true,
  };
  return `
    const { contextBridge } = require("electron");
    const project = ${JSON.stringify(project)};
    const archived = ${JSON.stringify(archived)};
    const task = ${JSON.stringify(task)};
    contextBridge.exposeInMainWorld("electronAPI", {
      getConfig: async () => ({
        providers: [{ id: "openai", label: "OpenAI 官方 API", configured: true }],
        models: [{ id: "openai/gpt-5.6-luna", label: "GPT-5.6 Luna", providers: ["openai"] }],
        upload: { maxRequestBytes: 83886080 },
        ocr: { enabled: false, available: false },
        workflow: { resolve: project.settings.resolve }
      }),
      saveProviderKey: async () => ({ provider: "openai", configured: true }),
      getModels: async () => ({ models: [{ id: "openai/gpt-5.6-luna", label: "GPT-5.6 Luna" }] }),
      recognize: async () => task,
      onRecognitionProgress: () => {},
      removeRecognitionProgressListener: () => {},
      saveFile: async () => ({ saved: false }),
      selectDirectory: async () => null,
      scanSlateDirectory: async () => ({ entries: [], warnings: [] }),
      listProjects: async () => [project, archived],
      getLibraryInfo: async () => ({ id: "library-baseline-001", name: "Baseline Library", path: "/synthetic/library", formatVersion: 1 }),
      importProjectLibrary: async () => ({ canceled: true }),
      exportProjectLibrary: async () => ({ canceled: true }),
      changeLibraryLocation: async () => ({ canceled: true }),
      createProject: async () => project,
      loadProject: async () => project,
      updateProject: async () => project,
      archiveProject: async () => archived,
      restoreProject: async () => project,
      listTasks: async () => [${JSON.stringify(taskSummary(task))}],
      loadTask: async () => task,
      saveTask: async () => task.id,
      deleteTask: async () => ({ deleted: task.id }),
      listScenarios: async () => [],
      loadScenario: async () => null,
      importScenario: async () => null,
      getOcrSettings: async () => ({ pythonPath: "", setupCompleted: false, setupSkipped: true }),
      saveOcrSettings: async () => ({ pythonPath: "", setupCompleted: false, setupSkipped: true }),
      checkOcr: async () => ({ ok: false, error: { message: "Synthetic OCR unavailable" } })
    });
  `;
}

function slateSvg(page) {
  const rows = page === 1
    ? [["A001", "C001", "001", "01", "01", "GOOD"], ["A001", "C002", "001", "01", "02", "HOLD"]]
    : [["A001", "C003", "002", "03", "01", "NG"], ["A001", "C004", "002", "03", "02", "GOOD"]];
  const rowMarkup = rows.map((row, rowIndex) => row.map((cell, columnIndex) =>
    `<text x="${62 + columnIndex * 126}" y="${324 + rowIndex * 86}" font-size="24" fill="#1f2937">${cell}</text>`,
  ).join("")).join("");
  return `data:image/svg+xml;charset=utf-8,${encodeURIComponent(`<svg xmlns="http://www.w3.org/2000/svg" width="1000" height="700" viewBox="0 0 1000 700"><rect width="1000" height="700" fill="#f8f4e8"/><rect x="38" y="35" width="924" height="630" rx="12" fill="#fffdf6" stroke="#182235" stroke-width="5"/><text x="60" y="95" font-family="sans-serif" font-size="38" font-weight="700" fill="#111827">SYNTHETIC SLATE · DAY 01 · PAGE ${page}</text><text x="60" y="145" font-family="sans-serif" font-size="22" fill="#526071">PROJECT BASELINE / CAMERA A / 24 FPS</text><path d="M60 190 H940 M60 265 H940 M60 355 H940 M60 445 H940 M60 535 H940" stroke="#9aa5b1" stroke-width="2"/><text x="62" y="235" font-family="sans-serif" font-size="20" font-weight="700" fill="#334155">CARD</text><text x="188" y="235" font-family="sans-serif" font-size="20" font-weight="700" fill="#334155">VIDEO</text><text x="314" y="235" font-family="sans-serif" font-size="20" font-weight="700" fill="#334155">SCENE</text><text x="440" y="235" font-family="sans-serif" font-size="20" font-weight="700" fill="#334155">SHOT</text><text x="566" y="235" font-family="sans-serif" font-size="20" font-weight="700" fill="#334155">TAKE</text><text x="692" y="235" font-family="sans-serif" font-size="20" font-weight="700" fill="#334155">STATUS</text><g font-family="sans-serif">${rowMarkup}</g><text x="60" y="610" font-family="sans-serif" font-size="20" fill="#64748b">Synthetic fixture — no production data</text></svg>`)}`;
}

async function waitFor(window, predicate, label) {
  const source = `(() => new Promise((resolve, reject) => {
    const deadline = performance.now() + 5000;
    const check = () => {
      try {
        if (${predicate}) return resolve(true);
        if (performance.now() >= deadline) return reject(new Error(${JSON.stringify(label)}));
        requestAnimationFrame(check);
      } catch (error) { reject(error); }
    };
    check();
  }))()`;
  await window.webContents.executeJavaScript(source, true);
}

async function settle(window) {
  await window.webContents.executeJavaScript(`(async () => {
    if (document.fonts) await document.fonts.ready;
    // Loading an existing task starts the production smooth scroll to the
    // results section. Readiness means five unchanged animation frames, not a
    // fixed delay or an arbitrary intermediate frame of that scroll.
    await new Promise((resolve, reject) => {
      const deadline = performance.now() + 5000;
      let previousX = scrollX;
      let previousY = scrollY;
      let stableFrames = 0;
      const check = () => {
        if (scrollX === previousX && scrollY === previousY) stableFrames += 1;
        else stableFrames = 0;
        previousX = scrollX;
        previousY = scrollY;
        if (stableFrames >= 5) return resolve();
        if (performance.now() >= deadline) return reject(new Error("root scroll did not settle"));
        requestAnimationFrame(check);
      };
      requestAnimationFrame(check);
    });
  })()`, true);
}

async function initializeDocument(window, stateName) {
  window.__visualStateName = stateName;
  await window.loadFile(join(ROOT, "public", "index.html"));
  await window.webContents.executeJavaScript(`(() => {
    document.documentElement.dataset.baseline = "true";
    const style = document.createElement("style");
    style.textContent = "*,*::before,*::after{animation:none!important;transition:none!important;scroll-behavior:auto!important;caret-color:transparent!important}";
    document.head.append(style);
  })()`, true);
  try {
    await waitFor(window, `!document.querySelector("#project-home-page")?.hidden && document.querySelectorAll("#project-grid .project-card").length === 1 && document.querySelectorAll("#archived-project-grid .project-card").length === 1`, "project library did not initialize");
  } catch (error) {
    const diagnostic = await window.webContents.executeJavaScript(`({
      readyState: document.readyState,
      hasBridge: Boolean(globalThis.electronAPI),
      projectHomeHidden: document.querySelector("#project-home-page")?.hidden,
      projectCards: document.querySelectorAll("#project-grid .project-card").length,
      archivedCards: document.querySelectorAll("#archived-project-grid .project-card").length,
      bodyText: document.body.innerText.slice(0, 500)
    })`, true);
    throw new Error(`${error.message}: ${JSON.stringify(diagnostic)}`);
  }
  const metrics = await window.webContents.executeJavaScript(`({ width: innerWidth, height: innerHeight, dpr: devicePixelRatio })`, true);
  if (metrics.width !== 1440 || metrics.height !== 900 || metrics.dpr !== 1) {
    throw new Error(`unexpected content viewport ${JSON.stringify(metrics)}`);
  }
}

async function withWindowLifecycle(window, stateName, operation) {
  let rejectLifecycle;
  const lifecycleFailure = new Promise((_, reject) => {
    rejectLifecycle = reject;
  });
  const unresponsive = () => rejectLifecycle(new Error(`${stateName} window became unresponsive`));
  const rendererGone = (_event, details) => {
    rejectLifecycle(new Error(`${stateName} Renderer exited: ${details.reason} (${details.exitCode})`));
  };
  const preloadError = (_event, path, error) => {
    rejectLifecycle(new Error(`${stateName} Preload failed: ${path}: ${error.message}`));
  };
  const failedLoad = (_event, code, description, url, isMainFrame) => {
    if (isMainFrame) {
      rejectLifecycle(new Error(`${stateName} main document failed to load: ${code} ${description} ${url}`));
    }
  };
  window.once("unresponsive", unresponsive);
  window.webContents.once("render-process-gone", rendererGone);
  window.webContents.once("preload-error", preloadError);
  window.webContents.on("did-fail-load", failedLoad);
  try {
    return await Promise.race([operation(), lifecycleFailure]);
  } finally {
    window.removeListener("unresponsive", unresponsive);
    window.webContents.removeListener("render-process-gone", rendererGone);
    window.webContents.removeListener("preload-error", preloadError);
    window.webContents.removeListener("did-fail-load", failedLoad);
  }
}

function createWindow(preloadPath) {
  const displayScaleFactor = screen.getPrimaryDisplay().scaleFactor;
  const zoomFactor = 1 / displayScaleFactor;
  const window = new BrowserWindow({
    // On Retina displays a proportionally smaller native content surface plus
    // inverse page zoom yields the required 1440×900 CSS viewport at DPR 1.
    // A fixed in-screen frameless origin prevents the macOS window manager
    // from shifting hidden windows around the menu bar between processes.
    x: 100,
    y: 100,
    frame: false,
    width: Math.round(1440 / displayScaleFactor),
    height: Math.round(900 / displayScaleFactor),
    useContentSize: true,
    show: false,
    backgroundColor: "#f8fafc",
    webPreferences: {
      contextIsolation: true,
      nodeIntegration: false,
      sandbox: true,
      webSecurity: true,
      allowRunningInsecureContent: false,
      backgroundThrottling: false,
      zoomFactor,
      // Reloading this non-persistent session resets each state without
      // creating the second macOS Renderer process that loses rendezvous.
      partition: `slatesync-visual-${process.pid}`,
      preload: preloadPath,
    },
  });
  window.webContents.on("console-message", (...args) => {
    const details = args[1];
    const message = typeof details === "object" && details !== null
      ? details.message
      : args[2] ?? details;
    process.stderr.write(`[renderer:${window.__visualStateName ?? "initializing"}] ${String(message)}\n`);
  });

  window.webContents.session.webRequest.onBeforeRequest((details, callback) => {
    callback({ cancel: /^(https?|wss?):/i.test(details.url) });
  });

  return window;
}

async function openWorkspace(window) {
  await window.webContents.executeJavaScript(`document.querySelector('[data-project-action="open"][data-project-id="project-default"]')?.click()`, true);
  await waitFor(window, `!document.querySelector("#workspace-page")?.hidden && document.querySelector("#project-context")?.textContent.includes("Baseline Project")`, "workspace did not open");
}

async function selectCompletedTask(window) {
  await window.webContents.executeJavaScript(`(() => {
    const select = document.querySelector("#task-select");
    select.value = "baseline-task-001";
    select.dispatchEvent(new Event("change", { bubbles: true }));
  })()`, true);
  await waitFor(window, `!document.querySelector("#results-section")?.hidden && document.querySelectorAll("#result-body tr").length === 3`, "completed task did not render");
}

async function prepareSyntheticSlate(window) {
  const pages = [slateSvg(1), slateSvg(2)];
  await window.webContents.executeJavaScript(`(() => {
    const pages = ${JSON.stringify(pages)};
    document.querySelector("#dropzone").hidden = true;
    document.querySelector("#file-card").hidden = false;
    document.querySelector("#file-thumb").src = pages[0];
    document.querySelector("#file-name").textContent = "synthetic-slate.pdf";
    document.querySelector("#file-meta").textContent = "PDF · 2 页 · 24.1 KB";
    document.querySelector("#empty-preview").hidden = true;
    const preview = document.querySelector("#preview-scroll");
    preview.hidden = false;
    preview.innerHTML = pages.map((src, index) => '<figure class="preview-page"><img src="' + src + '" alt="合成场记单第 ' + (index + 1) + ' 页"><figcaption>第 ' + (index + 1) + ' 页</figcaption></figure>').join("");
    document.querySelector("#processing-overlay").hidden = true;
    document.querySelector("#results-section").hidden = true;
    document.querySelector(".preview-panel").classList.add("is-ready");
    document.querySelector(".preview-panel").classList.remove("is-busy");
    document.querySelector("#preview-status").textContent = "2 页 · 已就绪";
  })()`, true);
  await waitFor(window, `document.querySelectorAll("#preview-scroll .preview-page img").length === 2 && [...document.querySelectorAll("#preview-scroll img")].every((image) => image.complete && image.naturalWidth > 0) && !document.querySelector("#recognition-settings-group")?.hidden`, "prepared slate did not render");
}

async function arrangeState(window, name) {
  if (!["project-library", "new-project-dialog"].includes(name)) await openWorkspace(window);
  if (name === "workspace-ready" || name === "recognition-progress") await prepareSyntheticSlate(window);
  if (name === "recognition-progress") {
    await window.webContents.executeJavaScript(`(() => {
      const overlay = document.querySelector("#processing-overlay");
      overlay.hidden = false;
      document.querySelector(".preview-panel").classList.add("is-busy");
      overlay.querySelector("strong").textContent = "多模态模型正在主识别";
      overlay.querySelector("small").textContent = "正在处理第 2 / 2 页";
      document.querySelector("#recognition-progress-bar").style.width = "68%";
      document.querySelector("#recognition-progress").setAttribute("aria-valuenow", "68");
      document.querySelector("#recognition-progress-stage").textContent = "主识别";
      document.querySelector("#recognition-progress-percent").textContent = "68%";
    })()`, true);
  }
  if (name === "result-detail" || name === "csv-preview") {
    await selectCompletedTask(window);
    await window.webContents.executeJavaScript(`document.querySelector(${JSON.stringify(name === "result-detail" ? "#tab-detail" : "#tab-csv")})?.click()`, true);
  }
  if (name === "project-settings") {
    await window.webContents.executeJavaScript(`document.querySelector("#nav-project-settings")?.click()`, true);
  }
  if (name === "global-settings" || name === "ocr-setup-dialog") {
    await window.webContents.executeJavaScript(`document.querySelector("#nav-global-settings")?.click()`, true);
  }
  if (name === "new-project-dialog") {
    await window.webContents.executeJavaScript(`document.querySelector("#new-project-button")?.click()`, true);
  }
  if (name === "ocr-setup-dialog") {
    await window.webContents.executeJavaScript(`document.querySelector("#global-ocr-open")?.click()`, true);
  }

  const assertions = {
    "project-library": `!document.querySelector("#project-home-page").hidden && document.querySelector("#project-dialog").hidden && document.querySelector("#ocr-setup-overlay").hidden`,
    "workspace-empty": `!document.querySelector("#workspace-page").hidden && !document.querySelector("#empty-preview").hidden && document.querySelector("#processing-overlay").hidden && document.querySelector("#results-section").hidden`,
    "workspace-ready": `!document.querySelector("#workspace-page").hidden && !document.querySelector("#file-card").hidden && document.querySelectorAll("#preview-scroll .preview-page").length === 2 && document.querySelector("#processing-overlay").hidden && document.querySelector("#results-section").hidden`,
    "recognition-progress": `!document.querySelector("#processing-overlay").hidden && document.querySelector("#recognition-progress").getAttribute("aria-valuenow") === "68" && document.querySelector("#results-section").hidden`,
    "result-detail": `!document.querySelector("#results-section").hidden && !document.querySelector("#panel-detail").hidden && document.querySelector("#panel-csv").hidden && document.querySelector("#processing-overlay").hidden`,
    "csv-preview": `!document.querySelector("#results-section").hidden && !document.querySelector("#panel-csv").hidden && document.querySelector("#panel-detail").hidden && document.querySelectorAll("#csv-result-body tr").length === 3 && document.querySelector("#processing-overlay").hidden`,
    "project-settings": `!document.querySelector("#project-settings-page").hidden && document.querySelector("#project-name-input").value === "Baseline Project"`,
    "global-settings": `!document.querySelector("#global-settings-page").hidden && document.querySelector("#ocr-setup-overlay").hidden`,
    "new-project-dialog": `!document.querySelector("#project-home-page").hidden && !document.querySelector("#project-dialog").hidden && document.querySelector("#ocr-setup-overlay").hidden`,
    "ocr-setup-dialog": `!document.querySelector("#global-settings-page").hidden && !document.querySelector("#ocr-setup-overlay").hidden && document.querySelector("#project-dialog").hidden`,
  };
  await waitFor(window, assertions[name], `${name} readiness assertion failed`);
  await settle(window);
}

async function captureState(window, stagingDir, name, route) {
  return withWindowLifecycle(window, name, async () => {
    // A full document reload re-runs the disposable Preload and restores the
    // asserted route/dialog/progress baseline before arranging this state.
    await initializeDocument(window, name);
    await arrangeState(window, name);
    const image = await window.capturePage();
    const size = image.getSize();
    if (size.width !== 1440 || size.height !== 900) {
      throw new Error(`${name} captured ${size.width}x${size.height}`);
    }
    const bytes = image.toPNG();
    const filename = `${name}.png`;
    await writeFile(join(stagingDir, filename), bytes);
    return {
      state: name,
      route,
      fixtureId,
      file: filename,
      width: size.width,
      height: size.height,
      bytes: bytes.length,
      sha256: createHash("sha256").update(bytes).digest("hex"),
    };
  });
}

function comparableCaptures(captures) {
  return captures.map(({ state, width, height, sha256 }) => ({ state, width, height, sha256 }));
}

async function publishCaptures(stagingDir, captures, manifest) {
  await mkdir(outputDir, { recursive: true });
  // PNGs are staged outside the repository. The manifest is published last,
  // so an interrupted first run cannot advertise an incomplete evidence set.
  for (const capture of captures) {
    await copyFile(join(stagingDir, capture.file), join(outputDir, capture.file));
  }
  await writeJson(join(outputDir, "manifest.json"), manifest);
}

async function recordRunEvidence(priorManifest, currentManifest, status) {
  await mkdir(evidenceDir, { recursive: true });
  if (priorManifest) {
    await writeJson(join(evidenceDir, "run-1-manifest.json"), priorManifest);
    await writeJson(join(evidenceDir, "run-2-manifest.json"), currentManifest);
  } else {
    await writeJson(join(evidenceDir, "run-1-manifest.json"), currentManifest);
  }
  await writeJson(join(evidenceDir, "comparison.json"), {
    status,
    captureCommand,
    firstCapturedAt: priorManifest?.capturedAt ?? currentManifest.capturedAt,
    secondCapturedAt: priorManifest ? currentManifest.capturedAt : null,
    firstDurationMs: priorManifest?.durationMs ?? currentManifest.durationMs,
    secondDurationMs: priorManifest ? currentManifest.durationMs : null,
    first: comparableCaptures(priorManifest?.captures ?? currentManifest.captures),
    second: priorManifest ? comparableCaptures(currentManifest.captures) : null,
  });
}

async function retainMismatchImages(stagingDir, priorManifest, currentManifest) {
  await mkdir(evidenceDir, { recursive: true });
  const priorByState = new Map(priorManifest.captures.map((capture) => [capture.state, capture]));
  for (const current of currentManifest.captures) {
    const prior = priorByState.get(current.state);
    if (prior?.sha256 === current.sha256) continue;
    // Retain only mismatched pairs; the canonical baseline itself remains the
    // first complete run until the cause is understood and corrected.
    await copyFile(join(outputDir, prior.file), join(evidenceDir, `${current.state}-run-1.png`));
    await copyFile(join(stagingDir, current.file), join(evidenceDir, `${current.state}-run-2.png`));
  }
}

const runtimeDir = mkdtempSync(join(tmpdir(), "slatesync-baseline-visual-"));
const userDataPath = join(runtimeDir, "userData");
const stagingDir = join(runtimeDir, "captures");
mkdirSync(userDataPath, { recursive: true, mode: 0o700 });
mkdirSync(stagingDir, { recursive: true, mode: 0o700 });
app.setPath("userData", userDataPath);

async function runCapture() {
  // Enclose setup as well as capture so preload/userData are removed when any
  // filesystem, app-ready, state assertion, or image operation fails.
  await mkdir(outputDir, { recursive: true });
  const preloadPath = join(runtimeDir, "visual-preload.cjs");
  await writeFile(preloadPath, preloadSource(), { encoding: "utf8", mode: 0o600 });
  let priorManifest = null;
  try {
    priorManifest = JSON.parse(await readFile(join(outputDir, "manifest.json"), "utf8"));
  } catch (error) {
    if (error?.code !== "ENOENT") throw error;
  }
  // Native theme is initialized with the ready lifecycle; setting it earlier
  // can block startup in Electron even though the production app boots.
  nativeTheme.themeSource = "light";
  const startedAt = performance.now();
  const captures = [];
  const captureWindow = createWindow(preloadPath);
  for (const [name, route] of requiredStates) {
    // State markers make a bounded CI/desktop capture diagnosable without
    // retaining Chromium logs or runtime files in the evidence directory.
    process.stdout.write(`capturing ${name}\n`);
    captures.push(await withTimeout(
      captureState(captureWindow, stagingDir, name, route),
      stateTimeoutMs,
      `${name} capture`,
    ));
  }
  const currentComparable = comparableCaptures(captures);
  const previousComparable = priorManifest?.captures
    ? comparableCaptures(priorManifest.captures)
    : null;
  const stable = previousComparable
    ? JSON.stringify(previousComparable) === JSON.stringify(currentComparable)
    : false;
  const manifest = {
    baselineCommit,
    capturedAt: new Date().toISOString(),
    fixtureId,
    platform: `${process.platform}-${process.arch}`,
    electron: process.versions.electron,
    captureCommand,
    viewport: { width: 1440, height: 900, kind: "content" },
    deviceScaleFactor: 1,
    appearance: "light",
    reducedMotion: true,
    locale: "zh-CN",
    timezone: "Asia/Shanghai",
    durationMs: Math.round(performance.now() - startedAt),
    stability: {
      verifiedAgainstPreviousRun: stable,
      identicalCaptureCount: stable ? captures.length : 0,
    },
    captures,
  };

  if (previousComparable && !stable) {
    await retainMismatchImages(stagingDir, priorManifest, manifest);
    await recordRunEvidence(priorManifest, manifest, "mismatch");
    throw new Error("isolated visual capture hashes or dimensions changed between runs");
  }

  await publishCaptures(stagingDir, captures, manifest);
  await recordRunEvidence(
    priorManifest,
    manifest,
    stable ? "stable" : "awaiting-second-run",
  );
  process.stdout.write(`${JSON.stringify({ captures: captures.length, durationMs: manifest.durationMs, stable: manifest.stability.verifiedAgainstPreviousRun })}\n`);
}

async function finishCapture(exitCode, error) {
  if (error) console.error("Visual baseline capture failed:", error);
  // Destroy every disposable window before removing its session/userData.
  for (const window of BrowserWindow.getAllWindows()) window.destroy();
  await rm(runtimeDir, { recursive: true, force: true });
  // Exit only after every disposable runtime path has been removed; the
  // failure branch has already emitted its bounded diagnostic above.
  process.exit(exitCode);
}

process.stdout.write("waiting for Electron app readiness\n");
// Match the production Main lifecycle: schedule work from the ready promise
// without top-level-awaiting it, so ESM evaluation can finish before Electron
// dispatches the native application-ready event.
void withTimeout(app.whenReady(), appReadyTimeoutMs, "Electron app.whenReady()")
  .then(async () => {
    process.stdout.write("Electron app ready\n");
    await runCapture();
    await finishCapture(0);
  })
  .catch(async (error) => {
    await finishCapture(1, error);
  });

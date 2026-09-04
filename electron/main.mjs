// Electron main process: composition root and window lifecycle.
//
// Loads .env + user-level global config + workflow config, wires up persisted
// keys/settings and the OCR Python path, registers IPC handlers, then opens the
// sandboxed BrowserWindow.
// The window loads the single compiled typed Preload directly because a
// sandboxed Electron Preload cannot require another application-local file.
// Packaged startup loads the modern out/renderer/index.html shell. Development
// startup may receive a local Vite URL for Renderer HMR; if that server is not
// available, the compiled Modern shell remains the bounded fallback. An
// internal --slatesync-renderer=legacy switch and bounded load-time fallback
// preserve recovery without creating a second BrowserWindow or gateway. The
// window blocks external navigation and only allows the active dev origin or
// file:// URLs under the selected legacy or modern shell root.
import { app, BrowserWindow, ipcMain, nativeImage, shell } from "electron";
import { access, mkdir } from "node:fs/promises";
import {
  basename,
  dirname,
  isAbsolute,
  join,
  relative,
  resolve,
} from "node:path";
import { fileURLToPath } from "node:url";
import { configureModelHttpAgent } from "../lib/ai-client.mjs";
import { createAppLogger } from "../lib/app-logger.mjs";
import { createWorkflowConfigProvider, PROVIDERS } from "../lib/config.mjs";
import { loadLocalEnv, createTaskLimiter, electronSettings } from "./env-loader.mjs";
import { registerIpcHandlers } from "./ipc-handlers.mjs";
import { createKeyStore } from "./key-store.mjs";
import { createGlobalConfigStore } from "./global-config-store.mjs";
import { applyGlobalConfig } from "./global-settings.mjs";
import { createFileDialogs } from "./file-dialogs.mjs";
import {
  isAllowedRendererDevNavigation,
  parseRendererDevUrl,
} from "./renderer-dev-url.mjs";
import { createSlateScanner } from "./slate-scanner.mjs";
import { createSettingsStore } from "./settings-store.mjs";
import {
  createProjectLibrary,
  LEGACY_DEFAULT_LIBRARY_FOLDER,
  migrateDefaultLibraryPath,
} from "../lib/project-library.mjs";
import {
  exportProjectLibrary,
  libraryExportPath,
  projectExportPath,
  validateProjectLibrary,
} from "../lib/project-library-transfer.mjs";
import { createProjectRuntime } from "../lib/project-runtime.mjs";
import { projectSettingsFromWorkflow } from "../lib/project-settings.mjs";
import {
  closePaddleOcrWorker,
  checkPaddleOcr,
  preloadPaddleOcr,
} from "../lib/ocr/paddleocr.mjs";
import { resolveOcrSelection } from "../lib/ocr/selection.mjs";
import { createPaddleOcrInstaller } from "./paddleocr-installer.mjs";
import { createOcrEnvironmentProbe } from "./ocr-environment.mjs";

const __dirname = dirname(fileURLToPath(import.meta.url));
const isDev = !app.isPackaged;
const ICON_COMPOSER_PATH = join(
  resolve(__dirname, ".."),
  "build",
  "slatesync.icon",
);
// electron-builder consumes the .icon container, while the dev Dock/window
// APIs need a raster image. This PNG is the artwork inside that same bundle,
// so development and packaged builds use one source of truth.
const DEV_ICON_PATH = join(ICON_COMPOSER_PATH, "Assets", "icon.png");
// Keep app teardown bounded while allowing the OCR queue to observe its
// invalidation and let the native Worker receive SIGTERM before Electron exits.
const PADDLEOCR_EXIT_SHUTDOWN_TIMEOUT_MS = 2_000;

// Set project root for OCR subprocess path resolution
// This flag lets packaged OCR code distinguish an installed App bundle from a
// development checkout before it decides whether Swift compilation is safe.
process.env.SLATESYNC_PACKAGED = app.isPackaged ? "true" : "false";
if (isDev) {
  process.env.SLATESYNC_PROJECT_DIR = resolve(__dirname, "..");
} else {
  process.env.SLATESYNC_PROJECT_DIR = join(process.resourcesPath, "app");
}

let mainWindow = null;
let projectLibrary = null;
let projectRuntime = null;
let appLogger = null;
let paddleOcrInstaller = null;
let paddleOcrExitCleanupPromise = null;
let paddleOcrExitCleanupComplete = false;

async function initialize() {
  // Start logging before any configuration or library work so startup failures
  // still leave a local diagnostic trail; the logger itself never throws.
  appLogger = createAppLogger(app.getPath("userData"));
  appLogger.info("app", `SlateSync ${app.getVersion()} 启动`, {
    platform: process.platform,
    arch: process.arch,
    packaged: app.isPackaged,
  });

  // Load machine stores before .env so the saved config path can participate
  // in startup resolution without exposing any file access to the Renderer.
  const userDataPath = app.getPath("userData");
  const defaultPaddleCacheHome = join(userDataPath, "paddlex");
  const settingsStore = createSettingsStore(userDataPath);
  const runtimeSettings = await settingsStore.load();
  const globalConfigStore = createGlobalConfigStore(userDataPath);
  const storedGlobalConfig = await globalConfigStore.load();
  const runtimeGlobalConfig = { ...(storedGlobalConfig?.values || {}) };
  // Custom endpoint records are kept in a mutable Main-owned array so CRUD
  // handlers can refresh the registry without putting connection details in
  // environment variables or exposing a private key to the Renderer.
  const runtimeCustomProviders = [...(storedGlobalConfig?.customProviders || [])];

  // Load .env from project root (dev) or userData (packaged)
  const envPath = isDev
    ? join(resolve(__dirname, ".."), ".env")
    : join(userDataPath, ".env");
  await loadLocalEnv(envPath);

  // Persisted non-secret settings override .env, while the provider key map
  // is applied separately below so credentials never enter global-config.json.
  const keyStore = createKeyStore(userDataPath);
  const runtimeProviderKeys = await keyStore.load();
  // The install target lives in userData, not Resources/app: packaged App
  // bundles are read-only on macOS and may be protected by code signing.
  paddleOcrInstaller = createPaddleOcrInstaller({
    userDataPath,
    checkOcr: checkPaddleOcr,
  });
  // Read-only probe for the Global Settings detection dialog; it observes the
  // same userData install target as the installer without ever writing to it.
  // runtimeEnv() is resolved per snapshot so a PaddleOCR Python path saved in
  // Global Settings is reflected immediately, exactly as recognition sees it.
  const ocrEnvironment = createOcrEnvironmentProbe({ userDataPath, env: () => runtimeEnv() });
  function runtimeEnv() {
    const env = { ...process.env };
    // Resolve the cache default after .env is loaded so a user-provided
    // PADDLE_PDX_CACHE_HOME remains effective; Global Settings then wins over
    // both sources without writing anything into process.env.
    if (!String(env.PADDLE_PDX_CACHE_HOME || "").trim()) {
      env.PADDLE_PDX_CACHE_HOME = defaultPaddleCacheHome;
    }
    const configuredEnv = applyGlobalConfig(env, runtimeGlobalConfig);
    for (const [providerId, apiKey] of runtimeProviderKeys) {
      const provider = PROVIDERS[providerId];
      if (provider) configuredEnv[provider.envKey] = apiKey;
    }
    // Keep the legacy first-run OCR setting readable, unless the new global
    // config explicitly owns the same field (including an empty reset).
    if (!Object.hasOwn(runtimeGlobalConfig, "PADDLEOCR_PYTHON") && runtimeSettings.ocrPythonPath) {
      configuredEnv.PADDLEOCR_PYTHON = runtimeSettings.ocrPythonPath;
    }
    return configuredEnv;
  }

  const initialRuntimeEnv = runtimeEnv();
  configureModelHttpAgent(initialRuntimeEnv);

  // Load workflow config
  const configPath = isDev
    ? resolve(
        resolve(__dirname, ".."),
        initialRuntimeEnv.SLATESYNC_CONFIG_PATH || "slatesync.config.json",
      )
    : join(process.resourcesPath, "app", "slatesync.config.json");
  const getWorkflowConfig = createWorkflowConfigProvider(configPath);
  await getWorkflowConfig();

  const settings = electronSettings(initialRuntimeEnv);
  const recognitionLimiter = createTaskLimiter(settings.maxConcurrentRecognitions);

  function refreshRuntimeSettings() {
    const env = runtimeEnv();
    Object.assign(settings, electronSettings(env));
    recognitionLimiter.setLimit?.(settings.maxConcurrentRecognitions);
    configureModelHttpAgent(env);
    refreshPaddleOcrPreload(env, "settings-saved");
  }

  function refreshPaddleOcrPreload(env, reason) {
    const selection = resolveOcrSelection(env, { autoEnable: true });
    if (selection.id !== "paddleocr") {
      // Vision/disabled routing does not need a resident Paddle pipeline; the
      // close operation still drains an active OCR request before releasing it.
      void closePaddleOcrWorker().catch((error) => {
        appLogger?.warn("ocr", "PaddleOCR Worker 释放失败", { reason, error });
      });
      return;
    }
    // Preload is deliberately fire-and-forget: saving settings must not wait
    // for model downloads, while recognition later awaits this same Worker.
    void preloadPaddleOcr(env, { autoEnable: true }).catch((error) => {
      appLogger?.warn("ocr", "PaddleOCR 后台预加载失败", { reason, error });
    });
  }

  const fileDialogs = createFileDialogs(() => mainWindow);
  const slateScanner = createSlateScanner();
  const workflowDefaults = projectSettingsFromWorkflow(await getWorkflowConfig());
  const libraryRoot = await initialLibraryPath(runtimeSettings.libraryPath);
  appLogger.info("app", "项目库路径已解析", { path: libraryRoot });
  if (runtimeSettings.libraryPath && resolve(runtimeSettings.libraryPath) !== resolve(libraryRoot)) {
    // Keep a previously persisted default path aligned with its successful
    // on-disk rename; arbitrary user-selected package paths are never changed.
    Object.assign(runtimeSettings, await settingsStore.save({
      ...runtimeSettings,
      libraryPath: libraryRoot,
    }));
  }
  projectLibrary = createProjectLibrary(libraryRoot, {
    defaultSettings: workflowDefaults,
  });
  // Copy the legacy global database into the default project without deleting
  // the original data directory. The library records a migration marker so
  // restarts remain safe and idempotent.
  await projectLibrary.migrateLegacyData(join(app.getPath("userData"), "data"));
  projectRuntime = createProjectRuntime(projectLibrary, {
    matching: async () => (await getWorkflowConfig()).scenario?.matching,
  });

  const libraryActions = {
    // 单项目导入/导出只改变当前项目库，成功后无需重启即可由 Renderer 刷新索引。
    async importProject() {
      const selected = await fileDialogs.selectProjectPackage(dirname(libraryRoot));
      if (!selected) return { canceled: true };
      const project = await projectLibrary.importProjectPackage(selected);
      return { canceled: false, project };
    },

    async exportProject(id) {
      const project = await projectLibrary.getProject(id);
      const selected = await fileDialogs.selectProjectPackageExportPath(
        projectExportPath(app.getPath("downloads"), project.name),
      );
      if (!selected) return { canceled: true };
      const target = projectExportPath(dirname(selected), basename(selected));
      const exported = await projectLibrary.exportProjectPackage(id, target);
      return { canceled: false, project: exported, path: target };
    },

    async importLibrary() {
      const selected = await fileDialogs.selectProjectLibrary(
        dirname(libraryRoot),
      );
      if (!selected) return { canceled: true };
      const imported = await validateProjectLibrary(selected);
      await activateLibrary(imported.path);
      return { canceled: false, restartRequired: true, library: imported };
    },

    async exportLibrary() {
      const selected = await fileDialogs.selectLibraryExportPath(
        join(app.getPath("downloads"), basename(libraryRoot)),
      );
      if (!selected) return { canceled: true };
      const target = libraryExportPath(dirname(selected), basename(selected));
      const exported = await exportProjectLibrary(libraryRoot, target);
      return { canceled: false, library: exported };
    },

    async changeLocation() {
      const selected = await fileDialogs.selectLibraryStorageDirectory(
        dirname(libraryRoot),
      );
      if (!selected) return { canceled: true };
      const target = libraryExportPath(selected, basename(libraryRoot));
      const relocated = await exportProjectLibrary(libraryRoot, target);
      await activateLibrary(relocated.path);
      return { canceled: false, restartRequired: true, library: relocated };
    },

    async renameLibrary(nextName) {
      const renamed = await projectLibrary.renameLibrary(nextName);
      await activateLibrary(renamed.path);
      return { canceled: false, restartRequired: true, library: renamed };
    },
  };

  async function activateLibrary(nextPath) {
    // Persist the selected package only after it has passed validation/copy.
    // Close current connections before scheduling a relaunch so no late WAL
    // write can race with the switch to the next Project Library.
    const saved = await settingsStore.save({
      ...runtimeSettings,
      libraryPath: resolve(nextPath),
    });
    Object.assign(runtimeSettings, saved);
    await projectRuntime?.close();
    await projectLibrary?.close();
    setTimeout(() => {
      app.relaunch();
      app.exit(0);
    }, 150);
  }

  registerIpcHandlers(ipcMain, {
    getWorkflowConfig,
    runtimeProviderKeys,
    runtimeEnv,
    recognitionLimiter,
    settings,
    keyStore,
    fileDialogs,
    slateScanner,
    projectLibrary,
    projectRuntime,
    settingsStore,
    runtimeSettings,
    globalConfigStore,
    runtimeGlobalConfig,
    runtimeCustomProviders,
    refreshRuntimeSettings,
    paddleOcrInstaller,
    ocrEnvironment,
    libraryActions,
    logger: appLogger,
    openLogDirectory,
  });

  // Return a closure so startup preload runs after the window is ready while
  // retaining the initialized runtime environment and global-config stores.
  return () => refreshPaddleOcrPreload(runtimeEnv(), "startup");
}

/** Create the log directory on demand, then reveal it in the native file manager. */
async function openLogDirectory(logsDir) {
  await mkdir(logsDir, { recursive: true, mode: 0o700 });
  const openError = await shell.openPath(logsDir);
  if (openError) throw new Error(openError);
  return { opened: true };
}

async function initialLibraryPath(configuredPath = "") {
  const applicationSupportPath = app.getPath("appData");
  const deployedPreviousDefault = join(
    applicationSupportPath,
    LEGACY_DEFAULT_LIBRARY_FOLDER,
  );
  const previousDefault = join(
    app.getPath("userData"),
    "Libraries",
    LEGACY_DEFAULT_LIBRARY_FOLDER,
  );
  if (configuredPath) {
    // Only known historical defaults are eligible for automatic shortening.
    // Imported and relocated Libraries retain their user-selected names.
    const knownDefaults = [deployedPreviousDefault, previousDefault]
      .map((path) => resolve(path));
    if (!knownDefaults.includes(resolve(configuredPath))) {
      return configuredPath;
    }
    return migrateDefaultLibraryPath(applicationSupportPath, [configuredPath], {
      // A persisted existing Library wins when the short default path is also
      // occupied; switching automatically could surface unrelated data.
      preserveLegacyOnConflict: true,
    });
  }
  return migrateDefaultLibraryPath(applicationSupportPath, [
    deployedPreviousDefault,
    previousDefault,
  ]);
}

async function exists(path) {
  try {
    await access(path);
    return true;
  } catch {
    return false;
  }
}

async function resolveRendererEntry() {
  const appRoot = resolve(__dirname, "..");
  const legacyRoot = isDev
    ? join(appRoot, "public")
    : join(__dirname, "..", "public");
  const modernRoot = join(appRoot, "out", "renderer");
  const modernRequested = process.argv.includes("--slatesync-renderer=modern");
  const legacyRequested = process.argv.includes("--slatesync-renderer=legacy");
  // The modern shell is the default; the explicit switch keeps the selected
  // recovery mode observable in smoke/evidence without adding a second gateway.
  const requestedModern = modernRequested || !legacyRequested;

  try {
    const { selectRendererEntry } = await import("../out/main/renderer-entry.js");
    const modernAvailable = await exists(join(modernRoot, "index.html"));
    const entry = selectRendererEntry({
      isDevelopment: isDev,
      requestedModern,
      modernAvailable,
      legacyRoot,
      modernRoot,
    });
    if (entry.mode === "legacy" && entry.reason === "modern-missing") {
      console.warn("Modern renderer entry is unavailable; using bounded legacy recovery.");
      appLogger?.warn("app", "Modern Renderer 不可用，使用 legacy 恢复入口");
    }
    return entry;
  } catch (error) {
    console.error("Modern renderer selector is unavailable; using legacy recovery:", error);
    appLogger?.error("app", "Modern Renderer 入口解析失败，使用 legacy 恢复入口", { error });
    return {
      mode: "legacy",
      root: legacyRoot,
      htmlPath: join(legacyRoot, "index.html"),
      reason: "modern-missing",
    };
  }
}

function isWithinRoot(filePath, root) {
  const pathFromRoot = relative(root, filePath);
  return pathFromRoot === "" || (!pathFromRoot.startsWith("..") && !isAbsolute(pathFromRoot));
}

async function createWindow() {
  const rendererEntry = await resolveRendererEntry();
  const rendererDev = rendererEntry.mode === "modern" && isDev
    ? parseRendererDevUrl(process.env.SLATESYNC_RENDERER_URL)
    : null;
  let activeRendererDevOrigin = rendererDev?.origin || null;
  let allowedRoot = rendererEntry.root;
  mainWindow = new BrowserWindow({
    width: 1440,
    height: 900,
    minWidth: 960,
    minHeight: 600,
    title: "SlateSync",
    ...(isDev ? { icon: DEV_ICON_PATH } : {}),
    webPreferences: {
      contextIsolation: true,
      nodeIntegration: false,
      sandbox: true,
      webSecurity: true,
      allowRunningInsecureContent: false,
      preload: join(__dirname, "..", "out", "preload", "index.cjs"),
    },
  });

  // Apply the same boundary to user navigation and server redirects. A Vite
  // response must not redirect the privileged Preload onto a remote origin.
  mainWindow.webContents.setWindowOpenHandler(() => ({ action: "deny" }));
  const guardRendererNavigation = (event, url) => {
    if (activeRendererDevOrigin) {
      if (isAllowedRendererDevNavigation(url, activeRendererDevOrigin)) return;
      event.preventDefault();
      return;
    }
    if (!url.startsWith("file://")) {
      event.preventDefault();
      return;
    }
    const filePath = fileURLToPath(url);
    if (!isWithinRoot(filePath, allowedRoot)) {
      event.preventDefault();
    }
  };
  mainWindow.webContents.on("will-navigate", guardRendererNavigation);
  mainWindow.webContents.on("will-redirect", guardRendererNavigation);

  try {
    if (rendererDev) {
      await mainWindow.loadURL(rendererDev.href);
      console.log(`Loaded modern renderer HMR: ${rendererDev.href}`);
      appLogger?.info("app", "已加载 Modern Renderer HMR", { origin: rendererDev.origin });
    } else {
      await mainWindow.loadFile(rendererEntry.htmlPath);
      console.log(`Loaded ${rendererEntry.mode} renderer: ${rendererEntry.htmlPath}`);
      appLogger?.info("app", `已加载 ${rendererEntry.mode} Renderer`, { path: rendererEntry.htmlPath });
    }
  } catch (error) {
    if (rendererDev) {
      // The dev orchestrator normally fails before Electron starts when Vite
      // is unavailable. This fallback also covers a server that dies after
      // the window was created, without widening the file access boundary.
      activeRendererDevOrigin = null;
      console.error("Renderer HMR server failed; falling back to compiled Modern renderer:", error);
      appLogger?.warn("app", "Renderer HMR 加载失败，回退到编译后的 Modern Renderer", { error });
      try {
        await mainWindow.loadFile(rendererEntry.htmlPath);
        console.log(`Loaded compiled modern renderer: ${rendererEntry.htmlPath}`);
        appLogger?.info("app", "已加载编译后的 Modern Renderer", { path: rendererEntry.htmlPath });
      } catch (fallbackError) {
        console.error("Failed to load compiled Modern renderer:", fallbackError);
        appLogger?.error("app", "编译后的 Modern Renderer 加载失败", { error: fallbackError });
      }
    } else if (rendererEntry.mode !== "modern") {
      console.error("Failed to load index.html:", error);
      appLogger?.error("app", "legacy Renderer 加载失败", { error });
    } else {
      const legacyRoot = isDev
        ? join(resolve(__dirname, ".."), "public")
        : join(__dirname, "..", "public");
      allowedRoot = legacyRoot;
      console.error("Modern renderer failed during initial load; falling back to legacy renderer:", error);
      appLogger?.warn("app", "Modern Renderer 初始加载失败，回退到 legacy Renderer", { error });
      try {
        await mainWindow.loadFile(join(legacyRoot, "index.html"));
        console.log(`Loaded legacy renderer fallback: ${join(legacyRoot, "index.html")}`);
        appLogger?.info("app", "已加载 legacy Renderer 回退入口", { path: join(legacyRoot, "index.html") });
      } catch (fallbackError) {
        console.error("Failed to load legacy renderer fallback:", fallbackError);
        appLogger?.error("app", "legacy Renderer 回退加载失败", { error: fallbackError });
      }
    }
  }

  mainWindow.on("closed", () => {
    mainWindow = null;
  });
}

function configureDevelopmentIcon() {
  if (!isDev || process.platform !== "darwin") return;
  const icon = nativeImage.createFromPath(DEV_ICON_PATH);
  if (!icon.isEmpty()) app.dock.setIcon(icon);
}

app.whenReady().then(async () => {
  configureDevelopmentIcon();
  let startPaddleOcrPreload;
  try {
    startPaddleOcrPreload = await initialize();
  } catch (error) {
    console.error("SlateSync initialization failed:", error);
    appLogger?.error("app", "SlateSync 初始化失败", { error });
    app.quit();
    return;
  }
  await createWindow();
  // Warm the selected local OCR route after the window is usable so cold model
  // download/initialization is outside the first recognition interaction.
  startPaddleOcrPreload?.();

  app.on("activate", () => {
    if (BrowserWindow.getAllWindows().length === 0) {
      void createWindow();
    }
  });
});

app.on("window-all-closed", () => {
  appLogger?.info("app", "所有窗口已关闭");
  app.quit();
});

app.on("before-quit", (event) => {
  if (paddleOcrExitCleanupComplete) return;
  // Electron does not await async event listeners. Prevent the first quit
  // request, close the queue with a hard deadline, then re-issue the quit so
  // will-quit can finish the remaining non-OCR resources.
  event.preventDefault();
  if (paddleOcrExitCleanupPromise) return;
  paddleOcrInstaller?.cancel();
  paddleOcrExitCleanupPromise = closePaddleOcrWorker({
    force: true,
    shutdown: true,
    deadlineAt: Date.now() + PADDLEOCR_EXIT_SHUTDOWN_TIMEOUT_MS,
  })
    .catch((error) => {
      appLogger?.warn("ocr", "应用退出时关闭 PaddleOCR Worker 失败", { error });
    })
    .finally(() => {
      paddleOcrExitCleanupComplete = true;
      app.quit();
    });
});

app.on("will-quit", () => {
  appLogger?.info("app", "应用即将退出");
  // Close cached project connections before Electron tears down the main
  // process. The library remains a portable folder that can be backed up.
  void projectRuntime?.close();
  void projectLibrary?.close();
  // Keep this idempotent fallback for direct/native quits that bypass the
  // before-quit gate; force mode also invalidates any late preload operation.
  paddleOcrInstaller?.cancel();
  void closePaddleOcrWorker({
    force: true,
    shutdown: true,
    deadlineAt: Date.now() + PADDLEOCR_EXIT_SHUTDOWN_TIMEOUT_MS,
  }).catch((error) => {
    appLogger?.warn("ocr", "退出阶段 PaddleOCR Worker 兜底关闭失败", { error });
  });
  // Awaiting the queue here preserves the final lifecycle line without making
  // logging part of the recognition or window error paths.
  void appLogger?.close();
});

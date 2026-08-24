// Electron main process: composition root and window lifecycle.
//
// Loads .env + workflow config, wires up persisted keys/settings and the OCR
// Python path, registers IPC handlers, then opens the sandboxed BrowserWindow.
// The window loads the single compiled typed Preload directly because a
// sandboxed Electron Preload cannot require another application-local file.
// Packaged startup loads the modern out/renderer/index.html shell. Development
// startup may receive a local Vite URL for Renderer HMR; if that server is not
// available, the compiled Modern shell remains the bounded fallback. An
// internal --slatesync-renderer=legacy switch and bounded load-time fallback
// preserve recovery without creating a second BrowserWindow or gateway. The
// window blocks external navigation and only allows the active dev origin or
// file:// URLs under the selected legacy or modern shell root.
import { app, BrowserWindow, ipcMain, nativeImage } from "electron";
import { access } from "node:fs/promises";
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
import { createWorkflowConfigProvider, PROVIDERS } from "../lib/config.mjs";
import { loadLocalEnv, createTaskLimiter, electronSettings } from "./env-loader.mjs";
import { registerIpcHandlers } from "./ipc-handlers.mjs";
import { createKeyStore } from "./key-store.mjs";
import { createFileDialogs } from "./file-dialogs.mjs";
import {
  isAllowedRendererDevNavigation,
  parseRendererDevUrl,
} from "./renderer-dev-url.mjs";
import { createSlateScanner } from "./slate-scanner.mjs";
import { createSettingsStore } from "./settings-store.mjs";
import {
  createProjectLibrary,
  DEFAULT_LIBRARY_FOLDER,
  defaultLibraryPath,
} from "../lib/project-library.mjs";
import {
  exportProjectLibrary,
  libraryExportPath,
  validateProjectLibrary,
} from "../lib/project-library-transfer.mjs";
import { createProjectRuntime } from "../lib/project-runtime.mjs";
import { projectSettingsFromWorkflow } from "../lib/project-settings.mjs";

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

// Set project root for OCR subprocess path resolution
if (isDev) {
  process.env.SLATESYNC_PROJECT_DIR = resolve(__dirname, "..");
} else {
  process.env.SLATESYNC_PROJECT_DIR = join(process.resourcesPath, "app");
}

// PaddleOCR model cache in userData to avoid writing to app install directory
if (!process.env.PADDLE_PDX_CACHE_HOME) {
  process.env.PADDLE_PDX_CACHE_HOME = join(
    app.getPath("userData"),
    "paddlex",
  );
}

let mainWindow = null;
let projectLibrary = null;
let projectRuntime = null;

async function initialize() {
  // Load .env from project root (dev) or userData (packaged)
  const envPath = isDev
    ? join(resolve(__dirname, ".."), ".env")
    : join(app.getPath("userData"), ".env");
  await loadLocalEnv(envPath);
  configureModelHttpAgent(process.env);

  // Load workflow config
  const configPath = isDev
    ? resolve(
        resolve(__dirname, ".."),
        process.env.SLATESYNC_CONFIG_PATH || "slatesync.config.json",
      )
    : join(process.resourcesPath, "app", "slatesync.config.json");
  const getWorkflowConfig = createWorkflowConfigProvider(configPath);
  await getWorkflowConfig();

  const settings = electronSettings(process.env);
  const recognitionLimiter = createTaskLimiter(settings.maxConcurrentRecognitions);

  // Load persisted API keys and app settings
  const keyStore = createKeyStore(app.getPath("userData"));
  const runtimeProviderKeys = await keyStore.load();
  const settingsStore = createSettingsStore(app.getPath("userData"));
  const runtimeSettings = await settingsStore.load();

  function runtimeEnv() {
    const env = { ...process.env };
    for (const [providerId, apiKey] of runtimeProviderKeys) {
      const provider = PROVIDERS[providerId];
      if (provider) env[provider.envKey] = apiKey;
    }
    if (runtimeSettings.ocrPythonPath) {
      env.PADDLEOCR_PYTHON = runtimeSettings.ocrPythonPath;
    }
    return env;
  }

  const fileDialogs = createFileDialogs(() => mainWindow);
  const slateScanner = createSlateScanner();
  const workflowDefaults = projectSettingsFromWorkflow(await getWorkflowConfig());
  const libraryRoot = runtimeSettings.libraryPath || await initialLibraryPath();
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
    libraryActions,
  });
}

async function initialLibraryPath() {
  const preferred = defaultLibraryPath(app.getPath("appData"));
  const previousDefault = join(
    app.getPath("userData"),
    "Libraries",
    DEFAULT_LIBRARY_FOLDER,
  );
  // Existing development installs used <userData>/Libraries. Prefer that
  // package only when the new Application Support default does not yet exist.
  if (!(await exists(preferred)) && await exists(previousDefault)) {
    return previousDefault;
  }
  return preferred;
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
    }
    return entry;
  } catch (error) {
    console.error("Modern renderer selector is unavailable; using legacy recovery:", error);
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
    } else {
      await mainWindow.loadFile(rendererEntry.htmlPath);
      console.log(`Loaded ${rendererEntry.mode} renderer: ${rendererEntry.htmlPath}`);
    }
  } catch (error) {
    if (rendererDev) {
      // The dev orchestrator normally fails before Electron starts when Vite
      // is unavailable. This fallback also covers a server that dies after
      // the window was created, without widening the file access boundary.
      activeRendererDevOrigin = null;
      console.error("Renderer HMR server failed; falling back to compiled Modern renderer:", error);
      try {
        await mainWindow.loadFile(rendererEntry.htmlPath);
        console.log(`Loaded compiled modern renderer: ${rendererEntry.htmlPath}`);
      } catch (fallbackError) {
        console.error("Failed to load compiled Modern renderer:", fallbackError);
      }
    } else if (rendererEntry.mode !== "modern") {
      console.error("Failed to load index.html:", error);
    } else {
      const legacyRoot = isDev
        ? join(resolve(__dirname, ".."), "public")
        : join(__dirname, "..", "public");
      allowedRoot = legacyRoot;
      console.error("Modern renderer failed during initial load; falling back to legacy renderer:", error);
      try {
        await mainWindow.loadFile(join(legacyRoot, "index.html"));
        console.log(`Loaded legacy renderer fallback: ${join(legacyRoot, "index.html")}`);
      } catch (fallbackError) {
        console.error("Failed to load legacy renderer fallback:", fallbackError);
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
  try {
    await initialize();
  } catch (error) {
    console.error("SlateSync initialization failed:", error);
    app.quit();
    return;
  }
  await createWindow();

  app.on("activate", () => {
    if (BrowserWindow.getAllWindows().length === 0) {
      void createWindow();
    }
  });
});

app.on("window-all-closed", () => {
  app.quit();
});

app.on("will-quit", () => {
  // Close cached project connections before Electron tears down the main
  // process. The library remains a portable folder that can be backed up.
  void projectRuntime?.close();
  void projectLibrary?.close();
});

// Electron main process: composition root and window lifecycle.
//
// Loads .env + workflow config, wires up persisted keys/settings and the OCR
// Python path, registers IPC handlers, then opens the sandboxed BrowserWindow
// that loads public/index.html. The window blocks external navigation and only
// allows file:// URLs under the app's public directory.
import { app, BrowserWindow, ipcMain, nativeImage } from "electron";
import { join, dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { configureModelHttpAgent } from "../lib/ai-client.mjs";
import { createWorkflowConfigProvider, PROVIDERS } from "../lib/config.mjs";
import { loadLocalEnv, createTaskLimiter, electronSettings } from "./env-loader.mjs";
import { registerIpcHandlers } from "./ipc-handlers.mjs";
import { createKeyStore } from "../lib/key-store.mjs";
import { createFileDialogs } from "./file-dialogs.mjs";
import { createSlateScanner } from "./slate-scanner.mjs";
import { createSettingsStore } from "./settings-store.mjs";
import { createDiagnosticsStore } from "../lib/diagnostics.mjs";
import { createTaskStore } from "../lib/task-store.mjs";
import { createScenarioStore } from "../lib/scenario/store.mjs";

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
  const diagnostics = createDiagnosticsStore(
    join(app.getPath("userData"), "data"),
  );
  const taskStore = createTaskStore(
    join(app.getPath("userData"), "data"),
  );
  const scenarioStore = createScenarioStore(
    join(app.getPath("userData"), "data"),
    { matching: async () => (await getWorkflowConfig()).scenario?.matching },
  );

  registerIpcHandlers(ipcMain, {
    getWorkflowConfig,
    runtimeProviderKeys,
    runtimeEnv,
    recognitionLimiter,
    settings,
    keyStore,
    fileDialogs,
    slateScanner,
    diagnostics,
    taskStore,
    scenarioStore,
    settingsStore,
    runtimeSettings,
  });
}

function createWindow() {
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
      preload: join(__dirname, "preload.cjs"),
    },
  });

  // Prevent navigation to external URLs
  mainWindow.webContents.setWindowOpenHandler(() => ({ action: "deny" }));
  const allowedDir = isDev
    ? join(resolve(__dirname, ".."), "public")
    : join(__dirname, "..", "public");
  mainWindow.webContents.on("will-navigate", (event, url) => {
    if (!url.startsWith("file://")) {
      event.preventDefault();
      return;
    }
    const filePath = fileURLToPath(url);
    if (!filePath.startsWith(allowedDir)) {
      event.preventDefault();
    }
  });

  const htmlPath = join(allowedDir, "index.html");
  mainWindow.loadFile(htmlPath).catch((error) => {
    console.error("Failed to load index.html:", error);
  });

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
  createWindow();

  app.on("activate", () => {
    if (BrowserWindow.getAllWindows().length === 0) {
      createWindow();
    }
  });
});

app.on("window-all-closed", () => {
  app.quit();
});

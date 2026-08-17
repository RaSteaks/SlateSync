// Preload script: bridges the sandboxed renderer to the main process.
//
// contextBridge exposes a single electronAPI object whose methods forward to
// the ipcMain channels registered in electron/ipc-handlers.mjs. The renderer
// never touches ipcRenderer directly; public/electron-bridge.js is the only
// consumer.
const { contextBridge, ipcRenderer } = require("electron");

let progressListener = null;

contextBridge.exposeInMainWorld("electronAPI", {
  isElectron: true,

  getConfig: () => ipcRenderer.invoke("get-config"),

  saveProviderKey: (provider, apiKey) =>
    ipcRenderer.invoke("save-provider-key", { provider, apiKey }),

  getModels: (providerId, forceRefresh) =>
    ipcRenderer.invoke("get-models", { providerId, forceRefresh }),

  recognize: (requestBody) =>
    ipcRenderer.invoke("recognize", requestBody),

  onRecognitionProgress: (callback) => {
    // Remove previous listener before adding a new one
    if (progressListener) {
      ipcRenderer.removeListener("recognition-progress", progressListener);
    }
    progressListener = (_event, data) => callback(data);
    ipcRenderer.on("recognition-progress", progressListener);
  },

  removeRecognitionProgressListener: () => {
    if (progressListener) {
      ipcRenderer.removeListener("recognition-progress", progressListener);
      progressListener = null;
    }
  },

  saveFile: (defaultFilename, data) =>
    ipcRenderer.invoke("save-file", { defaultFilename, data }),

  selectDirectory: () =>
    ipcRenderer.invoke("select-directory"),

  scanSlateDirectory: (dirPath, expectedKeys, maxDepth) =>
    ipcRenderer.invoke("scan-slate-directory", {
      dirPath,
      expectedKeys,
      maxDepth,
    }),

  // Every project-scoped read carries the project ID so the main process can
  // resolve the correct project database instead of trusting renderer state.
  listProjects: () => ipcRenderer.invoke("list-projects"),

  getLibraryInfo: () => ipcRenderer.invoke("get-library-info"),

  importProjectLibrary: () => ipcRenderer.invoke("import-project-library"),

  exportProjectLibrary: () => ipcRenderer.invoke("export-project-library"),

  changeLibraryLocation: () => ipcRenderer.invoke("change-library-location"),

  createProject: (project) => ipcRenderer.invoke("create-project", project),

  loadProject: (id) => ipcRenderer.invoke("load-project", { id }),

  updateProject: (project) => ipcRenderer.invoke("update-project", project),

  archiveProject: (id) => ipcRenderer.invoke("archive-project", { id }),

  restoreProject: (id) => ipcRenderer.invoke("restore-project", { id }),

  listTasks: (projectId) => ipcRenderer.invoke("list-tasks", { projectId }),

  loadTask: (projectId, id) => ipcRenderer.invoke("load-task", { projectId, id }),

  saveTask: (projectId, task) => ipcRenderer.invoke("save-task", { projectId, task }),

  deleteTask: (projectId, id) => ipcRenderer.invoke("delete-task", { projectId, id }),

  // Profiles are project-owned in Electron; imports create a copy in the
  // selected project's database instead of sharing a global row.
  listScenarios: (projectId) => ipcRenderer.invoke("list-scenarios", { projectId }),

  loadScenario: (projectId, id) => ipcRenderer.invoke("load-scenario", { projectId, id }),

  importScenario: (projectId, profile) =>
    ipcRenderer.invoke("import-scenario", { projectId, profile }),

  getOcrSettings: () => ipcRenderer.invoke("get-ocr-settings"),

  saveOcrSettings: (settings) =>
    ipcRenderer.invoke("save-ocr-settings", settings),

  checkOcr: (pythonPath) =>
    ipcRenderer.invoke("check-ocr", { pythonPath }),
});

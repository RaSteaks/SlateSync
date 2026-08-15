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

  listTasks: () => ipcRenderer.invoke("list-tasks"),

  loadTask: (id) => ipcRenderer.invoke("load-task", { id }),

  saveTask: (task) => ipcRenderer.invoke("save-task", task),

  deleteTask: (id) => ipcRenderer.invoke("delete-task", { id }),

  getOcrSettings: () => ipcRenderer.invoke("get-ocr-settings"),

  saveOcrSettings: (settings) =>
    ipcRenderer.invoke("save-ocr-settings", settings),

  checkOcr: (pythonPath) =>
    ipcRenderer.invoke("check-ocr", { pythonPath }),
});

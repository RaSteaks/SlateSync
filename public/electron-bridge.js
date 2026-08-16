// Unified API layer that transparently switches between Web (fetch) and
// Electron (ipcRenderer.invoke) modes based on the runtime environment.
//
// When adding a new API endpoint, update all three locations:
//   1. server.mjs (Web mode HTTP route)
//   2. electron/ipc-handlers.mjs (Electron IPC handler)
//   3. public/electron-bridge.js (this file, frontend dispatch)

import { readRecognitionResponse } from "./recognition-stream.js";

export const isElectron = Boolean(globalThis.electronAPI?.isElectron);

export async function fetchConfig() {
  if (isElectron) {
    return globalThis.electronAPI.getConfig();
  }
  const response = await fetch("/api/config");
  return response.json();
}

export async function saveProviderKeyApi(providerId, apiKey) {
  if (isElectron) {
    return globalThis.electronAPI.saveProviderKey(providerId, apiKey);
  }
  const response = await fetch("/api/provider-key", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ provider: providerId, apiKey }),
  });
  const data = await response.json();
  if (!response.ok) throw new Error(data.error || "API Key 保存失败");
  return data;
}

export async function fetchModelsApi(providerId, forceRefresh = false) {
  if (isElectron) {
    return globalThis.electronAPI.getModels(providerId, forceRefresh);
  }
  const query = new URLSearchParams({ provider: providerId });
  if (forceRefresh) query.set("refresh", "1");
  const response = await fetch(`/api/models?${query}`);
  const data = await response.json();
  if (!response.ok) throw new Error(data.error || "无法读取模型列表");
  return data;
}

export async function recognizeStreamApi(requestBody, onProgress) {
  if (isElectron) {
    globalThis.electronAPI.onRecognitionProgress(onProgress);
    try {
      const parsed = JSON.parse(requestBody);
      return await globalThis.electronAPI.recognize(parsed);
    } finally {
      globalThis.electronAPI.removeRecognitionProgressListener();
    }
  }
  const response = await fetch("/api/recognize-stream", {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      Accept: "application/x-ndjson",
    },
    body: requestBody,
  });
  return readRecognitionResponse(response, onProgress);
}

export async function downloadFileApi(bytes, filename) {
  if (isElectron) {
    return globalThis.electronAPI.saveFile(filename, Array.from(bytes));
  }
  const blob = new Blob([bytes], { type: "text/csv" });
  const link = document.createElement("a");
  link.href = URL.createObjectURL(blob);
  link.download = filename;
  link.click();
  setTimeout(() => URL.revokeObjectURL(link.href), 0);
  return { saved: true };
}

export async function pickDirectoryApi() {
  if (isElectron) {
    return globalThis.electronAPI.selectDirectory();
  }
  // Web mode: use File System Access API
  if (typeof globalThis.showDirectoryPicker === "function") {
    try {
      const handle = await globalThis.showDirectoryPicker({
        id: "slatesync-slate-root",
        mode: "read",
      });
      return { dirPath: null, dirName: handle.name, handle };
    } catch (error) {
      if (error?.name === "AbortError") return null;
      throw error;
    }
  }
  return null;
}

export async function scanSlateDirectoryApi(dirPath, expectedKeys, maxDepth) {
  if (isElectron) {
    return globalThis.electronAPI.scanSlateDirectory(
      dirPath,
      expectedKeys,
      maxDepth,
    );
  }
  throw new Error("Web 模式不支持主进程目录扫描");
}

export async function listTasksApi() {
  if (isElectron) {
    return globalThis.electronAPI.listTasks();
  }
  const response = await fetch("/api/tasks");
  return response.json();
}

export async function loadTaskApi(id) {
  if (isElectron) {
    return globalThis.electronAPI.loadTask(id);
  }
  const response = await fetch(`/api/tasks/${encodeURIComponent(id)}`);
  if (!response.ok) throw new Error("任务不存在");
  return response.json();
}

export async function saveTaskApi(task) {
  if (isElectron) {
    return globalThis.electronAPI.saveTask(task);
  }
  const response = await fetch(`/api/tasks/${encodeURIComponent(task.id)}`, {
    method: "PUT",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(task),
  });
  return response.json();
}

export async function deleteTaskApi(id) {
  if (isElectron) {
    return globalThis.electronAPI.deleteTask(id);
  }
  const response = await fetch(`/api/tasks/${encodeURIComponent(id)}`, {
    method: "DELETE",
  });
  return response.json();
}

export async function getOcrSettingsApi() {
  if (isElectron) {
    return globalThis.electronAPI.getOcrSettings();
  }
  throw new Error("本地 OCR 配置仅桌面版支持");
}

export async function saveOcrSettingsApi(settings) {
  if (isElectron) {
    return globalThis.electronAPI.saveOcrSettings(settings);
  }
  throw new Error("本地 OCR 配置仅桌面版支持");
}

export async function checkOcrApi(pythonPath) {
  if (isElectron) {
    return globalThis.electronAPI.checkOcr(pythonPath);
  }
  throw new Error("本地 OCR 配置仅桌面版支持");
}

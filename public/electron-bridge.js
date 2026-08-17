// Unified API layer that transparently switches between Web (fetch) and
// Electron (ipcRenderer.invoke) modes based on the runtime environment.
//
// When adding a shared API endpoint, update all three locations:
//   1. server.mjs (Web mode HTTP route)
//   2. electron/ipc-handlers.mjs (Electron IPC handler)
//   3. public/electron-bridge.js (this file, frontend dispatch)
// Project Library methods are Electron-only and intentionally do not fall
// back to the legacy Web task/Profile database.

import { readRecognitionResponse } from "./recognition-stream.js";

export const isElectron = Boolean(globalThis.electronAPI?.isElectron);

export async function fetchConfig() {
  if (isElectron) {
    return globalThis.electronAPI.getConfig();
  }
  const response = await fetch("/api/config");
  return response.json();
}

export async function listProjectsApi() {
  if (!isElectron) return [];
  return globalThis.electronAPI.listProjects();
}

export async function getLibraryInfoApi() {
  if (!isElectron) return null;
  return globalThis.electronAPI.getLibraryInfo();
}

export async function importProjectLibraryApi() {
  if (!isElectron) throw new Error("项目库导入仅桌面版支持");
  return globalThis.electronAPI.importProjectLibrary();
}

export async function exportProjectLibraryApi() {
  if (!isElectron) throw new Error("项目库导出仅桌面版支持");
  return globalThis.electronAPI.exportProjectLibrary();
}

export async function changeLibraryLocationApi() {
  if (!isElectron) throw new Error("项目库存储位置仅桌面版支持");
  return globalThis.electronAPI.changeLibraryLocation();
}

export async function createProjectApi(project) {
  if (!isElectron) throw new Error("项目管理仅桌面版支持");
  return globalThis.electronAPI.createProject(project);
}

export async function loadProjectApi(id) {
  if (!isElectron) throw new Error("项目管理仅桌面版支持");
  return globalThis.electronAPI.loadProject(id);
}

export async function updateProjectApi(project) {
  if (!isElectron) throw new Error("项目管理仅桌面版支持");
  return globalThis.electronAPI.updateProject(project);
}

export async function archiveProjectApi(id) {
  if (!isElectron) throw new Error("项目管理仅桌面版支持");
  return globalThis.electronAPI.archiveProject(id);
}

export async function restoreProjectApi(id) {
  if (!isElectron) throw new Error("项目管理仅桌面版支持");
  return globalThis.electronAPI.restoreProject(id);
}

export async function listScenariosApi(projectId) {
  if (isElectron) {
    return globalThis.electronAPI.listScenarios(projectId);
  }
  const response = await fetch("/api/scenarios");
  const data = await response.json();
  if (!response.ok) throw new Error(data.error || "无法读取场记结构列表");
  return data.scenarios || [];
}

export async function loadScenarioApi(id, projectId) {
  if (isElectron) {
    return globalThis.electronAPI.loadScenario(projectId, id);
  }
  const response = await fetch(`/api/scenarios/${encodeURIComponent(id)}`);
  const data = await response.json();
  if (!response.ok) throw new Error(data.error || "场记结构不存在");
  return data.scenario || data;
}

export async function importScenarioApi(profile, projectId) {
  if (isElectron) {
    return globalThis.electronAPI.importScenario(projectId, profile);
  }
  const response = await fetch("/api/scenarios/import", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ profile }),
  });
  const data = await response.json();
  if (!response.ok) throw new Error(data.error || "场记结构导入失败");
  return data;
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

export async function listTasksApi(projectId) {
  if (isElectron) {
    return globalThis.electronAPI.listTasks(projectId);
  }
  const response = await fetch("/api/tasks");
  return response.json();
}

export async function loadTaskApi(id, projectId) {
  if (isElectron) {
    return globalThis.electronAPI.loadTask(projectId, id);
  }
  const response = await fetch(`/api/tasks/${encodeURIComponent(id)}`);
  if (!response.ok) throw new Error("任务不存在");
  return response.json();
}

export async function saveTaskApi(task, projectId) {
  if (isElectron) {
    return globalThis.electronAPI.saveTask(projectId, task);
  }
  const response = await fetch(`/api/tasks/${encodeURIComponent(task.id)}`, {
    method: "PUT",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(task),
  });
  const data = await response.json();
  // Fetch resolves for HTTP failures; surface them so autosave cannot report a
  // failed Web write as durable and allow navigation to discard local edits.
  if (!response.ok) throw new Error(data.error || "任务保存失败");
  return data;
}

export async function deleteTaskApi(id, projectId) {
  if (isElectron) {
    return globalThis.electronAPI.deleteTask(projectId, id);
  }
  const response = await fetch(`/api/tasks/${encodeURIComponent(id)}`, {
    method: "DELETE",
  });
  const data = await response.json();
  if (!response.ok) throw new Error(data.error || "任务删除失败");
  return data;
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

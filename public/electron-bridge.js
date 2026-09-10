// Legacy Renderer compatibility adapter. The active typed window.slateSync
// gateway is the only transport; this module only converts its Result<T>
// values and request objects to the unchanged legacy call conventions. The
// complete adapter is removed after the modern Renderer replaces its callers.

function electronApi() {
  if (globalThis.slateSync) return globalThis.slateSync;
  throw new Error("Electron preload bridge is unavailable");
}

function legacyError(result) {
  const details = result?.error || {};
  const error = new Error(details.message || "未知错误");
  if (details.code) error.code = details.code;
  if (details.retryable !== undefined) error.retryable = details.retryable;
  const statusMatch = /^HTTP_(\d+)$/.exec(String(details.code || ""));
  if (statusMatch) error.status = Number(statusMatch[1]);
  return error;
}

function unwrap(result) {
  if (result?.ok === true) return result.data;
  if (result?.ok === false) throw legacyError(result);
  throw new Error("Invalid slateSync Result envelope");
}

async function call(operation) {
  return unwrap(await operation(electronApi()));
}

async function callGlobalSettings(operation) {
  return call((api) => {
    // A stale Legacy Renderer can share a window with an older Preload after
    // a development reload; turn the missing method into a recovery hint.
    const settings = api.settings;
    if (typeof settings?.getGlobalSettings !== "function" || typeof settings.saveGlobalSettings !== "function") {
      throw new Error("当前 Renderer 与 Preload 版本不一致，无法读取全局设置。请完全退出 SlateSync 后重新启动；开发环境请运行 npm run electron:dev:modern。不要只刷新窗口。");
    }
    return operation(api);
  });
}

export function fetchConfig() {
  return call((api) => api.app.getConfig());
}

export function listProjectsApi() {
  return call((api) => api.projects.list());
}

export function getLibraryInfoApi() {
  return call((api) => api.projects.getLibraryInfo());
}

export function importProjectLibraryApi() {
  return call((api) => api.projects.importLibrary());
}

export function exportProjectLibraryApi() {
  return call((api) => api.projects.exportLibrary());
}

// Legacy Renderer 通过同一 bridge 调用项目包导入/导出，保持与 Modern 的 API 语义一致。
export function importProjectApi() {
  return call((api) => api.projects.importProject());
}

export function exportProjectApi(id) {
  return call((api) => api.projects.exportProject({ id }));
}

export function changeLibraryLocationApi() {
  return call((api) => api.projects.changeLibraryLocation());
}

export function createProjectApi(project) {
  return call((api) => api.projects.create(project));
}

export function loadProjectApi(id) {
  return call((api) => api.projects.load({ id }));
}

export function updateProjectApi(project) {
  return call((api) => api.projects.update(project));
}

export function archiveProjectApi(id) {
  return call((api) => api.projects.archive({ id }));
}

export function restoreProjectApi(id) {
  return call((api) => api.projects.restore({ id }));
}

export function listScenariosApi(projectId) {
  return call((api) => api.projects.listScenarios({ projectId }));
}

export function loadScenarioApi(id, projectId) {
  return call((api) => api.projects.loadScenario({ id, projectId }));
}

export function importScenarioApi(profile, projectId) {
  return call((api) => api.projects.importScenario({ profile, projectId }));
}

export function saveProviderKeyApi(providerId, apiKey) {
  return call((api) => api.settings.saveProviderKey({ provider: providerId, apiKey }));
}

export function getGlobalSettingsApi() {
  return callGlobalSettings((api) => api.settings.getGlobalSettings());
}

export function saveGlobalSettingsApi(settings) {
  return callGlobalSettings((api) => api.settings.saveGlobalSettings(settings));
}

export function fetchModelsApi(providerId, forceRefresh = false) {
  return call((api) => api.recognition.getModels({ providerId, forceRefresh }));
}

export function listCustomProvidersApi() {
  return call((api) => api.settings.listCustomProviders());
}

export function createCustomProviderApi(provider) {
  return call((api) => api.settings.createCustomProvider(provider));
}

export function updateCustomProviderApi(provider) {
  return call((api) => api.settings.updateCustomProvider(provider));
}

export function deleteCustomProviderApi(id) {
  return call((api) => api.settings.deleteCustomProvider({ id, confirm: true }));
}

export function probeCustomModelsApi(providerId, modelIds) {
  return call((api) => api.settings.probeCustomModels({ providerId, modelIds }));
}

export function cancelCustomModelProbeApi(providerId) {
  return call((api) => api.settings.cancelCustomModelProbe({ providerId }));
}

export function onModelProbeProgressApi(listener) {
  try {
    const api = electronApi();
    return typeof api.settings?.onModelProbeProgress === "function"
      ? api.settings.onModelProbeProgress(listener)
      : () => {};
  } catch {
    // Legacy pages can be opened with an older preload during a dev reload;
    // lack of progress subscription must not block the CRUD recovery UI.
    return () => {};
  }
}

export async function recognizeApi(requestBody, onProgress) {
  const api = electronApi();
  const request = JSON.parse(requestBody);
  const unsubscribe = api.recognition.onProgress((event) => onProgress?.(event));
  try {
    return unwrap(await api.recognition.run(request));
  } finally {
    unsubscribe();
  }
}

function exactBinary(bytes) {
  const view = bytes instanceof Uint8Array ? bytes : new Uint8Array(bytes);
  // Keep a full view zero-copy; only a subview receives one exact-range copy so
  // adjacent bytes from a shared backing buffer cannot cross the IPC boundary.
  return view.byteOffset === 0 && view.byteLength === view.buffer.byteLength
    ? view.buffer
    : view.buffer.slice(view.byteOffset, view.byteOffset + view.byteLength);
}

export function downloadFileApi(bytes, filename) {
  const data = exactBinary(bytes);
  return call((api) => api.files.save({ defaultFilename: filename, data }));
}

export function pickDirectoryApi() {
  return call((api) => api.files.selectDirectory());
}

export function scanSlateDirectoryApi(dirPath, expectedKeys, maxDepth) {
  return call((api) => api.files.scanSlateDirectory({ dirPath, expectedKeys, maxDepth }));
}

export function listTasksApi(projectId) {
  return call((api) => api.tasks.list({ projectId }));
}

export function loadTaskApi(id, projectId) {
  return call((api) => api.tasks.load({ id, projectId }));
}

export function saveTaskApi(task, projectId) {
  return call((api) => api.tasks.save({ task, projectId }));
}

export function deleteTaskApi(id, projectId) {
  return call((api) => api.tasks.delete({ id, projectId }));
}

export function getOcrSettingsApi() {
  return call((api) => api.settings.getOcrSettings());
}

export function saveOcrSettingsApi(settings) {
  return call((api) => api.settings.saveOcrSettings(settings));
}

export function checkOcrApi(pythonPath) {
  return call((api) => api.settings.checkOcr({ pythonPath }));
}

export function installPaddleOcrApi() {
  return callGlobalSettings((api) => {
    if (typeof api.settings?.installPaddleOcr !== "function") {
      throw new Error("当前 Renderer 与 Preload 版本不一致，无法安装 PaddleOCR。请完全退出 SlateSync 后重新启动；不要只刷新窗口。");
    }
    return api.settings.installPaddleOcr();
  });
}

export function cancelPaddleOcrInstallApi() {
  return callGlobalSettings((api) => {
    if (typeof api.settings?.cancelPaddleOcrInstall !== "function") {
      throw new Error("当前 Renderer 与 Preload 版本不一致，无法取消 PaddleOCR 安装。请完全退出 SlateSync 后重新启动；不要只刷新窗口。");
    }
    return api.settings.cancelPaddleOcrInstall();
  });
}

export function onPaddleOcrInstallProgressApi(listener) {
  try {
    const api = electronApi();
    return typeof api.settings?.onPaddleOcrInstallProgress === "function"
      ? api.settings.onPaddleOcrInstallProgress(listener)
      : () => {};
  } catch {
    // A stale Legacy preload can still render the settings page; absence of
    // progress events must not turn the install button into a dead control.
    return () => {};
  }
}

// Keep the legacy adapter able to exercise the same typed capability probe as
// the Modern Renderer; the Main process remains the only owner of credentials.
export function checkCompatibleJsonSchemaApi() {
  return call((api) => api.settings.checkCompatibleJsonSchema());
}

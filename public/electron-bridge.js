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

export function fetchModelsApi(providerId, forceRefresh = false) {
  return call((api) => api.recognition.getModels({ providerId, forceRefresh }));
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

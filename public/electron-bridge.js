// Electron renderer API facade.
//
// Every backend operation crosses the context-isolated preload bridge. Keeping
// the lookup inside each call produces a clear startup error if preload fails,
// instead of silently falling back to a second transport.

function electronApi() {
  const api = globalThis.electronAPI;
  if (!api) {
    throw new Error("Electron preload bridge is unavailable");
  }
  return api;
}

export async function fetchConfig() {
  return electronApi().getConfig();
}

export async function listProjectsApi() {
  return electronApi().listProjects();
}

export async function getLibraryInfoApi() {
  return electronApi().getLibraryInfo();
}

export async function importProjectLibraryApi() {
  return electronApi().importProjectLibrary();
}

export async function exportProjectLibraryApi() {
  return electronApi().exportProjectLibrary();
}

export async function changeLibraryLocationApi() {
  return electronApi().changeLibraryLocation();
}

export async function createProjectApi(project) {
  return electronApi().createProject(project);
}

export async function loadProjectApi(id) {
  return electronApi().loadProject(id);
}

export async function updateProjectApi(project) {
  return electronApi().updateProject(project);
}

export async function archiveProjectApi(id) {
  return electronApi().archiveProject(id);
}

export async function restoreProjectApi(id) {
  return electronApi().restoreProject(id);
}

export async function listScenariosApi(projectId) {
  return electronApi().listScenarios(projectId);
}

export async function loadScenarioApi(id, projectId) {
  return electronApi().loadScenario(projectId, id);
}

export async function importScenarioApi(profile, projectId) {
  return electronApi().importScenario(projectId, profile);
}

export async function saveProviderKeyApi(providerId, apiKey) {
  return electronApi().saveProviderKey(providerId, apiKey);
}

export async function fetchModelsApi(providerId, forceRefresh = false) {
  return electronApi().getModels(providerId, forceRefresh);
}

export async function recognizeApi(requestBody, onProgress) {
  const api = electronApi();
  api.onRecognitionProgress(onProgress);
  try {
    return await api.recognize(JSON.parse(requestBody));
  } finally {
    api.removeRecognitionProgressListener();
  }
}

export async function downloadFileApi(bytes, filename) {
  return electronApi().saveFile(filename, Array.from(bytes));
}

export async function pickDirectoryApi() {
  return electronApi().selectDirectory();
}

export async function scanSlateDirectoryApi(dirPath, expectedKeys, maxDepth) {
  return electronApi().scanSlateDirectory(dirPath, expectedKeys, maxDepth);
}

export async function listTasksApi(projectId) {
  return electronApi().listTasks(projectId);
}

export async function loadTaskApi(id, projectId) {
  return electronApi().loadTask(projectId, id);
}

export async function saveTaskApi(task, projectId) {
  return electronApi().saveTask(projectId, task);
}

export async function deleteTaskApi(id, projectId) {
  return electronApi().deleteTask(projectId, id);
}

export async function getOcrSettingsApi() {
  return electronApi().getOcrSettings();
}

export async function saveOcrSettingsApi(settings) {
  return electronApi().saveOcrSettings(settings);
}

export async function checkOcrApi(pythonPath) {
  return electronApi().checkOcr(pythonPath);
}

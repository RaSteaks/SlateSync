// Internal, explicit RPC inventory. No renderer channel or arbitrary SQL crosses
// this boundary; functions, native handles and encryption keys stay in the owner.
export const LIBRARY_METHODS = Object.freeze([
  "getLibraryInfo", "listProjects", "getProject", "createProject", "updateProject",
  "exportProjectPackage", "importProjectPackage", "touchProjectActivity",
  "archiveProject", "restoreProject", "deleteProject", "migrateLegacyData", "renameLibrary",
]);
export const STORE_METHODS = Object.freeze({
  taskStore: ["saveTask", "loadTask", "updateTask", "listTasks", "deleteTask"],
  scenarioStore: ["listProfiles", "getProfile", "matchAndSave", "importProfile"],
  diagnostics: ["saveSession", "loadSession", "listSessions", "deleteSession", "getSessionDir"],
});
export function storageError(message = "存储 Worker 不可用，请重新启动应用") {
  return Object.assign(new Error(message), { code: "STORAGE_UNAVAILABLE", retryable: false });
}

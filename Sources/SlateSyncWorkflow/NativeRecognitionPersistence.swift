import Foundation
import SlateSyncDomain
import SlateSyncPersistence

/// Native tasks already own their media, CSV and metadata before recognition.
/// Apply the SM-07 result payload as a patch to that existing task; the SM-07
/// coordinator and its frozen creation path remain unchanged for other callers.
struct NativeRecognitionPersistence: RecognitionPersistence {
    let runtime: ProjectRuntime

    func recognitionProject(projectID: String) async throws -> ProjectData {
        try await runtime.recognitionProject(projectID: projectID)
    }

    func saveTask(projectID: String, taskID: String?, payload: Data) async throws -> String {
        // Native recognition completes an existing draft. Losing its identity
        // must fail instead of leaving a draft beside a new completed task.
        let id = try Self.requireTaskID(taskID)
        return try await runtime.updateTask(projectID: projectID, taskID: id, patch: payload)
    }

    static func requireTaskID(_ taskID: String?) throws -> String {
        guard let taskID, !taskID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw SlateSyncError(code: "RECOGNITION_TASK_REQUIRED", message: "请先创建或选择任务，再开始识别")
        }
        return taskID
    }

    func saveDiagnostic(projectID: String, sessionID: String?, payload: Data) async throws -> String {
        try await runtime.saveDiagnostic(projectID: projectID, sessionID: sessionID, payload: payload)
    }

    func touchRecognitionActivity(projectID: String) async throws {
        try await runtime.touchRecognitionActivity(projectID: projectID)
    }
}

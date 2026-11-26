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
        // Retire the resumable page set in the same transaction as the
        // completed result; a failed final save can still resume.
        var fields = try JSONDecoder().decode([String: JSONValue].self, from: payload)
        fields["pageCheckpoint"] = .null
        return try await runtime.updateTask(projectID: projectID, taskID: id, patch: JSONEncoder().encode(fields))
    }

    func checkpoint(projectID: String, taskID: String) async throws -> RecognitionPagePipeline.Checkpoint? {
        struct Envelope: Decodable { let pageCheckpoint: RecognitionPagePipeline.Checkpoint? }
        let bytes = try await runtime.loadTask(projectID: projectID, taskID: taskID)
        // A cache created by a newer recognizer may be unreadable. The task
        // itself remains available; rebuild its pages using the current schema.
        do { return try JSONDecoder().decode(Envelope.self, from: bytes).pageCheckpoint }
        catch is DecodingError { return nil }
    }

    func checkpoint(_ value: RecognitionPagePipeline.Checkpoint, projectID: String, taskID: String) async throws {
        let payload = try JSONEncoder().encode(["pageCheckpoint": value])
        _ = try await runtime.updateTask(projectID: projectID, taskID: taskID, patch: payload)
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

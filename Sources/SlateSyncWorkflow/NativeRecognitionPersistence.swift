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
        if let taskID {
            return try await runtime.updateTask(projectID: projectID, taskID: taskID, patch: payload)
        }
        return try await runtime.saveTask(projectID: projectID, taskID: nil, payload: payload)
    }

    func saveDiagnostic(projectID: String, sessionID: String?, payload: Data) async throws -> String {
        try await runtime.saveDiagnostic(projectID: projectID, sessionID: sessionID, payload: payload)
    }

    func touchRecognitionActivity(projectID: String) async throws {
        try await runtime.touchRecognitionActivity(projectID: projectID)
    }
}

import Foundation

public protocol ProjectLibraryServing: Sendable {
    func libraryInfo() async throws -> LibraryInfo
    func listProjects() async throws -> [ProjectSummary]
    func createProject(name: String, description: String) async throws -> ProjectData
}

public protocol TaskRepository: Sendable {
    func listTasks(projectID: String) async throws -> [String]
    func loadTask(projectID: String, taskID: String) async throws -> Data
    func saveTask(projectID: String, taskID: String?, payload: Data) async throws -> String
}

public protocol CSVProcessing: Sendable {
    func decode(_ data: Data) async throws -> ResolveCSVTable
    func encode(_ table: ResolveCSVTable) async throws -> Data
}

public protocol OCRServing: Sendable {
    func recognize(images: [Data]) async throws -> [OCRPageResult]
}

public protocol RecognitionServing: Sendable {
    func progress(for projectID: String) async -> AsyncStream<RecognitionProgress>
    func cancel(projectID: String) async
}

public protocol SettingsServing: Sendable {
    func value(for key: String) async -> String?
    func setValue(_ value: String?, for key: String) async throws
}

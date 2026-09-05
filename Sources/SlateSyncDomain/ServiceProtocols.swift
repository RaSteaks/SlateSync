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

public protocol SlateMetadataScanning: Sendable {
    func scan(directory: URL, options: SlateMetadataScanOptions) async throws -> ScanResult
}

public protocol ScenarioProfileProcessing: Sendable {
    func profile(from input: ScenarioObservationInput, resolve: ProjectSettings.ResolveSettings) async throws -> ScenarioProfile
    func normalize(_ profile: ScenarioProfile) async throws -> ScenarioProfile
    func similarity(_ left: ScenarioProfile, _ right: ScenarioProfile) async throws -> Double
}

/// Scenario matching persistence is addressed by project so Workflow cannot
/// retain a raw SQLite store and bypass ProjectRuntime's close/delete leases.
public protocol ScenarioMatchingPersistence: Sendable {
    func listScenarios(projectID: String) async throws -> [ScenarioSummary]
    func loadScenario(projectID: String, scenarioID: String) async throws -> ScenarioData
    func applyScenarioMatch(
        projectID: String,
        candidate: ScenarioProfile,
        selectedProfileID: String?,
        observationPayload: Data
    ) async throws -> ScenarioMatchCommit
}

public protocol OCRServing: Sendable {
    func recognize(images: [Data]) async throws -> [OCRPageResult]
}

/// SM-06 public boundaries carry immutable bytes/evidence, never framework or
/// database objects. Network orchestration remains the responsibility of SM-07.
public protocol MediaPreparing: Sendable {
    func prepare(_ input: MediaInput, options: MediaPreparationOptions, operation: MediaOperation, progress: MediaProgressSink?) async throws -> PreparedDocument
}
public protocol MediaRecompressing: Sendable {
    func recompress(_ document: PreparedDocument, profile: ImageCompressionProfile, operation: MediaOperation) async throws -> PreparedDocument
}
public protocol LocalOCREngine: Sendable {
    func recognize(_ document: PreparedDocument, operation: MediaOperation, progress: MediaProgressSink?) async throws -> OCREngineResult
    func close() async
}
public protocol OCRCapabilityProbing: Sendable {
    func isAvailable() async -> Bool
}

public protocol RecognitionServing: Sendable {
    func progress(for projectID: String) async -> AsyncStream<RecognitionProgress>
    func cancel(projectID: String) async
}

public protocol SettingsServing: Sendable {
    func value(for key: String) async -> String?
    func setValue(_ value: String?, for key: String) async throws
}

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

/// Provider credentials remain machine-local and are read only by the
/// transport while it constructs an Authorization header. Callers can ask for
/// configuration state without receiving the credential bytes.
public protocol ProviderCredentialReading: Sendable {
    func credential(for providerID: String) async throws -> String?
    func isCredentialConfigured(for providerID: String) async throws -> Bool
}

/// A monotonic clock keeps discovery TTLs and request deadlines deterministic
/// in tests without exposing URLSession tasks across actor boundaries.
public protocol ProviderClock: Sendable {
    func nowMilliseconds() -> Double
    func sleep(milliseconds: Int) async throws
}

public struct SystemProviderClock: ProviderClock {
    public init() {}
    public func nowMilliseconds() -> Double { ProcessInfo.processInfo.systemUptime * 1_000 }
    public func sleep(milliseconds: Int) async throws {
        try await Task.sleep(for: .milliseconds(milliseconds))
    }
}

/// Transport requests identify a provider and endpoint purpose but never
/// carry an API key. This is the only public network seam used by discovery,
/// probes, and recognition tests.
public protocol ProviderHTTPTransporting: Sendable {
    func send(_ request: ProviderTransportRequest) async throws -> ProviderTransportResponse
    func close() async
}

/// ProjectRuntime implements this address-only tail. Workflow never retains a
/// raw SQLite store or a project directory beyond the runtime's lease.
public protocol RecognitionPersistence: Sendable {
    func recognitionProject(projectID: String) async throws -> ProjectData
    func saveTask(projectID: String, taskID: String?, payload: Data) async throws -> String
    func saveDiagnostic(projectID: String, sessionID: String?, payload: Data) async throws -> String
    func touchRecognitionActivity(projectID: String) async throws
}

public protocol SettingsServing: Sendable {
    func value(for key: String) async -> String?
    func setValue(_ value: String?, for key: String) async throws
}

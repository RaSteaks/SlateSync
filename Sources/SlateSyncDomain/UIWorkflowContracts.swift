import Foundation

/// Immutable Library projection consumed by window-scoped UI models.
/// Keeping active and archived projects separate prevents view filters from
/// becoming a second lifecycle truth.
public struct ProjectLibraryProjection: Hashable, Sendable {
    public let library: LibraryInfo
    public let active: [ProjectSummary]
    public let archived: [ProjectSummary]

    public init(library: LibraryInfo, active: [ProjectSummary], archived: [ProjectSummary]) {
        self.library = library
        self.active = active
        self.archived = archived
    }
}

public struct GlobalSettingsProjection: Hashable, Sendable {
    public let values: GlobalSettingValues
    public let customProviders: [CustomProviderConfiguration]
    public let providers: [ProviderSummary]
    public let models: [ModelData]
    public let configuredCredentialProviderIDs: Set<String>
    public let visionAvailable: Bool
    public let paddleAvailable: Bool
    public let runtime: GlobalRuntimeProjection

    public init(
        values: GlobalSettingValues,
        customProviders: [CustomProviderConfiguration],
        providers: [ProviderSummary],
        models: [ModelData],
        configuredCredentialProviderIDs: Set<String>,
        visionAvailable: Bool,
        paddleAvailable: Bool,
        runtime: GlobalRuntimeProjection
    ) {
        self.values = values
        self.customProviders = customProviders
        self.providers = providers
        self.models = models
        self.configuredCredentialProviderIDs = configuredCredentialProviderIDs
        self.visionAvailable = visionAvailable
        self.paddleAvailable = paddleAvailable
        self.runtime = runtime
    }
}

public enum LegacyCredentialMigrationStatus: String, Codable, Hashable, Sendable {
    case notRun
    case sourceMissing
    case noCredentials
    case migrated
    case failed
}

/// Secret-free runtime status exposed across the Workflow boundary without
/// making SlateSyncUI import Persistence implementation types.
public struct GlobalRuntimeProjection: Hashable, Sendable {
    public let resolvedSettingCount: Int
    public let globalConfigVersion: Int
    public let environmentFileLoaded: Bool
    public let migrationStatus: LegacyCredentialMigrationStatus
    public let migrationErrorMessage: String?

    public init(
        resolvedSettingCount: Int,
        globalConfigVersion: Int,
        environmentFileLoaded: Bool,
        migrationStatus: LegacyCredentialMigrationStatus,
        migrationErrorMessage: String? = nil
    ) {
        self.resolvedSettingCount = resolvedSettingCount
        self.globalConfigVersion = globalConfigVersion
        self.environmentFileLoaded = environmentFileLoaded
        self.migrationStatus = migrationStatus
        self.migrationErrorMessage = migrationErrorMessage
    }
}

public enum ProductLogSeverity: String, CaseIterable, Codable, Hashable, Sendable {
    case debug
    case info
    case warning
    case error
}

/// Whitelisted file-log projection. It intentionally has no arbitrary
/// metadata dictionary, request body, credential, prompt, CSV cell, or path.
public struct ProductLogEntry: Identifiable, Codable, Hashable, Sendable {
    public let id: UUID
    public let timestamp: Date
    public let severity: ProductLogSeverity
    public let category: String
    public let event: String
    public let message: String
    public let operationID: String?
    public let completed: Int?
    public let total: Int?

    public init(
        id: UUID = UUID(),
        timestamp: Date,
        severity: ProductLogSeverity,
        category: String,
        event: String,
        message: String,
        operationID: String? = nil,
        completed: Int? = nil,
        total: Int? = nil
    ) {
        self.id = id
        self.timestamp = timestamp
        self.severity = severity
        self.category = category
        self.event = event
        self.message = message
        self.operationID = operationID
        self.completed = completed
        self.total = total
    }
}

public protocol ProjectLibraryWorkflowServing: Sendable {
    func projectLibrary() async throws -> ProjectLibraryProjection
    func project(id: String) async throws -> ProjectData
    func createProject(name: String, description: String) async throws -> ProjectData
    func updateProject(id: String, name: String, description: String, settings: ProjectSettings) async throws -> ProjectData
    func archiveProject(id: String) async throws -> ProjectData
    func restoreProject(id: String) async throws -> ProjectData
    func deleteProject(id: String) async throws
    func importProject(from packageURL: URL) async throws -> ProjectData
    func exportProject(id: String, to packageURL: URL) async throws -> ProjectExportResult
    func exportLibrary(to packageURL: URL) async throws -> LibraryExportResult
    func importLibrary(from packageURL: URL) async throws -> LibraryImportResult
    func relocateLibrary(to parentDirectory: URL) async throws -> LibraryLocationResult
    func renameLibrary(to name: String) async throws -> LibraryRenameResult
}

public protocol WorkspaceWorkflowServing: Sendable {
    func listTasks(projectID: String) async throws -> [TaskListItem]
    func loadTask(projectID: String, taskID: String) async throws -> TaskData
    func saveTask(projectID: String, taskID: String?, task: TaskData) async throws -> String
    func deleteTask(projectID: String, taskID: String) async throws
    func decodeResolveCSV(_ data: Data) async throws -> ResolveCSVTable
    func encodeResolveCSV(_ table: ResolveCSVTable) async throws -> Data
    func resolveMaterialKeys(in table: ResolveCSVTable) async throws -> [String]
    func scanMetadata(directory: URL, options: SlateMetadataScanOptions) async throws -> ScanResult
    func recognize(_ request: NativeRecognitionRequest) async throws -> RecognitionData
    func recognitionProgress(projectID: String) async -> AsyncStream<RecognitionProgress>
    func cancelRecognition(projectID: String) async
    func closeProject(id: String) async throws
}

/// Native input/preview adapters expose only SM-06 prepared JPEGs. Original
/// PDF bytes are consumed inside Media and never become downstream evidence.
public protocol MediaInputWorkflowServing: Sendable {
    func prepareInput(_ input: MediaInput) async throws -> PreparedDocument
    func restoreInput(groups: [[String]], filename: String) async throws -> PreparedDocument
}

public protocol ResolveExportWorkflowServing: Sendable {
    func mergeResolve(source: Data, records: [ResolveSlateRecord], metadata: [PersistedSlateMetadata], settings: ProjectSettings.ResolveSettings) async throws -> ResolveExportArtifact
    func exportStandalone(records: [ResolveSlateRecord], settings: ProjectSettings.ResolveSettings) async throws -> Data
}

/// Local slate input and Scenario options are projected by Workflow, keeping
/// parsing and project-runtime access out of SwiftUI's editing models.
public protocol LocalSlateWorkflowServing: Sendable {
    func decodeSlateCSV(_ data: Data) async throws -> [SlateCsvRecord]
    func localSlateRecords(_ records: [SlateCsvRecord]) async -> [PersistedRecognitionRecord]
    func listScenarios(projectID: String) async throws -> [ScenarioSummary]
}

public protocol GlobalSettingsWorkflowServing: Sendable {
    func globalSettings() async throws -> GlobalSettingsProjection
    func saveGlobalSettings(values: GlobalSettingValues, customProviders: [CustomProviderConfiguration]) async throws -> GlobalSettingsProjection
    func setProviderCredential(_ value: String?, providerID: String) async throws
    func retryLegacyCredentialMigration() async throws -> GlobalSettingsProjection
    func discoverModels(providerID: String, forceRefresh: Bool) async throws -> ModelDiscoveryResult
    func probeModels(
        providerID: String,
        modelIDs: [String],
        progress: @escaping @Sendable (ModelProbeProgress) -> Void
    ) async throws -> ModelProbeResult
    func cancelModelProbe(providerID: String) async
    func installPaddleOCR(
        progress: @escaping @Sendable (PaddleOcrInstallProgress) -> Void
    ) async throws -> PaddleOcrInstallResult
    func cancelPaddleOCRInstallation() async
}

public protocol LogWorkflowServing: Sendable {
    func logEntries(limit: Int, severities: Set<ProductLogSeverity>, category: String?) async -> [ProductLogEntry]
    func logSnapshot(limit: Int, severities: Set<ProductLogSeverity>, category: String?) async -> ProductLogReadResult
    func recordLog(_ entry: ProductLogEntry) async
    func logsDirectory() async -> URL
}

public struct ProductLogReadResult: Sendable {
    public let entries: [ProductLogEntry]
    public let degraded: Bool
    public let skippedLines: Int
    public init(entries: [ProductLogEntry], degraded: Bool = false, skippedLines: Int = 0) {
        self.entries = entries; self.degraded = degraded; self.skippedLines = skippedLines
    }
}

public extension LogWorkflowServing {
    func logSnapshot(limit: Int, severities: Set<ProductLogSeverity>, category: String?) async -> ProductLogReadResult {
        .init(entries: await logEntries(limit: limit, severities: severities, category: category))
    }
}

public protocol ProductLifecycleServing: Sendable {
    func drain() async throws
}

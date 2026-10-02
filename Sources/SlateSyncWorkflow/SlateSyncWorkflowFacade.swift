import Foundation
import SlateSyncDomain
import SlateSyncMedia
import SlateSyncPersistence

/// Project-scoped tickets close the factory-construction cancellation gap
/// without canceling recognition already running in unrelated windows.
struct RecognitionCancellationLedger: Sendable {
    private var revisions: [String: Int] = [:]

    func ticket(for projectID: String) -> Int { revisions[projectID, default: 0] }
    func permits(_ ticket: Int, for projectID: String) -> Bool {
        revisions[projectID, default: 0] == ticket
    }
    func requirePermit(_ ticket: Int, for projectID: String) throws {
        // A canceled caller can reach this actor after cancelRecognition has
        // already advanced the ledger and then capture that newer ticket.
        // Check task ownership as well as revision ownership at admission.
        guard !Task.isCancelled, permits(ticket, for: projectID) else {
            throw RecognitionFailure.canceled
        }
    }
    mutating func cancel(projectID: String) {
        revisions[projectID, default: 0] &+= 1
    }
}

/// Production façade consumed by the focused SM-08 UI models. It is the only
/// composition boundary allowed to join Library/runtime, CSV, media/OCR,
/// Provider transport, settings, and file logs; views receive only protocols.
public actor SlateSyncWorkflowFacade:
    ProjectLibraryWorkflowServing,
    WorkspaceWorkflowServing,
    ProjectContextWorkflowServing,
    MediaInputWorkflowServing,
    ResolveExportWorkflowServing,
    LocalSlateWorkflowServing,
    GlobalSettingsWorkflowServing,
    LogWorkflowServing,
    ProductLifecycleServing
{
    private let library: ProjectLibraryStartupService
    private let runtime: SlateSyncRuntime
    private let sm05: SM05WorkflowServices
    private let logs: LocalLogStore
    private let paddleInstaller: PaddleOCRInstallerService
    private let allowsExternalOperations: Bool
    private let providerTransportFactory: @Sendable () -> any ProviderHTTPTransporting
    private let recognitionRuntime: RecognitionRuntimeLifecycle
    private let providerSettings: ProviderSettingsCoordinator
    private var recognitionCancellations = RecognitionCancellationLedger()

    public init(
        library: ProjectLibraryStartupService,
        runtime: SlateSyncRuntime,
        sm05: SM05WorkflowServices = SM05WorkflowServices(),
        logs: LocalLogStore,
        paddleInstaller: PaddleOCRInstallerService,
        allowsExternalOperations: Bool = true,
        providerTransportFactory: (@Sendable () -> any ProviderHTTPTransporting)? = nil,
        draftProviderTransportFactory: (@Sendable (any ProviderCredentialReading) -> any ProviderHTTPTransporting)? = nil,
        allowsInjectedProviderOperations: Bool = false
    ) {
        self.library = library
        self.runtime = runtime
        self.sm05 = sm05
        self.logs = logs
        self.paddleInstaller = paddleInstaller
        self.allowsExternalOperations = allowsExternalOperations
        // Isolated fixtures must explicitly supply BOTH transports. No missing
        // injection may fall through to a production URLSession factory.
        let allowsProviderOperations = allowsExternalOperations
            || (allowsInjectedProviderOperations && providerTransportFactory != nil && draftProviderTransportFactory != nil)
        let transport = providerTransportFactory ?? { URLSessionProviderTransport(credentials: runtime.credentialStore) }
        self.providerTransportFactory = transport
        let recognitionRuntime = RecognitionRuntimeLifecycle()
        self.recognitionRuntime = recognitionRuntime
        self.providerSettings = ProviderSettingsCoordinator(runtime: runtime, logs: logs,
            recognitionRuntime: recognitionRuntime, allowsProviderOperations: allowsProviderOperations,
            providerTransportFactory: transport,
            draftProviderTransportFactory: draftProviderTransportFactory ?? { URLSessionProviderTransport(credentials: $0) })
    }

    /// Isolated app launches can exercise persistence and UI without reaching
    /// a production Provider or spawning an installer with network access.
    private func requireExternalOperations() throws {
        guard allowsExternalOperations else {
            throw SlateSyncError(code: "ISOLATED_OPERATION", message: "隔离验收环境已禁用外部服务", retryable: false)
        }
    }

    public func retryProjectLibraryUnlock() async { await LocalProjectEncryption.allowUnlockRetry() }

    public func projectLibrary() async throws -> ProjectLibraryProjection {
        try await library.projectLibrary()
    }

    public func project(id: String) async throws -> ProjectData {
        try await library.project(id: id)
    }

    public func createProject(name: String, description: String) async throws -> ProjectData {
        let config = try await runtime.workflowConfigProvider().current()
        let project = try await library.createProject(name: name, description: description, settings: .init(resolve: config.resolve))
        await record(.info, category: "project", event: "created", message: "项目已创建")
        return project
    }

    public func updateProject(id: String, name: String, description: String, settings: ProjectSettings) async throws -> ProjectData {
        let project = try await library.updateProject(id: id, name: name, description: description, settings: settings)
        await record(.info, category: "project", event: "updated", message: "项目设置已保存")
        return project
    }

    public func archiveProject(id: String) async throws -> ProjectData {
        await cancelRecognition(projectID: id)
        let project = try await library.archiveProject(id: id)
        await record(.info, category: "project", event: "archived", message: "项目已归档")
        return project
    }

    public func restoreProject(id: String) async throws -> ProjectData {
        let project = try await library.restoreProject(id: id)
        await record(.info, category: "project", event: "restored", message: "项目已恢复")
        return project
    }

    public func deleteProject(id: String) async throws {
        await cancelRecognition(projectID: id)
        try await library.deleteProject(id: id)
        await record(.warning, category: "project", event: "deleted", message: "项目已永久删除")
    }

    public func importProject(from packageURL: URL) async throws -> ProjectData {
        let project = try await library.importProject(from: packageURL)
        await record(.info, category: "project", event: "imported", message: "项目包已导入")
        return project
    }

    public func exportProject(id: String, to packageURL: URL) async throws -> ProjectExportResult {
        let result = try await library.exportProject(id: id, to: packageURL)
        await record(.info, category: "project", event: "exported", message: "项目包已导出")
        return result
    }

    public func exportLibrary(to packageURL: URL) async throws -> LibraryExportResult {
        try await library.exportLibrary(to: packageURL)
    }

    public func importLibrary(from packageURL: URL) async throws -> LibraryImportResult {
        try await resetRecognition()
        return try await library.importLibrary(from: packageURL)
    }

    public func relocateLibrary(to parentDirectory: URL) async throws -> LibraryLocationResult {
        try await resetRecognition()
        return try await library.relocateLibrary(to: parentDirectory)
    }

    public func renameLibrary(to name: String) async throws -> LibraryRenameResult {
        try await resetRecognition()
        return try await library.renameLibrary(to: name)
    }

    public func listTasks(projectID: String) async throws -> [TaskListItem] {
        try await library.projectRuntime().listTaskItems(projectID: projectID)
    }

    public func loadTask(projectID: String, taskID: String) async throws -> TaskData {
        let data = try await library.projectRuntime().loadTask(projectID: projectID, taskID: taskID)
        return try JSONDecoder().decode(TaskData.self, from: data)
    }

    public func saveTask(projectID: String, taskID: String?, task: TaskData) async throws -> String {
        // Preserve compatibility extensions through the native projection boundary.
        return try await library.projectRuntime().saveTaskProjection(projectID: projectID, taskID: taskID, task: task)
    }

    public func deleteTask(projectID: String, taskID: String) async throws {
        try await library.projectRuntime().deleteTask(projectID: projectID, taskID: taskID)
    }

    public func decodeResolveCSV(_ data: Data) async throws -> ResolveCSVTable {
        try await ResolveCSVEngine().decode(data)
    }

    public func encodeResolveCSV(_ table: ResolveCSVTable) async throws -> Data {
        try await ResolveCSVEngine().encode(table)
    }

    public func resolveMaterialKeys(in table: ResolveCSVTable) async throws -> [String] {
        try await sm05.resolveMaterialKeys(in: table)
    }

    public func scanMetadata(directory: URL, options: SlateMetadataScanOptions) async throws -> ScanResult {
        // The native workflow owns the scan-depth policy; the low-level
        // scanner continues to accept explicit options for independent callers.
        let config = try await runtime.workflowConfigProvider().current()
        var effective = options
        effective.maxDepth = config.slate.maxDirectoryDepth
        return try await sm05.scanMetadata(directory: directory, options: effective)
    }

    public func decodeSlateCSV(_ data: Data) async throws -> [SlateCsvRecord] { try await SlateCSVWorkflow().decode(data) }
    public func localSlateRecords(_ records: [SlateCsvRecord]) async -> [PersistedRecognitionRecord] { await SlateCSVWorkflow().records(records) }
    public func listScenarios(projectID: String) async throws -> [ScenarioSummary] {
        try await library.projectRuntime().listScenarios(projectID: projectID)
    }

    public func prepareInput(_ input: MediaInput) async throws -> PreparedDocument {
        try await MediaPreparationService().prepare(input)
    }

    public func restoreInput(groups: [[String]], filename: String) async throws -> PreparedDocument {
        guard !groups.isEmpty, groups.count <= MediaPreparationService.maximumPages else { throw MediaFailure.invalidInput }
        // V1 persisted tasks contain data URLs but no pixel dimensions. Exact
        // restore decodes every persisted data URL through Media and rebuilds
        // all views in order — original JPEG bytes, view order and view type
        // survive a reopen instead of re-cropping and re-compressing each
        // page's first image. No UI parser or raw PDF compatibility shortcut
        // exists.
        if PreparedDocumentRestore.isLegacySingleView(groups) {
            // Legacy tasks saved only one full image per page; keep their
            // bounded re-preparation fallback so crops and core-detail views
            // regenerate exactly as before exact restore existed.
            var pages: [PreparedMediaPage] = []
            for (index, group) in groups.enumerated() {
                try Task.checkCancellation()
                let data = try PreparedDocumentRestore.jpegData(group.first)
                let decoded = try await prepareInput(.bytes(data, filename: filename))
                guard let page = decoded.pages.first else { throw MediaFailure.invalidInput }
                pages.append(.init(pageNumber: index + 1, views: page.views))
            }
            return .init(filename: filename, pages: pages)
        }
        var pages: [PreparedMediaPage] = []
        for (index, group) in groups.enumerated() {
            try Task.checkCancellation()
            pages.append(.init(pageNumber: index + 1, views: try PreparedDocumentRestore.views(group)))
        }
        let document = PreparedDocument(filename: filename, pages: pages)
        try document.validate()
        return document
    }

    public func mergeResolve(source: Data, records: [ResolveSlateRecord], metadata: [PersistedSlateMetadata], settings: ProjectSettings.ResolveSettings, edits: [ResolveSparseEdit]) async throws -> ResolveExportArtifact {
        try await sm05.mergeAndEncode(source: source, records: records, metadata: metadata, fieldFormats: settings.fieldFormats, comments: settings.comments, edits: edits)
    }

    public func exportStandalone(records: [ResolveSlateRecord], settings: ProjectSettings.ResolveSettings) async throws -> Data {
        try await sm05.exportStandalone(records: records, fieldFormats: settings.fieldFormats)
    }

    public func recognize(_ request: NativeRecognitionRequest) async throws -> RecognitionData {
        try requireExternalOperations()
        // Validate ownership before any credential, OCR or Provider work. The
        // native entry point never creates a second task for a completed run;
        // the row-only probe avoids loading its potentially large media payload.
        let taskID = try NativeRecognitionPersistence.requireTaskID(request.taskID)
        try await library.projectRuntime().requireTaskExists(projectID: request.projectID, taskID: taskID)
        let cancellationTicket = recognitionCancellations.ticket(for: request.projectID)
        try recognitionCancellations.requirePermit(cancellationTicket, for: request.projectID)
        let coordinator = try await recognitionCoordinator()
        // A factory build can suspend long enough for close/archive to win.
        // Do not emit a misleading started event for work that is already
        // canceled and will never reach the Provider.
        try recognitionCancellations.requirePermit(cancellationTicket, for: request.projectID)
        await record(.info, category: "recognition", event: "started", message: "识别已开始")
        do {
            // Recording the start also suspends this actor. A close/archive
            // cancellation during that hop must stop the queued request.
            try recognitionCancellations.requirePermit(cancellationTicket, for: request.projectID)
            let result = try await coordinator.recognize(request)
            await record(.info, category: "recognition", event: "completed", message: "识别已完成")
            return result
        } catch {
            let wrapped = SlateSyncError.wrapped(error)
            await record(wrapped.retryable ? .warning : .error, category: "recognition", event: "failed", message: wrapped.message)
            throw wrapped
        }
    }

    public func recognitionProgress(projectID: String) async -> AsyncStream<RecognitionProgress> {
        guard allowsExternalOperations else { return AsyncStream { $0.finish() } }
        guard let coordinator = try? await recognitionCoordinator() else {
            return AsyncStream { $0.finish() }
        }
        return await coordinator.progress(for: projectID)
    }

    public func cancelRecognition(projectID: String) async {
        recognitionCancellations.cancel(projectID: projectID)
        await recognitionRuntime.cancel(projectID: projectID)
    }

    public func closeProject(id: String) async throws {
        await cancelRecognition(projectID: id)
        try await library.projectRuntime().closeProject(id)
    }

    public func globalSettings() async throws -> GlobalSettingsProjection {
        try await providerSettings.globalSettings()
    }

    /// Probe the editor's effective configuration without saving its draft or
    /// replacing the recognition coordinator currently serving a project.
    public func checkOCREnvironment(values: GlobalSettingValues) async throws -> [OCREnvironmentCheck] {
        let resolved = await runtime.resolveSettingsDraft(values)
        let resourcePaths = try OCRRuntimePaths(
            resources: Self.paddleResources(), python: URL(fileURLWithPath: "/usr/bin/python3"),
            workingDirectory: runtime.locator.url,
            modelCache: runtime.locator.url.appending(path: "paddle-models"), environment: [:])
        return try await OCREnvironmentChecker().check(
            values: resolved, directory: runtime.locator.url, runnerURL: resourcePaths.runner,
            environment: ProcessInfo.processInfo.environment)
    }

    public func saveGlobalSettings(values: GlobalSettingValues, customProviders: [CustomProviderConfiguration]) async throws -> GlobalSettingsProjection {
        try await providerSettings.saveGlobalSettings(values: values, customProviders: customProviders)
    }
    public func setProviderCredential(_ value: String?, providerID: String) async throws {
        try await providerSettings.setProviderCredential(value, providerID: providerID)
    }
    public func resetLocalProviderCredentials() async throws { try await providerSettings.resetLocalProviderCredentials() }
    public func discoverDraftModelIDs(baseURL: String, apiKey: String, savedProviderID: String?) async throws -> [String] {
        try await providerSettings.discoverDraftModelIDs(baseURL: baseURL, apiKey: apiKey, savedProviderID: savedProviderID)
    }
    public func discoverModels(providerID: String, forceRefresh: Bool) async throws -> ModelDiscoveryResult {
        try await providerSettings.discoverModels(providerID: providerID, forceRefresh: forceRefresh)
    }
    public func probeModels(providerID: String, modelIDs: [String], progress: @escaping @Sendable (ModelProbeProgress) -> Void) async throws -> ModelProbeResult {
        try await providerSettings.probeModels(providerID: providerID, modelIDs: modelIDs, progress: progress)
    }
    public func cancelModelProbe(providerID: String) async { await providerSettings.cancelModelProbe(providerID: providerID) }

    public func installPaddleOCR(
        progress: @escaping @Sendable (PaddleOcrInstallProgress) -> Void
    ) async throws -> PaddleOcrInstallResult {
        try requireExternalOperations()
        let result = try await paddleInstaller.install(progress: progress)
        let config = try await runtime.globalConfigStore.load()
        var values = config.values
        values[.paddleOCRPython] = result.pythonPath
        _ = try await saveGlobalSettings(values: values, customProviders: config.customProviders)
        return result
    }

    public func cancelPaddleOCRInstallation() async {
        await paddleInstaller.cancel()
    }

    public func logEntries(
        limit: Int,
        severities: Set<ProductLogSeverity>,
        category: String?
    ) async -> [ProductLogEntry] {
        await logs.read(limit: limit, severities: severities, category: category)
    }

    public func recordLog(_ entry: ProductLogEntry) async {
        await logs.append(Self.redacted(entry))
    }

    public func logSnapshot(limit: Int, severities: Set<ProductLogSeverity>, category: String?) async -> ProductLogReadResult {
        await logs.readSnapshot(limit: limit, severities: severities, category: category)
    }

    public func logsDirectory() async -> URL { logs.directory }

    public func drain() async throws {
        await paddleInstaller.cancelAndDrain()
        try await resetRecognition()
        await providerSettings.drain()
        try await library.close()
    }

    // Kept as an internal observation seam for module integration tests.
    func modelRegistry() async throws -> ProviderRegistry { try await providerSettings.modelRegistry() }

    private func recognitionCoordinator() async throws -> RecognitionCoordinator {
        try await recognitionRuntime.coordinator { try await self.makeRecognitionCoordinator() }
    }

    private func makeRecognitionCoordinator() async throws -> RecognitionCoordinator {
        let snapshot = await runtime.bootstrap()
        let registry = try await modelRegistry()
        let transport = providerTransportFactory()
        let client = ProviderRecognitionClient(transport: transport)
        let projectRuntime = try await library.projectRuntime()
        let values = snapshot.configuration.values
        let visionProbe = VisionOCRService(configuration: VisionOCRConfiguration(values))
        let visionAvailable = await visionProbe.isAvailable()
        await visionProbe.close()
        let paddlePaths = try Self.paddleRuntimePaths(runtime: runtime, values: values)
        let paddleAvailable = paddlePaths.map { paths in
            (try? paths.validate()) != nil
        } ?? false
        let workflowConfig = await runtime.workflowConfigProvider()
        let coordinator = RecognitionCoordinator(
            registry: registry,
            client: client,
            mediaFactory: {
                let vision = VisionOCRService(configuration: VisionOCRConfiguration(values))
                let paddle = paddlePaths.map {
                    PaddleOCRService(configuration: PaddleOCRConfiguration(values), paths: $0)
                }
                let local = LocalOCRService(
                    vision: vision,
                    paddle: paddle,
                    settings: values,
                    visionAvailable: visionAvailable,
                    paddleAvailable: paddleAvailable
                )
                return MediaOCRWorkflow(ocr: local)
            },
            scenarioPersistence: projectRuntime,
            persistence: NativeRecognitionPersistence(runtime: projectRuntime),
            settings: values,
            workflowConfiguration: { try await workflowConfig.current() }
        )
        return coordinator
    }

    private nonisolated static func paddleRuntimePaths(
        runtime: SlateSyncRuntime,
        values: GlobalSettingValues
    ) throws -> OCRRuntimePaths? {
        let rawPython = values[.paddleOCRPython]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !rawPython.isEmpty else { return nil }
        let root = runtime.locator.url
        let work = root.appending(path: "paddle-runtime", directoryHint: .isDirectory)
        let cache = root.appending(path: "paddle-models", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        return try OCRRuntimePaths(
            resources: paddleResources(),
            python: URL(fileURLWithPath: rawPython),
            workingDirectory: work,
            modelCache: cache,
            environment: ProcessInfo.processInfo.environment
        )
    }

    /// Diagnostics and inference must inspect the same bundled/development runner.
    private nonisolated static func paddleResources() -> OCRRuntimePaths.Resources {
        if let bundleRoot = Bundle.main.resourceURL?.appending(path: "PaddleOCR", directoryHint: .isDirectory),
           FileManager.default.isReadableFile(atPath: bundleRoot.appending(path: "paddleocr_runner.py").path) {
            // The folder reference preserves one canonical PaddleOCR subtree
            // in the bundle; runtime/cache paths remain outside Resources.
            return .bundle(bundleRoot)
        } else {
            return .development(URL(fileURLWithPath: FileManager.default.currentDirectoryPath))
        }
    }

    private func resetRecognition() async throws { await recognitionRuntime.reset() }

    private func record(
        _ severity: ProductLogSeverity,
        category: String,
        event: String,
        message: String
    ) async {
        await logs.append(Self.redacted(ProductLogEntry(
            timestamp: Date(),
            severity: severity,
            category: category,
            event: event,
            message: message
        )))
    }

    private nonisolated static func redacted(_ entry: ProductLogEntry) -> ProductLogEntry {
        // The same final projection is also enforced by the Persistence sink.
        ProductPrivacy.log(entry)
    }

    private nonisolated static func redactedMessage(_ raw: String) -> String {
        ProductPrivacy.message(raw)
    }

}

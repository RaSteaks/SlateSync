import Foundation
import SlateSyncDomain
import SlateSyncMedia
import SlateSyncPersistence

/// Production façade consumed by the focused SM-08 UI models. It is the only
/// composition boundary allowed to join Library/runtime, CSV, media/OCR,
/// Provider transport, settings, and file logs; views receive only protocols.
public actor SlateSyncWorkflowFacade:
    ProjectLibraryWorkflowServing,
    WorkspaceWorkflowServing,
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
    private var recognition: RecognitionCoordinator?
    private var recognitionRegistry: ProviderRegistry?
    private var settingsProviders: SettingsProviderRuntime?
    private var recognitionBuild: Task<RecognitionCoordinator, Error>?
    private var recognitionReset: Task<Void, Never>?
    private var recognitionGeneration = 0
    private var settingsBuild: Task<SettingsProviderRuntime, Error>?
    private var settingsReset: Task<Void, Never>?
    private var settingsGeneration = 0

    private struct SettingsProviderRuntime {
        let registry: ProviderRegistry
        let transport: URLSessionProviderTransport
        let discovery: ModelDiscoveryService
        let probe: ModelCapabilityProbeService
    }

    public init(
        library: ProjectLibraryStartupService,
        runtime: SlateSyncRuntime,
        sm05: SM05WorkflowServices = SM05WorkflowServices(),
        logs: LocalLogStore,
        paddleInstaller: PaddleOCRInstallerService,
        allowsExternalOperations: Bool = true
    ) {
        self.library = library
        self.runtime = runtime
        self.sm05 = sm05
        self.logs = logs
        self.paddleInstaller = paddleInstaller
        self.allowsExternalOperations = allowsExternalOperations
    }

    /// Isolated app launches can exercise persistence and UI without reaching
    /// a production Provider or spawning an installer with network access.
    private func requireExternalOperations() throws {
        guard allowsExternalOperations else {
            throw SlateSyncError(code: "ISOLATED_OPERATION", message: "隔离验收环境已禁用外部服务", retryable: false)
        }
    }

    public func projectLibrary() async throws -> ProjectLibraryProjection {
        try await library.projectLibrary()
    }

    public func project(id: String) async throws -> ProjectData {
        try await library.project(id: id)
    }

    public func createProject(name: String, description: String) async throws -> ProjectData {
        let project = try await library.createProject(name: name, description: description)
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
        let data = try JSONEncoder().encode(task)
        return try await library.projectRuntime().saveTask(projectID: projectID, taskID: taskID, payload: data)
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
        try await sm05.scanMetadata(directory: directory, options: options)
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
        var pages: [PreparedMediaPage] = []
        // V1 persisted tasks contain data URLs but no pixel dimensions. Decode
        // each full-page JPEG through Media to validate it and restore the
        // bounded views; no UI parser or raw PDF compatibility shortcut exists.
        for (index, group) in groups.enumerated() {
            try Task.checkCancellation()
            guard let first = group.first, first.hasPrefix("data:image/jpeg;base64,"),
                  let data = Data(base64Encoded: String(first.dropFirst("data:image/jpeg;base64,".count))) else { throw MediaFailure.invalidInput }
            let decoded = try await prepareInput(.bytes(data, filename: filename))
            guard let page = decoded.pages.first else { throw MediaFailure.invalidInput }
            pages.append(.init(pageNumber: index + 1, views: page.views))
        }
        return .init(filename: filename, pages: pages)
    }

    public func mergeResolve(source: Data, records: [ResolveSlateRecord], metadata: [PersistedSlateMetadata], settings: ProjectSettings.ResolveSettings) async throws -> ResolveExportArtifact {
        try await sm05.mergeAndEncode(source: source, records: records, metadata: metadata, fieldFormats: settings.fieldFormats, comments: settings.comments)
    }

    public func exportStandalone(records: [ResolveSlateRecord], settings: ProjectSettings.ResolveSettings) async throws -> Data {
        try await sm05.exportStandalone(records: records, fieldFormats: settings.fieldFormats)
    }

    public func recognize(_ request: NativeRecognitionRequest) async throws -> RecognitionData {
        try requireExternalOperations()
        let coordinator = try await recognitionCoordinator()
        await record(.info, category: "recognition", event: "started", message: "识别已开始")
        do {
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
        await recognition?.cancel(projectID: projectID)
    }

    public func closeProject(id: String) async throws {
        await cancelRecognition(projectID: id)
        try await library.projectRuntime().closeProject(id)
    }

    public func globalSettings() async throws -> GlobalSettingsProjection {
        let runtimeSnapshot = await runtime.bootstrap()
        let config = try await runtime.globalConfigStore.load()
        let registry = ProviderRegistry(
            settings: runtimeSnapshot.configuration.values,
            customProviders: config.customProviders,
            credentials: runtime.keychainStore
        )
        let providers = await registry.providerSummaries()
        var credentialIDs = Set<String>()
        for provider in providers where (try? await runtime.keychainStore.isCredentialConfigured(for: provider.id)) == true {
            credentialIDs.insert(provider.id)
        }
        let vision = VisionOCRService(configuration: VisionOCRConfiguration(runtimeSnapshot.configuration.values))
        let visionAvailable = await vision.isAvailable()
        await vision.close()
        let python = runtimeSnapshot.configuration.values[.paddleOCRPython] ?? ""
        let paddleAvailable = !python.isEmpty && FileManager.default.isExecutableFile(atPath: python)
        return GlobalSettingsProjection(
            values: config.values,
            customProviders: config.customProviders,
            providers: providers,
            models: await registry.publicModels(),
            configuredCredentialProviderIDs: credentialIDs,
            visionAvailable: visionAvailable,
            paddleAvailable: paddleAvailable,
            runtime: GlobalRuntimeProjection(
                resolvedSettingCount: runtimeSnapshot.configuration.values.values.count,
                globalConfigVersion: runtimeSnapshot.globalConfigVersion,
                environmentFileLoaded: runtimeSnapshot.environmentFileLoaded,
                migrationStatus: Self.migrationStatus(runtimeSnapshot.migration.status),
                migrationErrorMessage: runtimeSnapshot.migration.errorMessage.map(Self.redactedMessage)
            )
        )
    }

    public func saveGlobalSettings(
        values: GlobalSettingValues,
        customProviders: [CustomProviderConfiguration]
    ) async throws -> GlobalSettingsProjection {
        try await resetRecognition()
        await resetSettingsProviders()
        _ = try await runtime.globalConfigStore.save(values: values.values, customProviders: customProviders)
        _ = await runtime.refreshConfiguration()
        await record(.info, category: "settings", event: "saved", message: "全局设置已保存")
        return try await globalSettings()
    }

    public func setProviderCredential(_ value: String?, providerID: String) async throws {
        try await resetRecognition()
        await resetSettingsProviders()
        try await runtime.setProviderKey(value, for: providerID)
        await record(.info, category: "settings", event: "credential-updated", message: "Provider 凭据状态已更新")
    }

    public func retryLegacyCredentialMigration() async throws -> GlobalSettingsProjection {
        _ = await runtime.retryLegacyMigration()
        return try await globalSettings()
    }

    public func discoverModels(
        providerID: String,
        forceRefresh: Bool
    ) async throws -> ModelDiscoveryResult {
        try requireExternalOperations()
        return try await settingsProviderRuntime().discovery.discover(
            providerID: providerID,
            forceRefresh: forceRefresh
        )
    }

    public func probeModels(
        providerID: String,
        modelIDs: [String],
        progress: @escaping @Sendable (ModelProbeProgress) -> Void
    ) async throws -> ModelProbeResult {
        try requireExternalOperations()
        let value = try await settingsProviderRuntime().probe.probe(
            providerID: providerID,
            modelIDs: modelIDs,
            progress: progress
        )
        // The probe callback persists only a revision-matching cache. Rebuild
        // this settings-only runtime after completion so the next discovery
        // cannot reuse the pre-probe registry snapshot.
        await resetSettingsProviders()
        return value
    }

    public func cancelModelProbe(providerID: String) async {
        _ = await settingsProviders?.probe.cancel(providerID: providerID)
        // Reset also cancels an in-flight discovery transport. Provider edit
        // and delete therefore share one bounded drain path.
        await resetSettingsProviders()
    }

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
        await resetSettingsProviders()
        try await library.close()
    }

    private func settingsProviderRuntime() async throws -> SettingsProviderRuntime {
        guard settingsReset == nil else { throw CancellationError() }
        if let settingsProviders { return settingsProviders }
        let generation = settingsGeneration
        let build: Task<SettingsProviderRuntime, Error>
        if let settingsBuild { build = settingsBuild }
        else {
            build = Task { try await self.makeSettingsProviderRuntime() }
            settingsBuild = build
        }
        do {
            let value = try await build.value
            guard generation == settingsGeneration else { throw CancellationError() }
            settingsProviders = value
            settingsBuild = nil
            return value
        } catch {
            if generation == settingsGeneration { settingsBuild = nil }
            throw error
        }
    }

    /// Discovery and probe across multiple Provider rows share one retained
    /// transport; reset also joins construction suspended in config loading.
    private func makeSettingsProviderRuntime() async throws -> SettingsProviderRuntime {
        let snapshot = await runtime.bootstrap()
        let config = try await runtime.globalConfigStore.load()
        let registry = ProviderRegistry(
            settings: snapshot.configuration.values,
            customProviders: config.customProviders,
            credentials: runtime.keychainStore
        )
        let transport = URLSessionProviderTransport(credentials: runtime.keychainStore)
        let client = ProviderRecognitionClient(transport: transport)
        let discovery = ModelDiscoveryService(registry: registry, transport: transport)
        let probe = ModelCapabilityProbeService(
            registry: registry,
            client: client,
            save: { [weak self] providerID, revision, results in
                guard let self else { return }
                try await self.persistProbeResults(
                    providerID: providerID,
                    revision: revision,
                    results: results
                )
            }
        )
        let value = SettingsProviderRuntime(
            registry: registry,
            transport: transport,
            discovery: discovery,
            probe: probe
        )
        return value
    }

    private func resetSettingsProviders() async {
        if let settingsReset { await settingsReset.value; return }
        settingsGeneration += 1
        let current = settingsProviders
        let building = settingsBuild
        settingsProviders = nil
        settingsBuild = nil
        let reset = Task {
            if let current { await Self.closeSettingsProviderRuntime(current) }
            if let building, let value = try? await building.value { await Self.closeSettingsProviderRuntime(value) }
        }
        settingsReset = reset
        await reset.value
        settingsReset = nil
    }

    private static func closeSettingsProviderRuntime(_ value: SettingsProviderRuntime) async {
        await value.probe.close()
        await value.discovery.invalidate()
        await value.transport.close()
    }

    private func persistProbeResults(
        providerID: String,
        revision: Int,
        results: [ModelCapabilityProbeResult]
    ) async throws {
        let config = try await runtime.globalConfigStore.load()
        guard let index = config.customProviders.firstIndex(where: {
            $0.id == providerID && $0.revision == revision
        }) else { return }
        let original = config.customProviders[index]
        var cache = original.capabilityCache ?? [:]
        for result in results {
            cache[result.model] = CustomProviderCapabilityVerification(
                status: result.capabilityStatus,
                revision: revision,
                checkedAt: result.checkedAt,
                transport: result.transport,
                capabilitySource: "synthetic-image-probe",
                message: result.message
            )
        }
        var providers = config.customProviders
        providers[index] = CustomProviderConfiguration(
            id: original.id,
            name: original.name,
            label: original.label,
            baseUrl: original.baseUrl,
            transport: original.transport,
            jsonMode: original.jsonMode,
            imageDetail: original.imageDetail,
            manualModelIds: original.manualModelIds,
            revision: original.revision,
            capabilityCache: cache
        )
        _ = try await runtime.globalConfigStore.save(
            values: config.values.values,
            customProviders: providers
        )
        _ = await runtime.refreshConfiguration()
    }

    private func recognitionCoordinator() async throws -> RecognitionCoordinator {
        if recognitionReset != nil {
            throw SlateSyncError(code: "RECOGNITION_RECONFIGURING", message: "识别配置正在更新，请稍后重试", retryable: true)
        }
        if let recognition { return recognition }
        // Actor isolation does not serialize across await. Stream subscription
        // and request dispatch must join one factory or they create independent
        // limiters/transports and cancellation misses one of the operations.
        let generation = recognitionGeneration
        let build: Task<RecognitionCoordinator, Error>
        if let recognitionBuild { build = recognitionBuild }
        else {
            build = Task { try await self.makeRecognitionCoordinator() }
            recognitionBuild = build
        }
        do {
            let value = try await build.value
            guard generation == recognitionGeneration else { throw CancellationError() }
            recognition = value
            recognitionBuild = nil
            return value
        } catch {
            if generation == recognitionGeneration { recognitionBuild = nil }
            throw error
        }
    }

    private func makeRecognitionCoordinator() async throws -> RecognitionCoordinator {
        let snapshot = await runtime.bootstrap()
        let config = try await runtime.globalConfigStore.load()
        let registry = ProviderRegistry(
            settings: snapshot.configuration.values,
            customProviders: config.customProviders,
            credentials: runtime.keychainStore
        )
        let transport = URLSessionProviderTransport(credentials: runtime.keychainStore)
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
            settings: values
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
        let resources: OCRRuntimePaths.Resources
        if let bundleRoot = Bundle.main.resourceURL,
           FileManager.default.isReadableFile(atPath: bundleRoot.appending(path: "paddleocr_runner.py").path) {
            resources = .bundle(bundleRoot)
        } else {
            resources = .development(URL(fileURLWithPath: FileManager.default.currentDirectoryPath))
        }
        return try OCRRuntimePaths(
            resources: resources,
            python: URL(fileURLWithPath: rawPython),
            workingDirectory: work,
            modelCache: cache,
            environment: ProcessInfo.processInfo.environment
        )
    }

    private func resetRecognition() async throws {
        if let recognitionReset { await recognitionReset.value; return }
        recognitionGeneration += 1
        let current = recognition
        let building = recognitionBuild
        recognition = nil
        recognitionBuild = nil
        recognitionRegistry = nil
        let reset = Task {
            if let current { await current.close() }
            if let building, let value = try? await building.value { await value.close() }
        }
        recognitionReset = reset
        await reset.value
        recognitionReset = nil
    }

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

    private nonisolated static func migrationStatus(
        _ status: SlateSyncRuntimeMigrationStatus
    ) -> LegacyCredentialMigrationStatus {
        switch status {
        case .notRun: .notRun
        case .sourceMissing: .sourceMissing
        case .noCredentials: .noCredentials
        case .migrated: .migrated
        case .failed: .failed
        }
    }
}

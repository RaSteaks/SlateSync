import Foundation
import SlateSyncDomain

public struct SlateSyncRuntimeSnapshot: Codable, Hashable, Sendable {
    public let isBootstrapped: Bool
    public let configuration: ResolvedConfiguration
    public let machineSettings: MachineSettings
    public let globalConfigVersion: Int
    public let environmentFileLoaded: Bool
    /// Absolute path of the workflow config actually in effect. It follows the
    /// provider created at startup and deliberately ignores later setting
    /// changes until the process restarts.
    public let workflowConfigPath: String
    public let lastError: SlateSyncError?

    public init(
        isBootstrapped: Bool,
        configuration: ResolvedConfiguration,
        machineSettings: MachineSettings,
        globalConfigVersion: Int,
        environmentFileLoaded: Bool,
        workflowConfigPath: String = "",
        lastError: SlateSyncError? = nil
    ) {
        self.isBootstrapped = isBootstrapped
        self.configuration = configuration
        self.machineSettings = machineSettings
        self.globalConfigVersion = globalConfigVersion
        self.environmentFileLoaded = environmentFileLoaded
        self.workflowConfigPath = workflowConfigPath
        self.lastError = lastError
    }
}

/// Native startup composition root for machine settings, global overrides,
/// environment fallback, and encrypted-file Provider credentials. The actor keeps
/// the snapshot mutation single-writer while the injected stores remain
/// independently testable.
public actor SlateSyncRuntime: SettingsServing {
    public nonisolated let locator: ApplicationSupportLocator
    public nonisolated let machineSettingsStore: MachineSettingsStore
    public nonisolated let globalConfigStore: GlobalConfigStore
    public nonisolated let credentialStore: EncryptedFileCredentialStore

    private let processEnvironment: [String: String]
    private let environmentFileURL: URL
    private let workflowConfigEnvironment: WorkflowConfigPathEnvironment
    private let logger: SlateSyncLogger
    private var snapshot: SlateSyncRuntimeSnapshot
    /// Created exactly once per process from the startup-effective path. Old
    /// `createWorkflowConfigProvider` had the same lifecycle: a later setting
    /// change never hot-switches it; only a restart re-resolves.
    private var workflowConfigProviderInstance: WorkflowConfigProvider?

    public init(
        locator: ApplicationSupportLocator,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        writer: any AtomicFileWriting = FileManagerAtomicFileWriter(),
        loggerCategory: String = "runtime",
        workflowConfigEnvironment: WorkflowConfigPathEnvironment = .live()
    ) {
        self.locator = locator
        processEnvironment = environment
        environmentFileURL = locator.url.appending(path: ".env")
        self.workflowConfigEnvironment = workflowConfigEnvironment
        logger = SlateSyncLogger(category: loggerCategory)
        let machineSettingsStore = MachineSettingsStore(locator: locator, writer: writer)
        // The composition layer injects the resolved location; the resolver is
        // the only place that names the file.
        let globalConfigStore = GlobalConfigStore(
            fileURL: ConfigPathResolver.globalConfigFileURL(applicationSupportRoot: locator.url),
            writer: writer
        )
        // Provider secrets use files; project encryption owns its separate Keychain backend.
        self.machineSettingsStore = machineSettingsStore
        self.globalConfigStore = globalConfigStore
        self.credentialStore = EncryptedFileCredentialStore(locator: locator, writer: writer)

        self.snapshot = SlateSyncRuntimeSnapshot(
            isBootstrapped: false,
            configuration: ConfigurationResolver.resolveAll(
                applicationSupportRoot: locator.url
            ),
            machineSettings: MachineSettings(),
            globalConfigVersion: GlobalConfigStore.currentVersion,
            environmentFileLoaded: false,
        )
    }

    public init(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        writer: any AtomicFileWriting = FileManagerAtomicFileWriter(),
        loggerCategory: String = "runtime"
    ) throws {
        try self.init(
            locator: ApplicationSupportLocator(environment: environment),
            environment: environment,
            writer: writer,
            loggerCategory: loggerCategory
        )
    }

    public func currentSnapshot() -> SlateSyncRuntimeSnapshot {
        snapshot
    }

    /// Bootstrap is deliberately non-throwing: an unreadable non-secret store
    /// falls back to defaults so the App can still open. No legacy secrets are imported.
    @discardableResult
    public func bootstrap() async -> SlateSyncRuntimeSnapshot {
        if snapshot.isBootstrapped {
            return snapshot
        }

        let machineSettings = (try? await machineSettingsStore.load()) ?? MachineSettings()
        let globalSnapshot = (try? await globalConfigStore.load()) ?? GlobalConfigSnapshot()
        let environment = loadEnvironment()
        let resolvedConfiguration = ConfigurationResolver.resolveAll(
            globalSettings: globalSnapshot.values,
            processEnvironment: processEnvironment,
            envFile: environment.values,
            legacySettings: machineSettings,
            applicationSupportRoot: locator.url
        )

        // The workflow config path freezes the startup-effective setting.
        // refreshConfiguration re-runs bootstrap after every save, so the
        // provider is built only once and later changes wait for a restart.
        var effectiveWorkflowConfigPath = snapshot.workflowConfigPath
        if workflowConfigProviderInstance == nil {
            let workflowConfigURL = ConfigPathResolver.workflowConfigURL(
                configured: resolvedConfiguration.values[.slateSyncConfigPath],
                environment: workflowConfigEnvironment
            )
            workflowConfigProviderInstance = WorkflowConfigProvider(url: workflowConfigURL)
            effectiveWorkflowConfigPath = workflowConfigURL.standardizedFileURL.path
        }

        // Existing secrets are deliberately not imported. Users re-enter keys
        // in the encrypted-file store, without triggering legacy authorization.

        snapshot = SlateSyncRuntimeSnapshot(
            isBootstrapped: true,
            configuration: resolvedConfiguration,
            machineSettings: machineSettings,
            globalConfigVersion: globalSnapshot.version,
            environmentFileLoaded: environment.loaded,
            workflowConfigPath: effectiveWorkflowConfigPath,
            lastError: environment.error
        )
        logger.info(
            "native runtime bootstrapped",
            metadata: [
                "globalConfigVersion": .number(Double(globalSnapshot.version)),
                "resolvedSettingCount": .number(Double(resolvedConfiguration.values.values.count)),
                "environmentFileLoaded": .boolean(environment.loaded),
            ]
        )
        return snapshot
    }

    /// Re-resolves non-secret configuration after the Settings façade commits
    /// an atomic GlobalConfigStore snapshot; no credential import is performed.
    public func refreshConfiguration() async -> SlateSyncRuntimeSnapshot {
        snapshot = SlateSyncRuntimeSnapshot(
            isBootstrapped: false,
            configuration: snapshot.configuration,
            machineSettings: snapshot.machineSettings,
            globalConfigVersion: snapshot.globalConfigVersion,
            environmentFileLoaded: snapshot.environmentFileLoaded,
            workflowConfigPath: snapshot.workflowConfigPath,
            lastError: snapshot.lastError
        )
        return await bootstrap()
    }

    /// The process-wide workflow config provider. Its URL was resolved from
    /// the startup-effective setting; calling this before the first bootstrap
    /// resolves and creates it immediately.
    public func workflowConfigProvider() async -> WorkflowConfigProvider {
        if let workflowConfigProviderInstance { return workflowConfigProviderInstance }
        await bootstrap()
        if let workflowConfigProviderInstance { return workflowConfigProviderInstance }
        return WorkflowConfigProvider(
            url: ConfigPathResolver.workflowConfigURL(
                configured: snapshot.configuration.values[.slateSyncConfigPath],
                environment: workflowConfigEnvironment
            )
        )
    }

    public func value(for key: String) async -> String? {
        _ = await bootstrap()
        guard let typedKey = GlobalSettingKey(rawValue: key) else { return nil }
        return snapshot.configuration.values[typedKey]
    }

    /// Resolve an editor snapshot with the same environment/legacy precedence
    /// as a save, without changing the persisted or running configuration.
    public func resolveSettingsDraft(_ values: GlobalSettingValues) async -> GlobalSettingValues {
        _ = await bootstrap()
        return ConfigurationResolver.resolveAll(
            globalSettings: values,
            processEnvironment: processEnvironment,
            envFile: loadEnvironment().values,
            legacySettings: snapshot.machineSettings,
            applicationSupportRoot: locator.url
        ).values
    }

    public func setValue(_ value: String?, for key: String) async throws {
        _ = await bootstrap()
        guard GlobalSettingKey(rawValue: key) != nil else {
            throw SlateSyncError(code: "GLOBAL_CONFIG_INVALID", message: "不支持的全局配置项")
        }
        let patch = try GlobalSettingsPatch(rawValues: [key: value])
        let globalSnapshot = try await globalConfigStore.save(patch)
        let environment = loadEnvironment()
        let resolvedConfiguration = ConfigurationResolver.resolveAll(
            globalSettings: globalSnapshot.values,
            processEnvironment: processEnvironment,
            envFile: environment.values,
            legacySettings: snapshot.machineSettings,
            applicationSupportRoot: locator.url
        )
        snapshot = SlateSyncRuntimeSnapshot(
            isBootstrapped: true,
            configuration: resolvedConfiguration,
            machineSettings: snapshot.machineSettings,
            globalConfigVersion: globalSnapshot.version,
            environmentFileLoaded: environment.loaded,
            workflowConfigPath: snapshot.workflowConfigPath,
            lastError: environment.error
        )
    }

    public func providerKey(for providerID: String) async throws -> String? {
        try await credentialStore.value(providerID: providerID)
    }

    public func setProviderKey(_ value: String?, for providerID: String) async throws {
        try await credentialStore.setValue(value, providerID: providerID)
    }

    private func loadEnvironment() -> EnvironmentLoad {
        do {
            return EnvironmentLoad(
                values: try EnvironmentFileLoader.load(from: environmentFileURL),
                loaded: FileManager.default.fileExists(atPath: environmentFileURL.path),
                error: nil
            )
        } catch {
            logger.warning(
                "environment file ignored",
                metadata: ["path": .string(environmentFileURL.path), "errorCode": .string("ENV_INVALID")]
            )
            return EnvironmentLoad(
                values: [:],
                loaded: false,
                error: SlateSyncError(code: "ENV_INVALID", message: "环境配置文件无效，已使用安全回退")
            )
        }
    }


    private struct EnvironmentLoad {
        let values: [String: String]
        let loaded: Bool
        let error: SlateSyncError?
    }
}

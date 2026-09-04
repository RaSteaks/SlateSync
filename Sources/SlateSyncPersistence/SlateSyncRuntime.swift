import Foundation
import SlateSyncDomain

public enum SlateSyncRuntimeMigrationStatus: String, Codable, Hashable, Sendable {
    case notRun
    case sourceMissing
    case noCredentials
    case migrated
    case failed
}

/// Secret-free migration state suitable for SwiftUI and diagnostics. The
/// source path is useful for remediation, while credential bytes never enter
/// this snapshot.
public struct SlateSyncRuntimeMigrationState: Codable, Hashable, Sendable {
    public let status: SlateSyncRuntimeMigrationStatus
    public let sourceURL: URL
    public let verifiedProviderIDs: [String]
    public let writtenProviderIDs: [String]
    public let errorCode: String?
    public let errorMessage: String?

    public init(
        status: SlateSyncRuntimeMigrationStatus,
        sourceURL: URL,
        verifiedProviderIDs: [String] = [],
        writtenProviderIDs: [String] = [],
        errorCode: String? = nil,
        errorMessage: String? = nil
    ) {
        self.status = status
        self.sourceURL = sourceURL
        self.verifiedProviderIDs = verifiedProviderIDs
        self.writtenProviderIDs = writtenProviderIDs
        self.errorCode = errorCode
        self.errorMessage = errorMessage
    }
}

public struct SlateSyncRuntimeSnapshot: Codable, Hashable, Sendable {
    public let isBootstrapped: Bool
    public let configuration: ResolvedConfiguration
    public let machineSettings: MachineSettings
    public let globalConfigVersion: Int
    public let environmentFileLoaded: Bool
    public let migration: SlateSyncRuntimeMigrationState
    public let lastError: SlateSyncError?

    public init(
        isBootstrapped: Bool,
        configuration: ResolvedConfiguration,
        machineSettings: MachineSettings,
        globalConfigVersion: Int,
        environmentFileLoaded: Bool,
        migration: SlateSyncRuntimeMigrationState,
        lastError: SlateSyncError? = nil
    ) {
        self.isBootstrapped = isBootstrapped
        self.configuration = configuration
        self.machineSettings = machineSettings
        self.globalConfigVersion = globalConfigVersion
        self.environmentFileLoaded = environmentFileLoaded
        self.migration = migration
        self.lastError = lastError
    }
}

/// Native startup composition root for machine settings, global overrides,
/// environment fallback, and legacy provider-key migration. The actor keeps
/// the snapshot mutation single-writer while the injected stores remain
/// independently testable.
public actor SlateSyncRuntime: SettingsServing {
    public nonisolated let locator: ApplicationSupportLocator
    public nonisolated let machineSettingsStore: MachineSettingsStore
    public nonisolated let globalConfigStore: GlobalConfigStore
    public nonisolated let keychainStore: KeychainCredentialStore

    private let processEnvironment: [String: String]
    private let environmentFileURL: URL
    private let legacyCredentialURL: URL
    private let logger: SlateSyncLogger
    private var snapshot: SlateSyncRuntimeSnapshot

    public init(
        locator: ApplicationSupportLocator,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        writer: any AtomicFileWriting = FileManagerAtomicFileWriter(),
        keychainBackend: (any KeychainBackend)? = nil,
        loggerCategory: String = "runtime"
    ) {
        self.locator = locator
        processEnvironment = environment
        environmentFileURL = locator.url.appending(path: ".env")
        legacyCredentialURL = locator.url.appending(path: "provider-keys.json")
        logger = SlateSyncLogger(category: loggerCategory)
        let machineSettingsStore = MachineSettingsStore(locator: locator, writer: writer)
        let globalConfigStore = GlobalConfigStore(locator: locator, writer: writer)
        let backend = keychainBackend ?? SecurityKeychainBackend(
            coordinationDirectory: locator.url.appending(
                path: ".locks",
                directoryHint: .isDirectory
            )
        )
        let keychainStore = KeychainCredentialStore(
            backend: backend,
            service: KeychainCredentialStore.service
        )
        self.machineSettingsStore = machineSettingsStore
        self.globalConfigStore = globalConfigStore
        self.keychainStore = keychainStore

        let migration = SlateSyncRuntimeMigrationState(
            status: .notRun,
            sourceURL: legacyCredentialURL
        )
        self.snapshot = SlateSyncRuntimeSnapshot(
            isBootstrapped: false,
            configuration: ConfigurationResolver.resolveAll(
                applicationSupportRoot: locator.url
            ),
            machineSettings: MachineSettings(),
            globalConfigVersion: GlobalConfigStore.currentVersion,
            environmentFileLoaded: false,
            migration: migration
        )
    }

    public init(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        writer: any AtomicFileWriting = FileManagerAtomicFileWriter(),
        keychainBackend: (any KeychainBackend)? = nil,
        loggerCategory: String = "runtime"
    ) throws {
        try self.init(
            locator: ApplicationSupportLocator(environment: environment),
            environment: environment,
            writer: writer,
            keychainBackend: keychainBackend,
            loggerCategory: loggerCategory
        )
    }

    public func currentSnapshot() -> SlateSyncRuntimeSnapshot {
        snapshot
    }

    /// Bootstrap is deliberately non-throwing: an unreadable non-secret store
    /// falls back to defaults, and a failed legacy secret migration is retained
    /// as a retryable status so the App can still open.
    @discardableResult
    public func bootstrap(
        retryFailedMigration: Bool = false
    ) async -> SlateSyncRuntimeSnapshot {
        if snapshot.isBootstrapped && !retryFailedMigration {
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

        var migration = snapshot.migration
        if !snapshot.isBootstrapped || retryFailedMigration || migration.status == .notRun {
            migration = await migrateLegacyCredentials()
        }

        snapshot = SlateSyncRuntimeSnapshot(
            isBootstrapped: true,
            configuration: resolvedConfiguration,
            machineSettings: machineSettings,
            globalConfigVersion: globalSnapshot.version,
            environmentFileLoaded: environment.loaded,
            migration: migration,
            lastError: environment.error
        )
        logger.info(
            "native runtime bootstrapped",
            metadata: [
                "globalConfigVersion": .number(Double(globalSnapshot.version)),
                "resolvedSettingCount": .number(Double(resolvedConfiguration.values.values.count)),
                "environmentFileLoaded": .boolean(environment.loaded),
                "migrationStatus": .string(migration.status.rawValue),
            ]
        )
        return snapshot
    }

    public func retryLegacyMigration() async -> SlateSyncRuntimeSnapshot {
        await bootstrap(retryFailedMigration: true)
    }

    public func value(for key: String) async -> String? {
        _ = await bootstrap()
        guard let typedKey = GlobalSettingKey(rawValue: key) else { return nil }
        return snapshot.configuration.values[typedKey]
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
            migration: snapshot.migration,
            lastError: environment.error
        )
    }

    public func providerKey(for providerID: String) async throws -> String? {
        try await keychainStore.value(providerID: providerID)
    }

    public func setProviderKey(_ value: String?, for providerID: String) async throws {
        try await keychainStore.setValue(value, providerID: providerID)
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

    private func migrateLegacyCredentials() async -> SlateSyncRuntimeMigrationState {
        do {
            let report = try await keychainStore.migrateLegacyCredentials(at: legacyCredentialURL)
            return SlateSyncRuntimeMigrationState(
                status: SlateSyncRuntimeMigrationStatus(report.status),
                sourceURL: report.sourceURL,
                verifiedProviderIDs: report.verifiedProviderIDs,
                writtenProviderIDs: report.writtenProviderIDs
            )
        } catch is CancellationError {
            return SlateSyncRuntimeMigrationState(
                status: .failed,
                sourceURL: legacyCredentialURL,
                errorCode: "CANCELLED",
                errorMessage: "旧凭据迁移已取消，源文件已保留"
            )
        } catch let error as SlateSyncError {
            logger.warning(
                "legacy credential migration failed",
                metadata: [
                    "path": .string(legacyCredentialURL.path),
                    "errorCode": .string(error.code),
                ]
            )
            return SlateSyncRuntimeMigrationState(
                status: .failed,
                sourceURL: legacyCredentialURL,
                errorCode: error.code,
                errorMessage: "旧凭据迁移失败，源文件已保留，可重试"
            )
        } catch {
            logger.warning(
                "legacy credential migration failed",
                metadata: [
                    "path": .string(legacyCredentialURL.path),
                    "errorCode": .string("KEYCHAIN_MIGRATION_FAILED"),
                ]
            )
            return SlateSyncRuntimeMigrationState(
                status: .failed,
                sourceURL: legacyCredentialURL,
                errorCode: "KEYCHAIN_MIGRATION_FAILED",
                errorMessage: "旧凭据迁移失败，源文件已保留，可重试"
            )
        }
    }

    private struct EnvironmentLoad {
        let values: [String: String]
        let loaded: Bool
        let error: SlateSyncError?
    }
}

private extension SlateSyncRuntimeMigrationStatus {
    init(_ status: CredentialMigrationStatus) {
        switch status {
        case .sourceMissing: self = .sourceMissing
        case .noCredentials: self = .noCredentials
        case .migrated: self = .migrated
        }
    }
}

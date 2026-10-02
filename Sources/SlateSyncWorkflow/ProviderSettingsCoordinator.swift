import Foundation
import SlateSyncDomain
import SlateSyncMedia
import SlateSyncPersistence

/// Provider configuration, credentials, proofs, and their HTTP owners share one
/// operation boundary. The app facade delegates here without owning their
/// mutation state, while recognition retains its separate lifecycle owner.
actor ProviderSettingsCoordinator {
    private let runtime: SlateSyncRuntime
    private let logs: LocalLogStore
    private let recognitionRuntime: RecognitionRuntimeLifecycle
    private let allowsProviderOperations: Bool
    private let providerTransportFactory: @Sendable () -> any ProviderHTTPTransporting
    private let draftProviderTransportFactory: @Sendable (any ProviderCredentialReading) -> any ProviderHTTPTransporting
    private var sharedRegistry: ProviderRegistry?
    private var registryBuild: Task<ProviderRegistry, Error>?
    private var settingsProviders: SettingsProviderRuntime?
    private var settingsBuild: Task<SettingsProviderRuntime, Error>?
    private var settingsReset: Task<Void, Never>?
    private var settingsGeneration = 0
    private var mutatingConfiguration = false

    private struct SettingsProviderRuntime {
        let registry: ProviderRegistry
        let transport: any ProviderHTTPTransporting
        let discovery: ModelDiscoveryService
        let probe: ModelCapabilityProbeService
    }

    init(
        runtime: SlateSyncRuntime, logs: LocalLogStore, recognitionRuntime: RecognitionRuntimeLifecycle,
        allowsProviderOperations: Bool,
        providerTransportFactory: @escaping @Sendable () -> any ProviderHTTPTransporting,
        draftProviderTransportFactory:
            @escaping @Sendable (any ProviderCredentialReading) -> any ProviderHTTPTransporting
    ) {
        self.runtime = runtime
        self.logs = logs
        self.recognitionRuntime = recognitionRuntime
        self.allowsProviderOperations = allowsProviderOperations
        self.providerTransportFactory = providerTransportFactory
        self.draftProviderTransportFactory = draftProviderTransportFactory
    }

    func globalSettings() async throws -> GlobalSettingsProjection { try await globalSettings(restartRequired: false) }

    private func requireProviderOperations() throws {
        guard allowsProviderOperations else {
            throw SlateSyncError(code: "ISOLATED_OPERATION", message: "隔离验收环境已禁用外部服务", retryable: false)
        }
        guard !mutatingConfiguration else { throw CancellationError() }
    }

    func drain() async { await resetSettingsProviders() }

    private func globalSettings(restartRequired: Bool) async throws -> GlobalSettingsProjection {
        let runtimeSnapshot = await runtime.bootstrap()
        let config = try await runtime.globalConfigStore.load()
        let registry = try await modelRegistry()
        // Publish only availability; decrypted file contents never enter UI projections.
        let credentialStatuses = try await runtime.credentialStore.statuses(
            for: Array(Set(ProviderCatalog.definitions.map(\.id) + config.customProviders.map(\.id)))
        )
        let providers = await registry.providerSummaries(credentialStatuses: credentialStatuses)
        let credentialIDs = Set(credentialStatuses.filter { $0.value == .configured }.map(\.key))
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
                workflowConfigPath: runtimeSnapshot.workflowConfigPath.isEmpty
                    ? nil
                    : runtimeSnapshot.workflowConfigPath
            ),
            restartRequired: restartRequired,
            credentialStatuses: credentialStatuses
        )
    }

    func saveGlobalSettings(
        values: GlobalSettingValues,
        customProviders: [CustomProviderConfiguration]
    ) async throws -> GlobalSettingsProjection {
        return try await mutateConfiguration { owner in

            // Old save-global-settings compared the effective SLATESYNC_CONFIG_PATH
            // before and after the write: the workflow provider is constructed once
            // at startup, so a changed path cannot hot-switch and needs a relaunch.
            let previousPath = await owner.runtime.currentSnapshot().configuration.values[.slateSyncConfigPath] ?? ""
            let saved = try await owner.runtime.globalConfigStore.save(
                values: values.values, customProviders: customProviders)
            let snapshot = await owner.runtime.refreshConfiguration()
            try await owner.modelRegistry().replace(
                settings: snapshot.configuration.values, customProviders: saved.customProviders,
                builtinCapabilities: saved.builtinCapabilities)
            await owner.record(.info, category: "settings", event: "saved", message: "全局设置已保存")
            let nextPath = snapshot.configuration.values[.slateSyncConfigPath] ?? ""
            return try await owner.globalSettings(restartRequired: previousPath != nextPath)
        }
    }

    func setProviderCredential(_ value: String?, providerID: String) async throws {
        return try await mutateConfiguration { owner in

            // A changed secret is part of a custom provider's probe identity.
            // Rotate its revision so persisted model proofs cannot be reused.
            let config = try await owner.runtime.globalConfigStore.load()
            var values = config.values.values
            if values[.defaultProviderID] == providerID {
                values.removeValue(forKey: .defaultProviderID)
                values.removeValue(forKey: .defaultModelID)
            }
            if let rawChain = values[.recognitionFailoverChain],
                let chain = try? ProviderModelSelection.decodeAndValidateChain(rawChain)
            {
                values[.recognitionFailoverChain] = try ProviderModelSelection.encodeChain(
                    chain.filter { $0.providerID != providerID }
                )
            }
            var providers = config.customProviders
            if let index = config.customProviders.firstIndex(where: { $0.id == providerID }) {
                let old = config.customProviders[index]
                providers[index] = CustomProviderConfiguration(
                    id: old.id, name: old.name, label: old.label, baseUrl: old.baseUrl,
                    transport: old.transport, jsonMode: old.jsonMode,
                    imageDetail: old.imageDetail, manualModelIds: old.manualModelIds,
                    revision: old.revision + 1, capabilityCache: nil,
                    notes: old.notes, sourcePresetID: old.sourcePresetID
                )
            }
            if values != config.values.values || providers != config.customProviders {
                _ = try await owner.runtime.globalConfigStore.save(values: values, customProviders: providers)
                let refreshed = await owner.runtime.refreshConfiguration()
                await owner.sharedRegistry?.replace(
                    settings: refreshed.configuration.values, customProviders: providers)
            }
            try await owner.runtime.globalConfigStore.invalidateBuiltinCapabilities(providerID: providerID)
            await owner.sharedRegistry?.invalidate(providerID: providerID)
            // Invalidate durable proofs before an encrypted-file write. A failed or
            // interrupted file operation may cost a re-probe but cannot leave
            // a changed secret paired with stale persisted verification.
            try await owner.runtime.setProviderKey(value, for: providerID)
            await owner.record(.info, category: "settings", event: "credential-updated", message: "Provider 凭据状态已更新")
        }
    }

    /// Invalidate proofs before resetting secrets, just as individual key edits
    /// do. Interrupted reset cannot leave a new key with an old verified route.
    func resetLocalProviderCredentials() async throws {
        return try await mutateConfiguration { owner in

            let config = try await owner.runtime.globalConfigStore.load()
            var values = config.values.values
            values.removeValue(forKey: .defaultProviderID)
            values.removeValue(forKey: .defaultModelID)
            values[.recognitionFailoverChain] = "[]"
            var providers = config.customProviders
            for index in providers.indices {
                let old = providers[index]
                providers[index] = CustomProviderConfiguration(
                    id: old.id, name: old.name, label: old.label, baseUrl: old.baseUrl,
                    transport: old.transport, jsonMode: old.jsonMode, imageDetail: old.imageDetail,
                    manualModelIds: old.manualModelIds, revision: old.revision + 1,
                    capabilityCache: nil, notes: old.notes, sourcePresetID: old.sourcePresetID
                )
            }
            _ = try await owner.runtime.globalConfigStore.save(values: values, customProviders: providers)
            for definition in ProviderCatalog.definitions {
                try await owner.runtime.globalConfigStore.invalidateBuiltinCapabilities(providerID: definition.id)
            }
            // A credential reset changes identity even when the endpoint is the
            // same; route-only replace would retain in-memory verified models.
            await owner.sharedRegistry?.invalidate()
            try await owner.runtime.credentialStore.reset()
            let refreshed = await owner.runtime.refreshConfiguration()
            await owner.sharedRegistry?.replace(settings: refreshed.configuration.values, customProviders: providers)
        }
    }

    /// Draft credentials live only for this request; canceling the editor writes nothing.
    func discoverDraftModelIDs(baseURL: String, apiKey: String, savedProviderID: String?) async throws -> [String] {
        try requireProviderOperations()
        // Normalize once, before consulting saved credentials or creating a transport.
        let descriptor = try DraftModelDiscovery.descriptor(baseURL: baseURL)
        var key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if apiKey.isEmpty, let savedProviderID {
            key = try await runtime.credentialStore.credential(for: savedProviderID) ?? ""
        }
        guard !key.isEmpty else { throw SlateSyncError(code: "CREDENTIAL_EMPTY", message: "请先填写 API Key") }
        let transport = draftProviderTransportFactory(DraftProviderCredential(value: key))
        do {
            let ids = try await DraftModelDiscovery.fetch(provider: descriptor, transport: transport)
            await transport.close()
            return ids
        } catch {
            await transport.close()
            throw error
        }
    }

    func discoverModels(
        providerID: String,
        forceRefresh: Bool
    ) async throws -> ModelDiscoveryResult {
        try requireProviderOperations()
        return try await settingsProviderRuntime().discovery.discover(
            providerID: providerID,
            forceRefresh: forceRefresh
        )
    }

    func probeModels(
        providerID: String,
        modelIDs: [String],
        progress: @escaping @Sendable (ModelProbeProgress) -> Void
    ) async throws -> ModelProbeResult {
        try requireProviderOperations()
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

    func cancelModelProbe(providerID: String) async {
        _ = await settingsProviders?.probe.cancel(providerID: providerID)
        // Reset also cancels an in-flight discovery transport. Provider edit
        // and delete therefore share one bounded drain path.
        await resetSettingsProviders()
    }

    private func settingsProviderRuntime() async throws -> SettingsProviderRuntime {
        guard settingsReset == nil else { throw CancellationError() }
        if let settingsProviders { return settingsProviders }
        let generation = settingsGeneration
        let build: Task<SettingsProviderRuntime, Error>
        if let settingsBuild {
            build = settingsBuild
        } else {
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
        let registry = try await modelRegistry()
        let transport = providerTransportFactory()
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
            },
            saveBuiltin: { [runtime] proof in
                try await runtime.globalConfigStore.saveBuiltinCapabilities(proof)
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
        if let settingsReset {
            await settingsReset.value
            return
        }
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
        await value.transport.close()
    }

    private func persistProbeResults(
        providerID: String,
        revision: Int,
        results: [ModelCapabilityProbeResult]
    ) async throws {
        let config = try await runtime.globalConfigStore.load()
        guard
            let index = config.customProviders.firstIndex(where: {
                $0.id == providerID && $0.revision == revision
            })
        else { return }
        let original = config.customProviders[index]
        var cache = original.capabilityCache ?? [:]
        for result in results {
            cache[result.model] = CustomProviderCapabilityVerification(
                status: result.capabilityStatus,
                revision: revision,
                checkedAt: result.checkedAt,
                transport: result.transport,
                capabilitySource: "synthetic-image-probe",
                message: result.message,
                jsonMode: result.jsonMode
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
            capabilityCache: cache,
            notes: original.notes,
            sourcePresetID: original.sourcePresetID
        )
        _ = try await runtime.globalConfigStore.save(
            values: config.values.values,
            customProviders: providers
        )
        _ = await runtime.refreshConfiguration()
        // Publish into the registry already retained by active coordinators;
        // do not cancel another window's recognition to refresh capabilities.
        try await modelRegistry().refreshCapabilities(providers[index])
    }

    /// Join concurrent first-use requests so Settings and recognition cannot
    /// construct separate catalogs while configuration I/O is suspended.
    func modelRegistry() async throws -> ProviderRegistry {
        if let sharedRegistry { return sharedRegistry }
        let build: Task<ProviderRegistry, Error>
        if let registryBuild {
            build = registryBuild
        } else {
            build = Task { [runtime] in
                let snapshot = await runtime.bootstrap()
                let config = try await runtime.globalConfigStore.load()
                return ProviderRegistry(
                    settings: snapshot.configuration.values,
                    customProviders: config.customProviders, credentials: runtime.credentialStore,
                    builtinCapabilities: config.builtinCapabilities)
            }
            registryBuild = build
        }
        do {
            let registry = try await build.value
            sharedRegistry = registry
            registryBuild = nil
            return registry
        } catch {
            registryBuild = nil
            throw error
        }
    }

    private func mutateConfiguration<Value: Sendable>(
        _ action: @Sendable (isolated ProviderSettingsCoordinator) async throws -> Value
    ) async throws -> Value {
        guard !mutatingConfiguration else {
            throw SlateSyncError(code: "SETTINGS_BUSY", message: "设置正在保存，请稍后重试", retryable: true)
        }
        mutatingConfiguration = true
        await recognitionRuntime.suspend()
        await resetSettingsProviders()
        do {
            let result = try await action(self)
            await recognitionRuntime.resume()
            mutatingConfiguration = false
            return result
        } catch {
            await recognitionRuntime.resume()
            mutatingConfiguration = false
            throw error
        }
    }

    private func record(_ severity: ProductLogSeverity, category: String, event: String, message: String) async {
        await logs.append(
            ProductPrivacy.log(
                .init(
                    timestamp: Date(), severity: severity,
                    category: category, event: event, message: message)))
    }
}

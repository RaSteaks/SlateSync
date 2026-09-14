import Foundation
import Observation
import SlateSyncDomain

/// Result of the Provider panel's two persistence transactions. Keeping the
/// two flags separate lets the UI explain a successful ordinary-config write
/// when a subsequent Keychain write fails.
public struct BuiltinProviderSaveResult: Hashable, Sendable {
    public let configurationSaved: Bool
    public let credentialUpdateRequested: Bool
    public let credentialSaved: Bool
    public let message: String
    public let error: SlateSyncError?

    public var isComplete: Bool {
        configurationSaved && (!credentialUpdateRequested || credentialSaved)
    }

    public init(
        configurationSaved: Bool,
        credentialUpdateRequested: Bool,
        credentialSaved: Bool,
        message: String,
        error: SlateSyncError? = nil
    ) {
        self.configurationSaved = configurationSaved
        self.credentialUpdateRequested = credentialUpdateRequested
        self.credentialSaved = credentialSaved
        self.message = message
        self.error = error
    }
}

/// Global settings keeps editing and live snapshots separate. Provider key
/// bytes are accepted only as method arguments and are never published by this
/// observable model.
@MainActor @Observable
public final class GlobalSettingsModel {
    public private(set) var live: GlobalSettingsProjection?
    public private(set) var operation: OperationState = .idle
    /// Shared windows observe this monotonic publication token and reload the
    /// workflow-owned Provider/model projection after Settings changes.
    public private(set) var revision = 0
    public var draft = GlobalSettingValues()
    public var customProviders: [CustomProviderConfiguration] = []
    public private(set) var discoveryResults: [String: ModelDiscoveryResult] = [:]
    public private(set) var providerOperations: [String: OperationState] = [:]
    public private(set) var probeProgress: [String: ModelProbeProgress] = [:]
    /// Tracks probe ownership separately from generic provider operations so
    /// the UI can expose cancellation before the first progress callback.
    public private(set) var probingProviderIDs: Set<String> = []
    private let service: any GlobalSettingsWorkflowServing
    private var acceptsOperations = true
    private var activeCalls = 0
    private var drainWaiters: [CheckedContinuation<Void, Never>] = []
    private var providerRequests: [String: UUID] = [:]

    public init(service: any GlobalSettingsWorkflowServing) { self.service = service }

    public func load() async {
        guard beginOperation() else { return }
        defer { endOperation() }
        // Reopening Settings must not replace an existing unsaved draft.
        guard live == nil, !operation.isRunning else { return }
        operation = .running(label: "正在读取全局设置…")
        do {
            let value = try await service.globalSettings()
            publish(value)
            operation = .idle
        } catch {
            operation = .failed(ProductPrivacy.error(error))
        }
    }

    public func value(_ key: GlobalSettingKey) -> String { draft[key] ?? "" }
    public func setValue(_ value: String, for key: GlobalSettingKey) { draft[key] = value }

    public func save() async {
        guard beginOperation() else { return }
        defer { endOperation() }
        guard !operation.isRunning else { return }
        operation = .running(label: "正在保存全局设置…")
        let values = draft
        let providers = customProviders
        do {
            // Store loading remains deliberately tolerant for legacy config.
            // Explicit UI saves validate every entered field before any write.
            for (key, value) in values.values {
                _ = try GlobalSettingsValidator.normalizedPatchValue(value, for: key)
            }
            let saved = try await service.saveGlobalSettings(values: values, customProviders: providers)
            if draft == values, customProviders == providers { publish(saved) }
            else {
                live = saved
                revision += 1
            }
            // Frozen old save status (app.js): a changed workflow config path
            // cannot hot-switch the startup provider, so the save response
            // announces that a relaunch is needed.
            operation = saved.restartRequired
                ? .succeeded(message: "已保存；工作流路径下次启动生效。")
                : .succeeded(message: "全局设置已保存")
        } catch {
            operation = .failed(ProductPrivacy.error(error))
        }
    }

    public func storeCredential(_ value: String?, providerID: String) async throws {
        guard beginOperation() else { throw SlateSyncError(code: "SETTINGS_CLOSING", message: "设置正在关闭，请稍后重试") }
        defer { endOperation() }
        try await service.setProviderCredential(value, providerID: providerID)
        // Keychain edits refresh configured status without discarding unrelated
        // typed settings or an unsaved custom Provider revision.
        refreshPreservingDraft(try await service.globalSettings())
    }

    /// Saves only the fields owned by one built-in Provider. The current live
    /// snapshot is used as the base so an independent settings draft is not
    /// accidentally cleared when the small Provider sheet saves itself.
    public func saveBuiltinProviderConfiguration(
        providerID: String,
        values: [GlobalSettingKey: String?],
        apiKey: String?
    ) async -> BuiltinProviderSaveResult {
        guard beginOperation() else {
            let error = SlateSyncError(code: "SETTINGS_CLOSING", message: "设置正在关闭，请稍后重试")
            return .init(
                configurationSaved: false,
                credentialUpdateRequested: apiKey != nil,
                credentialSaved: false,
                message: error.message,
                error: error
            )
        }
        defer { endOperation() }
        operation = .running(label: "正在保存 Provider 配置…")

        let cleanedKey: String?
        if let apiKey {
            let value = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty else {
                let error = SlateSyncError(code: "PROVIDER_KEY_INVALID", message: "API Key 不能是纯空白；留空表示保留当前 Key")
                operation = .failed(error)
                return .init(
                    configurationSaved: false,
                    credentialUpdateRequested: true,
                    credentialSaved: false,
                    message: error.message,
                    error: error
                )
            }
            cleanedKey = value
        } else {
            cleanedKey = nil
        }

        var candidate = live?.values ?? draft
        let baseURLKeys: Set<GlobalSettingKey> = [
            .openAIBaseUrl,
            .openRouterBaseUrl,
            .tokenPlanBaseUrl,
            .dashScopeBaseUrl,
            .openAICompatibleBaseUrl,
        ]
        do {
            for (key, rawValue) in values {
                guard let rawValue else {
                    candidate[key] = nil
                    continue
                }
                let normalized = try GlobalSettingsValidator.normalizedPatchValue(rawValue, for: key)
                if normalized?.isEmpty == true {
                    guard !baseURLKeys.contains(key) else {
                        throw SlateSyncError(code: "PROVIDER_URL", message: "API 基础地址不能为空；请填写地址或恢复默认地址")
                    }
                    candidate[key] = nil
                } else {
                    candidate[key] = normalized
                }
            }
        } catch {
            let sanitized = ProductPrivacy.error(error)
            operation = .failed(sanitized)
            return .init(
                configurationSaved: false,
                credentialUpdateRequested: apiKey != nil,
                credentialSaved: false,
                message: "配置未保存：\(sanitized.message)",
                error: sanitized
            )
        }

        let saved: GlobalSettingsProjection
        do {
            saved = try await service.saveGlobalSettings(values: candidate, customProviders: customProviders)
            // A changed Base URL or protocol invalidates the old discovery and
            // probe result immediately; the workflow façade also resets its
            // Provider runtime before committing the ordinary configuration.
            providerRequests[providerID] = nil
            discoveryResults[providerID] = nil
            providerOperations[providerID] = nil
            probeProgress[providerID] = nil
            probingProviderIDs.remove(providerID)
            refreshPreservingDraft(saved)
        } catch {
            let sanitized = ProductPrivacy.error(error)
            operation = .failed(sanitized)
            return .init(
                configurationSaved: false,
                credentialUpdateRequested: apiKey != nil,
                credentialSaved: false,
                message: "配置未保存：\(sanitized.message)",
                error: sanitized
            )
        }

        guard let cleanedKey else {
            operation = .succeeded(message: "Provider 配置已保存；未修改当前 API Key")
            return .init(
                configurationSaved: true,
                credentialUpdateRequested: false,
                credentialSaved: false,
                message: "Provider 配置已保存；未修改当前 API Key"
            )
        }

        do {
            try await service.setProviderCredential(cleanedKey, providerID: providerID)
            // The write API intentionally returns no secret. Refresh only the
            // secret-free projection so status changes are visible in both the
            // list and this still-open configuration panel.
            if let refreshed = try? await service.globalSettings() {
                refreshPreservingDraft(refreshed)
            }
            operation = .succeeded(message: "Provider 配置与 API Key 已保存")
            return .init(
                configurationSaved: true,
                credentialUpdateRequested: true,
                credentialSaved: true,
                message: "Provider 配置与 API Key 已保存"
            )
        } catch {
            let sanitized = ProductPrivacy.error(error)
            operation = .failed(sanitized)
            return .init(
                configurationSaved: true,
                credentialUpdateRequested: true,
                credentialSaved: false,
                message: "普通配置已保存，但 API Key 保存失败：\(sanitized.message)",
                error: sanitized
            )
        }
    }

    /// Key deletion is independent from the blank API Key field. A dedicated
    /// call prevents an accidental empty submit from destroying a valid key.
    public func removeProviderCredential(providerID: String) async throws {
        guard beginOperation() else {
            throw SlateSyncError(code: "SETTINGS_CLOSING", message: "设置正在关闭，请稍后重试")
        }
        defer { endOperation() }
        operation = .running(label: "正在删除 API Key…")
        do {
            try await service.setProviderCredential(nil, providerID: providerID)
            if let refreshed = try? await service.globalSettings() {
                refreshPreservingDraft(refreshed)
            }
            discoveryResults[providerID] = nil
            providerOperations[providerID] = nil
            operation = .succeeded(message: "\(providerID) 的 API Key 已删除")
        } catch {
            let sanitized = ProductPrivacy.error(error)
            operation = .failed(sanitized)
            throw sanitized
        }
    }

    public func retryLegacyCredentialMigration() async {
        guard beginOperation() else { return }
        defer { endOperation() }
        operation = .running(label: "正在重试旧凭据迁移…")
        do {
            refreshPreservingDraft(try await service.retryLegacyCredentialMigration())
            operation = .idle
        } catch {
            operation = .failed(ProductPrivacy.error(error))
        }
    }

    public func discover(providerID: String, forceRefresh: Bool = true) async {
        guard beginOperation() else { return }
        defer { endOperation() }
        guard providerOperations[providerID]?.isRunning != true else { return }
        providerOperations[providerID] = .running(label: "正在刷新模型…")
        let request = UUID()
        providerRequests[providerID] = request
        do {
            let result = try await service.discoverModels(
                providerID: providerID,
                forceRefresh: forceRefresh
            )
            guard providerRequests[providerID] == request else { return }
            discoveryResults[providerID] = result
            providerOperations[providerID] = .succeeded(message: "发现 \(result.visionModelCount) 个可用模型")
        } catch {
            guard providerRequests[providerID] == request else { return }
            providerOperations[providerID] = .failed(ProductPrivacy.error(error))
        }
    }

    public func probe(providerID: String, modelIDs: [String]) async {
        guard beginOperation() else { return }
        defer { endOperation() }
        guard providerOperations[providerID]?.isRunning != true else { return }
        providerOperations[providerID] = .running(label: "正在验证视觉能力…")
        probeProgress[providerID] = nil
        probingProviderIDs.insert(providerID)
        let request = UUID()
        providerRequests[providerID] = request
        defer { if providerRequests[providerID] == request { probingProviderIDs.remove(providerID) } }
        do {
            let result = try await service.probeModels(
                providerID: providerID,
                modelIDs: modelIDs
            ) { [weak self] value in
                Task { @MainActor in
                    guard let self, self.providerRequests[providerID] == request,
                          self.providerOperations[providerID]?.isRunning == true else { return }
                    // Callback actor hops can be delivered after a newer
                    // sample. Preserve both count and percentage monotonicity
                    // so a late model result cannot regress the progress UI.
                    if let current = self.probeProgress[providerID] {
                        guard value.completed >= current.completed,
                              value.percent >= current.percent else { return }
                    }
                    self.probeProgress[providerID] = value
                    self.providerOperations[providerID] = .running(
                        label: "已验证 \(value.completed)/\(value.total)"
                    )
                }
            }
            guard providerRequests[providerID] == request else { return }
            providerOperations[providerID] = result.canceled
                ? .canceled
                : .succeeded(message: "模型能力验证完成")
            let refreshed = try await service.globalSettings()
            guard providerRequests[providerID] == request else { return }
            refreshPreservingDraft(refreshed)
        } catch {
            guard providerRequests[providerID] == request else { return }
            providerOperations[providerID] = .failed(ProductPrivacy.error(error))
        }
    }

    public func cancelProbe(providerID: String) async {
        // Cancellation is itself a service call. Count it in the same barrier
        // as probe/save operations so application drain cannot close the
        // workflow while this reset is still crossing actors.
        guard beginOperation() else { return }
        defer { endOperation() }
        guard providerOperations[providerID]?.isRunning == true else { return }
        providerOperations[providerID] = .running(label: "正在取消验证…")
        // A provider edit/removal can supersede this cancellation while the
        // service drains. Retain a unique owner so the late callback cannot
        // recreate operation state that the newer mutation already cleared.
        let cancellation = UUID()
        providerRequests[providerID] = cancellation
        await service.cancelModelProbe(providerID: providerID)
        guard providerRequests[providerID] == cancellation else { return }
        providerRequests[providerID] = nil
        probingProviderIDs.remove(providerID)
        providerOperations[providerID] = .canceled
    }

    @discardableResult
    public func addCustomProvider(name: String, baseURL: String, modelID: String) -> Bool {
        saveCustomProviderDraft(
            existing: nil,
            name: name,
            baseURL: baseURL,
            modelIDs: modelID,
            transport: .chatCompletions,
            jsonMode: .jsonSchema,
            imageDetail: .high
        )
    }

    public func saveCustomProvider(
        existing: CustomProviderConfiguration?,
        name: String,
        baseURL: String,
        modelIDs: String,
        transport: ProviderTransport,
        jsonMode: ProviderJSONMode,
        imageDetail: ImageDetail
    ) async -> Bool {
        guard beginOperation() else { return false }
        defer { endOperation() }
        if let existing {
            providerRequests[existing.id] = nil
            await service.cancelModelProbe(providerID: existing.id)
            providerOperations[existing.id] = nil
            probingProviderIDs.remove(existing.id)
        }
        return saveCustomProviderDraft(
            existing: existing,
            name: name,
            baseURL: baseURL,
            modelIDs: modelIDs,
            transport: transport,
            jsonMode: jsonMode,
            imageDetail: imageDetail
        )
    }

    private func saveCustomProviderDraft(
        existing: CustomProviderConfiguration?,
        name: String,
        baseURL: String,
        modelIDs: String,
        transport: ProviderTransport,
        jsonMode: ProviderJSONMode,
        imageDetail: ImageDetail
    ) -> Bool {
        let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanURL = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !customProviders.contains(where: {
            $0.id != existing?.id && $0.name.caseInsensitiveCompare(cleanName) == .orderedSame
        }) else {
            operation = .failed(.init(code: "CUSTOM_PROVIDER_DUPLICATE", message: "Provider 名称已存在"))
            return false
        }
        let models = modelIDs
            .split(whereSeparator: { $0 == "," || $0 == "\n" })
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        do {
            // Reuse the Domain compatibility validator so HTTP localhost,
            // UUID identity, model IDs and URL canonicalization cannot drift
            // from SM-07 merely because creation originated in SwiftUI.
            let provider: CustomProviderConfiguration
            if let existing {
                provider = try CustomProviderValidator.normalize(
                    CustomProviderConfiguration(
                        id: existing.id,
                        name: cleanName,
                        baseUrl: cleanURL,
                        transport: transport,
                        jsonMode: jsonMode,
                        imageDetail: imageDetail,
                        manualModelIds: models,
                        revision: existing.revision + 1,
                        capabilityCache: nil
                    )
                )
            } else {
                provider = try CustomProviderValidator.normalizeRequest(
                    CustomProviderConfigRequest(
                        name: cleanName,
                        baseUrl: cleanURL,
                        transport: transport,
                        jsonMode: jsonMode,
                        imageDetail: imageDetail,
                        manualModelIds: models
                    )
                )
            }
            if let index = customProviders.firstIndex(where: { $0.id == provider.id }) {
                customProviders[index] = provider
            } else {
                customProviders.append(provider)
            }
            discoveryResults[provider.id] = nil
            probeProgress[provider.id] = nil
            operation = .idle
            return true
        } catch {
            operation = .failed(ProductPrivacy.error(error))
            return false
        }
    }

    public func removeCustomProvider(id: String) async {
        guard beginOperation() else { return }
        defer { endOperation() }
        // Invalidate before the actor hop: a canceled discovery/probe may
        // finish while deletion waits for its transport to drain.
        providerRequests[id] = nil
        await service.cancelModelProbe(providerID: id)
        customProviders.removeAll { $0.id == id }
        discoveryResults[id] = nil
        providerOperations[id] = nil
        probeProgress[id] = nil
        probingProviderIDs.remove(id)
    }

    private func beginOperation() -> Bool {
        guard acceptsOperations else { return false }
        activeCalls += 1
        return true
    }

    private func endOperation() {
        activeCalls -= 1
        if activeCalls == 0 {
            let waiters = drainWaiters
            drainWaiters.removeAll()
            waiters.forEach { $0.resume() }
        }
    }

    /// Writes are never canceled mid-Keychain/config transaction. Quit stops
    /// admission, cancels network probes, then joins all active service calls.
    public func drain() async {
        acceptsOperations = false
        for id in providerOperations.keys where providerOperations[id]?.isRunning == true {
            await service.cancelModelProbe(providerID: id)
        }
        if activeCalls > 0 {
            await withCheckedContinuation { drainWaiters.append($0) }
        }
    }

    private func publish(_ value: GlobalSettingsProjection) {
        live = value
        draft = value.values
        customProviders = value.customProviders
        revision += 1
    }

    public func refresh() async {
        guard beginOperation() else { return }
        defer { endOperation() }
        do { refreshPreservingDraft(try await service.globalSettings()) }
        catch { operation = .failed(ProductPrivacy.error(error)) }
    }

    private func refreshPreservingDraft(_ value: GlobalSettingsProjection) {
        guard let previous = live else { publish(value); return }
        // Three-way refresh: update only values that the user has not changed
        // since the previous live snapshot. This preserves editing while also
        // retaining probe caches and the Python path installed in the meantime.
        for key in GlobalSettingKey.allCases where draft[key] == previous.values[key] {
            draft[key] = value.values[key]
        }
        customProviders = customProviders.compactMap { current in
            guard let old = previous.customProviders.first(where: { $0.id == current.id }), old == current else { return current }
            return value.customProviders.first(where: { $0.id == current.id })
        }
        for provider in value.customProviders where !previous.customProviders.contains(where: { $0.id == provider.id }) && !customProviders.contains(where: { $0.id == provider.id }) {
            customProviders.append(provider)
        }
        live = value
        revision += 1
    }
}

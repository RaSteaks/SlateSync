import Foundation
import Observation
import SlateSyncDomain

// Product copy uses the shared launch language; user content stays verbatim.

/// Result of the Provider panel's two persistence transactions. Keeping the
/// two flags separate lets the UI explain a successful ordinary-config write
/// when a subsequent encrypted-file write fails.
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
    public private(set) var ocrChecks: [OCREnvironmentCheck] = []
    public private(set) var ocrCheckOperation: OperationState = .idle
    private var checkedOCRDraft: GlobalSettingValues?
    private var ocrCheckTask: Task<[OCREnvironmentCheck], Error>?

    /// Keep historical results visible but never present them as current after
    /// edits, installation, or another settings snapshot changes their inputs.
    public var ocrChecksAreStale: Bool {
        guard let checkedOCRDraft else { return false }
        return Self.ocrInputs(checkedOCRDraft) != Self.ocrInputs(draft)
    }

    private static func ocrInputs(_ values: GlobalSettingValues) -> [GlobalSettingKey: String] {
        values.values.filter { $0.key.rawValue.hasPrefix("VISIONOCR_") || $0.key.rawValue.hasPrefix("PADDLEOCR_") }
    }

    public func checkOCREnvironment() async {
        guard !ocrCheckOperation.isRunning, beginOperation() else { return }
        defer { endOperation() }
        let snapshot = draft
        ocrChecks = []
        checkedOCRDraft = nil
        ocrCheckOperation = .running(label: L10n.tr("正在检测 OCR 环境…"))
        let task = Task { try await service.checkOCREnvironment(values: snapshot) }
        ocrCheckTask = task
        defer { ocrCheckTask = nil }
        do {
            let checks = try await task.value
            if task.isCancelled { throw CancellationError() }
            ocrChecks = checks
            checkedOCRDraft = snapshot
            ocrCheckOperation = .succeeded(message: L10n.tr("OCR 环境检测完成"))
        } catch is CancellationError {
            ocrCheckOperation = .canceled
        } catch {
            ocrCheckOperation = .failed(ProductPrivacy.error(error))
        }
    }

    public func cancelOCREnvironmentCheck() {
        // The retained task owns subprocess cleanup before completion.
        ocrCheckTask?.cancel()
    }

    public func invalidateOCREnvironmentCheck() {
        // Reinstallation can change packages without changing the Python path.
        ocrChecks = []
        checkedOCRDraft = nil
    }
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
        operation = .running(label: L10n.tr("正在读取全局设置…"))
        do {
            let value = try await service.globalSettings()
            publish(value)
            operation = .idle
        } catch is CancellationError {
            operation = .canceled
        } catch {
            operation = .failed(ProductPrivacy.error(error))
        }
    }

    public func value(_ key: GlobalSettingKey) -> String { draft[key] ?? "" }
    public func setValue(_ value: String, for key: GlobalSettingKey) { draft[key] = value }

    /// The workbench changes only the committed default pair. Rebase on the
    /// live snapshot so unrelated unsaved Settings drafts keep their barrier.
    public func setDefaultPair(providerID: String, modelID: String) async -> Bool {
        guard beginOperation() else { return false }
        defer { endOperation() }
        guard !operation.isRunning else { return false }
        guard let snapshot = live,
              snapshot.models.contains(where: {
                  $0.providers.contains(providerID) && $0.id == modelID
                      && $0.capabilityStatus == .verified && $0.verifiedAvailable != false
              }) else {
            operation = .failed(.init(code: "MODEL_NOT_VERIFIED", message: L10n.tr("请先在全局设置验证所选模型。")))
            return false
        }
        var values = snapshot.values
        values[.defaultProviderID] = providerID
        values[.defaultModelID] = modelID
        operation = .running(label: L10n.tr("正在保存默认组合…"))
        do {
            let saved = try await service.saveGlobalSettings(values: values, customProviders: snapshot.customProviders)
            refreshPreservingDraft(saved)
            draft[.defaultProviderID] = providerID
            draft[.defaultModelID] = modelID
            operation = .succeeded(message: L10n.tr("默认组合已保存"))
            return true
        } catch {
            operation = .failed(ProductPrivacy.error(error))
            return false
        }
    }

    public func save() async {
        guard beginOperation() else { return }
        defer { endOperation() }
        guard !operation.isRunning else { return }
        operation = .running(label: L10n.tr("正在保存全局设置…"))
        let values = draft
        let providers = customProviders
        do {
            // Store loading remains deliberately tolerant for legacy config.
            // Explicit UI saves validate every entered field before any write.
            for (key, value) in values.values {
                _ = try GlobalSettingsValidator.normalizedPatchValue(value, for: key)
            }
            try GlobalSettingsValidator.validateProviderSelections(values)
            let defaultProvider = values[.defaultProviderID] ?? ""
            let defaultModel = values[.defaultModelID] ?? ""
            let selected = (try? ProviderModelSelection.decodeAndValidateChain(values[.recognitionFailoverChain] ?? "[]")) ?? []
            let allPairs = selected + (defaultProvider.isEmpty ? [] : [.init(providerID: defaultProvider, modelID: defaultModel)])
            for pair in allPairs {
                guard isVerifiedPair(pair, customProviders: providers) else {
                    throw SlateSyncError(code: "MODEL_NOT_VERIFIED", message: L10n.tr("默认或备用模型尚未验证，请先在 Provider 设置完成验证。"))
                }
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
                ? .succeeded(message: L10n.tr("已保存；工作流路径下次启动生效。"))
                : .succeeded(message: L10n.tr("全局设置已保存"))
        } catch {
            operation = .failed(ProductPrivacy.error(error))
        }
    }

    private func isVerifiedPair(
        _ pair: ProviderModelSelection,
        customProviders: [CustomProviderConfiguration]
    ) -> Bool {
        if let custom = customProviders.first(where: { $0.id == pair.providerID }) {
            let modelID = custom.id == ProviderKind.openAICompatible.rawValue
                && pair.modelID == ProviderKind.openAICompatible.rawValue + "/custom"
                ? custom.manualModelIds.first ?? pair.modelID : pair.modelID
            let proof = custom.capabilityCache?[modelID]
            return custom.manualModelIds.contains(modelID)
                && proof?.revision == custom.revision && proof?.status == .verified
        }
        return live?.models.contains(where: {
            $0.providers.contains(pair.providerID) && $0.id == pair.modelID
                && $0.capabilityStatus == .verified && $0.verifiedAvailable != false
        }) == true
    }

    public func storeCredential(_ value: String?, providerID: String) async throws {
        guard beginOperation() else { throw SlateSyncError(code: "SETTINGS_CLOSING", message: L10n.tr("设置正在关闭，请稍后重试")) }
        defer { endOperation() }
        try await service.setProviderCredential(value, providerID: providerID)
        // encrypted-file edits refresh configured status without discarding unrelated
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
            let error = SlateSyncError(code: "SETTINGS_CLOSING", message: L10n.tr("设置正在关闭，请稍后重试"))
            return .init(
                configurationSaved: false,
                credentialUpdateRequested: apiKey != nil,
                credentialSaved: false,
                message: error.message,
                error: error
            )
        }
        defer { endOperation() }
        operation = .running(label: L10n.tr("正在保存 Provider 配置…"))

        let cleanedKey: String?
        if let apiKey {
            let value = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty else {
                let error = SlateSyncError(code: "PROVIDER_KEY_INVALID", message: L10n.tr("API Key 不能是纯空白；留空表示保留当前 Key"))
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
                        throw SlateSyncError(code: "PROVIDER_URL", message: L10n.tr("API 基础地址不能为空；请填写地址或恢复默认地址"))
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
                message: L10n.tr("配置未保存：{0}", [String(describing: L10n.message(sanitized.message))]),
                error: sanitized
            )
        }

        let requestKeys = baseURLKeys.union([
            .openAICompatibleModel, .openAICompatibleAPIMode,
            .openAICompatibleJSONMode, .openAICompatibleImageDetail,
            .openRouterSiteUrl, .openRouterAppTitle,
        ])
        if requestKeys.contains(where: { (live?.values[$0]) != candidate[$0] }) {
            // An endpoint, wire mode, model, or request-header edit removes
            // policy references until a fresh probe confirms the new route.
            if candidate[.defaultProviderID] == providerID {
                candidate[.defaultProviderID] = nil
                candidate[.defaultModelID] = nil
            }
            if let raw = candidate[.recognitionFailoverChain],
               let chain = try? ProviderModelSelection.decodeAndValidateChain(raw),
               let encoded = try? ProviderModelSelection.encodeChain(chain.filter { $0.providerID != providerID }) {
                candidate[.recognitionFailoverChain] = encoded
            }
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
                message: L10n.tr("配置未保存：{0}", [String(describing: L10n.message(sanitized.message))]),
                error: sanitized
            )
        }

        guard let cleanedKey else {
            operation = .succeeded(message: L10n.tr("Provider 配置已保存；未修改当前 API Key"))
            return .init(
                configurationSaved: true,
                credentialUpdateRequested: false,
                credentialSaved: false,
                message: L10n.tr("Provider 配置已保存；未修改当前 API Key")
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
            operation = .succeeded(message: L10n.tr("Provider 配置与 API Key 已保存"))
            return .init(
                configurationSaved: true,
                credentialUpdateRequested: true,
                credentialSaved: true,
                message: L10n.tr("Provider 配置与 API Key 已保存")
            )
        } catch is CancellationError {
            // Cancellation before admission is not a credential-file failure.
            operation = .canceled
            return .init(configurationSaved: true, credentialUpdateRequested: true,
                         credentialSaved: false, message: L10n.tr("已取消"))
        } catch {
            let sanitized = ProductPrivacy.error(error)
            operation = .failed(sanitized)
            return .init(
                configurationSaved: true,
                credentialUpdateRequested: true,
                credentialSaved: false,
                message: L10n.tr("普通配置已保存，但 API Key 保存失败：{0}", [String(describing: L10n.message(sanitized.message))]),
                error: sanitized
            )
        }
    }

    /// Key deletion is independent from the blank API Key field. A dedicated
    /// call prevents an accidental empty submit from destroying a valid key.
    public func removeProviderCredential(providerID: String) async throws {
        guard beginOperation() else {
            throw SlateSyncError(code: "SETTINGS_CLOSING", message: L10n.tr("设置正在关闭，请稍后重试"))
        }
        defer { endOperation() }
        operation = .running(label: L10n.tr("正在删除 API Key…"))
        do {
            try await service.setProviderCredential(nil, providerID: providerID)
            if let refreshed = try? await service.globalSettings() {
                refreshPreservingDraft(refreshed)
            }
            discoveryResults[providerID] = nil
            providerOperations[providerID] = nil
            operation = .succeeded(message: L10n.tr("{0} 的 API Key 已删除", [String(describing: providerID)]))
        } catch is CancellationError {
            operation = .canceled
            throw CancellationError()
        } catch {
            let sanitized = ProductPrivacy.error(error)
            operation = .failed(sanitized)
            throw sanitized
        }
    }

    public func resetLocalCredentials() async {
        guard beginOperation() else { return }
        defer { endOperation() }
        operation = .running(label: L10n.tr("正在重置本地凭据…"))
        providerRequests.removeAll()
        do {
            try await service.resetLocalProviderCredentials()
            discoveryResults.removeAll()
            providerOperations.removeAll()
            probeProgress.removeAll()
            probingProviderIDs.removeAll()
            draft[.defaultProviderID] = ""
            draft[.defaultModelID] = ""
            draft[.recognitionFailoverChain] = "[]"
            let refreshed = try await service.globalSettings()
            refreshPreservingDraft(refreshed)
            // Preserve unsaved metadata without preserving proofs made with
            // credentials that have just been removed.
            customProviders = customProviders.map { old in
                let revision = max(old.revision + 1, refreshed.customProviders.first { $0.id == old.id }?.revision ?? 1)
                return CustomProviderConfiguration(id: old.id, name: old.name, label: old.label,
                    baseUrl: old.baseUrl, transport: old.transport, jsonMode: old.jsonMode,
                    imageDetail: old.imageDetail, manualModelIds: old.manualModelIds,
                    revision: revision, capabilityCache: nil, notes: old.notes, sourcePresetID: old.sourcePresetID)
            }
            operation = .succeeded(message: L10n.tr("本地凭据已重置，请重新填写 API Key。"))
        } catch is CancellationError { operation = .canceled }
        catch { operation = .failed(ProductPrivacy.error(error)) }
    }

    /// The draft identity is returned even after partial failure so retries edit
    /// that same Provider. Secrets are arguments only, never observable state.
    public func saveCustomProviderConfiguration(
        existing: CustomProviderConfiguration?, name: String, baseURL: String,
        modelIDs: String, transport: ProviderTransport, jsonMode: ProviderJSONMode,
        imageDetail: ImageDetail, notes: String?, sourcePresetID: String?, apiKey: String?
    ) async -> CustomProviderSaveResult {
        guard !operation.isRunning, beginOperation() else {
            return .init(provider: existing, configurationSaved: false, credentialSaved: false, isComplete: false)
        }
        defer { endOperation() }
        if let apiKey, apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            operation = .failed(.init(code: "CREDENTIAL_EMPTY", message: L10n.tr("API Key 不能只包含空白字符")))
            return .init(provider: existing, configurationSaved: false, credentialSaved: false, isComplete: false)
        }
        operation = .running(label: L10n.tr("正在保存 Provider…"))
        if let existing {
            providerRequests[existing.id] = nil
            await service.cancelModelProbe(providerID: existing.id)
            providerOperations[existing.id] = nil
            probingProviderIDs.remove(existing.id)
        }
        let previousDraftProviders = customProviders
        let previousDraft = draft
        guard saveCustomProviderDraft(existing: existing, name: name, baseURL: baseURL,
            modelIDs: modelIDs, transport: transport, jsonMode: jsonMode,
            imageDetail: imageDetail, notes: notes, sourcePresetID: sourcePresetID),
            let provider = customProviders.first(where: { $0.id == existing?.id || $0.name == name.trimmingCharacters(in: .whitespacesAndNewlines) }) else {
            return .init(provider: existing, configurationSaved: false, credentialSaved: false, isComplete: false)
        }
        let editedDraft = draft
        operation = .running(label: L10n.tr("正在保存 Provider…"))
        do {
            // Commit this Provider and its invalidated references, while unrelated
            // settings remain drafts. Never persist an API key in ordinary config.
            var values = live?.values ?? GlobalSettingValues()
            if let persistedProvider = live?.customProviders.first(where: { $0.id == provider.id }),
               persistedProvider.revision != provider.revision {
                if values[.defaultProviderID] == provider.id {
                    values[.defaultProviderID] = nil; values[.defaultModelID] = nil
                }
                let chain = (try? ProviderModelSelection.decodeAndValidateChain(values[.recognitionFailoverChain] ?? "[]")) ?? []
                values[.recognitionFailoverChain] = try ProviderModelSelection.encodeChain(chain.filter { $0.providerID != provider.id })
            }
            var persisted = live?.customProviders ?? []
            persisted.removeAll { $0.id == provider.id }
            persisted.append(provider)
            refreshPreservingDraft(try await service.saveGlobalSettings(values: values, customProviders: persisted))
        } catch {
            // Failed immediate saves must not leave a phantom new entry that a
            // later page-level Save could accidentally commit after Cancel.
            customProviders.removeAll { $0.id == provider.id }
            if let old = previousDraftProviders.first(where: { $0.id == provider.id }) { customProviders.append(old) }
            for key: GlobalSettingKey in [.defaultProviderID, .defaultModelID, .recognitionFailoverChain]
                where draft[key] == editedDraft[key] {
                draft[key] = previousDraft[key]
            }
            operation = .failed(ProductPrivacy.error(error))
            return .init(provider: provider, configurationSaved: false, credentialSaved: false, isComplete: false)
        }
        if let apiKey {
            do {
                try await service.setProviderCredential(apiKey.trimmingCharacters(in: .whitespacesAndNewlines), providerID: provider.id)
            } catch is CancellationError {
                operation = .canceled
                return .init(provider: provider, configurationSaved: true, credentialSaved: false, isComplete: false)
            } catch {
                let sanitized = ProductPrivacy.error(error)
                operation = .failed(.init(code: sanitized.code,
                    message: L10n.tr("普通配置已保存，但 API Key 保存失败：{0}", [L10n.message(sanitized.message)])))
                return .init(provider: provider, configurationSaved: true, credentialSaved: false, isComplete: false)
            }
            // A completed write remains successful even if its status refresh
            // fails. Keep the editor open without claiming the key was lost.
            do {
                let refreshed = try await service.globalSettings()
                refreshPreservingDraft(refreshed)
                if let current = refreshed.customProviders.first(where: { $0.id == provider.id }),
                   let index = customProviders.firstIndex(where: { $0.id == provider.id }) {
                    customProviders[index] = current
                }
            } catch is CancellationError {
                operation = .canceled
                return .init(provider: provider, configurationSaved: true, credentialSaved: true, isComplete: false)
            } catch {
                let sanitized = ProductPrivacy.error(error)
                operation = .failed(.init(code: sanitized.code,
                    message: L10n.tr("Provider 配置与 API Key 已保存，但状态刷新失败：{0}", [L10n.message(sanitized.message)])))
                return .init(provider: provider, configurationSaved: true, credentialSaved: true, isComplete: false)
            }
        }
        operation = .succeeded(message: L10n.tr("Provider 配置已保存"))
        return .init(provider: customProviders.first { $0.id == provider.id } ?? provider,
                     configurationSaved: true, credentialSaved: apiKey != nil, isComplete: true)
    }



    public func discover(providerID: String, forceRefresh: Bool = true) async {
        guard beginOperation() else { return }
        defer { endOperation() }
        guard providerOperations[providerID]?.isRunning != true else { return }
        providerOperations[providerID] = .running(label: L10n.tr("正在刷新模型…"))
        let request = UUID()
        providerRequests[providerID] = request
        do {
            let result = try await service.discoverModels(
                providerID: providerID,
                forceRefresh: forceRefresh
            )
            guard providerRequests[providerID] == request else { return }
            discoveryResults[providerID] = result
            // Publish the shared catalog revision so already-open workspaces
            // refresh their model pickers without discarding Settings drafts.
            let refreshed = try await service.globalSettings()
            guard providerRequests[providerID] == request else { return }
            refreshPreservingDraft(refreshed)
            providerOperations[providerID] = .succeeded(message: L10n.tr("发现 {0} 个可用模型", [String(describing: result.visionModelCount)]))
        } catch {
            guard providerRequests[providerID] == request else { return }
            providerOperations[providerID] = .failed(ProductPrivacy.error(error))
        }
    }

    public func probe(providerID: String, modelIDs: [String]) async {
        guard beginOperation() else { return }
        defer { endOperation() }
        guard providerOperations[providerID]?.isRunning != true else { return }
        providerOperations[providerID] = .running(label: L10n.tr("正在验证视觉能力…"))
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
                        label: L10n.tr("已验证 {0}/{1}", [String(describing: value.completed), String(describing: value.total)])
                    )
                }
            }
            guard providerRequests[providerID] == request else { return }
            providerOperations[providerID] = result.canceled
                ? .canceled
                : .succeeded(message: L10n.tr("模型能力验证完成"))
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
        providerOperations[providerID] = .running(label: L10n.tr("正在取消验证…"))
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

    /// Shared validation for the single immediate-save entry point; never a second public draft API.
    private func saveCustomProviderDraft(
        existing: CustomProviderConfiguration?,
        name: String,
        baseURL: String,
        modelIDs: String,
        transport: ProviderTransport,
        jsonMode: ProviderJSONMode,
        imageDetail: ImageDetail,
        notes: String? = nil,
        sourcePresetID: String? = nil
    ) -> Bool {
        let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanURL = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !customProviders.contains(where: {
            $0.id != existing?.id && $0.name.caseInsensitiveCompare(cleanName) == .orderedSame
        }) else {
            operation = .failed(.init(code: "CUSTOM_PROVIDER_DUPLICATE", message: L10n.tr("Provider 名称已存在")))
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
                // A display-only edit preserves both revision and verified
                // capability cache; request-affecting edits invalidate both.
                let requestChanged = existing.baseUrl != (try? CustomProviderValidator.normalizeBaseURL(cleanURL))
                    || existing.transport != transport || existing.jsonMode != jsonMode
                    || existing.imageDetail != imageDetail
                    || existing.manualModelIds != models
                provider = try CustomProviderValidator.normalize(
                    CustomProviderConfiguration(
                        id: existing.id,
                        name: cleanName,
                        baseUrl: cleanURL,
                        transport: transport,
                        jsonMode: jsonMode,
                        imageDetail: imageDetail,
                        manualModelIds: models,
                        revision: existing.revision + (requestChanged ? 1 : 0),
                        capabilityCache: requestChanged ? nil : existing.capabilityCache,
                        notes: notes,
                        sourcePresetID: sourcePresetID ?? existing.sourcePresetID
                    )
                )
                if requestChanged {
                    // A request edit cannot leave a formerly verified pair
                    // active in the same draft. Re-add it after probing.
                    if draft[.defaultProviderID] == existing.id {
                        draft[.defaultProviderID] = ""
                        draft[.defaultModelID] = ""
                    }
                    if let chain = try? ProviderModelSelection.decodeAndValidateChain(draft[.recognitionFailoverChain] ?? "[]"),
                       let encoded = try? ProviderModelSelection.encodeChain(chain.filter { $0.providerID != existing.id }) {
                        draft[.recognitionFailoverChain] = encoded
                    }
                }
            } else {
                provider = try CustomProviderValidator.normalizeRequest(
                    CustomProviderConfigRequest(
                        name: cleanName,
                        baseUrl: cleanURL,
                        transport: transport,
                        jsonMode: jsonMode,
                        imageDetail: imageDetail,
                        manualModelIds: models,
                        notes: notes,
                        sourcePresetID: sourcePresetID
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
        // Remove references in the same unsaved draft transaction as deletion.
        if draft[.defaultProviderID] == id {
            draft[.defaultProviderID] = ""
            draft[.defaultModelID] = ""
        }
        if let chain = try? ProviderModelSelection.decodeAndValidateChain(draft[.recognitionFailoverChain] ?? "[]"),
           let encoded = try? ProviderModelSelection.encodeChain(chain.filter { $0.providerID != id }) {
            draft[.recognitionFailoverChain] = encoded
        }
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

    /// Writes are never canceled mid-encrypted-file/config transaction. Quit stops
    /// admission, cancels network probes, then joins all active service calls.
    public func drain() async {
        acceptsOperations = false
        ocrCheckTask?.cancel()
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

/// Separate transaction outcomes keep retry behavior explicit in the editor.
public struct CustomProviderSaveResult: Sendable {
    public let provider: CustomProviderConfiguration?
    public let configurationSaved: Bool
    public let credentialSaved: Bool
    public let isComplete: Bool
}

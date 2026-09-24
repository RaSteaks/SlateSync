import Foundation
import SlateSyncDomain

public actor ProviderRegistry {
    private struct Registration: Sendable {
        let revision: Int?
        let models: [String: ResolvedModel]
    }

    private var settings: GlobalSettingValues
    private var customProviders: [CustomProviderConfiguration]
    private let credentials: (any ProviderCredentialReading)?
    private var registrations: [String: Registration] = [:]
    private var generation = 0
    private var builtinCapabilities: [String: BuiltinProviderCapabilityCache]

    public init(
        settings: GlobalSettingValues = .init(),
        customProviders: [CustomProviderConfiguration] = [],
        credentials: (any ProviderCredentialReading)? = nil,
        builtinCapabilities: [String: BuiltinProviderCapabilityCache] = [:]
    ) {
        self.settings = settings
        self.customProviders = CustomProviderValidator.sanitize(customProviders)
        self.credentials = credentials
        self.builtinCapabilities = builtinCapabilities
    }

    /// Keep proofs across display/default edits. Endpoint, protocol, JSON
    /// mode, image detail, request headers, model IDs and revision changes
    /// still invalidate the affected provider's registration.
    public func replace(
        settings: GlobalSettingValues,
        customProviders: [CustomProviderConfiguration],
        builtinCapabilities: [String: BuiltinProviderCapabilityCache]? = nil
    ) {
        let ids = Set(ProviderCatalog.definitions.map(\.id)
            + self.customProviders.map(\.id) + customProviders.map(\.id))
        let oldSettings = self.settings
        let before = Dictionary(uniqueKeysWithValues: ids.map { ($0, try? descriptor(providerID: $0)) })
        self.settings = settings
        self.customProviders = CustomProviderValidator.sanitize(customProviders)
        let changed = ids.filter { id in
            (id == ProviderKind.openAICompatible.rawValue
                && oldSettings[.openAICompatibleModel] != settings[.openAICompatibleModel])
                || !Self.sameRoute(before[id] ?? nil, try? descriptor(providerID: id))
        }
        if !changed.isEmpty { generation += 1 }
        for id in changed {
            registrations.removeValue(forKey: id)
            self.builtinCapabilities.removeValue(forKey: id)
        }
        if let builtinCapabilities { self.builtinCapabilities = builtinCapabilities }
        self.builtinCapabilities = self.builtinCapabilities.filter { id, proof in
            guard let current = try? descriptor(providerID: id) else { return false }
            return proof.matches(current, configuredModel: configuredModel(for: id))
        }
    }

    private static func sameRoute(_ old: ProviderDescriptor?, _ new: ProviderDescriptor?) -> Bool {
        guard let old, let new else { return old == nil && new == nil }
        return old.baseURL == new.baseURL && old.transport == new.transport
            && old.jsonMode == new.jsonMode && old.imageDetail == new.imageDetail
            && old.revision == new.revision
            && old.openRouterSiteURL == new.openRouterSiteURL
            && old.openRouterTitle == new.openRouterTitle
    }

    public func currentGeneration() -> Int { generation }

    public func customConfiguration(providerID: String) -> CustomProviderConfiguration? {
        customProviders.first { $0.id == providerID }
    }

    public func setting(_ key: GlobalSettingKey) -> String? { settings[key] }

    public func descriptor(providerID: String) throws -> ProviderDescriptor {
        let kind = ProviderKind(id: providerID)
        if let custom = customProviders.first(where: { $0.id == providerID && $0.id != ProviderKind.openAICompatible.rawValue }) {
            guard let baseURL = URL(string: custom.baseUrl) else { throw RecognitionFailure.invalidURL }
            return ProviderDescriptor(
                id: custom.id, label: custom.name, origin: .custom, providerKind: kind, baseURL: baseURL,
                transport: custom.transport, jsonMode: custom.jsonMode,
                imageDetail: custom.imageDetail, credentialRequired: false,
                revision: custom.revision
            )
        }

        guard let definition = ProviderCatalog.definition(id: providerID) else {
            throw RecognitionFailure.unknownProvider
        }
        if kind == .openAICompatible,
           let materialized = customProviders.first(where: { $0.id == providerID }) {
            guard let baseURL = URL(string: materialized.baseUrl) else { throw RecognitionFailure.invalidURL }
            return ProviderDescriptor(
                id: providerID, label: materialized.name, origin: .builtin, providerKind: kind,
                baseURL: baseURL, transport: materialized.transport,
                jsonMode: materialized.jsonMode, imageDetail: materialized.imageDetail,
                credentialRequired: true, revision: materialized.revision,
                isLegacyCompatible: true
            )
        }
        let configuredBase = settings[definition.baseURLSetting]?.trimmingCharacters(in: .whitespacesAndNewlines)
        let rawBase = configuredBase?.isEmpty == false ? configuredBase! : definition.defaultBaseURL
        guard !rawBase.isEmpty else { throw RecognitionFailure.providerNotConfigured }
        let normalized: String
        do { normalized = try CustomProviderValidator.normalizeBaseURL(rawBase) }
        catch { throw RecognitionFailure.invalidURL }
        guard let baseURL = URL(string: normalized) else { throw RecognitionFailure.invalidURL }

        var transport = definition.transport
        var jsonMode = definition.jsonMode
        var detail: ImageDetail = .high
        if kind == .openAICompatible {
            if settings[.openAICompatibleAPIMode]?.lowercased() == ProviderTransport.responses.rawValue { transport = .responses }
            if let raw = settings[.openAICompatibleJSONMode]?.lowercased(), let mode = ProviderJSONMode(rawValue: raw) { jsonMode = mode }
            if transport == .responses, settings[.openAICompatibleJSONMode] == nil { jsonMode = .jsonSchema }
            if let raw = settings[.openAICompatibleImageDetail]?.lowercased(), let selected = ImageDetail(rawValue: raw) { detail = selected }
        }
        return ProviderDescriptor(
            id: providerID, label: definition.label, origin: .builtin, providerKind: kind,
            baseURL: baseURL, transport: transport, jsonMode: jsonMode,
            imageDetail: detail, credentialRequired: definition.credentialRequired,
            openRouterSiteURL: definition.kind == .openRouter ? settings[.openRouterSiteUrl] : nil,
            openRouterTitle: definition.kind == .openRouter ? settings[.openRouterAppTitle] : nil,
            isLegacyCompatible: kind == .openAICompatible
        )
    }

    private func configuredModel(for id: String) -> String? {
        id == ProviderKind.openAICompatible.rawValue ? settings[.openAICompatibleModel] : nil
    }

    private func builtinProof(providerID: String) -> BuiltinProviderCapabilityCache? {
        guard let proof = builtinCapabilities[providerID],
              let current = try? descriptor(providerID: providerID),
              proof.matches(current, configuredModel: configuredModel(for: providerID)) else { return nil }
        return proof
    }

    /// Merge only the probed physical IDs; discovery is a separate projection
    /// and cannot erase either successful or negative explicit probe results.
    public func mergingBuiltinProbeResults(provider: ProviderDescriptor,
        results: [ModelCapabilityProbeResult], generation expected: Int
    ) -> BuiltinProviderCapabilityCache? {
        guard expected == generation, provider.origin == .builtin,
              let current = try? descriptor(providerID: provider.id),
              Self.sameRoute(provider, current) else { return nil }
        var proof = builtinProof(providerID: provider.id) ?? .init(
            provider: current, configuredModel: configuredModel(for: provider.id))
        for result in results { proof.results[result.model] = result }
        return proof
    }

    public func restoreBuiltinCapabilities(_ proof: BuiltinProviderCapabilityCache, generation expected: Int) {
        guard expected == generation, let current = try? descriptor(providerID: proof.provider.id),
              proof.matches(current, configuredModel: configuredModel(for: proof.provider.id)) else { return }
        builtinCapabilities[proof.provider.id] = proof
    }

    private func probedModel(_ result: ModelCapabilityProbeResult, provider: ProviderDescriptor) -> ResolvedModel {
        let fixed = ProviderCatalog.resolveFixed(providerID: provider.id, modelID: result.model)
        // Preserve the public catalog alias used by already-persisted tasks.
        let publicID = provider.isLegacyCompatible ? provider.id + "/custom" : fixed?.publicID ?? result.model
        return .init(publicID: publicID, apiID: result.model, providerID: provider.id,
            label: fixed?.label ?? result.model, imageDetail: fixed?.imageDetail ?? provider.imageDetail,
            jsonMode: result.jsonMode ?? provider.jsonMode, capabilityStatus: result.capabilityStatus,
            revision: provider.revision)
    }

    public func resolveModel(providerID: String, modelID: String) throws -> ResolvedModel {
        let descriptor = try descriptor(providerID: providerID)
        let apiID = ProviderCatalog.resolveFixed(providerID: providerID, modelID: modelID)?.apiID
            ?? (descriptor.isLegacyCompatible && modelID == providerID + "/custom"
                ? configuredModel(for: providerID) : nil) ?? modelID
        if let result = builtinProof(providerID: providerID)?.results[apiID] {
            guard result.capabilityStatus == .verified else { throw RecognitionFailure.unsupportedModel }
            return probedModel(result, provider: descriptor)
        }
        if let registration = registrations[providerID], registration.revision == descriptor.revision,
           let registered = registration.models[modelID], registered.isUsable { return registered }
        if let fixed = ProviderCatalog.resolveFixed(providerID: providerID, modelID: modelID) { return fixed }

        if ProviderKind(id: providerID) == .openAICompatible {
            let materialized = customProviders.first(where: { $0.id == providerID })
            let persisted = materialized?.manualModelIds.first
            let configured = settings[.openAICompatibleModel]?.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let apiID = persisted ?? configured, ProviderCatalog.isValidModelID(apiID) else {
                throw RecognitionFailure.unsupportedModel
            }
            let proof = materialized?.capabilityCache?[apiID]
            let verified = proof?.revision == materialized?.revision && proof?.status == .verified
            return ResolvedModel(
                publicID: ProviderKind.openAICompatible.rawValue + "/custom", apiID: apiID,
                providerID: providerID, label: apiID,
                imageDetail: descriptor.imageDetail, jsonMode: verified ? (proof?.jsonMode ?? descriptor.jsonMode) : descriptor.jsonMode,
                capabilityStatus: verified ? .verified : .declared,
                revision: descriptor.revision
            )
        }

        if let custom = customProviders.first(where: { $0.id == providerID }),
           custom.manualModelIds.contains(modelID),
           let verification = custom.capabilityCache?[modelID],
           verification.revision == custom.revision,
           verification.status == .verified {
            return ResolvedModel(
                publicID: modelID, apiID: modelID, providerID: providerID,
                label: modelID, imageDetail: custom.imageDetail,
                jsonMode: verification.jsonMode ?? custom.jsonMode, capabilityStatus: .verified,
                revision: custom.revision
            )
        }
        throw RecognitionFailure.unsupportedModel
    }

    public func register(_ models: [ResolvedModel], providerID: String, revision: Int?, generation expected: Int? = nil) {
        // The caller's revision is checked after every discovery/probe await;
        // a late response from an edited provider cannot replace live state.
        // Built-ins have no revision, so configuration/probe generations also
        // fence responses from an old endpoint or superseded capability state.
        guard expected == nil || expected == generation,
              let current = try? descriptor(providerID: providerID),
              current.revision == revision else { return }
        var byID: [String: ResolvedModel] = [:]
        for model in models where model.providerID == providerID && model.isUsable {
            byID[model.publicID] = model
            byID[model.apiID] = byID[model.apiID] ?? model
        }
        registrations[providerID] = Registration(revision: revision, models: byID)
    }

    /// Capability-only changes keep other providers' discovered models alive.
    /// Replace the targeted model's eligibility, including negative probe results.
    public func refreshCapabilities(_ provider: CustomProviderConfiguration) {
        guard let index = customProviders.firstIndex(where: {
            $0.id == provider.id && $0.revision == provider.revision && $0.baseUrl == provider.baseUrl
        }) else { return }
        customProviders[index] = provider
        generation += 1
        var models = registrations[provider.id]?.models ?? [:]
        for (id, verification) in provider.capabilityCache ?? [:] where verification.revision == provider.revision {
            models = models.filter { $0.value.apiID != id }
            if verification.status == .verified {
                models[id] = ResolvedModel(publicID: id, apiID: id, providerID: provider.id,
                    label: id, imageDetail: provider.imageDetail, jsonMode: verification.jsonMode ?? provider.jsonMode,
                    capabilityStatus: .verified, revision: provider.revision)
            }
        }
        registrations[provider.id] = Registration(revision: provider.revision, models: models)
    }

    public func invalidate(providerID: String? = nil) {
        generation += 1
        if let providerID {
            registrations.removeValue(forKey: providerID)
            builtinCapabilities.removeValue(forKey: providerID)
        } else {
            registrations.removeAll()
            builtinCapabilities.removeAll()
        }
    }

    public func providerSummaries(credentialStatuses: [String: CredentialStatus]? = nil) async -> [ProviderSummary] {
        var result: [ProviderSummary] = []
        for definition in ProviderCatalog.definitions {
            let descriptor = try? descriptor(providerID: definition.id)
            // Settings supplies one secret-free snapshot for every consumer.
            let keyConfigured: Bool
            if let credentialStatuses {
                keyConfigured = credentialStatuses[definition.id] == .configured
                    || credentialStatuses[definition.id] == .authorizationRequired
            } else {
                keyConfigured = (try? await credentials?.isCredentialConfigured(for: definition.id)) ?? false
            }
            let configured = descriptor != nil && (!definition.credentialRequired || keyConfigured)
            result.append(.init(id: definition.id, label: definition.label, configured: configured, requiredEnv: definition.credentialRequired ? [credentialName(definition.id)] : [], type: .builtin, editable: definition.kind == .openAICompatible))
        }
        for provider in customProviders where provider.id != ProviderKind.openAICompatible.rawValue {
            // UUID custom providers intentionally permit anonymous local/LAN
            // endpoints, so configuration depends on the validated base URL.
            result.append(.init(id: provider.id, label: provider.name, configured: !provider.baseUrl.isEmpty, type: .custom, editable: true))
        }
        return result
    }

    public func publicModels() -> [ModelData] {
        var values = ProviderCatalog.definitions.flatMap { ProviderCatalog.fixedModels(providerID: $0.id) }
        for provider in customProviders {
            for modelID in provider.manualModelIds {
                let verification = provider.capabilityCache?[modelID]
                let status = verification?.revision == provider.revision ? (verification?.status ?? .pending) : .pending
                values.append(ModelData(
                    id: ProviderKind(id: provider.id) == .openAICompatible ? ProviderKind.openAICompatible.rawValue + "/custom" : modelID,
                    label: modelID, description: status == .verified ? "自定义接口模型" : "自定义接口模型，等待能力验证",
                    providers: [provider.id], vendor: ProviderCatalog.vendor(for: modelID),
                    imageDetail: provider.imageDetail, apiId: modelID, fixed: false,
                    discovered: false, verifiedAvailable: status == .verified,
                    capabilityStatus: status,
                    capabilitySource: bounded(verification?.capabilitySource, limit: 120),
                    capabilityMessage: bounded(verification?.message, limit: 500),
                    capabilityCheckedAt: bounded(verification?.checkedAt, limit: 80)
                ))
            }
        }
        // Discovery registrations must reach the same picker projection used
        // by recognition. Deduplication below folds public/API aliases together.
        for registration in registrations.values {
            for model in registration.models.values {
                values.append(ModelData(id: model.publicID, label: model.label,
                    description: "", providers: [model.providerID], imageDetail: model.imageDetail,
                    apiId: model.apiID, discovered: true, verifiedAvailable: model.isUsable,
                    capabilityStatus: model.capabilityStatus))
            }
        }
        // Explicit probes override discovery, including a failed re-probe.
        // Both aliases resolve to one physical model in the picker projection.
        for id in builtinCapabilities.keys {
            guard let proof = builtinProof(providerID: id) else { continue }
            for result in proof.results.values {
                let model = probedModel(result, provider: proof.provider)
                values.removeAll { $0.providers.contains(id) && ($0.apiId ?? $0.id) == model.apiID }
                values.append(ModelData(id: model.publicID, label: model.label, description: "",
                    providers: [id], imageDetail: model.imageDetail, apiId: model.apiID,
                    verifiedAvailable: result.capabilityStatus == .verified,
                    capabilityStatus: result.capabilityStatus))
            }
        }
        // Physical API identity, not the compatibility alias, controls public
        // deduplication. A verified descriptor wins over pending/canceled.
        var chosen: [String: ModelData] = [:]
        for value in values {
            let key = "\(value.providers.first ?? ""):\(value.apiId ?? value.id)"
            if let old = chosen[key], priority(old.capabilityStatus) >= priority(value.capabilityStatus) { continue }
            chosen[key] = value
        }
        return ProviderCatalog.sort(Array(chosen.values))
    }

    private func credentialName(_ providerID: String) -> String {
        switch ProviderKind(id: providerID) {
        case .openAI: return "OPENAI_API_KEY"
        case .openRouter: return "OPENROUTER_API_KEY"
        case .tokenPlan: return "TOKENPLAN_API_KEY"
        case .dashScope: return "DASHSCOPE_API_KEY"
        case .openAICompatible, .none: return "OPENAI_COMPATIBLE_API_KEY"
        }
    }

    private func bounded(_ value: String?, limit: Int) -> String? {
        guard let value else { return nil }
        return String(StructuredLogRedactor.redactText(value).prefix(limit))
    }

    private func priority(_ status: ModelCapabilityStatus?) -> Int {
        switch status { case .verified: return 6; case .failed: return 5; case .declared: return 4; case .inferred: return 3; case .pending: return 2; case .canceled: return 1; default: return 0 }
    }
}

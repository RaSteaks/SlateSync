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

    public init(
        settings: GlobalSettingValues = .init(),
        customProviders: [CustomProviderConfiguration] = [],
        credentials: (any ProviderCredentialReading)? = nil
    ) {
        self.settings = settings
        self.customProviders = CustomProviderValidator.sanitize(customProviders)
        self.credentials = credentials
    }

    /// Replacing a settings snapshot invalidates every registration. This is
    /// deliberately broad: endpoint, transport, JSON mode, image detail, key,
    /// and model edits must never leave a stale model eligible for execution.
    public func replace(
        settings: GlobalSettingValues,
        customProviders: [CustomProviderConfiguration]
    ) {
        self.settings = settings
        self.customProviders = CustomProviderValidator.sanitize(customProviders)
        generation += 1
        registrations.removeAll()
    }

    public func currentGeneration() -> Int { generation }

    public func customConfiguration(providerID: String) -> CustomProviderConfiguration? {
        customProviders.first { $0.id == providerID }
    }

    public func setting(_ key: GlobalSettingKey) -> String? { settings[key] }

    public func descriptor(providerID: String) throws -> ProviderDescriptor {
        if let custom = customProviders.first(where: { $0.id == providerID && $0.id != "openai-compatible" }) {
            guard let baseURL = URL(string: custom.baseUrl) else { throw RecognitionFailure.invalidURL }
            return ProviderDescriptor(
                id: custom.id, label: custom.name, kind: .custom, baseURL: baseURL,
                transport: custom.transport, jsonMode: custom.jsonMode,
                imageDetail: custom.imageDetail, credentialRequired: false,
                revision: custom.revision
            )
        }

        guard let definition = ProviderCatalog.definition(id: providerID) else {
            throw RecognitionFailure.unknownProvider
        }
        if providerID == "openai-compatible",
           let materialized = customProviders.first(where: { $0.id == providerID }) {
            guard let baseURL = URL(string: materialized.baseUrl) else { throw RecognitionFailure.invalidURL }
            return ProviderDescriptor(
                id: providerID, label: materialized.name, kind: .builtin,
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
        if providerID == "openai-compatible" {
            if settings[.openAICompatibleAPIMode]?.lowercased() == ProviderTransport.responses.rawValue { transport = .responses }
            if let raw = settings[.openAICompatibleJSONMode]?.lowercased(), let mode = ProviderJSONMode(rawValue: raw) { jsonMode = mode }
            if transport == .responses, settings[.openAICompatibleJSONMode] == nil { jsonMode = .jsonSchema }
            if let raw = settings[.openAICompatibleImageDetail]?.lowercased(), let selected = ImageDetail(rawValue: raw) { detail = selected }
        }
        return ProviderDescriptor(
            id: providerID, label: definition.label, kind: .builtin,
            baseURL: baseURL, transport: transport, jsonMode: jsonMode,
            imageDetail: detail, credentialRequired: definition.credentialRequired,
            openRouterSiteURL: providerID == "openrouter" ? settings[.openRouterSiteUrl] : nil,
            isLegacyCompatible: providerID == "openai-compatible"
        )
    }

    public func resolveModel(providerID: String, modelID: String) throws -> ResolvedModel {
        if let fixed = ProviderCatalog.resolveFixed(providerID: providerID, modelID: modelID) { return fixed }
        let descriptor = try descriptor(providerID: providerID)
        if let registration = registrations[providerID], registration.revision == descriptor.revision,
           let registered = registration.models[modelID], registered.isUsable { return registered }

        if providerID == "openai-compatible" {
            let persisted = customProviders.first(where: { $0.id == providerID })?.manualModelIds.first
            let configured = settings[.openAICompatibleModel]?.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let apiID = persisted ?? configured, ProviderCatalog.isValidModelID(apiID) else {
                throw RecognitionFailure.unsupportedModel
            }
            return ResolvedModel(
                publicID: "openai-compatible/custom", apiID: apiID,
                providerID: providerID, label: apiID,
                imageDetail: descriptor.imageDetail, jsonMode: descriptor.jsonMode,
                capabilityStatus: .declared, revision: descriptor.revision
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
                jsonMode: custom.jsonMode, capabilityStatus: .verified,
                revision: custom.revision
            )
        }
        throw RecognitionFailure.unsupportedModel
    }

    public func register(_ models: [ResolvedModel], providerID: String, revision: Int?) {
        // The caller's revision is checked after every discovery/probe await;
        // a late response from an edited provider cannot replace live state.
        let currentRevision = (try? descriptor(providerID: providerID).revision) ?? nil
        guard currentRevision == revision else { return }
        var byID: [String: ResolvedModel] = [:]
        for model in models where model.providerID == providerID && model.isUsable {
            byID[model.publicID] = model
            byID[model.apiID] = byID[model.apiID] ?? model
        }
        registrations[providerID] = Registration(revision: revision, models: byID)
    }

    public func invalidate(providerID: String? = nil) {
        generation += 1
        if let providerID { registrations.removeValue(forKey: providerID) }
        else { registrations.removeAll() }
    }

    public func providerSummaries() async -> [ProviderSummary] {
        var result: [ProviderSummary] = []
        for definition in ProviderCatalog.definitions {
            let descriptor = try? descriptor(providerID: definition.id)
            let keyConfigured = (try? await credentials?.isCredentialConfigured(for: definition.id)) ?? false
            let configured = descriptor != nil && (!definition.credentialRequired || keyConfigured)
            result.append(.init(id: definition.id, label: definition.label, configured: configured, requiredEnv: definition.credentialRequired ? [credentialName(definition.id)] : [], type: .builtin, editable: definition.id == "openai-compatible"))
        }
        for provider in customProviders where provider.id != "openai-compatible" {
            // UUID custom providers intentionally permit anonymous local/LAN
            // endpoints, so configuration depends on the validated base URL.
            result.append(.init(id: provider.id, label: provider.name, configured: !provider.baseUrl.isEmpty, type: .custom, editable: true))
        }
        return result
    }

    public func publicModels() -> [ModelData] {
        var values = ProviderCatalog.models
        for provider in customProviders {
            for modelID in provider.manualModelIds {
                let verification = provider.capabilityCache?[modelID]
                let status = verification?.revision == provider.revision ? (verification?.status ?? .pending) : .pending
                values.append(ModelData(
                    id: provider.id == "openai-compatible" ? "openai-compatible/custom" : modelID,
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
        switch providerID {
        case "openai": return "OPENAI_API_KEY"
        case "openrouter": return "OPENROUTER_API_KEY"
        case "tokenplan": return "TOKENPLAN_API_KEY"
        case "dashscope": return "DASHSCOPE_API_KEY"
        default: return "OPENAI_COMPATIBLE_API_KEY"
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

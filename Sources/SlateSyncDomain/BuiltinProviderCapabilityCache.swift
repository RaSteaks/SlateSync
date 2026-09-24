import Foundation

/// Durable, secret-free probe results bound to the request configuration.
/// Display labels and default/backup selections do not invalidate a proof.
public struct BuiltinProviderCapabilityCache: Codable, Hashable, Sendable {
    public let provider: ProviderDescriptor
    public let configuredModel: String?
    public var results: [String: ModelCapabilityProbeResult]

    public init(provider: ProviderDescriptor, configuredModel: String? = nil,
                results: [String: ModelCapabilityProbeResult] = [:]) {
        self.provider = provider
        self.configuredModel = configuredModel
        self.results = results
    }

    public func matches(_ current: ProviderDescriptor, configuredModel: String?) -> Bool {
        provider.id == current.id && provider.baseURL == current.baseURL
            && provider.transport == current.transport && provider.jsonMode == current.jsonMode
            && provider.imageDetail == current.imageDetail && provider.revision == current.revision
            && provider.openRouterSiteURL == current.openRouterSiteURL
            && provider.openRouterTitle == current.openRouterTitle
            && self.configuredModel == configuredModel
    }

    /// Removing proofs on persisted route edits prevents switching away and
    /// back from reviving an old proof. Runtime matching also covers env overrides.
    public var settingKeys: [GlobalSettingKey] {
        switch provider.providerKind {
        case .openAI: [.openAIBaseUrl]
        case .openRouter: [.openRouterBaseUrl, .openRouterSiteUrl, .openRouterAppTitle]
        case .tokenPlan: [.tokenPlanBaseUrl]
        case .dashScope: [.dashScopeBaseUrl]
        case .openAICompatible: [.openAICompatibleBaseUrl, .openAICompatibleModel,
            .openAICompatibleAPIMode, .openAICompatibleJSONMode, .openAICompatibleImageDetail]
        case nil: []
        }
    }
}

import Foundation
import SlateSyncDomain

public enum RecognitionRouteResolver {
    /// Resolve a complete pair at one precedence level. A half-configured
    /// level is an error instead of an invitation to splice another layer.
    public static func resolve(
        request: ProviderModelSelection?,
        project: ProviderModelSelection?,
        global: GlobalSettingValues
    ) throws -> ProviderModelSelection {
        if let request { return try validated(request) }
        if let project { return try validated(project) }
        let provider = global[.defaultProviderID]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let model = global[.defaultModelID]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !provider.isEmpty, !model.isEmpty else { throw RecognitionFailure.providerNotConfigured }
        return try validated(.init(providerID: provider, modelID: model))
    }

    private static func validated(_ pair: ProviderModelSelection) throws -> ProviderModelSelection {
        guard ProviderModelSelection.isValidIdentifier(pair.providerID),
              ProviderModelSelection.isValidIdentifier(pair.modelID) else {
            throw RecognitionFailure.providerNotConfigured
        }
        return pair
    }
}

public enum FailoverChain {
    public static func plan(primary: ProviderModelSelection, chain: [ProviderModelSelection]) -> [ProviderModelSelection] {
        var seen: Set<ProviderModelSelection> = [primary]
        return [primary] + chain.filter { seen.insert($0).inserted }
    }
}

/// Shared only by currently active and queued recognition tasks. A provider
/// failure affects future dispatches; draining the batch clears transient state.
public actor RecognitionFailoverState {
    private var unavailableProviders: Set<String> = []

    public init() {}

    public func isAvailable(_ providerID: String) -> Bool {
        !unavailableProviders.contains(providerID)
    }

    public func markUnavailable(_ providerID: String) {
        unavailableProviders.insert(providerID)
    }

    public func reset() { unavailableProviders.removeAll() }
}

public enum FailoverErrorClassifier {
    public enum Disposition: Equatable, Sendable { case provider, page, none }

    public static func disposition(_ error: SlateSyncError) -> Disposition {
        if [RecognitionFailure.canceled.code, RecognitionFailure.invalidInput.code,
            RecognitionFailure.requestTooLarge.code].contains(error.code) { return .none }
        if error.code == RecognitionFailure.invalidStructuredJSON.code { return .page }
        if [RecognitionFailure.timeout.code, RecognitionFailure.connection.code,
            RecognitionFailure.invalidResponse.code].contains(error.code) { return .provider }
        if error.code == "PROVIDER_ERROR" {
            switch error.status {
            case 401, 402, 403, 408, 429: return .provider
            case let status? where status >= 500: return .provider
            default: return .none
            }
        }
        return .none
    }
}

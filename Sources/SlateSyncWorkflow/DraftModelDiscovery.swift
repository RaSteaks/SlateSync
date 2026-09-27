import Foundation
import SlateSyncDomain

/// A request-local credential never enters settings projections, caches or disk.
struct DraftProviderCredential: ProviderCredentialReading {
    let value: String
    func credential(for providerID: String) async throws -> String? { value }
    func isCredentialConfigured(for providerID: String) async throws -> Bool { !value.isEmpty }
}

enum DraftModelDiscovery {
    /// The one boundary for raw address validation, shared by direct callers and the facade.
    static func descriptor(baseURL: String) throws -> ProviderDescriptor {
        let normalized = try CustomProviderValidator.normalizeBaseURL(baseURL)
        guard let url = URL(string: normalized) else { throw RecognitionFailure.invalidURL }
        return ProviderDescriptor(id: "draft", label: "Draft", origin: .custom,
                                  baseURL: url, transport: .chatCompletions)
    }

    static func fetch(baseURL: String, transport: any ProviderHTTPTransporting) async throws -> [String] {
        try await fetch(provider: descriptor(baseURL: baseURL), transport: transport)
    }

    /// Listing IDs is not vision verification. The descriptor has already crossed
    /// the raw URL boundary; use it unchanged rather than normalizing a second time.
    static func fetch(provider: ProviderDescriptor, transport: any ProviderHTTPTransporting) async throws -> [String] {
        let response = try await transport.send(.init(provider: provider, purpose: .discovery, method: .get,
                                                      timeoutMilliseconds: ModelDiscoveryService.timeoutMilliseconds))
        try Task.checkCancellation()
        guard let root = try? JSONDecoder().decode(JSONValue.self, from: response.body),
              case .object(let fields) = root else { throw RecognitionFailure.invalidResponse }
        let candidates: [JSONValue]
        if case .array(let values)? = fields["data"] { candidates = values }
        else if case .array(let values)? = fields["models"] { candidates = values }
        else { throw RecognitionFailure.invalidResponse }
        let ids = candidates.compactMap { value -> String? in
            let raw: String?
            if case .string(let id) = value { raw = id }
            else if case .object(let fields) = value {
                raw = ["id", "model", "name"].compactMap { key -> String? in
                    if case .string(let text)? = fields[key] { return text }; return nil
                }.first
            } else { raw = nil }
            guard let id = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
                  ProviderCatalog.isValidModelID(id) else { return nil }
            return id
        }
        return Set(ids).sorted()
    }
}

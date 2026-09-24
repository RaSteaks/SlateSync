import Foundation

/// A provider and its physical model ID travel together through defaults and
/// failover. Keeping the pair atomic prevents cross-provider model mixing.
public struct ProviderModelSelection: Codable, Hashable, Sendable {
    public let providerID: String
    public let modelID: String

    public init(providerID: String, modelID: String) {
        self.providerID = providerID
        self.modelID = modelID
    }

    public static func isValidIdentifier(_ value: String) -> Bool {
        let pattern = #"^[A-Za-z0-9][A-Za-z0-9._:/@-]*$"#
        return (1...220).contains(value.utf16.count)
            && value.range(of: pattern, options: .regularExpression) != nil
    }

    public static func decodeAndValidateChain(_ text: String) throws -> [Self] {
        guard let data = text.data(using: .utf8),
              let chain = try? JSONDecoder().decode([Self].self, from: data),
              chain.count <= 8 else { throw invalidChain() }
        var seen = Set<Self>()
        for entry in chain {
            guard isValidIdentifier(entry.providerID),
                  isValidIdentifier(entry.modelID),
                  seen.insert(entry).inserted else { throw invalidChain() }
        }
        return chain
    }

    public static func encodeChain(_ chain: [Self]) throws -> String {
        guard chain.count <= 8 else { throw invalidChain() }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(chain)
        guard let value = String(data: data, encoding: .utf8) else { throw invalidChain() }
        _ = try decodeAndValidateChain(value)
        return value
    }

    private static func invalidChain() -> SlateSyncError {
        SlateSyncError(code: "GLOBAL_CONFIG_INVALID", message: "备用组合必须是最多 8 项、无重复且完整的 Provider/模型列表")
    }
}

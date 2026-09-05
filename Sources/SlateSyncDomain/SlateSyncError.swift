import Foundation

/// Stable user-facing error envelope retained from the typed Electron contract.
public struct SlateSyncError: Error, Codable, Hashable, Sendable, LocalizedError {
    public let code: String
    public let message: String
    public let retryable: Bool
    public let status: Int?
    public let providerError: Bool?

    public init(
        code: String,
        message: String,
        retryable: Bool = false,
        status: Int? = nil,
        providerError: Bool? = nil
    ) {
        self.code = code
        self.message = message
        self.retryable = retryable
        self.status = status
        self.providerError = providerError
    }

    public var errorDescription: String? { message }

    public static func wrapped(_ error: any Error, code: String = "UNKNOWN") -> Self {
        if let slateSyncError = error as? SlateSyncError {
            return slateSyncError
        }
        return .init(code: code, message: error.localizedDescription)
    }
}

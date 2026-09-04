import Foundation

/// Shared error construction for Codable unions. Keeping branch validation in
/// one helper makes every seam report malformed wire data without exposing
/// implementation details or accepting an impossible state.
enum DiscriminatedResultSupport {
    static func decodingError(_ decoder: any Decoder, _ message: String) -> DecodingError {
        .dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: message))
    }

    static func initializationError(_ message: String) -> SlateSyncError {
        SlateSyncError(code: "CONTRACT_INVALID", message: message)
    }
}

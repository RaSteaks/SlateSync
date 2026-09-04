import Foundation
import OSLog

public enum SlateSyncLogLevel: String, Codable, Hashable, Sendable {
    case info
    case warning
    case error
}

public enum SlateSyncLogPrivacy: String, Codable, Hashable, Sendable {
    case `public`
    case `private`
    case redacted
}

public struct StructuredLogEvent: Codable, Hashable, Sendable {
    public let level: SlateSyncLogLevel
    public let category: String
    public let message: String
    public let metadata: [String: JSONValue]

    public init(
        level: SlateSyncLogLevel,
        category: String,
        message: String,
        metadata: [String: JSONValue] = [:]
    ) {
        self.level = level
        self.category = category
        self.message = message
        self.metadata = metadata
    }
}

/// Pure redaction is the testable boundary. `SlateSyncLogger` always calls it
/// before constructing an OSLog interpolation, so a secret cannot be exposed
/// by formatting an object first and trying to scrub the final string later.
public enum StructuredLogRedactor {
    public static let redactedText = "[已隐藏]"
    private static let maximumDepth = 64

    public static func redact(_ event: StructuredLogEvent) -> StructuredLogEvent {
        StructuredLogEvent(
            level: event.level,
            category: event.category,
            message: redactText(event.message),
            metadata: redactObject(event.metadata)
        )
    }

    public static func redactObject(_ metadata: [String: JSONValue]) -> [String: JSONValue] {
        Dictionary(uniqueKeysWithValues: metadata.map { key, value in
            (key, redact(value, fieldName: key, depth: 0))
        })
    }

    public static func redact(_ value: JSONValue, fieldName: String? = nil) -> JSONValue {
        redact(value, fieldName: fieldName, depth: 0)
    }

    private static func redact(
        _ value: JSONValue,
        fieldName: String?,
        depth: Int
    ) -> JSONValue {
        guard depth <= maximumDepth else {
            // A bounded replacement is safer than allowing an attacker to
            // trigger unbounded recursive traversal while logging malformed
            // diagnostic JSON.
            return .string(redactedText)
        }
        if let fieldName, privacy(for: fieldName) == .redacted {
            return .string(redactedText)
        }
        switch value {
        case .null, .boolean, .number:
            return value
        case .string(let text):
            return .string(redactText(text))
        case .array(let values):
            return .array(values.map { redact($0, fieldName: nil, depth: depth + 1) })
        case .object(let object):
            return .object(Dictionary(uniqueKeysWithValues: object.map { key, value in
                (key, redact(value, fieldName: key, depth: depth + 1))
            }))
        }
    }

    public static func redactText(_ text: String) -> String {
        var result = text
        // Scrub standalone bearer/key forms first. This prevents a labelled
        // `Authorization: Bearer <token>` match from replacing only `Bearer`
        // and leaving the token as an unlabelled fragment.
        let genericPatterns = [
            "(?i)\\bBearer\\s+[A-Za-z0-9._~+/=-]+",
            "(?i)\\bBasic\\s+[A-Za-z0-9+/=]+",
            "\\bsk-[A-Za-z0-9._-]+",
            "\\bgh[pousr]_[A-Za-z0-9_]+",
            "\\bAKIA[0-9A-Z]{16}\\b",
            "\\bAIza[A-Za-z0-9_-]{20,}\\b",
        ]
        for pattern in genericPatterns {
            result = result.replacingOccurrences(of: pattern, with: redactedText, options: .regularExpression)
        }

        let labelledPatterns = [
            "(?i)(api[ _-]?key|access[ _-]?token|refresh[ _-]?token|id[ _-]?token|oauth[ _-]?token|auth(?:entication)?[ _-]?token|bearer[ _-]?token|token|authorization|proxy[ _-]?authorization|client[ _-]?secret|credential|password|secret|private[ _-]?key|cookie)\\s*[:=]\\s*(\\\"[^\\\"]*\\\"|'[^']*'|[^\\s,;]+)",
            "(?i)(api[ _-]?key|access[ _-]?token|refresh[ _-]?token|id[ _-]?token|oauth[ _-]?token|auth(?:entication)?[ _-]?token|bearer[ _-]?token|token|authorization|proxy[ _-]?authorization|client[ _-]?secret|credential|password|secret|private[ _-]?key|cookie)\\s+([^\\s,;]+)",
        ]
        for pattern in labelledPatterns {
            result = result.replacingOccurrences(
                of: pattern,
                with: "$1=\(redactedText)",
                options: .regularExpression
            )
        }
        return result
    }

    public static func privacy(for fieldName: String) -> SlateSyncLogPrivacy {
        let normalized = fieldName
            .lowercased()
            .filter { $0.isLetter || $0.isNumber }
        // Match complete compound names/suffixes, not arbitrary substrings:
        // 'author' is a normal public field, while 'authorToken' remains
        // sensitive because its token component is explicit.
        if sensitiveFieldNames.contains(normalized) ||
            normalized.hasSuffix("apikey") ||
            normalized.hasSuffix("token") ||
            normalized.hasSuffix("accesstoken") ||
            normalized.hasSuffix("authorization") ||
            normalized.hasSuffix("credential") ||
            normalized.hasSuffix("password") ||
            normalized.hasSuffix("secret") ||
            normalized.hasSuffix("privatekey") ||
            normalized.hasSuffix("cookie") ||
            normalized.hasSuffix("signingkey") ||
            normalized.hasSuffix("encryptionkey") {
            return .redacted
        }
        if normalized.contains("path") ||
            normalized.contains("requestid") ||
            normalized.contains("sessionid") ||
            normalized.contains("taskid") ||
            normalized.contains("diagnostic") {
            return .private
        }
        return .public
    }

    private static let sensitiveFieldNames: Set<String> = [
        "apikey", "token", "accesstoken", "refreshtoken", "idtoken", "oauthtoken",
        "authtoken", "bearertoken", "authorization", "proxyauthorization", "clientsecret",
        "credential", "credentials", "password", "secret", "privatekey", "cookie",
    ]
}

/// Thin OSLog adapter with a stable subsystem/category vocabulary. Metadata is
/// redacted as typed JSON before it is rendered into an OSLog message.
public struct SlateSyncLogger: Sendable {
    public static let subsystem = "com.slatesync.app"

    private let logger: Logger
    private let category: String

    public init(category: String) {
        self.category = category
        logger = Logger(subsystem: Self.subsystem, category: category)
    }

    public func info(_ message: String, metadata: [String: JSONValue] = [:]) {
        write(.info, message: message, metadata: metadata)
    }

    public func warning(_ message: String, metadata: [String: JSONValue] = [:]) {
        write(.warning, message: message, metadata: metadata)
    }

    public func error(_ message: String, metadata: [String: JSONValue] = [:]) {
        write(.error, message: message, metadata: metadata)
    }

    private func write(_ level: SlateSyncLogLevel, message: String, metadata: [String: JSONValue]) {
        let safeEvent = StructuredLogRedactor.redact(
            StructuredLogEvent(level: level, category: category, message: message, metadata: metadata)
        )
        let renderedMetadata = Self.render(safeEvent.metadata)
        switch level {
        case .info:
            // Messages can contain provider/network errors that do not match a
            // known secret pattern, so privacy must not rely on best-effort
            // redaction alone.
            logger.info("\(safeEvent.message, privacy: .private) \(renderedMetadata, privacy: .private)")
        case .warning:
            logger.warning("\(safeEvent.message, privacy: .private) \(renderedMetadata, privacy: .private)")
        case .error:
            logger.error("\(safeEvent.message, privacy: .private) \(renderedMetadata, privacy: .private)")
        }
    }

    private static func render(_ metadata: [String: JSONValue]) -> String {
        guard !metadata.isEmpty else { return "" }
        return metadata.keys.sorted().map { key in
            guard let value = metadata[key] else { return "" }
            return "\(key)=\(render(value))"
        }.joined(separator: " ")
    }

    private static func render(_ value: JSONValue) -> String {
        switch value {
        case .null: return "null"
        case .boolean(let value): return String(value)
        case .number(let value): return String(value)
        case .string(let value): return value
        case .array(let values): return "[\(values.map(render).joined(separator: ","))]"
        case .object(let values): return "{\(render(values))}"
        }
    }
}

public typealias LogRedactor = StructuredLogRedactor

import Foundation

/// Final projection boundary for native UI and local logs. Reuse the frozen
/// credential scrubber, then remove private media paths and raw payload tails.
/// Provider bodies never become user-facing copy, even if they contain an
/// unlabelled credential that no pattern-based scrubber could recognize.
public enum ProductPrivacy {
    public static func message(_ raw: String) -> String {
        var value = StructuredLogRedactor.redactText(raw)
        for pattern in [
            #"[\"']/(?:Users|Volumes|private|var|tmp)/[^\"']*[\"']"#,
            #"/(?:Users|Volumes|private|var|tmp)/[^\s\"']*"#,
            #"(?is)\b(?:request|response|payload|prompt|csv|provider[ _-]?body)\s*[:=].*$"#,
        ] {
            value = value.replacingOccurrences(of: pattern, with: "[已隐藏]", options: .regularExpression)
        }
        return String(value.prefix(240))
    }

    public static func error(_ error: Error) -> SlateSyncError {
        let value = SlateSyncError.wrapped(error)
        return SlateSyncError(
            code: message(value.code),
            message: value.providerError == true ? "Provider 请求失败，请检查设置后重试" : message(value.message),
            retryable: value.retryable,
            status: value.status,
            providerError: value.providerError
        )
    }

    public static func log(_ entry: ProductLogEntry) -> ProductLogEntry {
        // Identifiers have their own whitelist; truncating an arbitrary string
        // still exposes credentials supplied as an event/category/operation ID.
        let categories = ["app", "project", "settings", "recognition", "ocr", "csv", "metadata", "persistence"]
        // Restrict to product-owned event names; even an all-lowercase token
        // can be a secret, so a character-pattern check is insufficient.
        let events: Set<String> = ["event", "started", "completed", "failed", "cancelled", "retry",
            "created", "updated", "archived", "restored", "deleted", "imported", "exported",
            "saved", "credential-updated"]
        return ProductLogEntry(
            id: entry.id, timestamp: entry.timestamp, severity: entry.severity,
            category: categories.contains(entry.category) ? entry.category : "app",
            event: events.contains(entry.event) ? entry.event : "event",
            message: message(entry.message),
            operationID: entry.operationID.flatMap(UUID.init(uuidString:))?.uuidString,
            completed: entry.completed, total: entry.total
        )
    }
}

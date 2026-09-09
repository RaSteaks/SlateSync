import Foundation
import Synchronization

/// Discovery/probe metadata stamps refresh times in plain ISO8601.
/// ISO8601DateFormatter is not thread-safe, so the module shares one
/// Mutex-protected instance instead of building a fresh formatter per call.
enum WorkflowTimestamps {
    private static let formatter = Mutex({
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }())

    static func string(_ date: Date) -> String {
        formatter.withLock { $0.string(from: date) }
    }
}

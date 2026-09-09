import Foundation
import Synchronization

/// Shared ISO8601 formatters for persistence timestamps. ISO8601DateFormatter
/// is not thread-safe, so instead of building a fresh instance per call the
/// module serializes access on Mutex-protected singletons. The rendered bytes
/// are frozen by PersistenceTimestampsRegressionTests — never change
/// formatOptions without migrating stored snapshots.
enum PersistenceTimestamps {
    private static let fractional = Mutex({
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }())

    private static let plain = Mutex({
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }())

    static func string(_ date: Date, fractionalSeconds: Bool) -> String {
        // Mutex is noncopyable, so the instance is selected by branch — a
        // ternary would consume it.
        if fractionalSeconds {
            return fractional.withLock { $0.string(from: date) }
        }
        return plain.withLock { $0.string(from: date) }
    }

    /// v1 library import validation accepts both timestamp shapes; the
    /// fractional formatter cannot parse second-precision stamps, so both
    /// configurations are tried in order.
    static func parse(_ value: String) -> Date? {
        fractional.withLock { $0.date(from: value) } ?? plain.withLock { $0.date(from: value) }
    }
}

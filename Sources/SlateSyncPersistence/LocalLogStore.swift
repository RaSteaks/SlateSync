import Darwin
import Foundation
import SlateSyncDomain

/// Actor-owned daily log sink. The encoded schema is deliberately the
/// secret-free ProductLogEntry projection; writes are serialized and a failed
/// sink never interrupts the product operation that emitted the event.
public actor LocalLogStore {
    public static let retentionDays = 7
    public static let defaultReadLimit = 500
    public static let maximumReadLimit = 2_000

    public nonisolated let directory: URL
    private let calendar: Calendar
    private let now: @Sendable () -> Date
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(
        directory: URL,
        calendar: Calendar = Calendar(identifier: .gregorian),
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.directory = directory.standardizedFileURL
        self.calendar = calendar
        self.now = now
        encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
    }

    public func append(_ entry: ProductLogEntry) {
        do {
            try prepareDirectory()
            try rotate(reference: now())
            // Sanitize at the sink as well as the façade, so no caller can
            // accidentally bypass privacy by writing directly to Persistence.
            var line = try encoder.encode(ProductPrivacy.log(entry))
            line.append(0x0A)
            let url = fileURL(for: entry.timestamp)
            let descriptor = open(url.path, O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK, 0o600)
            guard descriptor >= 0 else { return }
            defer { Darwin.close(descriptor) }
            var status = stat()
            guard fstat(descriptor, &status) == 0, (status.st_mode & S_IFMT) == S_IFREG else { return }
            // Best-effort logging must not hang product shutdown behind an
            // external file lock or a FIFO placed in the log directory.
            guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else { return }
            defer { _ = flock(descriptor, LOCK_UN) }
            line.withUnsafeBytes { bytes in
                guard let start = bytes.baseAddress else { return }
                var offset = 0
                while offset < bytes.count {
                    let written = Darwin.write(descriptor, start.advanced(by: offset), bytes.count - offset)
                    guard written > 0 else { return }
                    offset += written
                }
            }
            _ = fchmod(descriptor, 0o600)
        } catch {
            // Logging is best-effort by contract. Never recurse into OSLog
            // with the raw error because it may contain a private path.
        }
    }

    public func read(
        limit requestedLimit: Int = defaultReadLimit,
        severities: Set<ProductLogSeverity> = [],
        category: String? = nil
    ) -> [ProductLogEntry] {
        readSnapshot(limit: requestedLimit, severities: severities, category: category).entries
    }

    public func readSnapshot(
        limit requestedLimit: Int = defaultReadLimit,
        severities: Set<ProductLogSeverity> = [],
        category: String? = nil
    ) -> ProductLogReadResult {
        let limit = min(Self.maximumReadLimit, max(1, requestedLimit))
        var directoryStatus = stat()
        guard lstat(directory.path, &directoryStatus) == 0 else {
            return .init(entries: [], degraded: errno != ENOENT)
        }
        guard (directoryStatus.st_mode & S_IFMT) == S_IFDIR else { return .init(entries: [], degraded: true) }
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return .init(entries: [], degraded: true) }
        let requestedCategory = category?.trimmingCharacters(in: .whitespacesAndNewlines)
        var result: [ProductLogEntry] = []
        var degraded = false, skipped = 0
        let cutoff = fileURL(for: calendar.date(byAdding: .day, value: -(Self.retentionDays - 1), to: now()) ?? now()).lastPathComponent
        let today = fileURL(for: now()).lastPathComponent
        for file in files.filter({ isLogFile($0) && $0.lastPathComponent >= cutoff && $0.lastPathComponent <= today }).sorted(by: { $0.lastPathComponent > $1.lastPathComponent }) {
            // Read a bounded tail with O_NOFOLLOW. Invalid UTF-8/partial JSON
            // damages only its line, never the whole day's valid entries.
            let descriptor = open(file.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
            guard descriptor >= 0 else { degraded = true; continue }
            var status = stat()
            guard fstat(descriptor, &status) == 0, (status.st_mode & S_IFMT) == S_IFREG else {
                Darwin.close(descriptor); degraded = true; continue
            }
            let offset = max(0, status.st_size - 4 * 1024 * 1024)
            _ = lseek(descriptor, offset, SEEK_SET)
            var data = Data(), buffer = [UInt8](repeating: 0, count: 64 * 1024)
            while data.count < 4 * 1024 * 1024 {
                let count = Darwin.read(descriptor, &buffer, min(buffer.count, 4 * 1024 * 1024 - data.count))
                if count < 0 { degraded = true; break }
                if count == 0 { break }
                data.append(contentsOf: buffer.prefix(count))
            }
            Darwin.close(descriptor)
            var lines = data.split(separator: 0x0A, omittingEmptySubsequences: true)
            if offset > 0, !lines.isEmpty { lines.removeFirst(); degraded = true }
            if data.last != 0x0A, !lines.isEmpty { lines.removeLast(); degraded = true; skipped += 1 }
            for line in lines.reversed() {
                guard let entry = try? decoder.decode(ProductLogEntry.self, from: Data(line)) else { degraded = true; skipped += 1; continue }
                guard severities.isEmpty || severities.contains(entry.severity) else { continue }
                guard requestedCategory?.isEmpty != false || entry.category == requestedCategory else { continue }
                result.append(ProductPrivacy.log(entry))
            }
        }
        return .init(entries: Array(result.sorted { $0.timestamp > $1.timestamp }.prefix(limit)), degraded: degraded, skippedLines: skipped)
    }

    private func prepareDirectory() throws {
        var status = stat()
        if lstat(directory.path, &status) == 0, (status.st_mode & S_IFMT) == S_IFLNK {
            throw SlateSyncError(code: "LOG_PATH_INVALID", message: "日志目录不能是符号链接")
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
    }

    private func rotate(reference: Date) throws {
        guard let cutoff = calendar.date(byAdding: .day, value: -(Self.retentionDays - 1), to: reference) else { return }
        let values = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey])
        for file in values where isLogFile(file) {
            if file.lastPathComponent < fileURL(for: cutoff).lastPathComponent { try? FileManager.default.removeItem(at: file) }
        }
    }

    private func isLogFile(_ url: URL) -> Bool {
        url.lastPathComponent.range(of: #"^slatesync-\d{4}-\d{2}-\d{2}\.log$"#, options: .regularExpression) != nil
    }

    private func fileURL(for date: Date) -> URL {
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        let name = String(format: "slatesync-%04d-%02d-%02d.log", components.year ?? 0, components.month ?? 0, components.day ?? 0)
        return directory.appending(path: name)
    }
}

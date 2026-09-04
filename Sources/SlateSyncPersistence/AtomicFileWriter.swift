import Foundation
import Darwin
import SlateSyncDomain

public protocol AtomicFileWriting: Sendable {
    func writeAtomically(_ data: Data, to url: URL, permissions: Int) throws
}

/// Centralizes the private filesystem boundary shared by all machine-level
/// stores. Existing paths are repaired as well as newly-created paths so an
/// older installation cannot silently keep broader permissions forever.
public enum SecureFilePermissions {
    public static func prepareDirectory(at url: URL) throws {
        let fileManager = FileManager.default
        do {
            try fileManager.createDirectory(
                at: url,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: NSNumber(value: 0o700)]
            )
            try fileManager.setAttributes(
                [.posixPermissions: NSNumber(value: 0o700)],
                ofItemAtPath: url.path
            )
        } catch {
            throw SlateSyncError(code: "PERSISTENCE_PERMISSIONS", message: "无法保护配置目录")
        }
    }

    public static func repairFile(at url: URL, permissions: Int = 0o600) throws {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        do {
            try FileManager.default.setAttributes(
                [.posixPermissions: NSNumber(value: permissions)],
                ofItemAtPath: url.path
            )
        } catch {
            throw SlateSyncError(code: "PERSISTENCE_PERMISSIONS", message: "无法保护配置文件")
        }
    }

    public static func repairDirectory(at url: URL) throws {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        do {
            try FileManager.default.setAttributes(
                [.posixPermissions: NSNumber(value: 0o700)],
                ofItemAtPath: url.path
            )
        } catch {
            throw SlateSyncError(code: "PERSISTENCE_PERMISSIONS", message: "无法保护配置目录")
        }
    }
}

/// A small advisory lock shared by native writers that coordinate a
/// compare-and-delete or legacy-file removal. The lock is intentionally kept
/// as a sidecar rather than in the secret payload; callers that do not use
/// this process-wide convention are outside the migration's atomicity claim.
enum CrossProcessFileLock {
    static func withExclusiveLock<Value>(
        at url: URL,
        timeout: TimeInterval = 5,
        _ operation: () throws -> Value
    ) throws -> Value {
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: NSNumber(value: 0o700)]
            )
            try FileManager.default.setAttributes(
                [.posixPermissions: NSNumber(value: 0o700)],
                ofItemAtPath: url.deletingLastPathComponent().path
            )
        } catch {
            throw SlateSyncError(code: "FILE_LOCK", message: "无法建立文件协调锁目录")
        }

        let descriptor = open(url.path, O_CREAT | O_RDWR, mode_t(S_IRUSR | S_IWUSR))
        guard descriptor >= 0 else {
            throw SlateSyncError(code: "FILE_LOCK", message: "无法建立文件协调锁")
        }
        defer { close(descriptor) }

        guard fchmod(descriptor, mode_t(S_IRUSR | S_IWUSR)) == 0 else {
            throw SlateSyncError(code: "FILE_LOCK", message: "无法保护文件协调锁")
        }
        let timeoutNanoseconds = UInt64(max(0, timeout) * 1_000_000_000)
        let deadline = DispatchTime.now().uptimeNanoseconds &+ timeoutNanoseconds
        while true {
            if flock(descriptor, LOCK_EX | LOCK_NB) == 0 { break }
            if errno == EINTR { continue }
            guard errno == EWOULDBLOCK || errno == EAGAIN else {
                throw SlateSyncError(code: "FILE_LOCK", message: "无法取得文件协调锁")
            }
            guard DispatchTime.now().uptimeNanoseconds < deadline else {
                throw SlateSyncError(code: "FILE_LOCK_TIMEOUT", message: "取得文件协调锁超时")
            }
            // Keep the bounded wait cooperative; this path is only a
            // cross-process safety net and never holds the Swift actor.
            Thread.sleep(forTimeInterval: 0.01)
        }
        defer { _ = flock(descriptor, LOCK_UN) }
        return try operation()
    }
}

public struct FileManagerAtomicFileWriter: AtomicFileWriting, Sendable {
    public init() {}

    public func writeAtomically(_ data: Data, to url: URL, permissions: Int = 0o600) throws {
        let fileManager = FileManager.default
        let directory = url.deletingLastPathComponent()
        try SecureFilePermissions.prepareDirectory(at: directory)

        // A unique sibling avoids colliding with another actor writing the
        // same settings file while preserving the final rename boundary.
        let temporaryURL = directory.appendingPathComponent(
            ".\(url.lastPathComponent).\(UUID().uuidString).tmp"
        )
        defer {
            // A failed write must not leave an ambiguous temporary snapshot.
            try? fileManager.removeItem(at: temporaryURL)
        }

        guard fileManager.createFile(
            atPath: temporaryURL.path,
            contents: nil,
            attributes: [.posixPermissions: NSNumber(value: permissions)]
        ) else {
            throw SlateSyncError(code: "ATOMIC_WRITE", message: "无法创建临时配置文件")
        }
        try data.write(to: temporaryURL)
        try fileManager.setAttributes(
            [.posixPermissions: NSNumber(value: permissions)],
            ofItemAtPath: temporaryURL.path
        )

        if fileManager.fileExists(atPath: url.path) {
            _ = try fileManager.replaceItemAt(
                url,
                withItemAt: temporaryURL,
                backupItemName: nil,
                options: .usingNewMetadataOnly
            )
        } else {
            try fileManager.moveItem(at: temporaryURL, to: url)
        }
        try fileManager.setAttributes(
            [.posixPermissions: NSNumber(value: permissions)],
            ofItemAtPath: url.path
        )
    }
}

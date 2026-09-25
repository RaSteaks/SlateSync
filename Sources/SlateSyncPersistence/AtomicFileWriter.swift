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

/// Advisory sidecar lock for cooperating native processes performing atomic
/// file transactions or Keychain compare-and-delete. This is synchronous;
/// asynchronous credential callers must dispatch it to their I/O queue.
enum CrossProcessFileLock {
    static func withExclusiveLock<Value>(
        at url: URL,
        timeout: TimeInterval = 5,
        isolation: isolated (any Actor)? = #isolation,
        checkCancellation: () throws -> Void = {},
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

        let descriptor = open(url.path, O_CREAT | O_RDWR | O_NOFOLLOW, mode_t(S_IRUSR | S_IWUSR))
        guard descriptor >= 0 else {
            throw SlateSyncError(code: "FILE_LOCK", message: "无法建立文件协调锁")
        }
        defer { close(descriptor) }
        // Credential locks must not follow symlinks or operate on devices and
        // hard-linked files; validate the opened inode before changing metadata.
        var lockInfo = stat()
        guard fstat(descriptor, &lockInfo) == 0,
              (lockInfo.st_mode & S_IFMT) == S_IFREG,
              lockInfo.st_nlink == 1, lockInfo.st_uid == getuid() else {
            throw SlateSyncError(code: "FILE_LOCK", message: "文件协调锁类型无效")
        }

        guard fchmod(descriptor, mode_t(S_IRUSR | S_IWUSR)) == 0 else {
            throw SlateSyncError(code: "FILE_LOCK", message: "无法保护文件协调锁")
        }
        let timeoutNanoseconds = UInt64(max(0, timeout) * 1_000_000_000)
        let deadline = DispatchTime.now().uptimeNanoseconds &+ timeoutNanoseconds
        while true {
            try checkCancellation()
            if flock(descriptor, LOCK_EX | LOCK_NB) == 0 { break }
            if errno == EINTR { continue }
            guard errno == EWOULDBLOCK || errno == EAGAIN else {
                throw SlateSyncError(code: "FILE_LOCK", message: "无法取得文件协调锁")
            }
            guard DispatchTime.now().uptimeNanoseconds < deadline else {
                throw SlateSyncError(code: "FILE_LOCK_TIMEOUT", message: "取得文件协调锁超时")
            }
            // This synchronous wait blocks its caller. Credential operations
            // call from their dedicated I/O queue, with cancellation checks.
            Thread.sleep(forTimeInterval: 0.01)
        }
        defer { _ = flock(descriptor, LOCK_UN) }
        return try operation()
    }
}

public struct FileManagerAtomicFileWriter: AtomicFileWriting, Sendable {
    public init() {}

    public func writeAtomically(_ data: Data, to url: URL, permissions: Int = 0o600) throws {
        // Only files beneath an activated encrypted library are sealed. Export
        // destinations outside that boundary retain their portable format.
        let id = try LocalProjectEncryption.identifier(for: url)
        let output = try id.map { try LocalProjectEncryption.seal(data, id: $0) } ?? data
        try writeRaw(output, to: url, permissions: permissions)
    }

    func writeRaw(_ data: Data, to url: URL, permissions: Int) throws {
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

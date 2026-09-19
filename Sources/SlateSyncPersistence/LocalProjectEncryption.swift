import CryptoKit
import Foundation
import SlateSyncDomain
import Synchronization

/// Versioned authenticated envelopes for internal project files. Keys are held
/// in the login keychain; the marker contains only a random key identifier.
public enum LocalProjectEncryption {
    static let markerName = ".slatesync-encryption"
    private static let magic = Data("SLATESYNC-AES-GCM-1\n".utf8)
    private static let keys = Mutex<[String: SymmetricKey]>([:])
    private static let unlocks = ProjectKeyUnlockCoordinator()
    private static let service = "com.slatesync.local-project-encryption"

    static func error(_ message: String) -> SlateSyncError {
        SlateSyncError(code: "PROJECT_ENCRYPTION", message: message)
    }

    /// An existing marker must never result in a replacement key: losing the
    /// key is a recoverable access error, not permission to overwrite data.
    public static func prepare(at root: URL, backend: any KeychainBackend = SecurityKeychainBackend()) async throws {
        try SecureFilePermissions.prepareDirectory(at: root)
        // Validate the entire tree before reading a marker or changing data.
        _ = try migrationFiles(at: root)
        let marker = root.appending(path: markerName)
        let exists = FileManager.default.fileExists(atPath: marker.path)
        let id = exists ? try String(contentsOf: marker, encoding: .utf8) : await unlocks.newIdentifier(for: root.standardizedFileURL.path)
        guard UUID(uuidString: id) != nil else { throw error("本地加密标识无效") }
        let bytes = try await unlocks.unlock(id: id, mayCreate: !exists, service: service, backend: backend)
        keys.withLock { $0[id] = SymmetricKey(data: bytes) }
        if !exists {
            let installedID = try CrossProcessFileLock.withExclusiveLock(at: root.appending(path: ".encryption-setup.lock.tmp")) {
                if FileManager.default.fileExists(atPath: marker.path) {
                    return try String(contentsOf: marker, encoding: .utf8)
                }
                try FileManagerAtomicFileWriter().writeRaw(Data(id.utf8), to: marker, permissions: 0o600)
                return id
            }
            if installedID != id {
                // Another process won first activation; use its durable key ID.
                return try await prepare(at: root, backend: backend)
            }
        }
        // Resumable per-file migration: authenticate and atomically replace
        // each file. An interrupted migration is completed at the next launch.
        try await migrate(at: root)
    }

    /// Validation may unlock an existing library, but must not create a key,
    /// install a marker, or migrate a portable package before it is accepted.
    static func unlockExisting(at root: URL, backend: any KeychainBackend) async throws {
        guard let id = try identifier(for: root.appending(path: "library.json")) else { return }
        let bytes = try await unlocks.unlock(id: id, mayCreate: false, service: service, backend: backend)
        keys.withLock { $0[id] = SymmetricKey(data: bytes) }
    }

    /// Called only from explicit project-library Retry or import actions.
    public static func allowUnlockRetry() async { await unlocks.allowRetry() }

    /// Simulates process exit in isolated tests; production never clears keys
    /// while an encrypted database is open.
    static func resetUnlockCacheForTesting() async {
        await unlocks.reset()
        keys.withLock { $0.removeAll() }
    }

    static func identifier(for url: URL) throws -> String? {
        var parent = url.deletingLastPathComponent().standardizedFileURL
        while parent.path != "/" {
            let marker = parent.appending(path: markerName)
            if FileManager.default.fileExists(atPath: marker.path) {
                let id = try String(contentsOf: marker, encoding: .utf8)
                guard UUID(uuidString: id) != nil else { throw error("本地加密标识无效") }
                return id
            }
            parent.deleteLastPathComponent()
        }
        return nil
    }

    static func isEncrypted(_ data: Data) -> Bool { data.starts(with: magic) }

    static func seal(_ data: Data, id: String) throws -> Data {
        guard let key = keys.withLock({ $0[id] }) else { throw error("本地加密密钥尚未解锁") }
        let header = magic + Data(id.utf8) + Data([10])
        let sealed = try AES.GCM.seal(data, using: key, authenticating: header)
        guard let combined = sealed.combined else { throw error("无法加密项目数据") }
        return header + combined
    }

    static func open(_ data: Data) throws -> Data {
        guard isEncrypted(data) else { return data }
        let headerSize = magic.count + 37
        guard data.count > headerSize,
              data[headerSize - 1] == 10,
              let id = String(data: data[magic.count..<(headerSize - 1)], encoding: .utf8),
              let key = keys.withLock({ $0[id] }) else { throw error("找不到项目数据的本地加密密钥") }
        do {
            return try AES.GCM.open(AES.GCM.SealedBox(combined: data.dropFirst(headerSize)), using: key, authenticating: data.prefix(headerSize))
        } catch { throw Self.error("项目数据解密校验失败，文件可能损坏；原文件未被覆盖") }
    }

    static func read(from url: URL) throws -> Data { try open(Data(contentsOf: url)) }

    /// Encrypted SQLite databases run entirely in memory, so these derived
    /// files are never valid after an encrypted snapshot has been installed.
    /// Removing them also closes the crash window between replacing the main
    /// snapshot and cleaning legacy plaintext WAL artifacts.
    static func removeSQLiteSidecars(for url: URL) throws {
        for suffix in ["-wal", "-shm", "-journal"] {
            let sidecar = URL(fileURLWithPath: url.path + suffix)
            if FileManager.default.fileExists(atPath: sidecar.path) {
                try FileManager.default.removeItem(at: sidecar)
            }
        }
    }

    private static func migrationFiles(at root: URL) throws -> [URL] {
        var traversalFailed = false
        guard let files = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
            errorHandler: { _, _ in traversalFailed = true; return false }
        ) else {
            throw error("无法读取待加密项目库")
        }
        // Materialize before awaiting SQLite so directory traversal remains local.
        var urls: [URL] = []
        for case let url as URL in files {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values.isSymbolicLink != true else { throw error("加密项目库不能包含符号链接") }
            if values.isRegularFile == true { urls.append(url) }
        }
        guard !traversalFailed else { throw error("无法完整读取待加密项目库") }
        return urls
    }

    private static func migrate(at root: URL) async throws {
        let urls = try migrationFiles(at: root)
        for url in urls where url.pathExtension == "sqlite" {
            // Already-encrypted databases need authentication, not resealing.
            let stored = try Data(contentsOf: url)
            if isEncrypted(stored) {
                // Re-read under the same lock used by SQLite writers before
                // removing sidecars left by an interrupted migration.
                try CrossProcessFileLock.withExclusiveLock(at: URL(fileURLWithPath: url.path + ".lock.tmp")) {
                    let current = try Data(contentsOf: url)
                    guard isEncrypted(current) else { throw error("项目数据库格式在迁移期间发生变化") }
                    _ = try open(current)
                    try removeSQLiteSidecars(for: url)
                }
                continue
            }
            let database = try SQLiteDatabase(url: url)
            try await database.close()
        }
        for url in urls where url.pathExtension == "json" {
            let stored = try Data(contentsOf: url)
            let data = try open(stored)
            if !isEncrypted(stored) {
                try FileManagerAtomicFileWriter().writeAtomically(data, to: url, permissions: 0o600)
            }
        }
    }
}

/// Shares one authorization request per key ID and remembers a refusal until
/// the user explicitly retries. No key or failure state is persisted to disk.
private actor ProjectKeyUnlockCoordinator {
    private var provisionalIDs: [String: String] = [:]
    private var values: [String: Data] = [:]

    func newIdentifier(for path: String) -> String {
        if let id = provisionalIDs[path] { return id }
        let id = UUID().uuidString
        provisionalIDs[path] = id
        return id
    }
    private var pending: [String: Task<Data, any Error>] = [:]
    private var failures: [String: SlateSyncError] = [:]

    func unlock(id: String, mayCreate: Bool, service: String, backend: any KeychainBackend) async throws -> Data {
        if let value = values[id] { return value }
        if let failure = failures[id] { throw failure }
        let task: Task<Data, any Error>
        if let existing = pending[id] { task = existing }
        else {
            task = Task {
                var bytes = try await backend.read(service: service, account: id)
                if bytes == nil {
                    guard mayCreate else { throw LocalProjectEncryption.error("找不到此项目库的本地加密密钥，请恢复原 Mac 钥匙串或导入已导出的项目包") }
                    let candidate = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
                    _ = try await backend.createIfAbsent(candidate, service: service, account: id)
                    bytes = try await backend.read(service: service, account: id)
                }
                guard let bytes, bytes.count == 32 else { throw LocalProjectEncryption.error("无法读取本地加密密钥") }
                return bytes
            }
            pending[id] = task
        }
        do {
            let bytes = try await task.value
            pending[id] = nil
            values[id] = bytes
            return bytes
        } catch {
            pending[id] = nil
            let failure = SlateSyncError(code: "PROJECT_UNLOCK_REQUIRED", message: "项目库尚未解锁，请允许钥匙串访问后点击重试。若密钥已丢失，请恢复原钥匙串或导入备份。", retryable: true)
            failures[id] = failure
            throw failure
        }
    }

    func allowRetry() { failures.removeAll() }
    func reset() { values.removeAll(); failures.removeAll(); pending.removeAll() }
}

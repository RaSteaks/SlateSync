import CryptoKit
import Darwin
import Foundation
import SlateSyncDomain
import Synchronization

/// Machine-local authenticated credentials. The independent master file removes
/// Keychain prompts, but a reader with both files can decrypt the credentials.
public final class EncryptedFileCredentialStore: Sendable, ProviderCredentialReading {
    private static let header = Data("SLATESYNC-CREDENTIALS-AES256-GCM-1\n".utf8)
    private let queue = DispatchQueue(label: "com.slatesync.credentials.io")
    private let lockTimeout: TimeInterval
    private let directory: URL
    private let writer: any AtomicFileWriting
    private var keyURL: URL { directory.appending(path: "master.key") }
    private var payloadURL: URL { directory.appending(path: "provider-keys.enc") }
    private var lockURL: URL { directory.appending(path: ".credentials.lock") }

    public init(locator: ApplicationSupportLocator, writer: any AtomicFileWriting = FileManagerAtomicFileWriter(), lockTimeout: TimeInterval = 5) {
        directory = locator.url.appending(path: "Credentials", directoryHint: .isDirectory)
        self.writer = writer
        self.lockTimeout = lockTimeout
    }

    public func credential(for providerID: String) async throws -> String? {
        try await value(providerID: providerID)
    }

    public func isCredentialConfigured(for providerID: String) async throws -> Bool {
        try await value(providerID: providerID) != nil
    }

    public func value(providerID: String) async throws -> String? {
        try validate(providerID)
        return try await coordinated { store in try store.read()[providerID] }
    }

    public func status(providerID: String) async throws -> CredentialStatus {
        try await statuses(for: [providerID])[providerID] ?? .missing
    }

    /// One vault snapshot per projection; secret bytes never leave this store.
    /// Cancellation is propagated, while recoverable file failures remain visible.
    public func statuses(for providerIDs: [String]) async throws -> [String: CredentialStatus] {
        for id in providerIDs { try validate(id) }
        try Task.checkCancellation()
        guard !providerIDs.isEmpty else { return [:] }
        do {
            return try await coordinated { store in
                let entries = try store.read()
                return Dictionary(uniqueKeysWithValues: Set(providerIDs).map {
                    ($0, entries[$0] == nil ? CredentialStatus.missing : .configured)
                })
            }
        } catch is CancellationError { throw CancellationError() }
        catch {
            let code = (error as? SlateSyncError)?.code
            let status: CredentialStatus = switch code {
            case "FILE_LOCK_TIMEOUT": .temporarilyUnavailable
            case "CREDENTIAL_CORRUPT", "CREDENTIAL_KEY_MISSING": .unreadable
            default: .unavailable
            }
            return Dictionary(uniqueKeysWithValues: Set(providerIDs).map { ($0, status) })
        }
    }

    public func setValue(_ value: String?, providerID: String) async throws {
        try validate(providerID)
        try await coordinated { store in
            // Always read under the cross-process lock; never overwrite a newer
            // writer or recover a corrupt vault by silently replacing its key.
            var entries = try store.read()
            let cleaned = value?.trimmingCharacters(in: .whitespacesAndNewlines)
            entries[providerID] = cleaned.flatMap { $0.isEmpty ? nil : $0 }
            let key = try store.masterKey(create: true)
            let plain = try JSONEncoder().encode(entries)
            let box = try AES.GCM.seal(plain, using: key, authenticating: Self.header)
            guard let combined = box.combined else { throw store.accessFailure() }
            try store.writer.writeAtomically(Self.header + combined, to: store.payloadURL, permissions: 0o600)
        }
    }

    /// Explicit destructive recovery only. Keep the lock inode stable so other
    /// processes cannot acquire a different lock while this reset is running.
    public func reset() async throws {
        try await coordinated { store in
            for url in [store.payloadURL, store.keyURL] where try store.exists(url) {
                try FileManager.default.removeItem(at: url)
            }
        }
    }

    private func read() throws -> [String: String] {
        guard try exists(payloadURL) else {
            if try exists(keyURL) { _ = try masterKey(create: false) }
            return [:]
        }
        let key = try masterKey(create: false)
        let data = try Data(contentsOf: payloadURL)
        do {
            guard data.starts(with: Self.header) else { throw corruptFailure() }
            let box = try AES.GCM.SealedBox(combined: data.dropFirst(Self.header.count))
            let plain = try AES.GCM.open(box, using: key, authenticating: Self.header)
            let entries = try JSONDecoder().decode([String: String].self, from: plain)
            for id in entries.keys { try validate(id) }
            return entries
        } catch { throw corruptFailure() }
    }

    private func masterKey(create: Bool) throws -> SymmetricKey {
        if try exists(keyURL) {
            let data = try Data(contentsOf: keyURL)
            guard data.count == 32 else { throw corruptFailure() }
            return SymmetricKey(data: data)
        }
        guard create, try !exists(payloadURL) else {
            throw SlateSyncError(code: "CREDENTIAL_KEY_MISSING", message: "本地凭据主密钥缺失，无法解密；如无法恢复，可重置本地凭据后重新填写 API Key。")
        }
        let key = SymmetricKey(size: .bits256)
        try writer.writeAtomically(key.withUnsafeBytes { Data($0) }, to: keyURL, permissions: 0o600)
        return key
    }

    /// Synchronous filesystem work runs only on a dedicated queue, never on a
    /// Swift cooperative executor. Cancellation can finish a queued request early.
    private func coordinated<T: Sendable>(_ body: @escaping @Sendable (EncryptedFileCredentialStore) throws -> T) async throws -> T {
        let request = CredentialFileRequest<T>()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                request.install(continuation)
                queue.async { [self] in
                    do {
                        try request.checkCancellation()
                        try checkDirectory()
                        _ = try exists(lockURL)
                        let result = try CrossProcessFileLock.withExclusiveLock(
                            at: lockURL, timeout: lockTimeout, checkCancellation: { try request.checkCancellation() }
                        ) {
                            // Once admitted, the transaction returns its actual result,
                            // even if cancellation races with an atomic replacement.
                            try request.beginCommit()
                            _ = try exists(keyURL)
                            _ = try exists(payloadURL)
                            return try body(self)
                        }
                        request.finish(.success(result))
                    } catch is CancellationError { request.finish(.failure(CancellationError())) }
                    catch let error as SlateSyncError { request.finish(.failure(error)) }
                    catch { request.finish(.failure(accessFailure())) }
                }
            }
        } onCancel: { request.cancel() }
    }

    private func checkDirectory() throws {
        let parent = directory.deletingLastPathComponent()
        var parentInfo = stat()
        if lstat(parent.path, &parentInfo) == 0 {
            guard (parentInfo.st_mode & S_IFMT) == S_IFDIR, parentInfo.st_uid == getuid() else { throw accessFailure() }
        } else if errno != ENOENT { throw accessFailure() }
        try SecureFilePermissions.prepareDirectory(at: parent)
        var info = stat()
        if lstat(directory.path, &info) == 0 {
            guard (info.st_mode & S_IFMT) == S_IFDIR, info.st_uid == getuid() else { throw accessFailure() }
        } else if errno != ENOENT { throw accessFailure() }
        try SecureFilePermissions.prepareDirectory(at: directory)
    }

    /// lstat rejects dangling links, directories, devices and hard-linked files
    /// before any read, chmod, replacement or deletion can follow them.
    private func exists(_ url: URL) throws -> Bool {
        var info = stat()
        guard lstat(url.path, &info) == 0 else {
            if errno == ENOENT { return false }
            throw accessFailure()
        }
        guard (info.st_mode & S_IFMT) == S_IFREG, info.st_nlink == 1, info.st_uid == getuid() else { throw accessFailure() }
        try SecureFilePermissions.repairFile(at: url)
        return true
    }

    private func validate(_ id: String) throws {
        guard !id.isEmpty, id.count <= 256, !id.contains("\0") else { throw accessFailure() }
    }

    private func corruptFailure() -> SlateSyncError {
        SlateSyncError(code: "CREDENTIAL_CORRUPT", message: "本地凭据无法解密；如无法恢复，可重置本地凭据后重新填写 API Key。")
    }

    private func accessFailure() -> SlateSyncError {
        SlateSyncError(code: "CREDENTIAL_ACCESS", message: "无法访问本地凭据，请检查文件权限后重试。")
    }
}

/// Mutex protects continuation ownership and the cancellation/commit boundary.
/// Cancellation never races a second resume or reports a committed write as canceled.
private final class CredentialFileRequest<Value: Sendable>: Sendable {
    private struct State {
        var continuation: CheckedContinuation<Value, any Error>?
        var canceled = false
        var committing = false
    }
    private let state = Mutex(State())

    func install(_ continuation: CheckedContinuation<Value, any Error>) {
        let canceled = state.withLock { state in
            if state.canceled { return true }
            state.continuation = continuation
            return false
        }
        if canceled { continuation.resume(throwing: CancellationError()) }
    }

    func checkCancellation() throws {
        if state.withLock({ $0.canceled }) { throw CancellationError() }
    }

    func beginCommit() throws {
        try state.withLock { state in
            if state.canceled { throw CancellationError() }
            state.committing = true
        }
    }

    func cancel() {
        let continuation = state.withLock { state -> CheckedContinuation<Value, any Error>? in
            guard !state.committing else { return nil }
            state.canceled = true
            defer { state.continuation = nil }
            return state.continuation
        }
        continuation?.resume(throwing: CancellationError())
    }

    func finish(_ result: Result<Value, any Error>) {
        let continuation = state.withLock { state in
            defer { state.continuation = nil }
            return state.continuation
        }
        continuation?.resume(with: result)
    }
}

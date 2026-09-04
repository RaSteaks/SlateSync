import Foundation
import Security
import SlateSyncDomain

/// Minimal asynchronous seam around Security.framework. The migration actor
/// depends on this protocol so tests never need to touch the user's real
/// login keychain.
public protocol KeychainBackend: Sendable {
    func read(service: String, account: String) async throws -> Data?
    func write(_ data: Data, service: String, account: String) async throws
    func createIfAbsent(
        _ data: Data,
        service: String,
        account: String
    ) async throws -> KeychainCreateResult
    func delete(service: String, account: String) async throws
    func deleteIfMatching(
        _ expected: Data,
        service: String,
        account: String,
        ownership: Data?
    ) async throws -> KeychainConditionalDeleteResult
}

public enum KeychainCreateResult: Hashable, Sendable {
    /// The backend created the item and returned an opaque ownership marker.
    /// The marker is never included in a report, error, or persisted file.
    case created(ownership: Data)
    case alreadyExists
}

public enum KeychainConditionalDeleteResult: String, Codable, Hashable, Sendable {
    case removed
    case notFound
    case valueChanged
}

public extension KeychainBackend {
    /// Keep the original test/caller shape for a plain value comparison. A
    /// migration passes the ownership marker explicitly when compensating.
    func deleteIfMatching(
        _ expected: Data,
        service: String,
        account: String
    ) async throws -> KeychainConditionalDeleteResult {
        try await deleteIfMatching(
            expected,
            service: service,
            account: account,
            ownership: nil
        )
    }
}

/// Production Keychain backend. API-key bytes are kept in Security.framework;
/// this adapter never serializes them into a Swift Codable value or log event.
public struct SecurityKeychainBackend: KeychainBackend, Sendable {
    private let coordinationDirectory: URL
    private let usesDataProtectionKeychain: Bool

    /// Keychain operations are coordinated in Application Support so every
    /// SlateSync process uses the same namespace across launches. Tests pass a
    /// private directory and therefore never contend with production locks.
    public init(
        coordinationDirectory: URL? = nil,
        usesDataProtectionKeychain: Bool = true
    ) {
        self.usesDataProtectionKeychain = usesDataProtectionKeychain
        if let coordinationDirectory {
            self.coordinationDirectory = coordinationDirectory.standardizedFileURL
        } else if let root = try? ApplicationSupportLocator().url {
            self.coordinationDirectory = root.appending(path: ".locks", directoryHint: .isDirectory)
        } else {
            // Keep the fallback deterministic as well. A temporary-directory
            // lock would split the coordination namespace when GUI and CLI
            // processes use different TMPDIR values; if this path is not
            // writable, the operation fails closed instead of racing.
            self.coordinationDirectory = FileManager.default.homeDirectoryForCurrentUser
                .appending(path: "Library/Application Support/SlateSync/.locks", directoryHint: .isDirectory)
        }
    }

    public func read(service: String, account: String) async throws -> Data? {
        try withLock(service: service) {
            var query = baseQuery(service: service, account: account)
            query[kSecReturnData as String] = true
            query[kSecMatchLimit as String] = kSecMatchLimitOne
            var result: CFTypeRef?
            let status = SecItemCopyMatching(query as CFDictionary, &result)
            if status == errSecItemNotFound { return nil }
            guard status == errSecSuccess, let data = result as? Data else {
                throw securityError(status)
            }
            return data
        }
    }

    public func write(_ data: Data, service: String, account: String) async throws {
        try withLock(service: service) {
            try writeUnlocked(data, service: service, account: account)
        }
    }

    public func createIfAbsent(
        _ data: Data,
        service: String,
        account: String
    ) async throws -> KeychainCreateResult {
        try withLock(service: service) {
            let ownership = Data(UUID().uuidString.utf8)
            var attributes = baseQuery(service: service, account: account)
            attributes[kSecValueData as String] = data
            // SecItemAdd is the atomic create-if-absent primitive. The generic
            // attribute binds the later compensation to this migration's
            // creation, instead of relying on a value comparison alone.
            attributes[kSecAttrGeneric as String] = ownership
            if usesDataProtectionKeychain {
                attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            }
            let status = SecItemAdd(attributes as CFDictionary, nil)
            if status == errSecDuplicateItem { return .alreadyExists }
            guard status == errSecSuccess else { throw securityError(status) }
            return .created(ownership: ownership)
        }
    }

    public func delete(service: String, account: String) async throws {
        try withLock(service: service) {
            _ = try deleteUnlocked(service: service, account: account)
        }
    }

    public func deleteIfMatching(
        _ expected: Data,
        service: String,
        account: String,
        ownership: Data?
    ) async throws -> KeychainConditionalDeleteResult {
        try withLock(service: service) {
            guard let current = try readRecordUnlocked(service: service, account: account) else {
                return .notFound
            }
            guard current.data == expected else { return .valueChanged }
            if let ownership {
                guard current.ownership == ownership else { return .valueChanged }
            }

            // The ownership attribute is part of the delete query, so a
            // native writer cannot update the item marker and be deleted by
            // this compensating operation. For legacy clients that cannot
            // provide a marker, the shared file lock still closes the race
            // among SlateSync writers but cannot govern arbitrary Keychain
            // clients.
            var query = baseQuery(service: service, account: account)
            // Match both the expected value and the ownership marker in the
            // delete query itself, not only in a preceding read.
            query[kSecValueData as String] = expected
            if let ownership {
                query[kSecAttrGeneric as String] = ownership
            }
            let status = SecItemDelete(query as CFDictionary)
            if status == errSecItemNotFound { return .notFound }
            guard status == errSecSuccess else { throw securityError(status) }
            return .removed
        }
    }

    private func baseQuery(service: String, account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        .merging(
            usesDataProtectionKeychain
                ? [kSecUseDataProtectionKeychain as String: true]
                : [:],
            uniquingKeysWith: { _, new in new }
        )
    }

    private func writeUnlocked(_ data: Data, service: String, account: String) throws {
        let query = baseQuery(service: service, account: account)
        let updateStatus = SecItemUpdate(
            query as CFDictionary,
            [
                kSecValueData as String: data,
                // A normal upsert revokes any migration ownership marker.
                kSecAttrGeneric as String: Data("native-write".utf8),
            ] as CFDictionary
        )
        if updateStatus == errSecItemNotFound {
            var attributes = query
            attributes[kSecValueData as String] = data
            attributes[kSecAttrGeneric as String] = Data("native-write".utf8)
            if usesDataProtectionKeychain {
                attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            }
            let addStatus = SecItemAdd(attributes as CFDictionary, nil)
            if addStatus == errSecDuplicateItem {
                // The lock serializes native writers, but retain the normal
                // upsert fallback for items created by another Keychain API.
                let retryStatus = SecItemUpdate(
                    query as CFDictionary,
                    [
                        kSecValueData as String: data,
                        kSecAttrGeneric as String: Data("native-write".utf8),
                    ] as CFDictionary
                )
                guard retryStatus == errSecSuccess else { throw securityError(retryStatus) }
            } else if addStatus != errSecSuccess {
                throw securityError(addStatus)
            }
        } else if updateStatus != errSecSuccess {
            throw securityError(updateStatus)
        }
    }

    private func readRecordUnlocked(service: String, account: String) throws -> KeychainRecord? {
        var query = baseQuery(service: service, account: account)
        query[kSecReturnData as String] = true
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess,
              let attributes = result as? [String: Any],
              let data = attributes[kSecValueData as String] as? Data else {
            throw securityError(status)
        }
        return KeychainRecord(
            data: data,
            ownership: attributes[kSecAttrGeneric as String] as? Data
        )
    }

    private func deleteUnlocked(service: String, account: String) throws -> Bool {
        let status = SecItemDelete(baseQuery(service: service, account: account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw securityError(status)
        }
        return status == errSecSuccess
    }

    private func withLock<Value>(service: String, _ operation: () throws -> Value) throws -> Value {
        try CrossProcessFileLock.withExclusiveLock(at: lockURL(service: service), operation)
    }

    private func lockURL(service: String) -> URL {
        let safeService = service.utf8.map { String(format: "%02x", $0) }.joined()
        return coordinationDirectory
            .appendingPathComponent("keychain-\(safeService).lock")
    }

    private struct KeychainRecord {
        let data: Data
        let ownership: Data?
    }

    private func securityError(_ status: OSStatus) -> SlateSyncError {
        // Security.framework supplies an OS status, never the secret value;
        // keep the user-facing error similarly free of credential material.
        let detail = SecCopyErrorMessageString(status, nil) as String? ?? "Keychain 操作失败"
        // Retain the numeric OSStatus for diagnostics while avoiding any
        // Security.framework text that could contain credential material.
        return SlateSyncError(code: "KEYCHAIN", message: "\(detail) (OSStatus \(status))")
    }
}

/// The legacy file is intentionally abstracted so tests can use a temporary
/// path while production migration points at the existing Electron file.
public protocol LegacyCredentialSource: Sendable {
    var url: URL { get }
    func read() async throws -> Data?
    func remove(ifUnchangedFrom expected: Data) async throws
}

public actor FileLegacyCredentialSource: LegacyCredentialSource {
    public nonisolated let url: URL

    private var lastReadSnapshot: FileSnapshot?

    public init(url: URL) {
        self.url = url
    }

    public func read() async throws -> Data? {
        return try CrossProcessFileLock.withExclusiveLock(at: lockURL) {
            // Legacy key files are secret-bearing. Refuse to migrate if an old
            // installation cannot be tightened before its contents are read.
            try SecureFilePermissions.repairDirectory(at: url.deletingLastPathComponent())
            try SecureFilePermissions.repairFile(at: url)
            guard let opened = try openAndRead() else { return nil }
            let snapshot = opened.snapshot
            lastReadSnapshot = snapshot
            return opened.data
        }
    }

    public func remove(ifUnchangedFrom expected: Data) async throws {
        try CrossProcessFileLock.withExclusiveLock(at: lockURL) {
            try SecureFilePermissions.repairDirectory(at: url.deletingLastPathComponent())
            try SecureFilePermissions.repairFile(at: url)
            guard let opened = try openAndRead() else { return }
            // The descriptor supplies an inode/device snapshot, and the path
            // is lstat-checked immediately before unlink. This closes the
            // cooperating-writer race that path-only reads leave between
            // Data(contentsOf:) and removeItem(at:); callers outside the
            // shared migration lock remain outside the transaction contract.
            let currentSnapshot = opened.snapshot
            let originalSnapshot = lastReadSnapshot
            guard let originalSnapshot,
                  opened.data == expected,
                  currentSnapshot == originalSnapshot else {
                throw SlateSyncError(
                    code: "KEYCHAIN_MIGRATION_SOURCE_CHANGED",
                    message: "旧凭据文件在迁移期间发生变化，迁移已取消"
                )
            }
            guard opened.pathIdentity == currentPathIdentity() else {
                throw SlateSyncError(
                    code: "KEYCHAIN_MIGRATION_SOURCE_CHANGED",
                    message: "旧凭据文件在迁移期间发生变化，迁移已取消"
                )
            }
            guard unlink(url.path) == 0 else {
                if errno == ENOENT { return }
                throw SlateSyncError(
                    code: "KEYCHAIN_MIGRATION_SOURCE_REMOVE",
                    message: "旧凭据文件删除失败"
                )
            }
        }
    }

    private var lockURL: URL {
        url.deletingLastPathComponent()
            .appendingPathComponent(".\(url.lastPathComponent).migration.lock")
    }

    private func openAndRead() throws -> OpenedFile? {
        let descriptor = open(url.path, O_RDONLY | O_CLOEXEC)
        guard descriptor >= 0 else {
            if errno == ENOENT { return nil }
            throw SlateSyncError(code: "KEYCHAIN_MIGRATION_SOURCE_READ", message: "旧凭据文件读取失败")
        }
        defer { close(descriptor) }

        var before = stat()
        guard fstat(descriptor, &before) == 0 else {
            throw SlateSyncError(code: "KEYCHAIN_MIGRATION_SOURCE_READ", message: "旧凭据文件读取失败")
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
        let data: Data
        do {
            data = try handle.readToEnd() ?? Data()
        } catch {
            throw SlateSyncError(code: "KEYCHAIN_MIGRATION_SOURCE_READ", message: "旧凭据文件读取失败")
        }
        var after = stat()
        guard fstat(descriptor, &after) == 0,
              before.st_dev == after.st_dev,
              before.st_ino == after.st_ino,
              before.st_size == after.st_size else {
            throw SlateSyncError(
                code: "KEYCHAIN_MIGRATION_SOURCE_CHANGED",
                message: "旧凭据文件在读取期间发生变化，迁移已取消"
            )
        }
        return OpenedFile(
            data: data,
            snapshot: FileSnapshot(
                device: UInt64(before.st_dev),
                inode: UInt64(before.st_ino),
                size: Int64(before.st_size),
                data: data
            ),
            pathIdentity: FileIdentity(device: UInt64(before.st_dev), inode: UInt64(before.st_ino))
        )
    }

    private func currentPathIdentity() -> FileIdentity? {
        var status = stat()
        guard lstat(url.path, &status) == 0 else { return nil }
        return FileIdentity(device: UInt64(status.st_dev), inode: UInt64(status.st_ino))
    }

    private struct FileIdentity: Equatable, Sendable {
        let device: UInt64
        let inode: UInt64
    }

    private struct OpenedFile: Sendable {
        let data: Data
        let snapshot: FileSnapshot
        let pathIdentity: FileIdentity
    }

    private struct FileSnapshot: Equatable, Sendable {
        let device: UInt64
        let inode: UInt64
        let size: Int64
        let data: Data
    }
}

public enum CredentialMigrationStatus: String, Codable, Hashable, Sendable {
    case sourceMissing
    case noCredentials
    case migrated
}

public struct CredentialMigrationReport: Codable, Hashable, Sendable {
    public let status: CredentialMigrationStatus
    public let verifiedProviderIDs: [String]
    public let writtenProviderIDs: [String]
    public let sourceURL: URL

    public init(
        status: CredentialMigrationStatus,
        verifiedProviderIDs: [String] = [],
        writtenProviderIDs: [String] = [],
        sourceURL: URL
    ) {
        self.status = status
        self.verifiedProviderIDs = verifiedProviderIDs
        self.writtenProviderIDs = writtenProviderIDs
        self.sourceURL = sourceURL
    }
}

/// Owns provider credentials and performs one-way legacy migration only after
/// every Keychain create has been read back successfully. Existing conflicting
/// records are never overwritten, and a failed migration leaves the source.
/// Compensation is a single-call transaction with backend ownership markers
/// and advisory locks; it does not claim absolute atomicity against clients
/// that bypass those coordination rules.
public actor KeychainCredentialStore {
    public static let service = "com.slatesync.app.provider-key"

    private let backend: any KeychainBackend
    private let service: String

    public init(
        backend: any KeychainBackend = SecurityKeychainBackend(),
        service: String = KeychainCredentialStore.service
    ) {
        self.backend = backend
        self.service = service
    }

    public func value(providerID: String) async throws -> String? {
        try Self.validateProviderID(providerID)
        guard let data = try await backend.read(service: service, account: providerID) else { return nil }
        guard let value = String(data: data, encoding: .utf8) else {
            throw SlateSyncError(code: "KEYCHAIN", message: "Keychain 凭据格式无效")
        }
        return value
    }

    public func setValue(_ value: String?, providerID: String) async throws {
        try Self.validateProviderID(providerID)
        guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            try await backend.delete(service: service, account: providerID)
            return
        }
        try await backend.write(Data(value.utf8), service: service, account: providerID)
    }

    /// Migrates the Electron `provider-keys.json` shape without exposing key
    /// material in errors. The source is removed only after all entries are
    /// either verified as equal or newly created and read back. The source is
    /// removed only when its content and file identity still match the read
    /// snapshot, so a concurrent legacy writer can safely force a retry.
    @discardableResult
    public func migrateLegacyCredentials(
        from source: any LegacyCredentialSource
    ) async throws -> CredentialMigrationReport {
        guard let data = try await source.read() else {
            return CredentialMigrationReport(status: .sourceMissing, sourceURL: source.url)
        }

        let entries: [LegacyCredentialEntry]
        do {
            entries = try Self.parseLegacyEntries(data)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as SlateSyncError {
            throw error
        } catch {
            throw SlateSyncError(code: "KEYCHAIN_MIGRATION_INVALID", message: "旧凭据文件格式无效")
        }
        guard !entries.isEmpty else {
            // Empty or all-non-string legacy maps match Electron's load
            // behavior and remain available for a later explicit migration.
            return CredentialMigrationReport(status: .noCredentials, sourceURL: source.url)
        }

        do {
            for entry in entries {
                guard let data = try await backend.read(service: service, account: entry.providerID) else {
                    continue
                }
                guard data == entry.data else {
                    throw SlateSyncError(
                        code: "KEYCHAIN_MIGRATION_CONFLICT",
                        message: "Keychain 中已有不一致的提供商凭据，迁移已取消"
                    )
                }
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as SlateSyncError {
            throw error
        } catch {
            throw SlateSyncError(code: "KEYCHAIN_MIGRATION_READ", message: "读取 Keychain 失败，迁移已取消")
        }

        var attempted: [AttemptedCredential] = []
        var written: [LegacyCredentialEntry] = []
        do {
            for entry in entries {
                switch try await backend.createIfAbsent(
                    entry.data,
                    service: service,
                    account: entry.providerID
                ) {
                case .created(let ownership):
                    // Record ownership only after the backend atomically
                    // confirms that this call created the item.
                    attempted.append(AttemptedCredential(entry: entry, ownership: ownership))
                    guard let readBack = try await backend.read(service: service, account: entry.providerID),
                          readBack == entry.data else {
                        throw SlateSyncError(code: "KEYCHAIN_MIGRATION_VERIFY", message: "Keychain 凭据校验失败，迁移已取消")
                    }
                    written.append(entry)
                case .alreadyExists:
                    guard let current = try await backend.read(service: service, account: entry.providerID),
                          current == entry.data else {
                        throw SlateSyncError(
                            code: "KEYCHAIN_MIGRATION_CONFLICT",
                            message: "Keychain 中已有不一致的提供商凭据，迁移已取消"
                        )
                    }
                }
            }

            // Recheck equal pre-existing values immediately before touching the
            // source. This catches a cooperating writer changing a credential
            // after preflight and keeps the old file available for retry.
            for entry in entries {
                guard let current = try await backend.read(service: service, account: entry.providerID),
                      current == entry.data else {
                    throw SlateSyncError(
                        code: "KEYCHAIN_MIGRATION_CONFLICT",
                        message: "Keychain 中的提供商凭据在迁移期间发生变化，迁移已取消"
                    )
                }
            }
        } catch let error as SlateSyncError {
            let rollbackSucceeded = await compensate(attempted)
            if !rollbackSucceeded {
                throw SlateSyncError(
                    code: "KEYCHAIN_MIGRATION_ROLLBACK",
                    message: "迁移失败且回滚未完成，旧凭据文件已保留，请重试"
                )
            }
            throw error.code.hasPrefix("KEYCHAIN_MIGRATION_")
                ? error
                : SlateSyncError(code: "KEYCHAIN_MIGRATION_WRITE", message: "写入 Keychain 失败，迁移已取消")
        } catch is CancellationError {
            let rollbackSucceeded = await compensate(attempted)
            if !rollbackSucceeded {
                throw SlateSyncError(
                    code: "KEYCHAIN_MIGRATION_ROLLBACK",
                    message: "迁移失败且回滚未完成，旧凭据文件已保留，请重试"
                )
            }
            throw CancellationError()
        } catch {
            let rollbackSucceeded = await compensate(attempted)
            if !rollbackSucceeded {
                throw SlateSyncError(
                    code: "KEYCHAIN_MIGRATION_ROLLBACK",
                    message: "迁移失败且回滚未完成，旧凭据文件已保留，请重试"
                )
            }
            throw SlateSyncError(code: "KEYCHAIN_MIGRATION_WRITE", message: "写入 Keychain 失败，迁移已取消")
        }

        do {
            try await source.remove(ifUnchangedFrom: data)
        } catch is CancellationError {
            // Keychain has already been verified; preserve cancellation while
            // retaining the legacy source for a later retry.
            throw CancellationError()
        } catch {
            if let error = error as? SlateSyncError,
               error.code == "KEYCHAIN_MIGRATION_SOURCE_CHANGED" {
                throw error
            }
            // At this point Keychain is complete; preserving the source is
            // safer than retrying a destructive removal inside this call.
            throw SlateSyncError(code: "KEYCHAIN_MIGRATION_SOURCE_REMOVE", message: "凭据已写入 Keychain，但旧文件未能删除")
        }

        let verified = entries.map(\.providerID).sorted()
        return CredentialMigrationReport(
            status: .migrated,
            verifiedProviderIDs: verified,
            writtenProviderIDs: written.map(\.providerID).sorted(),
            sourceURL: source.url
        )
    }

    @discardableResult
    public func migrateLegacyCredentials(at url: URL) async throws -> CredentialMigrationReport {
        try await migrateLegacyCredentials(from: FileLegacyCredentialSource(url: url))
    }

    private func compensate(_ entries: [AttemptedCredential]) async -> Bool {
        // Delete only accounts for which this backend returned an ownership
        // marker. The marker plus the conditional value check prevents a
        // pre-existing account or a cooperating later write from being
        // mistaken for this migration's item.
        var complete = true
        for entry in entries.reversed() {
            do {
                switch try await backend.deleteIfMatching(
                    entry.entry.data,
                    service: service,
                    account: entry.entry.providerID,
                    ownership: entry.ownership
                ) {
                case .removed, .notFound:
                    break
                case .valueChanged:
                    complete = false
                }
            } catch {
                complete = false
            }
        }
        return complete
    }

    private static func validateProviderID(_ providerID: String) throws {
        let trimmed = providerID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 256,
              !trimmed.unicodeScalars.contains(where: {
                  $0.value <= 0x1F || (0x7F...0x9F).contains($0.value)
              }) else {
            throw SlateSyncError(code: "KEYCHAIN_PROVIDER_INVALID", message: "提供商标识无效")
        }
    }

    private struct LegacyCredentialEntry: Sendable {
        let providerID: String
        let data: Data
    }

    private struct AttemptedCredential: Sendable {
        let entry: LegacyCredentialEntry
        let ownership: Data
    }

    private static func parseLegacyEntries(_ data: Data) throws -> [LegacyCredentialEntry] {
        do {
            let keys = try TopLevelJSONKeyScanner.scan(data)
            let object = try JSONDecoder().decode([String: JSONValue].self, from: data)
            var entries: [LegacyCredentialEntry] = []
            for providerID in keys {
                guard let value = object[providerID] else {
                    throw SlateSyncError(code: "KEYCHAIN_MIGRATION_INVALID", message: "旧凭据文件格式无效")
                }
                guard case .string(let secret) = value else { continue }
                guard !secret.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
                try validateProviderID(providerID)
                entries.append(LegacyCredentialEntry(providerID: providerID, data: Data(secret.utf8)))
            }
            return entries.sorted { $0.providerID < $1.providerID }
        } catch let error as SlateSyncError {
            throw error
        } catch {
            throw SlateSyncError(code: "KEYCHAIN_MIGRATION_INVALID", message: "旧凭据文件格式无效")
        }
    }
}

/// Small JSON scanner that rejects duplicate keys before Foundation's decoder
/// collapses them into a dictionary. Only top-level names are relevant to the
/// legacy map; nested values are skipped by the grammar-aware scanner.
private enum TopLevelJSONKeyScanner {
    private static let maximumDepth = 64
    private enum ScanError: Error { case invalid, duplicate, depthExceeded }

    static func scan(_ data: Data) throws -> [String] {
        var parser = Parser(bytes: Array(data))
        let keys = try parser.parseTopLevelObject()
        return Array(keys)
    }

    private struct Parser {
        let bytes: [UInt8]
        var index = 0

        mutating func parseTopLevelObject() throws -> Set<String> {
            skipWhitespace()
            guard consume(0x7B) else { throw ScanError.invalid }
            var keys = Set<String>()
            skipWhitespace()
            if consume(0x7D) {
                skipWhitespace()
                guard index == bytes.count else { throw ScanError.invalid }
                return keys
            }
            while true {
                skipWhitespace()
                let key = try parseString()
                guard keys.insert(key).inserted else { throw ScanError.duplicate }
                skipWhitespace()
                guard consume(0x3A) else { throw ScanError.invalid }
                try skipValue(depth: 0)
                skipWhitespace()
                if consume(0x7D) { break }
                guard consume(0x2C) else { throw ScanError.invalid }
            }
            skipWhitespace()
            guard index == bytes.count else { throw ScanError.invalid }
            return keys
        }

        mutating func skipValue(depth: Int) throws {
            guard depth <= TopLevelJSONKeyScanner.maximumDepth else {
                throw ScanError.depthExceeded
            }
            skipWhitespace()
            guard index < bytes.count else { throw ScanError.invalid }
            switch bytes[index] {
            case 0x22:
                _ = try parseString()
            case 0x7B:
                try skipObject(depth: depth + 1)
            case 0x5B:
                try skipArray(depth: depth + 1)
            default:
                let start = index
                while index < bytes.count,
                      ![0x20, 0x09, 0x0A, 0x0D, 0x2C, 0x5D, 0x7D].contains(bytes[index]) {
                    index += 1
                }
                guard index > start else { throw ScanError.invalid }
            }
        }

        mutating func skipObject(depth: Int) throws {
            guard depth <= TopLevelJSONKeyScanner.maximumDepth else {
                throw ScanError.depthExceeded
            }
            guard consume(0x7B) else { throw ScanError.invalid }
            skipWhitespace()
            if consume(0x7D) { return }
            while true {
                skipWhitespace()
                _ = try parseString()
                skipWhitespace()
                guard consume(0x3A) else { throw ScanError.invalid }
                try skipValue(depth: depth + 1)
                skipWhitespace()
                if consume(0x7D) { return }
                guard consume(0x2C) else { throw ScanError.invalid }
            }
        }

        mutating func skipArray(depth: Int) throws {
            guard depth <= TopLevelJSONKeyScanner.maximumDepth else {
                throw ScanError.depthExceeded
            }
            guard consume(0x5B) else { throw ScanError.invalid }
            skipWhitespace()
            if consume(0x5D) { return }
            while true {
                try skipValue(depth: depth + 1)
                skipWhitespace()
                if consume(0x5D) { return }
                guard consume(0x2C) else { throw ScanError.invalid }
            }
        }

        mutating func parseString() throws -> String {
            guard index < bytes.count, bytes[index] == 0x22 else { throw ScanError.invalid }
            let start = index
            index += 1
            var escaped = false
            while index < bytes.count {
                let byte = bytes[index]
                index += 1
                if escaped {
                    escaped = false
                    continue
                }
                if byte == 0x5C {
                    escaped = true
                } else if byte == 0x22 {
                    let raw = Data(bytes[start..<index])
                    guard let string = try? JSONDecoder().decode(String.self, from: raw) else {
                        throw ScanError.invalid
                    }
                    return string
                } else if byte < 0x20 {
                    throw ScanError.invalid
                }
            }
            throw ScanError.invalid
        }

        mutating func consume(_ byte: UInt8) -> Bool {
            guard index < bytes.count, bytes[index] == byte else { return false }
            index += 1
            return true
        }

        mutating func skipWhitespace() {
            while index < bytes.count, [0x20, 0x09, 0x0A, 0x0D].contains(bytes[index]) {
                index += 1
            }
        }
    }
}

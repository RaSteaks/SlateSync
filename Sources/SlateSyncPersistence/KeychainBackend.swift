import Foundation
import LocalAuthentication
import Security
import SlateSyncDomain

/// Asynchronous Security.framework boundary for project-library encryption.
/// Tests inject a backend without touching the user's login keychain.
public protocol KeychainBackend: Sendable {
    func status(service: String, account: String) async -> CredentialStatus
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
    /// Unknown backends must not implement status by reading secret bytes.
    func status(service: String, account: String) async -> CredentialStatus { .unavailable }

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

/// Production Keychain backend. Project-key bytes stay in Security.framework;
/// this adapter never serializes them into a Swift Codable value or log event.
public struct SecurityKeychainBackend: KeychainBackend, Sendable {
    private let coordinationDirectory: URL
    private let usesDataProtectionKeychain: Bool

    /// Keychain operations are coordinated in Application Support so every
    /// SlateSync process uses the same namespace across launches. Tests pass a
    /// private directory and therefore never contend with production locks.
    /// The login keychain encrypts credentials without requiring a developer
    /// provisioning profile. Data Protection remains an explicit opt-in for
    /// callers whose signed application has the necessary entitlements.
    public init(
        coordinationDirectory: URL? = nil,
        usesDataProtectionKeychain: Bool = false
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

    public func status(service: String, account: String) async -> CredentialStatus {
        // Attribute-only queries never request the password. A non-interactive
        // LAContext prevents rendering Provider settings from opening an
        // authorization sheet while still reporting a protected item.
        let context = LAContext()
        context.interactionNotAllowed = true
        var query = baseQuery(service: service, account: account)
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        query[kSecUseAuthenticationContext as String] = context
        var result: CFTypeRef?
        switch SecItemCopyMatching(query as CFDictionary, &result) {
        case errSecSuccess: return .configured
        case errSecItemNotFound: return .missing
        case errSecInteractionNotAllowed, errSecAuthFailed, errSecUserCanceled: return .authorizationRequired
        default: return .unavailable
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
        if [errSecInteractionNotAllowed, errSecAuthFailed, errSecUserCanceled].contains(status) {
            // Project unlock retries require a new user action; background
            // reads must not repeatedly request Keychain authorization.
            return SlateSyncError(code: "KEYCHAIN_AUTHORIZATION", message: "钥匙串访问未获授权，请解锁钥匙串后重新执行操作 (OSStatus \(status))")
        }
        let detail = SecCopyErrorMessageString(status, nil) as String? ?? "Keychain 操作失败"
        // Retain the numeric OSStatus for diagnostics while avoiding any
        // Security.framework text that could contain credential material.
        return SlateSyncError(code: "KEYCHAIN", message: "\(detail) (OSStatus \(status))")
    }
}


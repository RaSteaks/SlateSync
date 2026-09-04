import Foundation
import SlateSyncDomain
@testable import SlateSyncPersistence

/// Deterministic test-only Keychain backend. Keeping this implementation under
/// the test target prevents production code from accidentally selecting an
/// in-memory credential store.
actor InMemoryKeychainBackend: KeychainBackend {
    var failNextRead = false
    var failNextReadAfterWrite = false
    var failNextWrite = false
    var failNextWriteAfterPersist = false
    var failNextDelete = false
    var cancelNextReadAfterWrite = false

    private var values: [String: StoredValue]
    private var readFailureAfterWritePending = false
    private var cancellationAfterWritePending = false

    init(values: [String: String] = [:]) {
        self.values = Dictionary(uniqueKeysWithValues: values.map {
            (
                "\(KeychainCredentialStore.service)\u{1F}\($0.key)",
                StoredValue(data: Data($0.value.utf8), ownership: nil)
            )
        })
    }

    func read(service: String, account: String) async throws -> Data? {
        if failNextRead {
            failNextRead = false
            throw SlateSyncError(code: "KEYCHAIN_TEST_READ", message: "测试 Keychain 读取失败")
        }
        if readFailureAfterWritePending {
            readFailureAfterWritePending = false
            throw SlateSyncError(code: "KEYCHAIN_TEST_READBACK", message: "测试 Keychain 回读失败")
        }
        if cancellationAfterWritePending {
            cancellationAfterWritePending = false
            throw CancellationError()
        }
        return values[key(service: service, account: account)]?.data
    }

    func write(_ data: Data, service: String, account: String) async throws {
        if failNextWrite {
            failNextWrite = false
            throw SlateSyncError(code: "KEYCHAIN_TEST_WRITE", message: "测试 Keychain 写入失败")
        }
        values[key(service: service, account: account)] = StoredValue(
            data: data,
            ownership: Data("native-write".utf8)
        )
        if failNextWriteAfterPersist {
            failNextWriteAfterPersist = false
            throw SlateSyncError(code: "KEYCHAIN_TEST_WRITE_AFTER_PERSIST", message: "测试 Keychain 写入后失败")
        }
        if failNextReadAfterWrite {
            failNextReadAfterWrite = false
            readFailureAfterWritePending = true
        }
    }

    func createIfAbsent(
        _ data: Data,
        service: String,
        account: String
    ) async throws -> KeychainCreateResult {
        if failNextWrite {
            failNextWrite = false
            throw SlateSyncError(code: "KEYCHAIN_TEST_WRITE", message: "测试 Keychain 写入失败")
        }
        let storageKey = key(service: service, account: account)
        guard values[storageKey] == nil else { return .alreadyExists }
        let ownership = Data(UUID().uuidString.utf8)
        values[storageKey] = StoredValue(data: data, ownership: ownership)
        if failNextReadAfterWrite {
            failNextReadAfterWrite = false
            readFailureAfterWritePending = true
        }
        if cancelNextReadAfterWrite {
            cancelNextReadAfterWrite = false
            cancellationAfterWritePending = true
        }
        return .created(ownership: ownership)
    }

    func delete(service: String, account: String) async throws {
        if failNextDelete {
            failNextDelete = false
            throw SlateSyncError(code: "KEYCHAIN_TEST_DELETE", message: "测试 Keychain 删除失败")
        }
        values.removeValue(forKey: key(service: service, account: account))
    }

    func deleteIfMatching(
        _ expected: Data,
        service: String,
        account: String,
        ownership: Data?
    ) async throws -> KeychainConditionalDeleteResult {
        if failNextDelete {
            failNextDelete = false
            throw SlateSyncError(code: "KEYCHAIN_TEST_DELETE", message: "测试 Keychain 删除失败")
        }
        let storageKey = key(service: service, account: account)
        guard let current = values[storageKey] else { return .notFound }
        guard current.data == expected else { return .valueChanged }
        if let ownership, current.ownership != ownership { return .valueChanged }
        values.removeValue(forKey: storageKey)
        return .removed
    }

    func failNextReadbackOnce() {
        failNextReadAfterWrite = true
    }

    func failNextWriteOnce() {
        failNextWrite = true
    }

    func failNextWriteAfterPersistOnce() {
        failNextWriteAfterPersist = true
    }

    func failNextDeleteOnce() {
        failNextDelete = true
    }

    func cancelNextReadbackOnce() {
        cancelNextReadAfterWrite = true
    }

    func value(service: String = KeychainCredentialStore.service, account: String) -> String? {
        guard let data = values[key(service: service, account: account)]?.data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func storedValues(service: String = KeychainCredentialStore.service) -> [String: String] {
        values.reduce(into: [:]) { result, entry in
            guard entry.key.hasPrefix("\(service)\u{1F}"),
                  let value = String(data: entry.value.data, encoding: .utf8) else { return }
            let account = String(entry.key.dropFirst(service.count + 1))
            result[account] = value
        }
    }

    private func key(service: String, account: String) -> String {
        "\(service)\u{1F}\(account)"
    }

    private struct StoredValue {
        let data: Data
        let ownership: Data?
    }
}

import Foundation
import SlateSyncDomain
import XCTest
@testable import SlateSyncPersistence

/// Counts secret reads independently of metadata queries; uses no real keychain.
private actor CountingKeychain: KeychainBackend {
    let storage = InMemoryKeychainBackend()
    private(set) var reads = 0
    private(set) var statuses = 0
    var rejectRead = false
    var rejectWrite = false
    func rejectNextWrite() { rejectWrite = true }
    func rejectNextRead() { rejectRead = true }
    func status(service: String, account: String) async -> CredentialStatus {
        statuses += 1
        return await storage.status(service: service, account: account)
    }
    func read(service: String, account: String) async throws -> Data? {
        reads += 1
        try await Task.sleep(for: .milliseconds(15))
        if rejectRead {
            rejectRead = false
            throw SlateSyncError(code: "KEYCHAIN_AUTHORIZATION", message: "test authorization declined")
        }
        return try await storage.read(service: service, account: account)
    }
    func write(_ data: Data, service: String, account: String) async throws {
        if rejectWrite { rejectWrite = false; throw SlateSyncError(code: "TEST_WRITE", message: "write failed") }
        try await storage.write(data, service: service, account: account)
    }
    func createIfAbsent(_ data: Data, service: String, account: String) async throws -> KeychainCreateResult { try await storage.createIfAbsent(data, service: service, account: account) }
    func delete(service: String, account: String) async throws { try await storage.delete(service: service, account: account) }
    func deleteIfMatching(_ expected: Data, service: String, account: String, ownership: Data?) async throws -> KeychainConditionalDeleteResult {
        try await storage.deleteIfMatching(expected, service: service, account: account, ownership: ownership)
    }
}

final class CredentialUnlockTests: XCTestCase {
    func testStatusNeverReadsSecretAndConcurrentReadsShareOneRequest() async throws {
        let backend = CountingKeychain()
        try await backend.write(Data("key".utf8), service: KeychainCredentialStore.service, account: "openrouter")
        let store = KeychainCredentialStore(backend: backend)
        let status = await store.status(providerID: "openrouter")
        XCTAssertEqual(status, .configured)
        let before = await backend.reads
        XCTAssertEqual(before, 0)
        let values = try await withThrowingTaskGroup(of: String?.self) { group in
            for _ in 0..<20 { group.addTask { try await store.value(providerID: "openrouter") } }
            var values: [String?] = []
            for try await value in group { values.append(value) }
            return values
        }
        XCTAssertEqual(values, Array(repeating: "key", count: 20))
        let reads = await backend.reads
        XCTAssertEqual(reads, 1)
        try await store.setValue("new-key", providerID: "openrouter")
        let changed = try await store.value(providerID: "openrouter")
        XCTAssertEqual(changed, "new-key")
        try await store.setValue(nil, providerID: "openrouter")
        let deleted = try await store.value(providerID: "openrouter")
        XCTAssertNil(deleted)
    }

    func testWriteSupersedesAnInflightReadAndFailedSaveIsNotCached() async throws {
        let backend = CountingKeychain()
        try await backend.write(Data("old".utf8), service: KeychainCredentialStore.service, account: "openrouter")
        let store = KeychainCredentialStore(backend: backend)
        let reading = Task { try await store.value(providerID: "openrouter") }
        while await backend.reads == 0 { await Task.yield() }
        try await store.setValue("new", providerID: "openrouter")
        let latest = try await reading.value
        XCTAssertEqual(latest, "new")
        await backend.rejectNextWrite()
        do { try await store.setValue("failed", providerID: "openrouter"); XCTFail("Write should fail") } catch {}
        let retained = try await store.value(providerID: "openrouter")
        XCTAssertEqual(retained, "new")
    }

    func testRefusalStaysLatchedUntilAnExplicitUserOperation() async throws {
        let backend = CountingKeychain()
        try await backend.write(Data("key".utf8), service: KeychainCredentialStore.service, account: "openrouter")
        let store = KeychainCredentialStore(backend: backend)
        await backend.rejectNextRead()
        for _ in 0..<3 {
            do { _ = try await store.value(providerID: "openrouter"); XCTFail("Authorization must fail") } catch {}
        }
        let reads = await backend.reads
        XCTAssertEqual(reads, 1)
        let status = await store.status(providerID: "openrouter")
        XCTAssertEqual(status, .authorizationRequired)
        await store.beginUserOperation(providerID: "openrouter")
        let recovered = try await store.value(providerID: "openrouter")
        XCTAssertEqual(recovered, "key")
    }

    func testProjectKeyReusedAndRefusalDoesNotRegenerateKey() async throws {
        let root = try PersistenceTestSupport.temporaryRoot("unlock-cache")
        defer { try? FileManager.default.removeItem(at: root) }
        let backend = CountingKeychain()
        try await LocalProjectEncryption.prepare(at: root, backend: backend)
        let marker = try Data(contentsOf: root.appending(path: LocalProjectEncryption.markerName))
        let first = await backend.reads
        try await LocalProjectEncryption.prepare(at: root, backend: backend)
        let second = await backend.reads
        XCTAssertEqual(first, second)
        await LocalProjectEncryption.resetUnlockCacheForTesting()
        await backend.rejectNextRead()
        for _ in 0..<3 {
            do { try await LocalProjectEncryption.prepare(at: root, backend: backend); XCTFail("Must stay locked") } catch {}
        }
        let refused = await backend.reads
        XCTAssertEqual(refused, second + 1)
        await LocalProjectEncryption.allowUnlockRetry()
        try await LocalProjectEncryption.prepare(at: root, backend: backend)
        XCTAssertEqual(try Data(contentsOf: root.appending(path: LocalProjectEncryption.markerName)), marker)
    }
}

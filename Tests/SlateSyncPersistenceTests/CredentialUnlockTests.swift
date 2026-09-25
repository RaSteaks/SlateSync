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
    // Project-key caching and explicit authorization retry remain supported.
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

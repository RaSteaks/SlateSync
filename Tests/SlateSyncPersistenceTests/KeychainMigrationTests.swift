import Foundation
import XCTest
@testable import SlateSyncDomain
@testable import SlateSyncPersistence

final class KeychainMigrationTests: XCTestCase {
    func testLegacyCredentialsMigrateAndRemoveSourceOnlyAfterVerification() async throws {
        let root = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let legacyURL = root.appending(path: "provider-keys.json")
        try Data(#"{"openai":"sk-openai-secret","custom":"custom-secret"}"#.utf8).write(to: legacyURL)
        let backend = InMemoryKeychainBackend()
        let store = KeychainCredentialStore(backend: backend)

        let report = try await store.migrateLegacyCredentials(at: legacyURL)

        XCTAssertEqual(report.status, .migrated)
        XCTAssertEqual(report.verifiedProviderIDs, ["custom", "openai"])
        XCTAssertEqual(report.writtenProviderIDs, ["custom", "openai"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacyURL.path))
        let values = await backend.storedValues()
        XCTAssertEqual(values["openai"], "sk-openai-secret")
        XCTAssertEqual(values["custom"], "custom-secret")
    }

    func testLegacyCredentialSourceRepairsExistingPermissionsBeforeRead() async throws {
        let root = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let legacyURL = root.appending(path: "provider-keys.json")
        // Model an older installation whose secret-bearing directory and file
        // were created with broader permissions than the migration requires.
        try Data(#"{"openai":"permission-secret"}"#.utf8).write(to: legacyURL)
        try setFilePermissions(at: root, permissions: 0o755)
        try setFilePermissions(at: legacyURL, permissions: 0o644)

        let source = FileLegacyCredentialSource(url: legacyURL)
        let loaded = try await source.read()
        XCTAssertNotNil(loaded)
        XCTAssertEqual(try filePermissions(at: root), 0o700)
        XCTAssertEqual(try filePermissions(at: legacyURL), 0o600)
    }

    func testEqualExistingKeyIsRetainedAndConflictingKeyAbortsWithoutOverwrite() async throws {
        let root = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let matchingURL = root.appending(path: "matching.json")
        try Data(#"{"openai":"same-secret"}"#.utf8).write(to: matchingURL)
        let backend = InMemoryKeychainBackend(values: ["openai": "same-secret"])
        let store = KeychainCredentialStore(backend: backend)

        let matching = try await store.migrateLegacyCredentials(at: matchingURL)
        XCTAssertEqual(matching.writtenProviderIDs, [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: matchingURL.path))

        let conflictURL = root.appending(path: "conflict.json")
        try Data(#"{"openai":"new-secret","other":"other-secret"}"#.utf8).write(to: conflictURL)
        do {
            _ = try await store.migrateLegacyCredentials(at: conflictURL)
            XCTFail("Expected a pre-existing conflict")
        } catch let error as SlateSyncError {
            XCTAssertEqual(error.code, "KEYCHAIN_MIGRATION_CONFLICT")
            XCTAssertFalse(error.message.contains("new-secret"))
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: conflictURL.path))
        let retained = await backend.value(account: "openai")
        let missing = await backend.value(account: "other")
        XCTAssertEqual(retained, "same-secret")
        XCTAssertNil(missing)
    }

    func testWriteAndReadbackFailuresCompensateAndKeepLegacySource() async throws {
        let root = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let legacyURL = root.appending(path: "provider-keys.json")
        try Data(#"{"openai":"sk-readback-secret"}"#.utf8).write(to: legacyURL)
        let backend = InMemoryKeychainBackend()
        await backend.failNextReadbackOnce()
        let store = KeychainCredentialStore(backend: backend)

        do {
            _ = try await store.migrateLegacyCredentials(at: legacyURL)
            XCTFail("Expected readback failure")
        } catch let error as SlateSyncError {
            XCTAssertEqual(error.code, "KEYCHAIN_MIGRATION_WRITE")
            XCTAssertFalse(error.message.contains("sk-readback-secret"))
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: legacyURL.path))
        let removedAfterReadbackFailure = await backend.value(account: "openai")
        XCTAssertNil(removedAfterReadbackFailure)

        // createIfAbsent reports ownership only after persistence; make the
        // second migration fail during readback so compensation has a known
        // ownership marker to validate.
        await backend.failNextReadbackOnce()
        do {
            _ = try await store.migrateLegacyCredentials(at: legacyURL)
            XCTFail("Expected post-persist write failure")
        } catch let error as SlateSyncError {
            XCTAssertEqual(error.code, "KEYCHAIN_MIGRATION_WRITE")
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: legacyURL.path))
        let removedAfterWriteFailure = await backend.value(account: "openai")
        XCTAssertNil(removedAfterWriteFailure)
    }

    func testRollbackFailureKeepsSourceAndAllowsAReadOnlyRetry() async throws {
        let root = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let legacyURL = root.appending(path: "provider-keys.json")
        try Data(#"{"openai":"sk-rollback-secret"}"#.utf8).write(to: legacyURL)
        let backend = InMemoryKeychainBackend()
        await backend.failNextReadbackOnce()
        await backend.failNextDeleteOnce()
        let store = KeychainCredentialStore(backend: backend)

        do {
            _ = try await store.migrateLegacyCredentials(at: legacyURL)
            XCTFail("Expected rollback failure")
        } catch let error as SlateSyncError {
            XCTAssertEqual(error.code, "KEYCHAIN_MIGRATION_ROLLBACK")
            XCTAssertFalse(error.message.contains("sk-rollback-secret"))
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: legacyURL.path))
        let strandedValue = await backend.value(account: "openai")
        XCTAssertEqual(strandedValue, "sk-rollback-secret")

        // The retry observes the equal Keychain value and only removes the
        // source after verification, without writing the secret again.
        let retry = try await store.migrateLegacyCredentials(at: legacyURL)
        XCTAssertEqual(retry.writtenProviderIDs, [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacyURL.path))
    }

    func testConditionalDeletePreservesAValueChangedByAnotherWriter() async throws {
        let backend = InMemoryKeychainBackend(values: ["openai": "new-secret"])

        let outcome = try await backend.deleteIfMatching(
            Data("old-secret".utf8),
            service: KeychainCredentialStore.service,
            account: "openai"
        )

        XCTAssertEqual(outcome, .valueChanged)
        let retainedValue = await backend.value(account: "openai")
        XCTAssertEqual(retainedValue, "new-secret")
    }

    func testCreateIfAbsentReturnsOwnershipAndRejectsWrongOwnerCompensation() async throws {
        let backend = InMemoryKeychainBackend()
        let first = try await backend.createIfAbsent(
            Data("first-secret".utf8),
            service: KeychainCredentialStore.service,
            account: "openai"
        )
        guard case .created(let ownership) = first else {
            XCTFail("Expected the first create to own the item")
            return
        }
        let duplicate = try await backend.createIfAbsent(
            Data("second-secret".utf8),
            service: KeychainCredentialStore.service,
            account: "openai"
        )
        XCTAssertEqual(duplicate, .alreadyExists)

        let wrongOwner = try await backend.deleteIfMatching(
            Data("first-secret".utf8),
            service: KeychainCredentialStore.service,
            account: "openai",
            ownership: Data("another-migration".utf8)
        )
        XCTAssertEqual(wrongOwner, .valueChanged)
        let retained = await backend.value(account: "openai")
        XCTAssertEqual(retained, "first-secret")

        let correctOwner = try await backend.deleteIfMatching(
            Data("first-secret".utf8),
            service: KeychainCredentialStore.service,
            account: "openai",
            ownership: ownership
        )
        XCTAssertEqual(correctOwner, .removed)

        let recreated = try await backend.createIfAbsent(
            Data("first-secret".utf8),
            service: KeychainCredentialStore.service,
            account: "openai"
        )
        guard case .created(let recreatedOwnership) = recreated else {
            XCTFail("Expected a fresh create after compensation")
            return
        }

        // Even an identical credential written later revokes the old marker;
        // compensation must not delete another native writer's same-value
        // update merely because the bytes happen to match.
        try await backend.write(
            Data("first-secret".utf8),
            service: KeychainCredentialStore.service,
            account: "openai"
        )
        let sameValueLaterWriter = try await backend.deleteIfMatching(
            Data("first-secret".utf8),
            service: KeychainCredentialStore.service,
            account: "openai",
            ownership: recreatedOwnership
        )
        XCTAssertEqual(sameValueLaterWriter, .valueChanged)
    }

    func testLegacySourceChangeIsDetectedBeforeRemoval() async throws {
        let root = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let legacyURL = root.appending(path: "provider-keys.json")
        let original = Data(#"{"openai":"source-secret"}"#.utf8)
        try original.write(to: legacyURL)

        let source = FileLegacyCredentialSource(url: legacyURL)
        let loaded = try await source.read()
        let snapshot = try XCTUnwrap(loaded)
        try FileManager.default.removeItem(at: legacyURL)
        try Data(#"{"openai":"source-secret"}"#.utf8).write(to: legacyURL)

        do {
            try await source.remove(ifUnchangedFrom: snapshot)
            XCTFail("Expected replacement file identity to be rejected")
        } catch let error as SlateSyncError {
            XCTAssertEqual(error.code, "KEYCHAIN_MIGRATION_SOURCE_CHANGED")
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: legacyURL.path))
    }

    func testMalformedEmptyAndDuplicateLegacyFilesNeverExposeSecrets() async throws {
        let root = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let backend = InMemoryKeychainBackend()
        let store = KeychainCredentialStore(backend: backend)

        let emptyURL = root.appending(path: "empty.json")
        try Data(#"{"openai":"  ","ignored":42}"#.utf8).write(to: emptyURL)
        let emptyReport = try await store.migrateLegacyCredentials(at: emptyURL)
        XCTAssertEqual(emptyReport.status, .noCredentials)
        XCTAssertTrue(FileManager.default.fileExists(atPath: emptyURL.path))

        let duplicateURL = root.appending(path: "duplicate.json")
        try Data(#"{"openai":"first-secret","openai":"second-secret"}"#.utf8).write(to: duplicateURL)
        do {
            _ = try await store.migrateLegacyCredentials(at: duplicateURL)
            XCTFail("Expected duplicate-key rejection")
        } catch let error as SlateSyncError {
            XCTAssertEqual(error.code, "KEYCHAIN_MIGRATION_INVALID")
            XCTAssertFalse(error.message.contains("first-secret"))
            XCTAssertFalse(error.message.contains("second-secret"))
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: duplicateURL.path))

        let invalidProviderURL = root.appending(path: "invalid-provider.json")
        try Data(#"{"":"sk-empty-provider-secret"}"#.utf8).write(to: invalidProviderURL)
        do {
            _ = try await store.migrateLegacyCredentials(at: invalidProviderURL)
            XCTFail("Expected invalid provider rejection")
        } catch let error as SlateSyncError {
            XCTAssertEqual(error.code, "KEYCHAIN_PROVIDER_INVALID")
            XCTAssertFalse(error.message.contains("sk-empty-provider-secret"))
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: invalidProviderURL.path))

        let controlProviderURL = root.appending(path: "control-provider.json")
        try Data("{\"bad\\u001fprovider\":\"control-secret\"}".utf8).write(to: controlProviderURL)
        do {
            _ = try await store.migrateLegacyCredentials(at: controlProviderURL)
            XCTFail("Expected control-character provider rejection")
        } catch let error as SlateSyncError {
            XCTAssertEqual(error.code, "KEYCHAIN_PROVIDER_INVALID")
            XCTAssertFalse(error.message.contains("control-secret"))
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: controlProviderURL.path))
    }

    func testSourceRemovalFailureLeavesVerifiedKeychainAndSourceForRetry() async throws {
        let source = FailingRemovalSource(
            url: URL(fileURLWithPath: "/private/tmp/slatesync-source-failure.json"),
            data: Data(#"{"openai":"sk-source-secret"}"#.utf8)
        )
        let backend = InMemoryKeychainBackend()
        let store = KeychainCredentialStore(backend: backend)

        do {
            _ = try await store.migrateLegacyCredentials(from: source)
            XCTFail("Expected source removal failure")
        } catch let error as SlateSyncError {
            XCTAssertEqual(error.code, "KEYCHAIN_MIGRATION_SOURCE_REMOVE")
            XCTAssertFalse(error.message.contains("sk-source-secret"))
        }
        let migratedValue = await backend.value(account: "openai")
        XCTAssertEqual(migratedValue, "sk-source-secret")
    }

    func testCancellationCompensatesCreatedItemsAndPreservesLegacySource() async throws {
        let root = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let legacyURL = root.appending(path: "provider-keys.json")
        try Data(#"{"openai":"sk-cancel-secret"}"#.utf8).write(to: legacyURL)
        let backend = InMemoryKeychainBackend()
        await backend.cancelNextReadbackOnce()
        let store = KeychainCredentialStore(backend: backend)

        do {
            _ = try await store.migrateLegacyCredentials(at: legacyURL)
            XCTFail("Expected cancellation to propagate")
        } catch is CancellationError {
            // Cancellation remains distinguishable from an ordinary write
            // failure, while the just-created item is compensated first.
        }

        XCTAssertTrue(FileManager.default.fileExists(atPath: legacyURL.path))
        let compensatedValue = await backend.value(account: "openai")
        XCTAssertNil(compensatedValue)
    }

    func testLegacyScannerRejectsExcessiveNestedDepthWithoutDeletingSource() async throws {
        let root = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let legacyURL = root.appending(path: "deep.json")
        var nested = "null"
        for _ in 0..<70 {
            nested = "[\(nested)]"
        }
        let data = Data("{\"openai\":\"sk-depth-secret\",\"nested\":\(nested)}".utf8)
        try data.write(to: legacyURL)

        do {
            _ = try await KeychainCredentialStore(
                backend: InMemoryKeychainBackend()
            ).migrateLegacyCredentials(at: legacyURL)
            XCTFail("Expected the bounded JSON scanner to reject deep input")
        } catch let error as SlateSyncError {
            XCTAssertEqual(error.code, "KEYCHAIN_MIGRATION_INVALID")
            XCTAssertFalse(error.message.contains("sk-depth-secret"))
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: legacyURL.path))
    }

    private func makeTemporaryRoot() throws -> URL {
        // Keep legacy source fixtures isolated from every other migration test.
        let root = FileManager.default.temporaryDirectory
            .appending(path: "SlateSyncTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func filePermissions(at url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0
    }

    private func setFilePermissions(at url: URL, permissions: Int) throws {
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: permissions)],
            ofItemAtPath: url.path
        )
    }
}

private struct FailingRemovalSource: LegacyCredentialSource, Sendable {
    let url: URL
    let data: Data

    func read() async throws -> Data? { data }

    func remove(ifUnchangedFrom expected: Data) async throws {
        throw SlateSyncError(code: "TEST_SOURCE_REMOVE", message: "injected")
    }
}

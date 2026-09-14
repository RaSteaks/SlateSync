import Foundation
import SlateSyncPersistence
import XCTest

final class SlateSyncTests: XCTestCase {
    func testAppCompositionCanOpenAnIsolatedLibrary() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "SlateSyncAppTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }

        let store = try ProjectLibraryStore(applicationSupportRoot: root)
        let info = try await store.libraryInfo()

        XCTAssertEqual(info.formatVersion, 1)
        XCTAssertEqual(info.name, ProjectLibraryStore.defaultLibraryName)
    }

    func testSecurityKeychainBackendUsesAnIsolatedServiceAndConditionalDelete() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "SlateSyncKeychainTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let service = "com.slatesync.test.\(UUID().uuidString)"
        let account = "account-\(UUID().uuidString)"
        let backend = SecurityKeychainBackend(
            // Exercise the production default from an ad-hoc signed bundle;
            // overriding the mode here would hide a missing-entitlement regression.
            coordinationDirectory: root.appending(path: "coordination", directoryHint: .isDirectory)
        )
        let secret = Data("isolated-keychain-secret".utf8)

        do {
            let created = try await backend.createIfAbsent(
                secret,
                service: service,
                account: account
            )
            guard case .created(let ownership) = created else {
                XCTFail("A random service/account unexpectedly already exists")
                // XCTest assertions do not throw, so clean the random target
                // explicitly before returning from this early branch.
                try? await backend.delete(service: service, account: account)
                return
            }
            let createdValue = try await backend.read(service: service, account: account)
            XCTAssertEqual(createdValue, secret)

            let wrongValue = try await backend.deleteIfMatching(
                Data("different-secret".utf8),
                service: service,
                account: account,
                ownership: ownership
            )
            XCTAssertEqual(wrongValue, .valueChanged)
            let retainedValue = try await backend.read(service: service, account: account)
            XCTAssertEqual(retainedValue, secret)

            let removed = try await backend.deleteIfMatching(
                secret,
                service: service,
                account: account,
                ownership: ownership
            )
            XCTAssertEqual(removed, .removed)
            let deletedValue = try await backend.read(service: service, account: account)
            XCTAssertNil(deletedValue)

            // Keep cleanup explicit even when an XCTest assertion above fails;
            // failed assertions do not enter the `catch` block.
            try? await backend.delete(service: service, account: account)
        } catch {
            // Always clean the random Keychain item if an assertion or
            // Security.framework operation fails partway through the test.
            try? await backend.delete(service: service, account: account)
            throw error
        }
    }
}

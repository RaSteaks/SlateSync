import Foundation
import XCTest
@testable import SlateSyncDomain
@testable import SlateSyncPersistence

final class SlateSyncRuntimeTests: XCTestCase {
    func testBootstrapLoadsStoresResolvesDynamicDefaultsAndReportsMissingSource() async throws {
        let root = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let runtime = SlateSyncRuntime(
            locator: ApplicationSupportLocator(root: root),
            environment: [:],
            keychainBackend: InMemoryKeychainBackend()
        )

        let snapshot = await runtime.bootstrap()

        XCTAssertTrue(snapshot.isBootstrapped)
        XCTAssertEqual(snapshot.globalConfigVersion, GlobalConfigStore.currentVersion)
        XCTAssertFalse(snapshot.environmentFileLoaded)
        XCTAssertEqual(snapshot.migration.status, .sourceMissing)
        XCTAssertEqual(
            snapshot.configuration.values[.paddlePDXCacheHome],
            root.appending(path: "paddlex").path
        )
        XCTAssertEqual(snapshot.configuration.sources[.paddlePDXCacheHome], .defaults)
        XCTAssertNil(snapshot.lastError)
    }

    func testBootstrapMigratesLegacyCredentialsThroughTheInjectedBackend() async throws {
        let root = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let legacyURL = root.appending(path: "provider-keys.json")
        try Data(#"{"openai":"sk-runtime-secret","custom":"runtime-custom-secret"}"#.utf8)
            .write(to: legacyURL)
        let backend = InMemoryKeychainBackend()
        let runtime = SlateSyncRuntime(
            locator: ApplicationSupportLocator(root: root),
            environment: ["PADDLEOCR_LANGUAGE": "en"],
            keychainBackend: backend
        )

        let snapshot = await runtime.bootstrap()

        XCTAssertEqual(snapshot.migration.status, .migrated)
        XCTAssertEqual(snapshot.migration.verifiedProviderIDs, ["custom", "openai"])
        XCTAssertEqual(snapshot.configuration.values[.paddleOCRLanguage], "en")
        XCTAssertEqual(snapshot.configuration.sources[.paddleOCRLanguage], .processEnvironment)
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacyURL.path))
        let openAIValue = await backend.value(account: "openai")
        let customValue = await backend.value(account: "custom")
        XCTAssertEqual(openAIValue, "sk-runtime-secret")
        XCTAssertEqual(customValue, "runtime-custom-secret")
    }

    func testMigrationFailureIsNonBlockingSecretFreeAndRetryable() async throws {
        let root = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let legacyURL = root.appending(path: "provider-keys.json")
        let secret = "sk-runtime-failure-secret"
        try Data("{\"openai\":\"\(secret)\"}".utf8).write(to: legacyURL)
        let backend = InMemoryKeychainBackend()
        await backend.failNextWriteOnce()
        let runtime = SlateSyncRuntime(
            locator: ApplicationSupportLocator(root: root),
            environment: [:],
            keychainBackend: backend
        )

        let failed = await runtime.bootstrap()
        XCTAssertTrue(failed.isBootstrapped)
        XCTAssertEqual(failed.migration.status, .failed)
        XCTAssertEqual(failed.migration.errorCode, "KEYCHAIN_MIGRATION_WRITE")
        XCTAssertEqual(failed.migration.errorMessage, "旧凭据迁移失败，源文件已保留，可重试")
        XCTAssertTrue(FileManager.default.fileExists(atPath: legacyURL.path))
        let serialized = String(decoding: try JSONEncoder().encode(failed), as: UTF8.self)
        XCTAssertFalse(serialized.contains(secret))

        let retried = await runtime.retryLegacyMigration()
        XCTAssertEqual(retried.migration.status, .migrated)
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacyURL.path))
        let migratedValue = await backend.value(account: "openai")
        XCTAssertEqual(migratedValue, secret)
    }

    private func makeTemporaryRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "SlateSyncRuntimeTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
}

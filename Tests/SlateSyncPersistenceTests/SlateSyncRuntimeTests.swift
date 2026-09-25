import Foundation
import XCTest
@testable import SlateSyncDomain
@testable import SlateSyncPersistence

final class SlateSyncRuntimeTests: XCTestCase {
    func testSettingsDraftResolutionDoesNotSaveOrReplaceRuntime() async throws {
        let root = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let runtime = SlateSyncRuntime(locator: ApplicationSupportLocator(root: root),
                                       environment: ["PADDLEOCR_PYTHON": "/environment/python"])
        let before = await runtime.bootstrap()
        // Diagnostics preview follows normal precedence but does not commit.
        let preview = await runtime.resolveSettingsDraft(.init([.paddleOCRPython: "/draft/python", .visionOCRLanguage: "en-US"]))
        XCTAssertEqual(preview[.paddleOCRPython], "/draft/python")
        XCTAssertEqual(preview[.visionOCRLanguage], "en-US")
        let after = await runtime.currentSnapshot()
        let stored = try await runtime.globalConfigStore.load()
        XCTAssertEqual(after.configuration.values, before.configuration.values)
        XCTAssertNil(stored.values[.paddleOCRPython])
        let fallback = await runtime.resolveSettingsDraft(.init())
        XCTAssertEqual(fallback[.paddleOCRPython], "/environment/python")
    }

    func testBootstrapLoadsStoresAndResolvesDynamicDefaults() async throws {
        let root = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let runtime = SlateSyncRuntime(
            locator: ApplicationSupportLocator(root: root),
            environment: [:]
        )

        let snapshot = await runtime.bootstrap()

        XCTAssertTrue(snapshot.isBootstrapped)
        XCTAssertEqual(snapshot.globalConfigVersion, GlobalConfigStore.currentVersion)
        XCTAssertFalse(snapshot.environmentFileLoaded)
        XCTAssertEqual(
            snapshot.configuration.values[.paddlePDXCacheHome],
            root.appending(path: "paddlex").path
        )
        XCTAssertEqual(snapshot.configuration.sources[.paddlePDXCacheHome], .defaults)
        XCTAssertNil(snapshot.lastError)
    }

    func testProviderFileStorageNeverReadsOrMigratesOldSecrets() async throws {
        let root = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let legacy = root.appending(path: "provider-keys.json")
        let original = Data("{\"openai\":\"old-file-secret\"}".utf8)
        try original.write(to: legacy)
        let runtime = SlateSyncRuntime(locator: .init(root: root), environment: [:])
        // Repeated startup has no legacy-import branch.
        _ = await runtime.bootstrap()
        _ = await runtime.bootstrap()
        let missing = try await runtime.providerKey(for: "openai")
        XCTAssertNil(missing)
        try await runtime.setProviderKey("new-file-secret", for: "openai")
        let fresh = SlateSyncRuntime(locator: .init(root: root), environment: [:])
        let saved = try await fresh.providerKey(for: "openai")
        XCTAssertEqual(saved, "new-file-secret")
        XCTAssertEqual(try Data(contentsOf: legacy), original)
    }

    private func makeTemporaryRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "SlateSyncRuntimeTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
}

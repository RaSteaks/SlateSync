import Foundation
import XCTest
@testable import SlateSyncDomain
@testable import SlateSyncPersistence

final class ConfigurationStoreTests: XCTestCase {
    func testMachineSettingsRoundTripUsesIsolatedRootAndPrivateFile() async throws {
        let root = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MachineSettingsStore(applicationSupportRoot: root)
        let expected = MachineSettings(
            libraryPath: "/synthetic/library.slatesync-library",
            ocrPythonPath: "/synthetic/python",
            ocrSetupCompleted: true
        )

        _ = try await store.save(expected)
        let loaded = try await store.load()
        XCTAssertEqual(loaded, expected)
        XCTAssertEqual(try filePermissions(at: store.fileURL), 0o600)
    }

    func testMalformedMachineSettingsFallBackWithoutTouchingRealApplicationSupport() async throws {
        let root = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MachineSettingsStore(applicationSupportRoot: root)
        try Data(#"{"libraryPath":42,"ocrSetupCompleted":"yes"}"#.utf8).write(to: store.fileURL)

        let loaded = try await store.load()
        XCTAssertEqual(loaded, MachineSettings())
        XCTAssertTrue(store.fileURL.path.contains("SlateSyncTests-"))
    }

    func testGlobalConfigFixtureLoadsDefaultsAndPreservesProvidersOnPatch() async throws {
        let root = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = GlobalConfigStore(applicationSupportRoot: root)
        try fixtureData(named: "global-config-v2").write(to: store.fileURL)

        let loaded = try await store.load()
        XCTAssertEqual(loaded.values[.openAIBaseUrl], "https://example.test/v1")
        XCTAssertEqual(loaded.values[.maxBodyMB], "120")
        XCTAssertNil(loaded.values[.openRouterBaseUrl])
        XCTAssertEqual(loaded.customProviders.first?.name, "Legacy Gateway")
        XCTAssertEqual(loaded.customProviders.first?.transport, .chatCompletions)

        let saved = try await store.save(rawValues: ["MAX_BODY_MB": "140"])
        XCTAssertEqual(saved.values[.maxBodyMB], "140")
        XCTAssertEqual(saved.customProviders.count, 1)
        XCTAssertEqual(try filePermissions(at: store.fileURL), 0o600)
    }

    func testGlobalConfigNullPatchDeletesStoredOverride() async throws {
        let root = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = GlobalConfigStore(applicationSupportRoot: root)

        _ = try await store.save(rawValues: ["MAX_BODY_MB": "120"])
        let deleted = try await store.save(rawValues: ["MAX_BODY_MB": nil])

        XCTAssertNil(deleted.values[.maxBodyMB])
        let reloaded = try await GlobalConfigStore(applicationSupportRoot: root).load()
        XCTAssertNil(reloaded.values[.maxBodyMB])
    }

    func testMissingEnvironmentFileMatchesElectronEmptyMapBehavior() throws {
        let root = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        // A missing .env is a normal first-run condition, not a malformed
        // configuration; the loader must preserve the Electron empty-map
        // behavior for the native resolver.
        let values = try EnvironmentFileLoader.load(
            from: root.appending(path: ".env")
        )
        XCTAssertTrue(values.isEmpty)
    }

    func testExistingStorePathsAreRepairedToPrivatePermissions() async throws {
        let machineRoot = try makeTemporaryRoot()
        let globalRoot = try makeTemporaryRoot()
        defer {
            try? FileManager.default.removeItem(at: machineRoot)
            try? FileManager.default.removeItem(at: globalRoot)
        }

        let machineStore = MachineSettingsStore(applicationSupportRoot: machineRoot)
        _ = try await machineStore.save(MachineSettings(libraryPath: "/synthetic/library"))
        try setFilePermissions(at: machineRoot, permissions: 0o755)
        try setFilePermissions(at: machineStore.fileURL, permissions: 0o644)
        _ = try await machineStore.load()
        XCTAssertEqual(try filePermissions(at: machineRoot), 0o700)
        XCTAssertEqual(try filePermissions(at: machineStore.fileURL), 0o600)

        let globalStore = GlobalConfigStore(applicationSupportRoot: globalRoot)
        _ = try await globalStore.save(rawValues: ["MAX_BODY_MB": "120"])
        try setFilePermissions(at: globalRoot, permissions: 0o755)
        try setFilePermissions(at: globalStore.fileURL, permissions: 0o644)
        _ = try await globalStore.load()
        XCTAssertEqual(try filePermissions(at: globalRoot), 0o700)
        XCTAssertEqual(try filePermissions(at: globalStore.fileURL), 0o600)
    }

    func testGlobalConfigDropsInvalidProvidersAndReadsLegacyAliases() async throws {
        let root = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = GlobalConfigStore(applicationSupportRoot: root)
        let data = Data(
            #"{"customProviders":[{"id":"openai-compatible:00000000-0000-4000-8000-000000000003","label":"Alias Gateway","url":"https://gateway.example/v1///","models":["model-a","bad model"],"verification":{"model-a":{"status":"verified","revision":1,"message":"Bearer hidden"}}},{"id":"openai-compatible:invalid","name":"Dropped","baseUrl":"https://invalid.example/v1"}]}"#.utf8
        )
        try data.write(to: store.fileURL)

        let loaded = try await store.load()

        XCTAssertEqual(loaded.customProviders.count, 1)
        XCTAssertEqual(loaded.customProviders[0].name, "Alias Gateway")
        XCTAssertEqual(loaded.customProviders[0].baseUrl, "https://gateway.example/v1")
        XCTAssertEqual(loaded.customProviders[0].manualModelIds, ["model-a"])
        XCTAssertEqual(loaded.customProviders[0].capabilityCache?["model-a"]?.message, "[已隐藏]")
    }

    func testInvalidProviderSaveDoesNotPublishPartialSnapshot() async throws {
        let root = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = GlobalConfigStore(applicationSupportRoot: root)
        let valid = CustomProviderConfiguration(
            id: "openai-compatible",
            name: "Valid Gateway",
            baseUrl: "https://gateway.example/v1"
        )
        _ = try await store.save(values: [:], customProviders: [valid])
        let before = try Data(contentsOf: store.fileURL)

        let invalid = CustomProviderConfiguration(
            id: "openai-compatible:invalid",
            name: "Invalid Gateway",
            baseUrl: "https://gateway.example/v1"
        )
        do {
            _ = try await store.save(values: [:], customProviders: [invalid])
            XCTFail("Expected invalid provider rejection")
        } catch let error as SlateSyncError {
            XCTAssertEqual(error.code, "CUSTOM_PROVIDER_INVALID")
        }

        XCTAssertEqual(try Data(contentsOf: store.fileURL), before)
    }

    func testAtomicStoreFailureDoesNotPublishAFile() async throws {
        let root = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = GlobalConfigStore(applicationSupportRoot: root, writer: FailingAtomicWriter())

        do {
            _ = try await store.save(rawValues: ["MAX_BODY_MB": "120"])
            XCTFail("Expected injected atomic writer failure")
        } catch let error as SlateSyncError {
            XCTAssertEqual(error.code, "TEST_ATOMIC_WRITE")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.fileURL.path))
    }

    func testConfigurationResolverReportsExactPrecedenceAndEmptyProcessMask() {
        let global = GlobalSettingValues([.openAIBaseUrl: "https://global.example/v1"])
        let result = ConfigurationResolver.resolveAll(
            globalSettings: global,
            processEnvironment: [
                "OPENAI_BASE_URL": "https://process.example/v1",
                "OPENROUTER_BASE_URL": "https://process.example/v1",
                "PADDLEOCR_LANGUAGE": "",
            ],
            envFile: [
                "OPENAI_BASE_URL": "https://env.example/v1",
                "OPENROUTER_BASE_URL": "https://env.example/v1",
                "PADDLEOCR_LANGUAGE": "en",
            ]
        )

        XCTAssertEqual(result.values[.openAIBaseUrl], "https://global.example/v1")
        XCTAssertEqual(result.sources[.openAIBaseUrl], .globalSettings)
        XCTAssertEqual(result.values[.openRouterBaseUrl], "https://process.example/v1")
        XCTAssertEqual(result.sources[.openRouterBaseUrl], .processEnvironment)
        XCTAssertEqual(result.values[.paddleOCRLanguage], "ch")
        XCTAssertEqual(result.sources[.paddleOCRLanguage], .defaults)
    }

    func testEnvironmentParserAndWorkflowLoaderHandleLegacyInput() throws {
        let env = EnvironmentFileLoader.parse("# comment\nOPENAI_BASE_URL=\"https://example.test/v1\"\nEMPTY=\nDUPLICATE=first\nDUPLICATE=second\n")
        XCTAssertEqual(env["OPENAI_BASE_URL"], "https://example.test/v1")
        XCTAssertEqual(env["EMPTY"], "")
        XCTAssertEqual(env["DUPLICATE"], "first")

        let root = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let configURL = root.appending(path: "slatesync.config.json")
        let json = Data([0xEF, 0xBB, 0xBF]) + Data(#"{"slate":{"maxDirectoryDepth":6}}"#.utf8)
        try json.write(to: configURL)
        let config = try WorkflowConfigLoader.load(from: configURL)
        XCTAssertEqual(config.slate.maxDirectoryDepth, 6)
        XCTAssertEqual(config.scenario.matching.threshold, 0.85)
    }

    func testEnvironmentParserTreatsCRLFAndLFAsTheSameRecordSeparator() {
        let lf = EnvironmentFileLoader.parse("FIRST=one\nSECOND=two\n")
        let crlf = EnvironmentFileLoader.parse("FIRST=one\r\nSECOND=two\r\n")

        // `.env` files arrive from both Windows and Unix editors; only the
        // optional CR in CRLF should be discarded, not the record itself.
        XCTAssertEqual(crlf, lf)
        XCTAssertEqual(EnvironmentFileLoader.parse("FIRST=one\r\nSECOND=two")["SECOND"], "two")
    }

    func testConfigurationResolverUsesTheConcreteRootForDynamicDefaults() throws {
        let root = try makeTemporaryRoot()

        let resolved = ConfigurationResolver.resolve(
            key: .paddlePDXCacheHome,
            applicationSupportRoot: root
        )

        XCTAssertEqual(resolved.value, root.appending(path: "paddlex").path)
        XCTAssertEqual(resolved.source, .defaults)
    }

    private func makeTemporaryRoot() throws -> URL {
        // Each test owns a unique root so parallel XCTest workers cannot share
        // settings files or accidentally observe another test's snapshot.
        let root = FileManager.default.temporaryDirectory
            .appending(path: "SlateSyncTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func fixtureData(named name: String) throws -> Data {
        let url = try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: "json"))
        return try Data(contentsOf: url)
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

/// The failure writer is injected rather than replacing FileManager globally,
/// keeping the atomicity test deterministic and isolated from other tests.
private struct FailingAtomicWriter: AtomicFileWriting, Sendable {
    func writeAtomically(_ data: Data, to url: URL, permissions: Int) throws {
        throw SlateSyncError(code: "TEST_ATOMIC_WRITE", message: "injected")
    }
}

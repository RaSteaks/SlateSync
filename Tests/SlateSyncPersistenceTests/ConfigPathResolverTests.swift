import Foundation
import SlateSyncDomain
import XCTest
@testable import SlateSyncPersistence

/// Regression freeze for review finding #8: one `ConfigPathResolver` owns both
/// config-path policies. `global-config.json` is injected by the startup
/// composition layer (Application Support stays the fallback), and the
/// workflow config path freezes the old Electron rules — dev resolves the
/// configured value against the project root (absolute wins, relative
/// normalizes, empty falls back to the default name), packaged uses the
/// bundled copy and ignores the setting.
final class ConfigPathResolverTests: XCTestCase {
    private let developmentRoot = URL(fileURLWithPath: "/dev-project", isDirectory: true)

    private func resolve(_ configured: String?, isPackaged: Bool = false, bundled: URL? = nil) -> URL {
        ConfigPathResolver.workflowConfigURL(
            configured: configured,
            environment: WorkflowConfigPathEnvironment(
                isPackaged: isPackaged,
                developmentRoot: developmentRoot,
                bundledResourceURL: bundled
            )
        )
    }

    // MARK: - development rules (old main.mjs dev branch)

    func testDevelopmentDefaultUsesProjectRootWhenConfiguredValueIsEmpty() {
        XCTAssertEqual(resolve(nil), developmentRoot.appending(path: "slatesync.config.json"))
        XCTAssertEqual(resolve(""), developmentRoot.appending(path: "slatesync.config.json"))
        XCTAssertEqual(resolve("   "), developmentRoot.appending(path: "slatesync.config.json"))
    }

    func testDevelopmentRelativeValueResolvesAgainstProjectRoot() {
        XCTAssertEqual(resolve("config/dev.json"), developmentRoot.appending(path: "config/dev.json"))
        XCTAssertEqual(resolve("overrides/prod/workflow.json"), developmentRoot.appending(path: "overrides/prod/workflow.json"))
    }

    func testDevelopmentDotDotSegmentsNormalizeLikeNodePathResolve() {
        XCTAssertEqual(resolve("../shared/config.json"), URL(fileURLWithPath: "/shared/config.json"))
        XCTAssertEqual(resolve("./a/../b.json"), developmentRoot.appending(path: "b.json"))
    }

    func testDevelopmentAbsoluteValueWins() {
        XCTAssertEqual(resolve("/etc/slatesync.config.json"), URL(fileURLWithPath: "/etc/slatesync.config.json"))
    }

    // MARK: - packaged rule (old main.mjs packaged branch)

    func testPackagedBundleResourceWinsAndConfiguredValueIsIgnored() {
        let bundled = URL(fileURLWithPath: "/Applications/SlateSync.app/Contents/Resources", isDirectory: true)
        XCTAssertEqual(resolve("custom.json", isPackaged: true, bundled: bundled), bundled.appending(path: "slatesync.config.json"))
        XCTAssertEqual(resolve(nil, isPackaged: true, bundled: bundled), bundled.appending(path: "slatesync.config.json"))
        XCTAssertEqual(resolve("/etc/absolute.json", isPackaged: true, bundled: bundled), bundled.appending(path: "slatesync.config.json"))
    }

    // MARK: - global config store location

    func testGlobalConfigFileURLStaysBesideMachineStores() {
        XCTAssertEqual(
            ConfigPathResolver.globalConfigFileURL(applicationSupportRoot: developmentRoot),
            developmentRoot.appending(path: "global-config.json")
        )
    }
}

/// Runtime wiring: the workflow config path resolves once per process from the
/// startup-effective setting (process env → .env → global override), the
/// provider never hot-switches inside a running process, and a restart
/// re-resolves from the persisted override.
final class WorkflowConfigPathRuntimeTests: XCTestCase {
    private func makeTemporaryRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "ConfigPathResolverTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func writeConfig(_ name: String, depth: Int, in root: URL) throws {
        let url = root.appending(path: name)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(#"{"slate":{"maxDirectoryDepth":\#(depth)}}"#.utf8)
            .write(to: url)
    }

    private func makeRuntime(
        root: URL,
        environment: [String: String] = [:]
    ) -> SlateSyncRuntime {
        SlateSyncRuntime(
            locator: ApplicationSupportLocator(root: root),
            environment: environment,
            keychainBackend: InMemoryKeychainBackend(),
            workflowConfigEnvironment: .init(
                isPackaged: false,
                developmentRoot: root,
                bundledResourceURL: nil
            )
        )
    }

    func testProcessEnvironmentResolvesRelativeValueAgainstDevelopmentRoot() async throws {
        let root = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let runtime = makeRuntime(root: root, environment: ["SLATESYNC_CONFIG_PATH": "config/custom.json"])

        let snapshot = await runtime.bootstrap()

        XCTAssertEqual(snapshot.workflowConfigPath, root.appending(path: "config/custom.json").path)
    }

    func testDefaultPathUsesDevelopmentRootWhenNothingIsConfigured() async throws {
        let root = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let runtime = makeRuntime(root: root)

        let snapshot = await runtime.bootstrap()

        XCTAssertEqual(snapshot.workflowConfigPath, root.appending(path: "slatesync.config.json").path)
    }

    func testGlobalOverrideWinsOverProcessEnvironmentWithoutHotSwitch() async throws {
        let root = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try writeConfig("config/custom.json", depth: 6, in: root)
        try writeConfig("override.json", depth: 3, in: root)
        let runtime = makeRuntime(root: root, environment: ["SLATESYNC_CONFIG_PATH": "config/custom.json"])

        _ = await runtime.bootstrap()
        // Saving a global override changes the resolved value, but the path in
        // effect (and therefore the provider) must stay on the startup value.
        try await runtime.setValue("override.json", for: GlobalSettingKey.slateSyncConfigPath.rawValue)

        let snapshot = await runtime.currentSnapshot()
        XCTAssertEqual(snapshot.configuration.values[.slateSyncConfigPath], "override.json")
        XCTAssertEqual(snapshot.workflowConfigPath, root.appending(path: "config/custom.json").path)
        let provider = await runtime.workflowConfigProvider()
        let config = try await provider.current()
        XCTAssertEqual(config.slate.maxDirectoryDepth, 6, "进行中的进程不得热切换工作流配置")
    }

    func testRestartReResolvesPathAndReReadsPersistedOverride() async throws {
        let root = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try writeConfig("a.json", depth: 6, in: root)
        try writeConfig("b.json", depth: 3, in: root)
        let runtime1 = makeRuntime(root: root, environment: ["SLATESYNC_CONFIG_PATH": "a.json"])
        _ = await runtime1.bootstrap()
        let firstConfig = try await runtime1.workflowConfigProvider().current()
        XCTAssertEqual(firstConfig.slate.maxDirectoryDepth, 6)
        try await runtime1.setValue("b.json", for: GlobalSettingKey.slateSyncConfigPath.rawValue)

        // A restart resolves the persisted override anew.
        let runtime2 = makeRuntime(root: root)
        let snapshot2 = await runtime2.bootstrap()
        XCTAssertEqual(snapshot2.workflowConfigPath, root.appending(path: "b.json").path)
        let secondConfig = try await runtime2.workflowConfigProvider().current()
        XCTAssertEqual(secondConfig.slate.maxDirectoryDepth, 3)
    }

    func testMissingWorkflowConfigFileFailsClosedOnFirstRead() async throws {
        let root = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let runtime = makeRuntime(root: root)
        _ = await runtime.bootstrap()

        do {
            _ = try await runtime.workflowConfigProvider().current()
            XCTFail("缺失的工作流配置必须在首次读取时失败（旧行为）")
        } catch let error as SlateSyncError {
            XCTAssertEqual(error.code, "CONFIG_MISSING")
        }
    }

    func testInjectedGlobalConfigFileURLRoundTripsWithoutTouchingDefaultLocation() async throws {
        let root = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(
            at: root.appending(path: "machine", directoryHint: .isDirectory),
            withIntermediateDirectories: true
        )
        let injectedURL = root.appending(path: "machine/global-config.json")
        let store = GlobalConfigStore(fileURL: injectedURL)

        _ = try await store.save(rawValues: ["PADDLEOCR_LANGUAGE": "en"])
        let loaded = try await store.load()

        XCTAssertEqual(loaded.values[.paddleOCRLanguage], "en")
        XCTAssertTrue(FileManager.default.fileExists(atPath: injectedURL.path))
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: root.appending(path: "global-config.json").path),
            "注入的 fileURL 不得在默认位置落盘"
        )
    }
}

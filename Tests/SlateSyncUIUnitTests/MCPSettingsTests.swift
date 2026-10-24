import Foundation
import SlateSyncDomain
import XCTest
@testable import SlateSyncUI

/// Lifecycle regression tests use a protocol double and isolated preferences;
/// they never launch the app, inspect the screen, or read real provider settings.
@MainActor final class MCPSettingsTests: XCTestCase {
    func testDefaultIsOffAndEnablingPersistsAndStartsOnlyOnce() async throws {
        let (preferences, suite) = try isolatedPreferences()
        defer { preferences.removePersistentDomain(forName: suite) }
        let service = MCPServiceDouble()
        let model = MCPSettingsModel(service: service, preferences: preferences, socketPath: "/tmp/fixture.sock")
        model.activate()
        var starts = await service.starts
        XCTAssertEqual(starts, 0)
        XCTAssertFalse(model.automaticallyStarts)
        model.configuration = .init(executablePath: "/tmp/组件 \"test\"/run_mcp.sh", directories: ["/tmp/media"])
        model.setAutomaticallyStarts(true)
        model.start()
        try await settled(model)
        model.activate()
        starts = await service.starts
        XCTAssertEqual(starts, 1)
        XCTAssertTrue(model.isRunning)
        let restored = MCPSettingsModel(service: service, preferences: preferences, socketPath: "/tmp/fixture.sock")
        XCTAssertTrue(restored.automaticallyStarts)
        XCTAssertEqual(restored.configuration, model.configuration)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(model.clientConfiguration.utf8)) as? [String: Any])
        let servers = try XCTUnwrap(object["mcpServers"] as? [String: [String: Any]])
        XCTAssertEqual(servers["slatesync"]?["command"] as? String, model.configuration.executablePath)
        XCTAssertEqual(servers["slatesync"]?["args"] as? [String], ["--connect", "/tmp/fixture.sock"])
        await model.drain()
    }

    func testLaunchRestoresAutomaticStartAndDisablingStopsService() async throws {
        let (preferences, suite) = try isolatedPreferences()
        defer { preferences.removePersistentDomain(forName: suite) }
        preferences.set(true, forKey: MCPSettingsModel.automaticKey)
        preferences.set(try JSONEncoder().encode(MCPLaunchConfiguration(executablePath: "/tmp/run_mcp.sh", directories: ["/tmp/media"])), forKey: MCPSettingsModel.configurationKey)
        let service = MCPServiceDouble()
        let model = MCPSettingsModel(service: service, preferences: preferences, socketPath: "/tmp/fixture.sock")
        model.activate()
        try await settled(model)
        XCTAssertTrue(model.isRunning)
        model.setAutomaticallyStarts(false)
        try await settled(model)
        XCTAssertFalse(model.isRunning)
        XCTAssertFalse(preferences.bool(forKey: MCPSettingsModel.automaticKey))
        let stops = await service.stops
        XCTAssertEqual(stops, 1)
    }

    func testFailedStartCanRetryAndQuitDrainsPendingStartup() async throws {
        let (preferences, suite) = try isolatedPreferences()
        defer { preferences.removePersistentDomain(forName: suite) }
        let service = MCPServiceDouble(failsFirstStart: true)
        let model = MCPSettingsModel(service: service, preferences: preferences, socketPath: "/tmp/fixture.sock")
        model.start()
        try await settled(model)
        if case .failed = model.operation {} else { XCTFail("Expected actionable startup failure") }
        model.start()
        // Preparation is now a separate stage. Wait until startup has actually
        // entered the service before asserting that Quit drains that stage.
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while await service.starts < 2, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(1)) }
        await model.drain()
        XCTAssertFalse(model.isRunning)
        let running = await service.isRunning()
        XCTAssertFalse(running)
        let starts = await service.starts
        XCTAssertEqual(starts, 2)
        // Manual Stop/Quit preserve next-launch preference; only the toggle
        // changes the persisted automatic-start policy.
        XCTAssertFalse(model.automaticallyStarts)
    }

    func testImmediateQuitClearsBusyStateAndAllowsRetryAfterCanceledQuit() async throws {
        let (preferences, suite) = try isolatedPreferences()
        defer { preferences.removePersistentDomain(forName: suite) }
        let service = MCPServiceDouble()
        let model = MCPSettingsModel(service: service, preferences: preferences, socketPath: "/tmp/fixture.sock")
        // Drain can arrive before the unstructured startup task begins. It
        // must still clear busy UI, including when another editor vetoes Quit.
        model.start()
        await model.drain()
        XCTAssertFalse(model.isRunning)
        XCTAssertFalse(model.operation.isRunning)
        model.start()
        try await settled(model)
        XCTAssertTrue(model.isRunning)
        await model.drain()
    }

    func testOneClickWithoutPathsPreparesAndCanRestart() async throws {
        let (preferences, suite) = try isolatedPreferences()
        defer { preferences.removePersistentDomain(forName: suite) }
        let service = MCPServiceDouble()
        let model = MCPSettingsModel(service: service, preferences: preferences, socketPath: "/tmp/fixture.sock")
        XCTAssertTrue(model.canStart)
        model.start()
        XCTAssertFalse(model.canStart)
        try await settled(model)
        XCTAssertTrue(model.isRunning)
        XCTAssertEqual(model.statusText, L10n.tr("运行中"))
        XCTAssertTrue(model.configuration.directories.isEmpty)
        model.stop()
        try await settled(model)
        XCTAssertEqual(model.statusText, L10n.tr("已停止"))
        XCTAssertTrue(model.canStart)
        model.start()
        try await settled(model)
        let preparations = await service.preparations
        XCTAssertEqual(preparations, 2)
        await model.drain()
    }

    func testOneClickClientAddStartsOnceAndFailureKeepsServiceRunning() async throws {
        let (preferences, suite) = try isolatedPreferences()
        defer { preferences.removePersistentDomain(forName: suite) }
        let service = MCPServiceDouble(failsInstall: true)
        let model = MCPSettingsModel(service: service, preferences: preferences, socketPath: "/tmp/fixture.sock")
        model.install(client: .codex)
        model.install(client: .claudeCode)
        model.start()
        try await settled(model)
        XCTAssertTrue(model.isRunning)
        XCTAssertEqual(model.statusText, L10n.tr("运行中"))
        if case .failed = model.clientOperation {} else { XCTFail("Expected client failure") }
        let starts = await service.starts, installs = await service.installs
        XCTAssertEqual(starts, 1)
        XCTAssertEqual(installs, [.codex])
        await model.drain()
    }

    func testClientAddSuccessAndLegacyPreferencesWithoutSourceOverride() async throws {
        let (preferences, suite) = try isolatedPreferences()
        defer { preferences.removePersistentDomain(forName: suite) }
        preferences.set(Data(#"{"executablePath":"/tmp/helper","directories":[],"allowsModelRequests":false}"#.utf8), forKey: MCPSettingsModel.configurationKey)
        let model = MCPSettingsModel(service: MCPServiceDouble(), preferences: preferences, socketPath: "/tmp/fixture.sock")
        XCTAssertEqual(model.configuration.executablePath, "/tmp/helper")
        XCTAssertNil(model.configuration.sourceDirectory)
        model.install(client: .claudeCode)
        try await settled(model)
        if case .succeeded = model.clientOperation {} else { XCTFail("Expected registration feedback") }
        await model.drain()
    }

    func testBuildFailureStopsBeforeLaunchAndCanRetry() async throws {
        let (preferences, suite) = try isolatedPreferences()
        defer { preferences.removePersistentDomain(forName: suite) }
        let service = MCPServiceDouble(failsFirstPreparation: true)
        let model = MCPSettingsModel(service: service, preferences: preferences, socketPath: "/tmp/fixture.sock")
        model.start()
        try await settled(model)
        let starts = await service.starts
        XCTAssertEqual(starts, 0)
        XCTAssertEqual(model.statusText, L10n.tr("启动失败"))
        XCTAssertTrue(model.canStart)
        model.start()
        try await settled(model)
        XCTAssertTrue(model.isRunning)
        await model.drain()
    }

    func testCancelPreparationPreventsLaunchAndAllowsRetry() async throws {
        let (preferences, suite) = try isolatedPreferences()
        defer { preferences.removePersistentDomain(forName: suite) }
        let service = MCPServiceDouble(preparationDelay: .milliseconds(150))
        let model = MCPSettingsModel(service: service, preferences: preferences, socketPath: "/tmp/fixture.sock")
        model.install(client: .codex)
        model.cancelPreparation()
        try await settled(model)
        let starts = await service.starts, installs = await service.installs
        XCTAssertEqual(starts, 0)
        XCTAssertEqual(installs, [])
        XCTAssertEqual(model.operation, .canceled)
        XCTAssertEqual(model.clientOperation, .canceled)
        XCTAssertTrue(model.canStart)
        model.start()
        try await settled(model)
        XCTAssertTrue(model.isRunning)
        await model.drain()
    }

    func testUnexpectedExitUpdatesStatusAndAllowsRestart() async throws {
        let (preferences, suite) = try isolatedPreferences()
        defer { preferences.removePersistentDomain(forName: suite) }
        let service = MCPServiceDouble()
        let model = MCPSettingsModel(service: service, preferences: preferences, socketPath: "/tmp/fixture.sock")
        model.start()
        try await settled(model)
        await service.stop()
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while model.isRunning, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(model.statusText, L10n.tr("已停止（异常退出）"))
        XCTAssertTrue(model.canStart)
        model.start()
        try await settled(model)
        XCTAssertTrue(model.isRunning)
        await model.drain()
    }

    private func isolatedPreferences() throws -> (UserDefaults, String) {
        let suite = "SlateSync.MCP.tests.\(UUID().uuidString)"
        return (try XCTUnwrap(UserDefaults(suiteName: suite)), suite)
    }

    private func settled(_ model: MCPSettingsModel) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while model.isBusy, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertFalse(model.isBusy)
    }
}

private actor MCPServiceDouble: MCPServiceManaging {
    var starts = 0
    var stops = 0
    var preparations = 0
    var installs: [MCPClient] = []
    private var running = false
    private let failsFirstStart: Bool
    private let failsFirstPreparation: Bool
    private let failsInstall: Bool
    private let preparationDelay: Duration
    init(failsFirstStart: Bool = false, failsFirstPreparation: Bool = false, failsInstall: Bool = false, preparationDelay: Duration = .zero) {
        self.failsFirstStart = failsFirstStart
        self.failsFirstPreparation = failsFirstPreparation
        self.failsInstall = failsInstall
        self.preparationDelay = preparationDelay
    }
    func prepare(configuration: MCPLaunchConfiguration) async throws -> MCPLaunchConfiguration {
        preparations += 1
        try await Task.sleep(for: preparationDelay)
        if failsFirstPreparation && preparations == 1 { throw SlateSyncError(code: "TEST_BUILD", message: "MCP build fixture") }
        return configuration
    }
    func install(client: MCPClient, configuration: MCPLaunchConfiguration) throws {
        installs.append(client)
        if failsInstall { throw SlateSyncError(code: "TEST_CLIENT", message: "MCP client fixture") }
    }
    func start(configuration: MCPLaunchConfiguration) async throws {
        starts += 1
        if failsFirstStart && starts == 1 { throw SlateSyncError(code: "TEST_START", message: "MCP start fixture") }
        try await Task.sleep(for: .milliseconds(20))
        running = true
    }
    func stop() { stops += 1; running = false }
    func isRunning() -> Bool { running }
}

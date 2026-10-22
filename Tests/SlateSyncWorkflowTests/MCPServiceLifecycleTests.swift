import Foundation
import SlateSyncDomain
import SlateSyncWorkflow
import XCTest

/// Only disposable shell helpers are launched here. Real MCP protocol/session
/// coverage lives in mcp_stdio_smoke.py --managed and never needs an app window.
final class MCPServiceLifecycleTests: XCTestCase {
    func testCanceledReadinessWaitReapsHelperAndAllowsRestart() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "mcp-cancel-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let launcher = root.appending(path: "helper.sh"), pidFile = root.appending(path: "pid")
        // The helper records admission but deliberately withholds readiness;
        // EOF still drains it so cancellation can be tested without a timeout.
        try Data("#!/bin/zsh\nprint -r -- $$ > \"${0:h}/pid\"\nexec /bin/cat > /dev/null\n".utf8).write(to: launcher)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: launcher.path)
        let service = MCPServiceLifecycle(settingsDirectory: root)
        let configuration = MCPLaunchConfiguration(executablePath: launcher.path)
        let startup = Task { try await service.start(configuration: configuration) }
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !FileManager.default.fileExists(atPath: pidFile.path), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        startup.cancel()
        do { try await startup.value; XCTFail("Canceled startup must not succeed") }
        catch is CancellationError {} catch { XCTFail("Cancellation was changed into \(error)") }
        let pid = try XCTUnwrap(Int32(String(contentsOf: pidFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)))
        XCTAssertEqual(kill(pid, 0), -1, "Cancel must reap the helper before returning")
        let running = await service.isRunning()
        XCTAssertFalse(running)
        try Data("#!/bin/zsh\nprint -r -- SLATESYNC_MCP_READY\nexec /bin/cat > /dev/null\n".utf8).write(to: launcher)
        try await service.start(configuration: configuration)
        await service.stop()
    }

    func testReadyHandshakeDuplicateStartAndControlEOFStop() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "mcp-lifecycle-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let launcher = root.appending(path: "helper.sh")
        try Data("#!/bin/zsh\nprint -r -- SLATESYNC_MCP_READY\n/bin/cat > /dev/null\n".utf8).write(to: launcher)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: launcher.path)
        let service = MCPServiceLifecycle(settingsDirectory: root, socketPath: root.appending(path: "fixture.sock").path)
        // Empty grants must support the same ready/stop/restart lifecycle.
        let configuration = MCPLaunchConfiguration(executablePath: launcher.path)
        try await service.start(configuration: configuration)
        var running = await service.isRunning()
        XCTAssertTrue(running)
        do { try await service.start(configuration: configuration); XCTFail("Duplicate start must fail") }
        catch { XCTAssertEqual((error as? SlateSyncError)?.code, "MCP_ALREADY_RUNNING") }
        await service.stop()
        running = await service.isRunning()
        XCTAssertFalse(running)
        // An ordinary Stop must release every owned handle so Start can retry.
        try await service.start(configuration: configuration)
        await service.stop()
    }

    func testInvalidConfigurationAndIsolatedEnvironmentFailClosed() async throws {
        let root = FileManager.default.temporaryDirectory
        let isolated = MCPServiceLifecycle(settingsDirectory: root, allowsLaunching: false)
        do { try await isolated.start(configuration: .init()); XCTFail("Isolation must reject launch") }
        catch { XCTAssertEqual((error as? SlateSyncError)?.code, "MCP_UNAVAILABLE") }
        let service = MCPServiceLifecycle(settingsDirectory: root)
        do { try await service.start(configuration: .init(executablePath: "/missing-mcp", directories: [root.path])); XCTFail("Missing executable") }
        catch { XCTAssertEqual((error as? SlateSyncError)?.code, "MCP_EXECUTABLE") }
        do { try await service.start(configuration: .init(executablePath: "/bin/cat", directories: ["/missing-mcp-directory"])); XCTFail("Invalid grant") }
        catch { XCTAssertEqual((error as? SlateSyncError)?.code, "MCP_DIRECTORIES") }
        await service.stop()
    }
}

import Foundation
import SlateSyncDomain
import XCTest
@testable import SlateSyncWorkflow

/// Synthetic compiler/client executables record argv in disposable homes.
/// These tests never register a server in the operator's real clients.
final class MCPSetupOperationsTests: XCTestCase {
    private func fixture() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appending(path: "mcp-setup-\(UUID().uuidString) 空格")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    private func script(_ path: URL, _ body: String) throws {
        try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(("#!/bin/zsh\n" + body).utf8).write(to: path)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: path.path)
    }

    private func source(_ root: URL) throws {
        try FileManager.default.createDirectory(at: root.appending(path: "MCP"), withIntermediateDirectories: true)
        try Data().write(to: root.appending(path: "MCP/Package.swift"))
        try script(root.appending(path: "script/run_mcp.sh"), "exit 0\n")
    }

    func testAutomaticBuildUsesSeparateArgumentsAndReturnsLauncherWithoutGrants() async throws {
        let root = try fixture()
        try source(root)
        let compiler = root.appending(path: "compiler")
        try script(compiler, """
        print -rl -- "$@" > "$HOME/argv"
        /bin/mkdir -p "$4/.build/release"
        /usr/bin/touch "$4/.build/release/slatesync-mcp"
        /bin/chmod +x "$4/.build/release/slatesync-mcp"
        """)
        let setup = MCPSetupOperations(settingsDirectory: root, sourceRoot: root,
            environment: ["HOME": root.path], compiler: compiler, bundledExecutable: nil)
        let prepared = try await setup.prepare(configuration: .init())
        XCTAssertEqual(prepared.executablePath, root.appending(path: "script/run_mcp.sh").path)
        XCTAssertTrue(prepared.directories.isEmpty)
        let args = try String(contentsOf: root.appending(path: "argv"), encoding: .utf8)
        XCTAssertEqual(args, "swift\nbuild\n--package-path\n\(root.path)/MCP\n--configuration\nrelease\n")
        // Reuse is incremental, not a stale binary short-circuit.
        _ = try await setup.prepare(configuration: prepared)
    }

    func testMissingSourceBuildFailureAndRetry() async throws {
        let root = try fixture(), compiler = root.appending(path: "compiler")
        let setup = MCPSetupOperations(settingsDirectory: root, sourceRoot: root,
            environment: ["HOME": root.path], compiler: compiler, bundledExecutable: nil)
        do { _ = try await setup.prepare(configuration: .init()); XCTFail("Missing source") }
        catch { XCTAssertEqual((error as? SlateSyncError)?.code, "MCP_SOURCE") }
        try source(root)
        try script(compiler, "exit 2\n")
        do { _ = try await setup.prepare(configuration: .init()); XCTFail("Build failure") }
        catch { XCTAssertEqual((error as? SlateSyncError)?.code, "MCP_BUILD") }
        // A selected standalone helper bypasses building and preserves consent.
        let helper = root.appending(path: "slatesync-mcp")
        try script(helper, "exit 0\n")
        let config = MCPLaunchConfiguration(executablePath: helper.path, allowsModelRequests: true)
        let prepared = try await setup.prepare(configuration: config)
        XCTAssertEqual(prepared, config)
    }

    func testSourceOverrideAndBundledHelper() async throws {
        let root = try fixture(), moved = root.appending(path: "relocated")
        try source(moved)
        let helper = root.appending(path: "slatesync-mcp")
        try script(helper, "exit 0\n")
        let setup = MCPSetupOperations(settingsDirectory: root, sourceRoot: root,
            environment: ["HOME": root.path], compiler: URL(fileURLWithPath: "/usr/bin/false"), bundledExecutable: helper)
        let bundled = try await setup.prepare(configuration: .init())
        XCTAssertEqual(bundled.executablePath, helper.path)
        do { _ = try await setup.prepare(configuration: .init(sourceDirectory: moved.path)); XCTFail("Explicit source must build") }
        catch { XCTAssertEqual((error as? SlateSyncError)?.code, "MCP_BUILD") }
    }

    func testCanceledBuildReleasesOperationAndTerminatesCompiler() async throws {
        let root = try fixture(), compiler = root.appending(path: "compiler")
        try source(root)
        try script(compiler, "print -r -- $$ > \"$HOME/pid\"\nexec /bin/sleep 60\n")
        let setup = MCPSetupOperations(settingsDirectory: root, sourceRoot: root,
            environment: ["HOME": root.path], compiler: compiler, bundledExecutable: nil)
        let task = Task { try await setup.prepare(configuration: .init()) }
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !FileManager.default.fileExists(atPath: root.appending(path: "pid").path), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        task.cancel()
        do { _ = try await task.value; XCTFail("Canceled build") } catch is CancellationError {} catch { XCTFail("\(error)") }
        let pid = try XCTUnwrap(Int32(String(contentsOf: root.appending(path: "pid"), encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)))
        XCTAssertEqual(kill(pid, 0), -1)
        try script(compiler, "exit 1\n")
        do { _ = try await setup.prepare(configuration: .init()); XCTFail("Expected build error") }
        catch { XCTAssertEqual((error as? SlateSyncError)?.code, "MCP_BUILD") }
    }

    func testClientArgumentsUserScopeAndEnvironmentIsolation() async throws {
        let root = try fixture(), helper = root.appending(path: "helper \"quote\" $dollar")
        try script(helper, "exit 0\n")
        for name in ["codex", "claude"] {
            try script(root.appending(path: "bin/\(name)"), "print -rl -- \"$@\" > \"$HOME/\(name)-argv\"\n[[ -z \"$PROVIDER_API_KEY\" ]]\n")
        }
        let setup = MCPSetupOperations(settingsDirectory: root, environment: ["HOME": root.path,
            "PATH": root.appending(path: "bin").path, "PROVIDER_API_KEY": "must-not-reach-cli"])
        try await setup.install(client: .codex, executable: helper.path, socketPath: "/tmp/test.sock")
        try await setup.install(client: .claudeCode, executable: helper.path, socketPath: "/tmp/test.sock")
        XCTAssertEqual(try String(contentsOf: root.appending(path: "codex-argv"), encoding: .utf8),
            "mcp\nadd\nslatesync\n--\n\(helper.path)\n--connect\n/tmp/test.sock\n")
        XCTAssertEqual(try String(contentsOf: root.appending(path: "claude-argv"), encoding: .utf8),
            "mcp\nadd\n--transport\nstdio\n--scope\nuser\nslatesync\n--\n\(helper.path)\n--connect\n/tmp/test.sock\n")
    }

    func testClientFailureAndClaudeDuplicatePreserveConfiguration() async throws {
        let root = try fixture(), helper = root.appending(path: "helper")
        try script(helper, "exit 0\n")
        try script(root.appending(path: "bin/claude"), "exit 3\n")
        let setup = MCPSetupOperations(settingsDirectory: root, environment: ["HOME": root.path, "PATH": root.appending(path: "bin").path])
        do { try await setup.install(client: .claudeCode, executable: helper.path, socketPath: "/tmp/test.sock"); XCTFail("CLI failure") }
        catch { XCTAssertEqual((error as? SlateSyncError)?.code, "MCP_CLIENT_INSTALL") }
        let file = root.appending(path: ".claude.json")
        let original = try JSONSerialization.data(withJSONObject: ["unrelated": ["keep": true], "mcpServers": ["slatesync": [
            "type": "stdio", "command": helper.path, "args": ["--connect", "/tmp/test.sock"]]]])
        try original.write(to: file)
        // Identical entry is a no-op even though the fake CLI fails.
        try await setup.install(client: .claudeCode, executable: helper.path, socketPath: "/tmp/test.sock")
        do { try await setup.install(client: .claudeCode, executable: helper.path, socketPath: "/tmp/other.sock"); XCTFail("Conflict") }
        catch { XCTAssertEqual((error as? SlateSyncError)?.code, "MCP_CLIENT_CONFLICT") }
        XCTAssertEqual(try Data(contentsOf: file), original)
    }
}

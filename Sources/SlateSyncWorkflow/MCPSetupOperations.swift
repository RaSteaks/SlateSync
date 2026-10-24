import Darwin
import Foundation
import SlateSyncDomain

/// Builds the optional package and delegates client configuration to official
/// CLIs. No shell command interpolation and no provider credentials are used.
actor MCPSetupOperations {
    private let settingsDirectory: URL
    private let sourceRoot: URL
    private let environment: [String: String]
    private let compiler: URL
    private let bundledExecutable: URL?
    private var busy = false

    init(settingsDirectory: URL,
         sourceRoot: URL = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent(),
         environment: [String: String] = ProcessInfo.processInfo.environment,
         compiler: URL = URL(fileURLWithPath: "/usr/bin/xcrun"),
         bundledExecutable: URL? = Bundle.main.url(forResource: "slatesync-mcp", withExtension: nil, subdirectory: "MCP")) {
        self.settingsDirectory = settingsDirectory
        self.sourceRoot = sourceRoot
        self.environment = environment
        self.compiler = compiler
        self.bundledExecutable = bundledExecutable
    }

    func prepare(configuration: MCPLaunchConfiguration) async throws -> MCPLaunchConfiguration {
        guard !busy else { throw failure("MCP_BUSY", "MCP 正在处理另一项操作，请稍后重试。") }
        busy = true
        defer { busy = false }
        var result = configuration
        let selected = configuration.executablePath
        // Explicit standalone binaries remain usable without a source checkout.
        if !selected.isEmpty, URL(fileURLWithPath: selected).lastPathComponent != "run_mcp.sh" {
            try validateExecutable(selected)
            return result
        }
        if selected.isEmpty, configuration.sourceDirectory == nil, let bundledExecutable,
           FileManager.default.isExecutableFile(atPath: bundledExecutable.path) {
            result.executablePath = bundledExecutable.path
            return result
        }
        let root: URL
        if let override = configuration.sourceDirectory, !override.isEmpty {
            root = URL(fileURLWithPath: override)
        } else if !selected.isEmpty {
            root = URL(fileURLWithPath: selected).deletingLastPathComponent().deletingLastPathComponent()
        } else {
            root = sourceRoot
        }
        let launcher = root.appending(path: "script/run_mcp.sh")
        guard root.path.hasPrefix("/"),
              FileManager.default.fileExists(atPath: root.appending(path: "MCP/Package.swift").path),
              FileManager.default.isExecutableFile(atPath: launcher.path) else {
            throw failure("MCP_SOURCE", "未找到 MCP 源码。请在高级设置中选择 SlateSync 源码目录，或选择已构建的启动程序。")
        }
        // SwiftPM performs an incremental release build. Running xcrun directly
        // lets cancellation reach SwiftPM instead of leaving a waiting shell.
        let status = try await run(compiler, arguments: ["swift", "build", "--package-path", root.appending(path: "MCP").path,
            "--configuration", "release"], timeout: .seconds(900), logName: "mcp-build.log")
        guard status == 0 else {
            throw failure("MCP_BUILD", "MCP 构建失败。请检查 Xcode / Swift 工具链、网络及 mcp-build.log 后重试。")
        }
        try validateExecutable(root.appending(path: "MCP/.build/release/slatesync-mcp").path)
        result.executablePath = launcher.path
        return result
    }

    func install(client: MCPClient, executable: String, socketPath: String) async throws {
        guard !busy else { throw failure("MCP_BUSY", "MCP 正在处理另一项操作，请稍后重试。") }
        busy = true
        defer { busy = false }
        try validateExecutable(executable)
        let name = client == .codex ? "codex" : "claude"
        guard let cli = findCLI(name) else {
            throw failure("MCP_CLIENT_MISSING", "未找到客户端命令行工具。请先安装 Codex CLI 或 Claude Code，再重试；也可复制托管配置手动添加。")
        }
        let arguments: [String]
        switch client {
        case .codex:
            // Codex owns TOML parsing and updates only this named server.
            arguments = ["mcp", "add", "slatesync", "--", executable, "--connect", socketPath]
        case .claudeCode:
            // Claude rejects duplicate names. Treat an identical user entry as
            // success, and preserve a conflicting entry instead of remove/add.
            if try hasClaudeEntry(executable: executable, socketPath: socketPath) { return }
            arguments = ["mcp", "add", "--transport", "stdio", "--scope", "user", "slatesync", "--", executable, "--connect", socketPath]
        }
        let status = try await run(cli, arguments: arguments, timeout: .seconds(30), logName: "mcp-client.log")
        guard status == 0 else {
            throw failure("MCP_CLIENT_INSTALL", "添加客户端失败。请检查同名配置、客户端权限及 mcp-client.log 后重试。")
        }
    }

    private func hasClaudeEntry(executable: String, socketPath: String) throws -> Bool {
        let home = environment["HOME"] ?? FileManager.default.homeDirectoryForCurrentUser.path
        let directory = environment["CLAUDE_CONFIG_DIR"] ?? home
        let file = URL(fileURLWithPath: directory).appending(path: ".claude.json")
        guard FileManager.default.fileExists(atPath: file.path) else { return false }
        // Only inspect the requested entry; never log the surrounding user config.
        guard let data = try? Data(contentsOf: file),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let servers = object["mcpServers"] as? [String: Any] else { return false }
        guard let entry = servers["slatesync"] as? [String: Any] else { return false }
        guard entry["command"] as? String == executable,
              entry["args"] as? [String] == ["--connect", socketPath],
              entry["type"] as? String == nil || entry["type"] as? String == "stdio",
              (entry["env"] as? [String: String] ?? [:]).isEmpty else {
            throw failure("MCP_CLIENT_CONFLICT", "Claude Code 已有不同的 slatesync 配置。请先在客户端移除该条目，再重新添加。")
        }
        return true
    }

    private func searchDirectories() -> [String] {
        let home = environment["HOME"] ?? FileManager.default.homeDirectoryForCurrentUser.path
        return (environment["PATH"] ?? "").split(separator: ":").map(String.init).filter { $0.hasPrefix("/") }
            + [home + "/.local/bin", home + "/.npm-global/bin", "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"]
    }

    private func findCLI(_ name: String) -> URL? {
        var candidates = searchDirectories().map { URL(fileURLWithPath: $0).appending(path: name) }
        if name == "codex" {
            candidates += ["/Applications/Codex.app/Contents/Resources/codex",
                "/Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex"].map { URL(fileURLWithPath: $0) }
        }
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    private func run(_ executable: URL, arguments: [String], timeout: Duration, logName: String) async throws -> Int32 {
        try Task.checkCancellation()
        let logs = settingsDirectory.appending(path: "logs", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        let file = logs.appending(path: logName)
        if !FileManager.default.fileExists(atPath: file.path) {
            FileManager.default.createFile(atPath: file.path, contents: nil, attributes: [.posixPermissions: 0o600])
        }
        let log = try FileHandle(forWritingTo: file)
        defer { try? log.close() }
        try log.seekToEnd()
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        // Finder apps have a minimal PATH. Include the selected CLI's directory
        // for npm's /usr/bin/env node launcher; never source user shell scripts.
        var childEnvironment = environment.filter {
            ["HOME", "TMPDIR", "LANG", "DEVELOPER_DIR", "SDKROOT", "CODEX_HOME", "CLAUDE_CONFIG_DIR"].contains($0.key)
        }
        childEnvironment["PATH"] = ([executable.deletingLastPathComponent().path] + searchDirectories()).joined(separator: ":")
        process.environment = childEnvironment
        process.currentDirectoryURL = settingsDirectory
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = log
        process.standardError = log
        try process.run()
        do {
            let deadline = ContinuousClock.now.advanced(by: timeout)
            while process.isRunning {
                try Task.checkCancellation()
                guard ContinuousClock.now < deadline else { throw failure("MCP_TIMEOUT", "MCP 操作超时，请检查日志后重试。") }
                try await Task.sleep(for: .milliseconds(50))
            }
            try Task.checkCancellation()
            return process.terminationStatus
        } catch {
            // SwiftPM handles SIGINT and cancels its compiler jobs. Bound cleanup
            // before force-killing only the process owned by this operation.
            if process.isRunning { process.interrupt() }
            let deadline = ContinuousClock.now.advanced(by: .seconds(2))
            while process.isRunning, ContinuousClock.now < deadline {
                await Task.detached { try? await Task.sleep(for: .milliseconds(25)) }.value
            }
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            while process.isRunning { await Task.detached { try? await Task.sleep(for: .milliseconds(25)) }.value }
            throw error
        }
    }

    private func validateExecutable(_ path: String) throws {
        guard path.hasPrefix("/"), FileManager.default.isExecutableFile(atPath: path) else {
            throw failure("MCP_EXECUTABLE", "请选择已构建的 run_mcp.sh 或 slatesync-mcp 可执行文件。")
        }
    }

    private func failure(_ code: String, _ message: String) -> SlateSyncError { .init(code: code, message: message) }
}

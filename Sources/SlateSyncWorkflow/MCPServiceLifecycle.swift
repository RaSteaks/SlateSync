import Darwin
import Foundation
import SlateSyncDomain

/// Owns only the helper launched by this app. Closing its control pipe also
/// stops the broker if the app crashes; client-owned stdio servers are untouched.
public actor MCPServiceLifecycle: MCPServiceManaging {
    public static var socketPath: String { "/tmp/slatesync-mcp-\(getuid())/service.sock" }
    private let settingsDirectory: URL
    private let allowsLaunching: Bool
    private let endpoint: String
    private var child: Process?
    private var control: Pipe?
    private var output: Pipe?
    private var ready = false
    private var readiness = Data()
    private let setup: MCPSetupOperations

    public init(settingsDirectory: URL, allowsLaunching: Bool = true, socketPath: String = MCPServiceLifecycle.socketPath) {
        self.settingsDirectory = settingsDirectory
        self.allowsLaunching = allowsLaunching
        self.endpoint = socketPath
        self.setup = MCPSetupOperations(settingsDirectory: settingsDirectory)
    }

    public func prepare(configuration: MCPLaunchConfiguration) async throws -> MCPLaunchConfiguration {
        guard allowsLaunching else { throw failure("MCP_UNAVAILABLE", "当前隔离或沙盒环境不支持启动外部 MCP 组件。") }
        return try await setup.prepare(configuration: configuration)
    }

    public func install(client: MCPClient, configuration: MCPLaunchConfiguration) async throws {
        guard allowsLaunching else { throw failure("MCP_UNAVAILABLE", "当前隔离或沙盒环境不支持启动外部 MCP 组件。") }
        try await setup.install(client: client, executable: configuration.executablePath, socketPath: endpoint)
    }

    public func start(configuration: MCPLaunchConfiguration) async throws {
        try Task.checkCancellation()
        guard child == nil else { throw failure("MCP_ALREADY_RUNNING", "MCP 服务已启动或正在停止。") }
        guard allowsLaunching else { throw failure("MCP_UNAVAILABLE", "当前隔离或沙盒环境不支持启动外部 MCP 组件。") }
        guard configuration.executablePath.hasPrefix("/"),
              FileManager.default.isExecutableFile(atPath: configuration.executablePath) else {
            throw failure("MCP_EXECUTABLE", "请选择已构建的 run_mcp.sh 或 slatesync-mcp 可执行文件。")
        }
        // An empty grant list starts a discoverable service with no file access.
        // Validate supplied grants without making them a startup prerequisite.
        guard configuration.directories.allSatisfy({ path in
                  var directory: ObjCBool = false
                  return path.hasPrefix("/") && FileManager.default.fileExists(atPath: path, isDirectory: &directory) && directory.boolValue
              }) else { throw failure("MCP_DIRECTORIES", "授权目录不存在，请移除或重新选择后启动。") }

        let process = Process(), input = Pipe(), output = Pipe()
        process.executableURL = URL(fileURLWithPath: configuration.executablePath)
        process.arguments = ["--managed-socket", endpoint, "--settings-directory", settingsDirectory.path]
            + configuration.directories.flatMap { ["--allow-directory", $0] }
            + (configuration.allowsModelRequests ? ["--allow-model-requests"] : [])
        // No inherited provider tokens or shell evaluation. Persistent helper
        // diagnostics stay in the app's existing isolated Application Support.
        process.environment = ProcessInfo.processInfo.environment.filter { ["PATH", "TMPDIR", "LANG", "HOME"].contains($0.key) }
        let logs = settingsDirectory.appending(path: "logs", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        let logURL = logs.appending(path: "mcp-service.log")
        if !FileManager.default.fileExists(atPath: logURL.path) {
            FileManager.default.createFile(atPath: logURL.path, contents: nil, attributes: [.posixPermissions: 0o600])
        }
        let log = try FileHandle(forWritingTo: logURL)
        try log.seekToEnd()
        defer { try? log.close() }
        process.standardInput = input
        process.standardOutput = output
        process.standardError = log
        child = process; control = input; self.output = output
        ready = false; readiness = Data()
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil }
            Task { await self?.receiveReadiness(data, process: process) }
        }
        do {
            try process.run()
            let deadline = ContinuousClock.now.advanced(by: .seconds(8))
            while child === process, process.isRunning, !ready, ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(40))
            }
            try Task.checkCancellation()
            guard child === process, process.isRunning, ready else {
                throw failure("MCP_START_FAILED", "MCP 未能启动，请检查组件版本、目录权限及 mcp-service.log。")
            }
        } catch {
            await stop()
            // Cancel/quit must retain their UI meaning after the owned helper
            // has been reaped, including cancellation racing the ready signal.
            if error is CancellationError || Task.isCancelled { throw CancellationError() }
            throw error as? SlateSyncError ?? failure("MCP_START_FAILED", "MCP 未能启动，请检查组件版本、目录权限及 mcp-service.log。")
        }
    }

    public func isRunning() -> Bool { child?.isRunning == true && ready }

    public func stop() async {
        guard let process = child else { return }
        // EOF requests the same graceful drain as SIGTERM, including every
        // connected session. Never signal unrelated processes by name or PID file.
        try? control?.fileHandleForWriting.close()
        let deadline = ContinuousClock.now.advanced(by: .seconds(12))
        while process.isRunning, ContinuousClock.now < deadline {
            // Startup cancellation also reaches this cleanup. Sleep outside
            // that canceled task so drain cannot become a CPU-spinning loop.
            await Task.detached { try? await Task.sleep(for: .milliseconds(40)) }.value
        }
        if process.isRunning {
            // The helper owns a dedicated process group; a stuck descendant
            // cannot survive a forced application shutdown indefinitely.
            if getpgid(process.processIdentifier) == process.processIdentifier { kill(-process.processIdentifier, SIGKILL) }
            else { kill(process.processIdentifier, SIGKILL) }
            while process.isRunning { await Task.detached { try? await Task.sleep(for: .milliseconds(20)) }.value }
        }
        if child === process {
            output?.fileHandleForReading.readabilityHandler = nil
            try? output?.fileHandleForReading.close()
            try? control?.fileHandleForReading.close()
            child = nil; control = nil; output = nil; ready = false
        }
    }

    private func receiveReadiness(_ data: Data, process: Process) {
        guard child === process, readiness.count < 128 else { return }
        readiness.append(data.prefix(128 - readiness.count))
        ready = readiness == Data("SLATESYNC_MCP_READY\n".utf8)
        if ready { output?.fileHandleForReading.readabilityHandler = nil }
    }

    private func failure(_ code: String, _ message: String) -> SlateSyncError { .init(code: code, message: message) }
}

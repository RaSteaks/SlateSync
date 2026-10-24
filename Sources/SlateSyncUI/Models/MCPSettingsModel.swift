import Foundation
import Observation
import SlateSyncDomain

/// App-scoped ownership survives closing Settings and switching categories.
/// Preferences contain paths and consent only, never provider credentials.
@MainActor @Observable
public final class MCPSettingsModel {
    public var configuration: MCPLaunchConfiguration { didSet { persist() } }
    public private(set) var automaticallyStarts: Bool
    public private(set) var isRunning = false
    public private(set) var operation: OperationState = .idle
    public private(set) var clientOperation: OperationState = .idle
    public private(set) var isBusy = false
    public let socketPath: String
    private let service: any MCPServiceManaging
    private let preferences: UserDefaults
    private var task: Task<Void, Never>?
    private var monitor: Task<Void, Never>?
    private var activated = false
    private var acceptsOperations = true
    static let configurationKey = "mcp.launchConfiguration"
    static let automaticKey = "mcp.automaticallyStarts"

    public init(service: any MCPServiceManaging, preferences: UserDefaults = .standard, socketPath: String) {
        self.service = service
        self.preferences = preferences
        self.socketPath = socketPath
        configuration = preferences.data(forKey: Self.configurationKey)
            .flatMap { try? JSONDecoder().decode(MCPLaunchConfiguration.self, from: $0) } ?? .init()
        automaticallyStarts = preferences.bool(forKey: Self.automaticKey)
    }

    // Preparation discovers/builds the helper; file grants never gate startup.
    public var canStart: Bool { acceptsOperations && !isBusy && !isRunning }
    public var hasClientConfiguration: Bool { !configuration.executablePath.isEmpty }
    public var statusText: String {
        if case .running(let label) = operation { return label }
        if isRunning { return L10n.tr("运行中") }
        if case .failed(let error) = operation {
            return error.code == "MCP_EXITED" ? L10n.tr("已停止（异常退出）") : L10n.tr("启动失败")
        }
        return L10n.tr("已停止")
    }

    public var clientConfiguration: String {
        // JSONSerialization escapes quotes, backslashes and non-ASCII paths;
        // client reconnects cannot widen the broker's directory/model grants.
        let value = ["mcpServers": ["slatesync": ["command": configuration.executablePath, "args": ["--connect", socketPath]]]] as [String: Any]
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]),
              let text = String(data: data, encoding: .utf8) else { return "" }
        return text
    }

    public func activate() {
        guard !activated, acceptsOperations else { return }
        activated = true
        if automaticallyStarts { start() }
    }

    public func setAutomaticallyStarts(_ enabled: Bool) {
        guard acceptsOperations, task == nil else { return }
        automaticallyStarts = enabled
        preferences.set(enabled, forKey: Self.automaticKey)
        if enabled { start() } else { stop() }
    }

    public func start() {
        guard acceptsOperations, task == nil, !isRunning else { return }
        isBusy = true
        operation = .running(label: L10n.tr("正在检查 / 构建 MCP…"))
        task = Task { [weak self] in
            guard let self else { return }
            defer { task = nil; isBusy = false }
            guard acceptsOperations else { return }
            do {
                try await launchIfNeeded()
            } catch {
                reportLaunchFailure(error)
            }
        }
    }

    /// One click can prepare/start and then register the bridge. Client errors
    /// have separate feedback, so a failed registration never hides a live broker.
    public func install(client: MCPClient) {
        guard acceptsOperations, task == nil else { return }
        isBusy = true
        clientOperation = .running(label: L10n.tr("正在添加到 {0}…", [client.displayName]))
        task = Task { [weak self] in
            guard let self else { return }
            defer { task = nil; isBusy = false }
            guard acceptsOperations else { return }
            do {
                try await launchIfNeeded()
                try Task.checkCancellation()
                try await service.install(client: client, configuration: configuration)
                clientOperation = .succeeded(message: L10n.tr("已添加到 {0}。请在客户端重新连接 MCP 或开始新会话。", [client.displayName]))
            } catch {
                if !isRunning { reportLaunchFailure(error) }
                if error is CancellationError { clientOperation = .canceled; return }
                clientOperation = .failed(.init(code: (error as? SlateSyncError)?.code ?? "MCP_CLIENT_INSTALL",
                    message: (error as? SlateSyncError).map { L10n.message($0.message) }
                        ?? L10n.tr("添加客户端失败。请检查同名配置、客户端权限及 mcp-client.log 后重试。")))
            }
        }
    }

    private func launchIfNeeded() async throws {
        guard !isRunning else { return }
        operation = .running(label: L10n.tr("正在检查 / 构建 MCP…"))
        configuration = try await service.prepare(configuration: configuration)
        try Task.checkCancellation()
        operation = .running(label: L10n.tr("正在启动 MCP…"))
        try await service.start(configuration: configuration)
        isRunning = true
        operation = .succeeded(message: L10n.tr("MCP 已启动"))
        observeExit()
    }

    private func reportLaunchFailure(_ error: Error) {
        isRunning = false
        if error is CancellationError { operation = .canceled; return }
        operation = .failed(.init(code: (error as? SlateSyncError)?.code ?? "MCP_START_FAILED",
            message: (error as? SlateSyncError).map { L10n.message($0.message) }
                ?? L10n.tr("MCP 未能启动，请检查组件版本、目录权限及 mcp-service.log。")))
    }

    /// Stop a long first build without closing Settings. Keep admission closed
    /// until the task has reaped its child, then allow an ordinary retry.
    public func cancelPreparation() {
        guard isBusy, !isRunning else { return }
        task?.cancel()
    }

    public func stop() {
        guard acceptsOperations, task == nil else { return }
        isBusy = true
        monitor?.cancel(); monitor = nil
        operation = .running(label: L10n.tr("正在停止 MCP…"))
        task = Task { [weak self] in
            guard let self else { return }
            await service.stop()
            isRunning = false
            operation = .succeeded(message: L10n.tr("MCP 已停止"))
            task = nil
            isBusy = false
        }
    }

    public func drain() async {
        // Close admission before awaiting pending startup, then stop exactly
        // the app's helper. A canceled Quit leaves manual retry available.
        acceptsOperations = false
        monitor?.cancel(); monitor = nil
        // A first build may take minutes. Quit cancels preparation/registration
        // and drains its owned process before releasing the broker.
        task?.cancel()
        await task?.value
        // Startup may have installed a monitor while drain awaited it. Retire
        // that monitor too, and clear pending UI even if Quit is later vetoed.
        monitor?.cancel(); monitor = nil
        await service.stop()
        isRunning = false
        operation = .succeeded(message: L10n.tr("MCP 已停止"))
        clientOperation = .idle
        isBusy = false
        acceptsOperations = true
    }

    private func observeExit() {
        monitor?.cancel()
        monitor = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(500)) } catch { return }
                guard let self, !Task.isCancelled else { return }
                let running = await service.isRunning()
                guard !Task.isCancelled else { return }
                if !running {
                    // Reap before exposing Retry, and reject a late monitor
                    // response after an explicit Stop or application drain.
                    await service.stop()
                    guard !Task.isCancelled else { return }
                    isRunning = false
                    operation = .failed(.init(code: "MCP_EXITED", message: L10n.tr("MCP 服务意外退出，请检查日志后重新启动。")))
                    return
                }
            }
        }
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(configuration) { preferences.set(data, forKey: Self.configurationKey) }
    }
}

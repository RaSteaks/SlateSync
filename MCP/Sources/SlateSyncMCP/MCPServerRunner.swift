import Darwin
import Dispatch
import Foundation
import MCP
import SlateSyncMedia
import SlateSyncPersistence

public struct MCPServerOptions: Sendable {
    public var directories: [URL] = []
    public var settingsDirectory: URL?
    public var paddleResources: URL?
    public var allowsModelRequests = false
    public init(arguments: [String]) throws {
        var index = 0
        while index < arguments.count {
            let option = arguments[index]
            if option == "--allow-model-requests" { allowsModelRequests = true; index += 1; continue }
            guard ["--allow-directory", "--settings-directory", "--paddle-resources"].contains(option),
                  index + 1 < arguments.count, arguments[index + 1].hasPrefix("/") else {
                throw MCPError.invalidParams("Unknown option or missing absolute directory: \(option)")
            }
            let url = URL(fileURLWithPath: arguments[index + 1], isDirectory: true)
            switch option {
            case "--allow-directory": directories.append(url)
            case "--settings-directory": settingsDirectory = url
            default: paddleResources = url
            }
            index += 2
        }
    }
}

public enum MCPServerRunner {
    // Grants restrict file capabilities; they are no longer prerequisites for
    // initialization or tool discovery in either direct or managed mode.
    public static let help = """
    SlateSync local MCP server (stdio)
    Usage: slatesync-mcp [options]
      --allow-directory PATH       Grant file access; repeat for additional directories.
      --settings-directory PATH    Use a separate SlateSync settings/credential directory.
      --paddle-resources PATH      Trusted directory containing paddleocr_runner.py.
      --allow-model-requests       Allow page/OCR transmission and provider API charges.
      --managed-socket PATH       App-owned local broker; stdin EOF stops every session.
      --connect PATH              Bridge client stdio to the running app-owned broker.
      --help                      Show this help without starting a server.
      --version                   Show the integration version.
    Configure providers in SlateSync before enabling model requests.
    No directory grants are needed to start; without grants all file access is denied.
    The server never opens or changes the desktop project library.
    """

    public static func run(options: MCPServerOptions) async throws {
        let access = try MCPFileAccess(roots: options.directories)
        let locator: ApplicationSupportLocator
        if let root = options.settingsDirectory { locator = .init(root: root) }
        else { locator = try .init() }
        let runtime = SlateSyncRuntime(locator: locator)
        let service = MCPToolService(files: access, runtime: runtime, allowsModelRequests: options.allowsModelRequests,
            resources: options.paddleResources.map { .bundle($0) })
        let initialization = MCPInitializationGate()
        let server = Server(name: "slatesync", version: SlateSyncMCPVersion.current, title: "SlateSync",
            instructions: "Inspect slatesync_preview_merge before exporting. File access is limited to launch grants. Model requests may incur charges. Never pass API keys as tool arguments.",
            capabilities: .init(tools: .init(listChanged: false)))
        await server.withMethodHandler(ListTools.self) { params in
            try await initialization.requireReady()
            guard params.cursor == nil else { throw MCPError.invalidParams("This tool catalog has no additional pages.") }
            return .init(tools: MCPToolCatalog.tools)
        }
        await server.withMethodHandler(CallTool.self) { params in
            try await initialization.requireReady()
            return try await service.call(params) { event in
                guard let token = params._meta?.progressToken else { return }
                try? await server.notify(ProgressNotification.message(.init(progressToken: token,
                    progress: Double(event.percent ?? 0), total: 100, message: event.message)))
            }
        }
        // Responses and progress notifications share the same complete-frame
        // writer; serializing tool execution alone cannot protect SDK sends.
        let transport = await MCPSerialTransport(StdioTransport())
        // EOF and signals share the same drain: cancel tool work before closing
        // the protocol transport. Standard output contains MCP messages only.
        let signals = [SIGINT, SIGTERM].map { number -> any DispatchSourceSignal in
            Darwin.signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: .global())
            source.setEventHandler {
                Task { await service.close(); await server.stop() }
            }
            source.resume()
            return source
        }
        defer { signals.forEach { $0.cancel() } }
        do {
            try await server.start(transport: transport, initializeHook: { _, _ in await initialization.ready() })
            await server.waitUntilCompleted()
            await service.close()
            await server.stop()
        } catch { await service.close(); await server.stop(); throw error }
    }
}

/// SDK 0.11's strict pre-initialize check throws before its response-sending
/// task and leaves clients waiting. Enforce the same gate inside tool handlers
/// so the SDK serializes a proper JSON-RPC error instead of dropping it.
private actor MCPInitializationGate {
    private var initialized = false
    func ready() { initialized = true }
    func requireReady() throws {
        guard initialized else { throw MCPError.invalidRequest("Send initialize before using tools.") }
    }
}

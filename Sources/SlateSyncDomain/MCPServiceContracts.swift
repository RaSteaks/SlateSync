import Foundation

/// The optional helper stays outside the app's dependency graph. Only explicit
/// directory grants and model-request consent cross this process boundary.
public struct MCPLaunchConfiguration: Codable, Equatable, Sendable {
    public var executablePath: String
    public var directories: [String]
    public var allowsModelRequests: Bool
    /// Optional source override for relocated checkouts; old preferences decode without it.
    public var sourceDirectory: String?

    public init(executablePath: String = "", directories: [String] = [], allowsModelRequests: Bool = false, sourceDirectory: String? = nil) {
        self.executablePath = executablePath
        self.directories = directories
        self.allowsModelRequests = allowsModelRequests
        self.sourceDirectory = sourceDirectory
    }
}

public protocol MCPServiceManaging: Sendable {
    func prepare(configuration: MCPLaunchConfiguration) async throws -> MCPLaunchConfiguration
    func start(configuration: MCPLaunchConfiguration) async throws
    func stop() async
    func isRunning() async -> Bool
    func install(client: MCPClient, configuration: MCPLaunchConfiguration) async throws
}

/// Client-specific CLI arguments stay typed across the UI/workflow boundary.
public enum MCPClient: String, CaseIterable, Sendable {
    case codex, claudeCode
    public var displayName: String { self == .codex ? "Codex" : "Claude Code" }
}

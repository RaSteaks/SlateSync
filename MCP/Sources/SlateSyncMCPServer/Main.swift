import Darwin
import Foundation
import SlateSyncMCP

// The stdio entrypoint is deliberately independent of the SwiftUI app.
@main struct SlateSyncMCPMain {
    static func main() async {
        let arguments = Array(CommandLine.arguments.dropFirst())
        // The repository launcher prepends the trusted Paddle resource path.
        // Informational flags must still work through that wrapper.
        if arguments.contains("--help") { print(MCPServerRunner.help); return }
        if arguments.contains("--version") { print(SlateSyncMCPVersion.current); return }
        do {
            // The launcher can prepend Paddle flags. Remove only the managed
            // transport pair and keep the existing stdio options unchanged.
            if let index = arguments.firstIndex(where: { $0 == "--managed-socket" || $0 == "--connect" }) {
                guard index + 1 < arguments.count else { throw NSError(domain: "MCP", code: 1, userInfo: [NSLocalizedDescriptionKey: "Missing managed socket path."]) }
                var remaining = arguments
                remaining.removeSubrange(index...(index + 1))
                if arguments[index] == "--connect" { try MCPManagedConnection.connectStdio(path: arguments[index + 1]) }
                else { try MCPManagedConnection.serve(path: arguments[index + 1], arguments: remaining) }
            } else { try await MCPServerRunner.run(options: .init(arguments: arguments)) }
        }
        catch {
            // CLI failures belong on stderr; never corrupt the JSON-RPC stream.
            FileHandle.standardError.write(Data("SlateSync MCP: \(error.localizedDescription)\n".utf8))
            exit(1)
        }
    }
}

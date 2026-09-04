import Foundation

public struct ApplicationSupportLocator: Sendable {
    public static let productDirectoryName = "SlateSync"

    public let url: URL

    /// Explicit roots are the only construction path used by automated tests;
    /// production callers can use `root()` to preserve macOS Application
    /// Support semantics and the existing Electron directory name.
    public init(root: URL) {
        url = root.standardizedFileURL
    }

    public init(environment: [String: String] = ProcessInfo.processInfo.environment) throws {
        url = try Self.root(environment: environment)
    }

    /// Tests must opt into a temporary root; production deliberately reuses the
    /// Electron product-name directory so migration cannot fork user data.
    public static func root(environment: [String: String] = ProcessInfo.processInfo.environment) throws -> URL {
        if let testRoot = environment["SLATESYNC_TEST_ROOT"], !testRoot.isEmpty {
            return URL(fileURLWithPath: testRoot, isDirectory: true).standardizedFileURL
        }
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return base.appending(path: productDirectoryName, directoryHint: .isDirectory)
    }
}

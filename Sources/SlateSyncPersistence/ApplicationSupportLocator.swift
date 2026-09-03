import Foundation

public enum ApplicationSupportLocator {
    /// Tests must opt into a temporary root; production deliberately reuses the
    /// Electron product-name directory so migration cannot fork user data.
    public static func root(environment: [String: String] = ProcessInfo.processInfo.environment) throws -> URL {
        if let testRoot = environment["SLATESYNC_TEST_ROOT"], !testRoot.isEmpty {
            return URL(fileURLWithPath: testRoot, isDirectory: true)
        }
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return base.appending(path: "SlateSync", directoryHint: .isDirectory)
    }
}

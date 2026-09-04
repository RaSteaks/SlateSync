import Foundation
import SlateSyncDomain

/// Lazily opens the active Project Library selected by machine settings.
/// Lazy composition lets the synchronous SwiftUI `App` initializer retain an
/// actor-owned settings store without blocking or opening user data eagerly.
public actor ProjectLibraryStartupService: ProjectLibraryServing {
    private let machineSettings: MachineSettingsStore
    private let defaultLibraryParent: URL
    private let legacyDefaultRoots: [URL]
    private var library: ProjectLibraryStore?

    /// Production follows Electron's macOS paths: settings live in the
    /// product-specific directory while the default Library lives directly in
    /// Application Support. Test and degraded roots stay completely isolated.
    public init(
        locator: ApplicationSupportLocator,
        machineSettings: MachineSettingsStore,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        forceIsolatedRoot: Bool = false
    ) {
        let hasTestRoot = !(environment["SLATESYNC_TEST_ROOT"] ?? "").isEmpty
        let parent = (hasTestRoot || forceIsolatedRoot)
            ? locator.url
            : locator.url.deletingLastPathComponent()
        self.machineSettings = machineSettings
        defaultLibraryParent = parent.standardizedFileURL
        legacyDefaultRoots = [
            parent.appending(
                path: ProjectLibraryStore.legacyDefaultLibraryName,
                directoryHint: .isDirectory
            ),
            locator.url
                .appending(path: "Libraries", directoryHint: .isDirectory)
                .appending(
                    path: ProjectLibraryStore.legacyDefaultLibraryName,
                    directoryHint: .isDirectory
                ),
        ]
    }

    /// Explicit roots keep differential tests away from the operator's real
    /// Application Support and make every legacy migration candidate visible.
    public init(
        machineSettings: MachineSettingsStore,
        defaultLibraryParent: URL,
        legacyDefaultRoots: [URL]
    ) {
        self.machineSettings = machineSettings
        self.defaultLibraryParent = defaultLibraryParent.standardizedFileURL
        self.legacyDefaultRoots = legacyDefaultRoots.map(\.standardizedFileURL)
    }

    public func libraryInfo() async throws -> LibraryInfo {
        try await activeLibrary().libraryInfo()
    }

    public func listProjects() async throws -> [ProjectSummary] {
        try await activeLibrary().listProjects()
    }

    public func createProject(name: String, description: String) async throws -> ProjectData {
        try await activeLibrary().createProject(name: name, description: description)
    }

    /// Exposes the resolved location for composition tests and later workflow
    /// wiring without leaking the mutable Library actor itself.
    public func activeLibraryRoot() async throws -> URL {
        let opened = try await activeLibrary()
        return await opened.libraryRoot
    }

    private func activeLibrary() async throws -> ProjectLibraryStore {
        if let library { return library }

        var settings = try await machineSettings.load()
        let resolved = resolveLibraryRoot(configuredPath: settings.libraryPath)
        if !settings.libraryPath.isEmpty,
           URL(fileURLWithPath: settings.libraryPath, isDirectory: true).standardizedFileURL != resolved {
            // Only a known historical default is eligible to reach this path;
            // arbitrary portable Library selections are never renamed.
            settings.libraryPath = resolved.path
            _ = try await machineSettings.save(settings)
        }

        let opened = try ProjectLibraryStore(libraryRoot: resolved)
        library = opened
        return opened
    }

    private func resolveLibraryRoot(configuredPath: String) -> URL {
        if !configuredPath.isEmpty {
            let configured = URL(
                fileURLWithPath: configuredPath,
                isDirectory: true
            ).standardizedFileURL
            let isKnownDefault = legacyDefaultRoots.contains(configured)
            guard isKnownDefault else { return configured }
            return ProjectLibraryStore.resolveDefaultLibraryRoot(
                applicationSupportRoot: defaultLibraryParent,
                legacyRoots: [configured],
                preserveLegacyOnConflict: true
            )
        }
        return ProjectLibraryStore.resolveDefaultLibraryRoot(
            applicationSupportRoot: defaultLibraryParent,
            legacyRoots: legacyDefaultRoots
        )
    }
}

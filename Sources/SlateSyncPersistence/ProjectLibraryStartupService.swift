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
    private var runtime: ProjectRuntime?
    private var activation: ProjectLibraryActivationCoordinator?
    private var openingTask: Task<ProjectLibraryStore, any Error>?

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

    /// SM-08 workflow entry points remain on this lazy owner so the UI never
    /// opens a second Library database or constructs a project store directly.
    public func projectLibrary() async throws -> ProjectLibraryProjection {
        let store = try await activeLibrary()
        async let info = store.libraryInfo()
        async let projects = store.listProjects(includeArchived: true)
        let (library, allProjects) = try await (info, projects)
        return ProjectLibraryProjection(
            library: library,
            active: allProjects.filter { $0.archivedAt == nil },
            archived: allProjects.filter { $0.archivedAt != nil }
        )
    }

    public func project(id: String) async throws -> ProjectData {
        try await activeLibrary().getProject(id)
    }

    public func updateProject(
        id: String,
        name: String,
        description: String,
        settings: ProjectSettings
    ) async throws -> ProjectData {
        try await activeLibrary().updateProject(
            id,
            name: name,
            description: description,
            settings: settings
        )
    }

    public func archiveProject(id: String) async throws -> ProjectData {
        try await projectRuntime().closeProject(id)
        return try await activeLibrary().archiveProject(id)
    }

    public func restoreProject(id: String) async throws -> ProjectData {
        try await activeLibrary().restoreProject(id)
    }

    public func deleteProject(id: String) async throws {
        _ = try await projectRuntime().deleteProject(id)
    }

    public func importProject(from packageURL: URL) async throws -> ProjectData {
        let result = try await activeLibrary().importProject(from: packageURL)
        guard let project = result.project else {
            throw SlateSyncError(code: "PROJECT_IMPORT_CANCELED", message: "未导入项目")
        }
        return project
    }

    public func exportProject(id: String, to packageURL: URL) async throws -> ProjectExportResult {
        try await activeLibrary().exportProject(id, to: packageURL)
    }

    /// The caller's application-wide barrier has flushed every window before
    /// the existing SM-04 snapshot/export transaction starts.
    public func exportLibrary(to packageURL: URL) async throws -> LibraryExportResult {
        try await activeLibrary().exportLibrary(to: packageURL)
    }

    public func importLibrary(from packageURL: URL) async throws -> LibraryImportResult {
        let coordinator = try await activationCoordinator()
        return try await coordinator.importLibrary(at: packageURL)
    }

    public func relocateLibrary(to parentDirectory: URL) async throws -> LibraryLocationResult {
        let coordinator = try await activationCoordinator()
        return try await coordinator.relocateLibrary(to: parentDirectory)
    }

    public func renameLibrary(to name: String) async throws -> LibraryRenameResult {
        let coordinator = try await activationCoordinator()
        return try await coordinator.renameLibrary(to: name)
    }

    public func projectRuntime() async throws -> ProjectRuntime {
        if let runtime { return runtime }
        let library = try await activeLibrary()
        // Multiple native windows may join activeLibrary while startup is
        // suspended. Recheck before constructing the one lease owner.
        if let runtime { return runtime }
        let value = ProjectRuntime(library: library)
        runtime = value
        return value
    }

    /// Termination drains project leases before the Library connection. The
    /// method is idempotent through ProjectRuntime and ProjectLibraryStore.
    public func close() async throws {
        // Failed project closes retain their owners for retry. The Library
        // connection must remain available until those leases are released.
        try await runtime?.close()
        try await library?.close()
    }

    /// Exposes the resolved location for composition tests and later workflow
    /// wiring without leaking the mutable Library actor itself.
    public func activeLibraryRoot() async throws -> URL {
        let opened = try await activeLibrary()
        return await opened.libraryRoot
    }

    private func activeLibrary() async throws -> ProjectLibraryStore {
        if let library { return library }
        if let openingTask { return try await openingTask.value }

        let settingsStore = machineSettings
        let parent = defaultLibraryParent
        let legacyRoots = legacyDefaultRoots
        // libraryInfo and listProjects are intentionally requested in parallel
        // by SwiftUI. Publish the shared opener before awaiting settings so both
        // calls receive the same Library actor and bootstrap transaction.
        let task = Task<ProjectLibraryStore, any Error> {
            var settings = try await settingsStore.load()
            let resolved = Self.resolveLibraryRoot(
                configuredPath: settings.libraryPath,
                defaultLibraryParent: parent,
                legacyDefaultRoots: legacyRoots
            )
            if !settings.libraryPath.isEmpty,
               URL(fileURLWithPath: settings.libraryPath, isDirectory: true).standardizedFileURL != resolved {
                // Only a known historical default is eligible to reach this
                // path; arbitrary portable selections are never renamed.
                settings.libraryPath = resolved.path
                _ = try await settingsStore.save(settings)
            }
            return try ProjectLibraryStore(libraryRoot: resolved)
        }
        openingTask = task
        do {
            let opened = try await task.value
            library = opened
            openingTask = nil
            return opened
        } catch {
            openingTask = nil
            throw error
        }
    }

    private func activationCoordinator() async throws -> ProjectLibraryActivationCoordinator {
        if let activation { return activation }
        let value = ProjectLibraryActivationCoordinator(
            library: try await activeLibrary(),
            projectRuntime: try await projectRuntime(),
            machineSettings: machineSettings
        )
        activation = value
        return value
    }

    private static func resolveLibraryRoot(
        configuredPath: String,
        defaultLibraryParent: URL,
        legacyDefaultRoots: [URL]
    ) -> URL {
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

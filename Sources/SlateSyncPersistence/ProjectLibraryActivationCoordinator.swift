import Foundation
import SlateSyncDomain

/// Coordinates the durable part of an active-Library switch. Successful
/// results always require the app composition root to relaunch: the new path is
/// saved first, then every current project and Library connection is closed.
public actor ProjectLibraryActivationCoordinator {
    private let library: ProjectLibraryStore
    private let projectRuntime: ProjectRuntime
    private let machineSettings: MachineSettingsStore
    private var didActivate = false

    public init(
        library: ProjectLibraryStore,
        projectRuntime: ProjectRuntime,
        machineSettings: MachineSettingsStore
    ) {
        self.library = library
        self.projectRuntime = projectRuntime
        self.machineSettings = machineSettings
    }

    public func importLibrary(at selectedURL: URL) async throws -> LibraryImportResult {
        let info = try await ProjectLibraryTransfer.validateLibrary(at: selectedURL)
        try await activate(info)
        return .imported(info)
    }

    public func relocateLibrary(to parentDirectory: URL) async throws -> LibraryLocationResult {
        let source = await library.libraryRoot
        let baseName = source.lastPathComponent.hasSuffix(ProjectLibraryStore.libraryExtension)
            ? source.lastPathComponent
            : source.lastPathComponent + ProjectLibraryStore.libraryExtension
        let target = parentDirectory.standardizedFileURL.appending(
            path: baseName,
            directoryHint: .isDirectory
        )
        let info = try await ProjectLibraryTransfer.exportLibrary(from: source, to: target)
        try await activate(info)
        return .imported(info)
    }

    public func renameLibrary(to name: String) async throws -> LibraryRenameResult {
        let renamed = try await library.renameLibrary(name)
        // renameLibrary already committed and verified its own v1 manifest;
        // activating that exact result must not introduce a second fallible
        // external-package validation after the directory has moved.
        let info = ValidatedLibraryInfo(
            id: renamed.id,
            name: renamed.name,
            formatVersion: renamed.formatVersion,
            path: renamed.path,
            projectCount: 0
        )
        try await activate(info)
        return .renamed(renamed)
    }

    private func activate(_ info: ValidatedLibraryInfo) async throws {
        guard !didActivate else {
            throw SlateSyncError(code: "LIBRARY_RESTART_PENDING", message: "项目库已切换，正在等待应用重启")
        }
        var settings = try await machineSettings.load()
        settings.libraryPath = URL(fileURLWithPath: info.path).standardizedFileURL.path
        _ = try await machineSettings.save(settings)
        // Publish the terminal state before shutdown awaits; a concurrent UI
        // action must not begin a second switch or reopen the outgoing Library.
        didActivate = true
        do {
            try await projectRuntime.close()
            try await library.close()
        } catch {
            throw SlateSyncError(code: "LIBRARY_CLOSE", message: "项目库路径已保存，但旧连接关闭失败，请立即重启应用")
        }
    }
}

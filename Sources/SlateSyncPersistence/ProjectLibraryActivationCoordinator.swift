import Foundation
import SlateSyncDomain

/// Coordinates the durable part of an active-Library switch. Successful
/// results always require the app composition root to relaunch: the new path is
/// saved first, then every current project and Library connection is closed.
public actor ProjectLibraryActivationCoordinator {
    private enum State {
        case ready
        case switching
        case restartPending
    }

    private let library: ProjectLibraryStore
    private let projectRuntime: ProjectRuntime
    private let machineSettings: MachineSettingsStore
    private var state = State.ready

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
        try beginSwitch()
        do {
            let info = try await ProjectLibraryTransfer.validateLibrary(at: selectedURL)
            try await activate(info)
            return .imported(info)
        } catch {
            resetFailedPreparation()
            throw error
        }
    }

    public func relocateLibrary(to parentDirectory: URL) async throws -> LibraryLocationResult {
        try beginSwitch()
        do {
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
        } catch {
            resetFailedPreparation()
            throw error
        }
    }

    public func renameLibrary(to name: String) async throws -> LibraryRenameResult {
        try beginSwitch()
        var runtimeIsTerminal = false
        do {
            try await library.preflightLibraryRename(name)
            // A POSIX directory rename keeps SQLite file descriptors alive but
            // not the snapshot URLs retained by project stores. Drain and close
            // them before moving the Library so no late write recreates oldRoot.
            runtimeIsTerminal = true
            do {
                try await projectRuntime.close()
            } catch {
                throw SlateSyncError(
                    code: "LIBRARY_CLOSE",
                    message: "项目库改名前无法关闭旧连接，请立即重启应用"
                )
            }
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
            try await activate(info, runtimeAlreadyClosed: true)
            return .renamed(renamed)
        } catch {
            if runtimeIsTerminal { state = .restartPending }
            resetFailedPreparation()
            throw error
        }
    }

    private func activate(
        _ info: ValidatedLibraryInfo,
        runtimeAlreadyClosed: Bool = false
    ) async throws {
        guard state == .switching else {
            throw SlateSyncError(code: "LIBRARY_RESTART_PENDING", message: "项目库已切换，正在等待应用重启")
        }
        var settings = try await machineSettings.load()
        settings.libraryPath = URL(fileURLWithPath: info.path).standardizedFileURL.path
        _ = try await machineSettings.save(settings)
        // Publish the terminal state before shutdown awaits; a concurrent UI
        // action must not begin a second switch or reopen the outgoing Library.
        state = .restartPending
        // Attempt both owners even if the first close reports an error; restart
        // is already mandatory and no outgoing connection should be skipped.
        var closeFailed = false
        if !runtimeAlreadyClosed {
            do { try await projectRuntime.close() } catch { closeFailed = true }
        }
        do { try await library.close() } catch { closeFailed = true }
        if closeFailed {
            throw SlateSyncError(code: "LIBRARY_CLOSE", message: "项目库路径已保存，但旧连接关闭失败，请立即重启应用")
        }
    }

    private func beginSwitch() throws {
        guard state == .ready else {
            throw SlateSyncError(code: "LIBRARY_RESTART_PENDING", message: "项目库正在切换或等待应用重启")
        }
        // Publish before validation/export awaits so a second UI action cannot
        // create another portable copy or overwrite the selected startup path.
        state = .switching
    }

    private func resetFailedPreparation() {
        if state == .switching { state = .ready }
    }
}

import Foundation
import Observation
import SlateSyncDomain

/// Project Library projection and operation owner. Destructive actions are
/// single-flight and refresh from the service rather than predicting database
/// state in the view.
@MainActor @Observable
public final class ProjectLibraryModel {
    public private(set) var library: LibraryInfo?
    public private(set) var activeProjects: [ProjectSummary] = []
    public private(set) var archivedProjects: [ProjectSummary] = []
    public private(set) var operation: OperationState = .idle
    public private(set) var error: SlateSyncError?
    public private(set) var libraryRestartRequired = false
    public var selection: String?
    public var createName = ""
    public var createDescription = ""
    public var showsCreateSheet = false
    public var deletionConfirmation = ""
    public var projectPendingDeletion: ProjectSummary?
    public var libraryNameDraft = ""
    public var mutationCoordinator: (@MainActor (@escaping @MainActor () async throws -> Void) async throws -> Void)?
    public var didChangeLibrary: (@MainActor (Set<String>) async -> Void)?
    public var didRequireRestart: (@MainActor () -> Void)?

    private let service: any ProjectLibraryWorkflowServing
    private let workspaceBarrier: @MainActor @Sendable () async throws -> Void
    private var loadGeneration = 0

    public init(
        service: any ProjectLibraryWorkflowServing,
        workspaceBarrier: @escaping @MainActor @Sendable () async throws -> Void = {}
    ) {
        self.service = service
        self.workspaceBarrier = workspaceBarrier
    }

    public var projects: [ProjectSummary] { activeProjects }
    public var isLoading: Bool { operation.isRunning }
    public var selectedProject: ProjectSummary? {
        (activeProjects + archivedProjects).first { $0.id == selection }
    }

    public func load() async {
        loadGeneration += 1
        let generation = loadGeneration
        operation = .running(label: "正在读取项目库…")
        error = nil
        do {
            let snapshot = try await service.projectLibrary()
            guard generation == loadGeneration else { return }
            library = snapshot.library
            activeProjects = snapshot.active
            archivedProjects = snapshot.archived
            if let selection,
               !(activeProjects + archivedProjects).contains(where: { $0.id == selection }) {
                self.selection = nil
            }
            libraryNameDraft = snapshot.library.name
            operation = .idle
        } catch {
            guard generation == loadGeneration else { return }
            self.error = ProductPrivacy.error(error)
            operation = .failed(ProductPrivacy.error(error))
        }
    }

    public func createProject() async -> ProjectSummary? {
        let name = createName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            error = .init(code: "PROJECT_NAME_REQUIRED", message: "请输入项目名称")
            return nil
        }
        guard !operation.isRunning else { return nil }
        operation = .running(label: "正在创建项目…")
        error = nil
        do {
            try await workspaceBarrier()
            let created = CreationResult()
            let action: @MainActor @Sendable () async throws -> Void = {
                created.project = try await self.service.createProject(name: name, description: self.createDescription)
                try await self.refreshAfterMutation()
            }
            if let mutationCoordinator { try await mutationCoordinator(action) }
            else { try await action() }
            guard let project = created.project else { return nil }
            createName = ""
            createDescription = ""
            showsCreateSheet = false
            selection = project.id
            operation = .succeeded(message: "项目已创建")
            return project.summary
        } catch {
            self.error = ProductPrivacy.error(error)
            operation = .failed(ProductPrivacy.error(error))
            return nil
        }
    }

    public func archive(_ project: ProjectSummary) async {
        await perform(label: "正在归档…", success: "项目已归档") {
            _ = try await self.service.archiveProject(id: project.id)
        }
    }

    public func restore(_ project: ProjectSummary) async {
        await perform(label: "正在恢复…", success: "项目已恢复") {
            _ = try await self.service.restoreProject(id: project.id)
        }
    }

    public func requestDeletion(_ project: ProjectSummary) {
        deletionConfirmation = ""
        projectPendingDeletion = project
    }

    public func confirmDeletion() async {
        guard let project = projectPendingDeletion,
              deletionConfirmation == project.name else {
            error = .init(code: "PROJECT_DELETE_CONFIRMATION", message: "请逐字输入项目名称")
            return
        }
        await perform(label: "正在永久删除…", success: "项目已永久删除") {
            try await self.service.deleteProject(id: project.id)
        }
        if error == nil { projectPendingDeletion = nil }
    }

    public func importProject(from url: URL) async {
        await perform(label: "正在导入项目…", success: "项目已导入") {
            _ = try await self.service.importProject(from: url)
        }
    }

    public func export(_ project: ProjectSummary, to url: URL) async {
        await perform(label: "正在导出项目…", success: "项目已导出") {
            let result = try await self.service.exportProject(id: project.id, to: url)
            if result.canceled { throw CancellationError() }
        }
    }

    public func exportLibrary(to url: URL) async {
        await perform(label: "正在导出项目库…", success: "项目库已导出") {
            let result = try await self.service.exportLibrary(to: url)
            if result.canceled { throw CancellationError() }
        }
    }

    public func importLibrary(from url: URL) async {
        await performRestartRequired(label: "正在切换项目库…") {
            let result = try await self.service.importLibrary(from: url)
            if result.canceled { throw CancellationError() }
        }
    }

    public func relocateLibrary(to url: URL) async {
        await performRestartRequired(label: "正在移动项目库…") {
            let result = try await self.service.relocateLibrary(to: url)
            if result.canceled { throw CancellationError() }
        }
    }

    public func renameLibrary() async {
        let name = libraryNameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            error = .init(code: "LIBRARY_NAME_REQUIRED", message: "请输入项目库名称")
            return
        }
        await performRestartRequired(label: "正在重命名…") {
            let result = try await self.service.renameLibrary(to: name)
            if result.canceled { throw CancellationError() }
        }
    }

    public func clearError() { error = nil }

    private func perform(
        label: String,
        success: String,
        action: @escaping @MainActor () async throws -> Void
    ) async {
        guard !operation.isRunning else { return }
        operation = .running(label: label)
        error = nil
        do {
            // Every Library mutation shares the window's editor barrier. A
            // failed flush stops before Persistence observes the operation.
            try await workspaceBarrier()
            let mutation: @MainActor @Sendable () async throws -> Void = {
                try await action()
                try await self.refreshAfterMutation()
            }
            if let mutationCoordinator { try await mutationCoordinator(mutation) }
            else { try await mutation() }
            operation = .succeeded(message: success)
        } catch is CancellationError {
            operation = .canceled
        } catch {
            self.error = ProductPrivacy.error(error)
            operation = .failed(ProductPrivacy.error(error))
        }
    }

    private func performRestartRequired(
        label: String,
        action: @escaping @MainActor () async throws -> Void
    ) async {
        guard !operation.isRunning, !libraryRestartRequired else { return }
        operation = .running(label: label)
        error = nil
        do {
            // Library replacement invalidates every open runtime, so it must
            // never overtake a pending task or result-cell write.
            try await workspaceBarrier()
            let mutation: @MainActor @Sendable () async throws -> Void = {
                try await action()
                self.libraryRestartRequired = true
                self.didRequireRestart?()
            }
            if let mutationCoordinator { try await mutationCoordinator(mutation) }
            else { try await mutation() }
            operation = .succeeded(message: "项目库位置已保存，请重启 SlateSync")
        } catch is CancellationError {
            operation = .canceled
        } catch {
            self.error = ProductPrivacy.error(error)
            operation = .failed(ProductPrivacy.error(error))
        }
    }

    private func refreshAfterMutation() async throws {
        // Reconcile every open project while the shared mutation barrier is
        // still held; archived/deleted projects must never become editable.
        do {
            let snapshot = try await service.projectLibrary()
            library = snapshot.library
            activeProjects = snapshot.active
            archivedProjects = snapshot.archived
            await didChangeLibrary?(Set(snapshot.active.map(\.id)))
        } catch {
            // The mutation already succeeded. A stale cross-window snapshot
            // must remain frozen until restart can reopen the authoritative DB.
            libraryRestartRequired = true
            didRequireRestart?()
            throw error
        }
    }
}

/// Mutable result stays on MainActor while the global mutation task is joined.
@MainActor private final class CreationResult { var project: ProjectData? }

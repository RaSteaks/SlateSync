import Observation
import SlateSyncDomain

/// Window-scoped navigation owner. Route publication happens only after the
/// active editor barrier flushes, so commands cannot move a window away from
/// a recoverable draft failure.
@MainActor @Observable
public final class AppSessionModel {
    public private(set) var route: SidebarDestination = .projects
    // Identity is always the workspace's acquired context, including when a
    // pending open finishes after the user has navigated to Help or Logs.
    public var projectID: String? { workspace.projectID }
    public var taskID: String? { workspace.selectedTaskID }
    public private(set) var generation = 0
    public private(set) var navigationError: SlateSyncError?

    // Published before any suspension; each window owns its own pending open.
    public private(set) var openingProjectName: String?

    private let workspace: WorkspaceModel
    public var flushProjectSettings: (@MainActor () async throws -> Void)?

    public init(workspace: WorkspaceModel) {
        self.workspace = workspace
    }

    public func navigate(to destination: SidebarDestination) async {
        generation += 1
        let request = generation
        guard destination != route else { return }
        if [.workspace, .projectSettings].contains(destination), projectID == nil {
            navigationError = .init(code: "PROJECT_REQUIRED", message: "请先从项目库打开一个活跃项目")
            return
        }
        do {
            if route == .projectSettings { try await flushProjectSettings?() }
            if route == .workspace { try await workspace.flush() }
            guard generation == request else { return }
            route = destination
            navigationError = nil
        } catch {
            guard generation == request else { return }
            navigationError = ProductPrivacy.error(error)
        }
    }

    public func openProject(_ project: ProjectSummary) async {
        await open(project, destination: .workspace)
    }

    public func showProjectSettings(_ project: ProjectSummary) async {
        await open(project, destination: .projectSettings)
    }

    private func open(_ project: ProjectSummary, destination: SidebarDestination) async {
        // Repeated clicks must neither start another read nor invalidate the
        // generation of the opening request already crossing the save barrier.
        guard openingProjectName == nil else { return }
        openingProjectName = project.name
        navigationError = nil
        defer { openingProjectName = nil }
        generation += 1
        let request = generation
        do {
            if route == .projectSettings { try await flushProjectSettings?() }
            guard generation == request else { return }
            try await workspace.activate(projectID: project.id)
            // Keep the acquired workspace owner; newer navigation owns the route.
            guard generation == request else { return }
            route = destination
        } catch {
            guard generation == request else { return }
            navigationError = ProductPrivacy.error(error)
        }
    }

    public func selectTask(_ id: String) async {
        generation += 1
        let request = generation
        do {
            try await workspace.selectTask(id)
            guard generation == request else { return }
            navigationError = nil
        } catch {
            guard generation == request else { return }
            navigationError = ProductPrivacy.error(error)
        }
    }

    public func clearError() { navigationError = nil }

    public func reconcileClosedProject() {
        guard workspace.projectID == nil else { return }
        route = .projects
        generation += 1
    }
}

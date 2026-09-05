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
        generation += 1
        let request = generation
        do {
            if route == .projectSettings { try await flushProjectSettings?() }
            guard generation == request else { return }
            try await workspace.activate(projectID: project.id)
            // Keep the acquired workspace owner, but only the latest intent
            // may change the visible route after a suspended database read.
            guard generation == request else { return }
            route = .workspace
            navigationError = nil
        } catch {
            guard generation == request else { return }
            navigationError = ProductPrivacy.error(error)
        }
    }

    public func showProjectSettings(_ project: ProjectSummary) async {
        generation += 1
        let request = generation
        do {
            if route == .projectSettings { try await flushProjectSettings?() }
            guard generation == request else { return }
            // Settings and Workspace must name the same acquired project;
            // changing only the sidebar identity leaves commands on old data.
            try await workspace.activate(projectID: project.id)
            guard generation == request else { return }
            route = .projectSettings
            navigationError = nil
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

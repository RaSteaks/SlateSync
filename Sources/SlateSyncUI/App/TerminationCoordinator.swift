import Foundation
import Observation
import SlateSyncDomain

/// One ordered teardown pipeline owned by the coordinator. Window close, Quit
/// and library mutation execute the same registered session, so a writer added
/// to teardown joins the shared pipeline and cannot join only one path.
@MainActor
final class WindowSession {
    typealias Action = @MainActor () async throws -> Void
    private struct Step {
        let name: String
        let action: Action
    }

    private let drainSteps: [Step]
    private let closeSteps: [Step]

    /// Steps are listed in frozen execution order: selection stability →
    /// settings flush → CSV/recognition/metadata/media drain → workspace
    /// flush; a full window close continues with runtime close → logs stop.
    init(
        drainSteps: [(name: String, action: Action)],
        closeSteps: [(name: String, action: Action)]
    ) {
        self.drainSteps = drainSteps.map { Step(name: $0.name, action: $0.action) }
        self.closeSteps = closeSteps.map { Step(name: $0.name, action: $0.action) }
    }

    /// The shared prefix every termination path must reach a terminal state.
    func drain() async throws {
        for step in drainSteps { try await step.action() }
    }

    /// Window close continues the shared drain with runtime close and logs.
    func close() async throws {
        try await drain()
        for step in closeSteps { try await step.action() }
    }
}

private actor WindowSessionRegistry {
    private var sessions: [UUID: WindowSession] = [:]
    private var refreshes: [UUID: @MainActor @Sendable (Set<String>) async -> Void] = [:]

    func register(id: UUID, session: WindowSession, refresh: (@MainActor @Sendable (Set<String>) async -> Void)? = nil) {
        sessions[id] = session; refreshes[id] = refresh
    }
    func unregister(id: UUID) { sessions[id] = nil; refreshes[id] = nil }
    func session(for id: UUID) -> WindowSession? { sessions[id] }

    func refreshAll(activeIDs: Set<String>) async {
        for refresh in refreshes.values { await refresh(activeIDs) }
    }

    func drainAll() async throws {
        // Stable ordering makes failure injection and repeated termination
        // deterministic while every window still owns its own writer.
        for id in sessions.keys.sorted(by: { $0.uuidString < $1.uuidString }) {
            if let session = sessions[id] { try await session.drain() }
        }
    }
}

/// Awaitable application shutdown owner. Each WindowGroup instance registers
/// its independent editor/recognition drain, while the application-scoped
/// façade is closed only after all window work has reached a terminal state.
@MainActor @Observable
public final class TerminationCoordinator {
    public private(set) var error: SlateSyncError?
    public private(set) var isDraining = false
    public private(set) var isMutatingLibrary = false
    public private(set) var restartRequired = false
    private let lifecycle: any ProductLifecycleServing
    private let windows = WindowSessionRegistry()
    private var drainTask: Task<Bool, Never>?
    private var libraryMutationTask: Task<Void, Error>?
    public var applicationDrain: (@MainActor () async throws -> Void)?

    public init(lifecycle: any ProductLifecycleServing) { self.lifecycle = lifecycle }

    public func registerWindow(
        id: UUID,
        workspace: WorkspaceModel,
        recognition: RecognitionModel,
        csv: ResolveCSVModel,
        metadata: MetadataScanModel,
        media: MediaInputModel? = nil,
        settings: ProjectSettingsModel? = nil,
        logs: LogsModel? = nil,
        refresh: (@MainActor @Sendable (Set<String>) async -> Void)? = nil
    ) async {
        // The frozen teardown pipeline. Window close, Quit and library
        // mutation all execute THIS step list; a writer added to teardown
        // joins it here, never per path.
        await registerSession(
            id: id,
            session: WindowSession(
                drainSteps: [
                    (name: "selection-stability", action: { try workspace.requireStableSelection() }),
                    (name: "settings-flush", action: { try await settings?.flushIfNeeded() }),
                    (name: "csv-drain", action: { await csv.drain() }),
                    (name: "recognition-drain", action: { await recognition.drain() }),
                    (name: "metadata-drain", action: { await metadata.drain() }),
                    (name: "media-drain", action: { await media?.drain() }),
                    (name: "workspace-flush", action: { try await workspace.flush() }),
                ],
                closeSteps: [
                    (name: "runtime-close", action: { try await workspace.close() }),
                    (name: "logs-stop", action: { logs?.stopPolling() }),
                ]
            ),
            refresh: refresh
        )
    }

    /// Low-level registration for the shared pipeline; `registerWindow` builds
    /// the production session from the window's writers.
    func registerSession(
        id: UUID,
        session: WindowSession,
        refresh: (@MainActor @Sendable (Set<String>) async -> Void)? = nil
    ) async {
        await windows.register(id: id, session: session, refresh: refresh)
    }

    public func unregisterWindow(id: UUID) async { await windows.unregister(id: id) }

    /// The single window-close entrance: the registered session drains, then
    /// the window's runtime closes and its logs stop. A failure keeps the
    /// window registered so the close can be retried after the user resolves
    /// the reported error.
    public func closeWindow(id: UUID) async throws {
        guard !isDraining, !isMutatingLibrary else {
            throw SlateSyncError(code: "LIBRARY_BUSY", message: "项目库正在更新，请稍后关闭窗口", retryable: true)
        }
        guard let session = await windows.session(for: id) else { return }
        try await session.close()
        await windows.unregister(id: id)
    }

    public func reportCloseFailure(_ failure: Error) { error = ProductPrivacy.error(failure) }

    /// Window-close and termination failures are owned here rather than by
    /// navigation. Dismissing their banner must not mutate workspace state.
    public func clearError() { error = nil }

    public func requireRestart() { restartRequired = true }

    public func refreshProjects(activeIDs: Set<String>) async { await windows.refreshAll(activeIDs: activeIDs) }

    public func performLibraryMutation(_ action: @escaping @MainActor () async throws -> Void) async throws {
        guard !isMutatingLibrary, !isDraining, !restartRequired else {
            throw SlateSyncError(code: "LIBRARY_BUSY", message: "项目库正在更新或等待重启，请稍后重试", retryable: true)
        }
        // All windows freeze editing before the shared mutation starts. Each
        // writer and operation drains, including windows that are not focused.
        isMutatingLibrary = true
        let task = Task { @MainActor [windows] in
            try await windows.drainAll()
            try await action()
        }
        libraryMutationTask = task
        defer { isMutatingLibrary = false; libraryMutationTask = nil }
        try await task.value
    }

    public func requestTermination() async -> Bool {
        if let drainTask { return await drainTask.value }
        isDraining = true
        error = nil
        let mutation = libraryMutationTask
        let task = Task { @MainActor [windows, lifecycle] in
            do {
                // A relocation/import may already be suspended in I/O. Join
                // its exact task before closing the shared Library runtime.
                try await mutation?.value
                // Quit reuses the same window drain as closeWindow, then
                // drains the application and the shared runtime.
                try await windows.drainAll()
                try await self.applicationDrain?()
                do { try await lifecycle.drain() }
                catch {
                    // Persistence may be partially closed. Preserve the UI
                    // snapshot, freeze edits, and allow a subsequent Quit to
                    // retry resource release without advertising recovery.
                    self.restartRequired = true
                    throw error
                }
                return true
            } catch {
                self.error = ProductPrivacy.error(error)
                return false
            }
        }
        drainTask = task
        let result = await task.value
        drainTask = nil
        isDraining = false
        return result
    }
}

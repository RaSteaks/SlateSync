import Foundation
import Observation
import SlateSyncDomain

private actor WindowDrainRegistry {
    typealias Drain = @MainActor @Sendable () async throws -> Void
    private var drains: [UUID: Drain] = [:]
    private var refreshes: [UUID: @MainActor @Sendable (Set<String>) async -> Void] = [:]

    func register(id: UUID, drain: @escaping Drain, refresh: (@MainActor @Sendable (Set<String>) async -> Void)? = nil) {
        drains[id] = drain; refreshes[id] = refresh
    }
    func unregister(id: UUID) { drains[id] = nil; refreshes[id] = nil }

    func refreshAll(activeIDs: Set<String>) async {
        for refresh in refreshes.values { await refresh(activeIDs) }
    }

    func drainAll() async throws {
        // Stable ordering makes failure injection and repeated termination
        // deterministic while every window still owns its own writer.
        for id in drains.keys.sorted(by: { $0.uuidString < $1.uuidString }) {
            if let drain = drains[id] { try await drain() }
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
    private let windows = WindowDrainRegistry()
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
        refresh: (@MainActor @Sendable (Set<String>) async -> Void)? = nil
    ) async {
        await windows.register(id: id, drain: {
            // An already-started selection operation owns its stores until it
            // finishes. A failed barrier keeps the application open for retry.
            try workspace.requireStableSelection()
            try await settings?.flushIfNeeded()
            await csv.drain()
            await recognition.drain()
            await metadata.drain()
            await media?.drain()
            try await workspace.flush()
        }, refresh: refresh)
    }

    public func unregisterWindow(id: UUID) async { await windows.unregister(id: id) }

    public func reportCloseFailure(_ failure: Error) { error = ProductPrivacy.error(failure) }

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

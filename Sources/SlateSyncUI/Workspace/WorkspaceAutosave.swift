import Foundation
import SlateSyncDomain

/// The only task autosave writer. View changes replace the pending immutable
/// snapshot, while this actor serializes persistence and keeps the failed
/// snapshot available for retry. Project/task switches call flush explicitly.
public actor WorkspaceAutosave {
    public typealias Writer = @Sendable (_ projectID: String, _ taskID: String?, _ snapshot: TaskData) async throws -> String

    private struct Pending: Sendable {
        let revision: Int
        let projectID: String
        let taskID: String?
        let snapshot: TaskData
    }

    private let delay: Duration
    private let writer: Writer
    private var revision = 0
    private var pending: Pending?
    private var timer: Task<Void, Never>?
    private var worker: Task<Void, Never>?
    private var lastError: SlateSyncError?
    private var closed = false
    public struct State: Sendable {
        public let revision: Int
        public let error: SlateSyncError?
        public let pending: Bool
    }
    public nonisolated let states: AsyncStream<State>
    private let stateContinuation: AsyncStream<State>.Continuation

    public init(delay: Duration = .milliseconds(500), writer: @escaping Writer) {
        self.delay = delay
        self.writer = writer
        (states, stateContinuation) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(1))
    }

    public func schedule(projectID: String, taskID: String?, snapshot: TaskData, delay override: Duration? = nil) {
        guard !closed else { return }
        revision += 1
        pending = Pending(revision: revision, projectID: projectID, taskID: taskID, snapshot: snapshot)
        lastError = nil
        timer?.cancel()
        let requestedRevision = revision
        // General edits and result cells use the same revision sequence;
        // only their debounce duration differs. A second delayed enqueue
        // could otherwise publish an older full snapshot after a newer edit.
        let delay = override ?? self.delay
        timer = Task { [delay] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            self.startWorker(ifCurrent: requestedRevision)
        }
        publishState()
    }

    public func flush() async throws {
        timer?.cancel()
        timer = nil
        startWorker(ifCurrent: nil)
        if let worker { await worker.value }
        if let lastError { throw lastError }
    }

    public func retry() async throws {
        lastError = nil
        try await flush()
    }

    public func reset() async {
        timer?.cancel()
        timer = nil
        if let worker { await worker.value }
        pending = nil
        lastError = nil
        revision += 1
        publishState()
    }

    public func close() async throws {
        try await flush()
        closed = true
        stateContinuation.finish()
    }

    public func error() -> SlateSyncError? { lastError }
    public func hasPendingChanges() -> Bool { pending != nil || worker != nil }

    private func startWorker(ifCurrent expectedRevision: Int?) {
        guard worker == nil else { return }
        if let expectedRevision, pending?.revision != expectedRevision { return }
        guard pending != nil else { return }
        worker = Task { await self.performWrites() }
    }

    private func performWrites() async {
        defer { worker = nil; publishState() }
        while let value = pending {
            pending = nil
            do {
                _ = try await writer(value.projectID, value.taskID, value.snapshot)
                lastError = nil
            } catch {
                // Re-publish the failed snapshot only if a newer edit did not
                // arrive while the writer was suspended.
                if pending == nil { pending = value }
                lastError = ProductPrivacy.error(error)
                return
            }
        }
    }

    private func publishState() {
        // Automatic debounce failures must reach the window immediately,
        // without waiting for another edit or explicit navigation flush.
        stateContinuation.yield(.init(revision: revision, error: lastError, pending: pending != nil || worker != nil))
    }
}

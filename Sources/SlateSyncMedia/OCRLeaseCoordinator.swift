import Foundation
import SlateSyncDomain

/// Actor-owned FIFO admission for the single-flight OCR engines. Queue changes
/// are driven by continuations, cancellation edges and deadline tasks; no
/// caller wakes periodically to compete for the active lease.
actor OCRLeaseCoordinator {
    struct Snapshot: Sendable { let active: Int; let pending: Int }

    private struct ActiveLease: Sendable {
        let id: UUID
        let operation: MediaOperation
    }
    private struct Waiter {
        let id: UUID
        let generation: Int
        let operation: MediaOperation
        let deadline: OCRDeadline
        let clock: any OCRClock
        let continuation: CheckedContinuation<UUID, Error>
        var cancellationToken: UUID?
        var deadlineTask: Task<Void, Never>?
    }

    private var active: ActiveLease?
    private var waiters: [Waiter] = []
    private var drainWaiters: [CheckedContinuation<Void, Never>] = []
    private var generation = 0
    private var closing = false
    private var permanentlyClosed = false

    func snapshot() -> Snapshot { .init(active: active == nil ? 0 : 1, pending: waiters.count) }

    func acquire(operation: MediaOperation, deadline: OCRDeadline, clock: any OCRClock) async throws -> UUID {
        let id = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                do {
                    try validate(operation: operation, deadline: deadline, clock: clock, expectedGeneration: generation)
                    if active == nil, waiters.isEmpty {
                        active = .init(id: id, operation: operation)
                        continuation.resume(returning: id)
                        return
                    }
                    let capturedGeneration = generation
                    waiters.append(.init(
                        id: id,
                        generation: capturedGeneration,
                        operation: operation,
                        deadline: deadline,
                        clock: clock,
                        continuation: continuation,
                        cancellationToken: nil,
                        deadlineTask: nil
                    ))
                    let cancellationToken = operation.addCancellationHandler { [weak self] in
                        Task { await self?.cancelWaiter(id: id) }
                    }
                    if let index = waiters.firstIndex(where: { $0.id == id }) {
                        waiters[index].cancellationToken = cancellationToken
                        scheduleDeadline(for: id)
                    } else if let cancellationToken {
                        operation.removeCancellationHandler(cancellationToken)
                    }
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        } onCancel: {
            // MediaOperation is the shared cancellation latch for Task and
            // explicit caller cancellation, so both paths remove this waiter.
            operation.cancel()
        }
    }

    func release(_ id: UUID) {
        guard active?.id == id else { return }
        active = nil
        promoteNext()
        if active == nil { resumeDrainWaiters() }
    }

    /// Starts a close generation without waiting for active engine work. The
    /// owner can first close its process/bridge to unblock that work, then call
    /// finishClose() to await the matching lease release.
    func beginClose(permanent: Bool) {
        if permanent { permanentlyClosed = true }
        guard !closing else { active?.operation.cancel(); return }
        closing = true
        generation += 1
        active?.operation.cancel()
        failAllWaiters(with: MediaFailure.closed)
        if active == nil { resumeDrainWaiters() }
    }

    func finishClose() async {
        if active != nil {
            await withCheckedContinuation { drainWaiters.append($0) }
        }
        if !permanentlyClosed { closing = false }
    }

    private func validate(
        operation: MediaOperation,
        deadline: OCRDeadline,
        clock: any OCRClock,
        expectedGeneration: Int
    ) throws {
        try deadline.check(clock: clock, operation: operation)
        guard !closing, !permanentlyClosed, generation == expectedGeneration else {
            throw MediaFailure.closed
        }
    }

    private func scheduleDeadline(for id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        let deadline = waiters[index].deadline
        let clock = waiters[index].clock
        let remaining = max(1, Int(ceil(deadline.end - clock.nowMilliseconds())))
        waiters[index].deadlineTask = Task { [weak self] in
            do { try await clock.sleep(milliseconds: remaining) }
            catch { return }
            await self?.expireWaiter(id: id)
        }
    }

    private func expireWaiter(id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        let waiter = waiters[index]
        guard waiter.clock.nowMilliseconds() >= waiter.deadline.end else {
            scheduleDeadline(for: id)
            return
        }
        finishWaiter(at: index, result: .failure(MediaFailure.timeout))
    }

    private func cancelWaiter(id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        finishWaiter(at: index, result: .failure(MediaFailure.canceled))
    }

    private func promoteNext() {
        while active == nil, !waiters.isEmpty {
            let waiter = waiters.removeFirst()
            cleanup(waiter)
            do {
                try validate(
                    operation: waiter.operation,
                    deadline: waiter.deadline,
                    clock: waiter.clock,
                    expectedGeneration: waiter.generation
                )
                active = .init(id: waiter.id, operation: waiter.operation)
                waiter.continuation.resume(returning: waiter.id)
            } catch {
                waiter.continuation.resume(throwing: error)
            }
        }
    }

    private func finishWaiter(at index: Int, result: Result<UUID, Error>) {
        let waiter = waiters.remove(at: index)
        cleanup(waiter)
        waiter.continuation.resume(with: result)
    }

    private func failAllWaiters(with error: any Error) {
        let queued = waiters
        waiters.removeAll(keepingCapacity: false)
        for waiter in queued {
            cleanup(waiter)
            waiter.continuation.resume(throwing: error)
        }
    }

    private func cleanup(_ waiter: Waiter) {
        waiter.deadlineTask?.cancel()
        if let token = waiter.cancellationToken {
            waiter.operation.removeCancellationHandler(token)
        }
    }

    private func resumeDrainWaiters() {
        let continuations = drainWaiters
        drainWaiters.removeAll(keepingCapacity: false)
        for continuation in continuations { continuation.resume() }
    }
}

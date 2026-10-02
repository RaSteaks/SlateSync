import Foundation
import SlateSyncDomain

/// Owns lazy construction, reset, and admission for the recognition runtime.
/// Configuration mutations keep admission suspended through their final write,
/// not merely until the previous coordinator finishes closing.
actor RecognitionRuntimeLifecycle {
    private var current: RecognitionCoordinator?
    private var building: Task<RecognitionCoordinator, Error>?
    private var resetting: Task<Void, Never>?
    private var generation = 0
    private var suspended = false

    func coordinator(make: @escaping @Sendable () async throws -> RecognitionCoordinator) async throws
        -> RecognitionCoordinator
    {
        guard !suspended, resetting == nil else {
            throw SlateSyncError(code: "RECOGNITION_RECONFIGURING", message: "识别配置正在更新，请稍后重试", retryable: true)
        }
        if let current { return current }
        let captured = generation
        let task: Task<RecognitionCoordinator, Error>
        if let building {
            task = building
        } else {
            task = Task { try await make() }
            building = task
        }
        do {
            let value = try await task.value
            guard captured == generation, !suspended else { throw CancellationError() }
            current = value
            building = nil
            return value
        } catch {
            if captured == generation { building = nil }
            throw error
        }
    }

    func cancel(projectID: String) async {
        let current = current
        let building = building
        if let current { await current.cancel(projectID: projectID) }
        if let building, let value = try? await building.value { await value.cancel(projectID: projectID) }
    }

    func suspend() async {
        suspended = true
        await reset()
    }
    func resume() { suspended = false }

    func reset() async {
        if let resetting {
            await resetting.value
            return
        }
        generation += 1
        let current = current
        let building = building
        self.current = nil
        self.building = nil
        let task = Task {
            if let current { await current.close() }
            if let building, let value = try? await building.value { await value.close() }
        }
        resetting = task
        await task.value
        resetting = nil
    }
}

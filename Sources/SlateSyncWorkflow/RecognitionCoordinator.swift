import Foundation
import SlateSyncDomain

public actor RecognitionCoordinator: RecognitionServing {
    private var continuations: [String: AsyncStream<RecognitionProgress>.Continuation] = [:]
    private var operations: [String: Task<Void, Never>] = [:]

    public init() {}

    public func progress(for projectID: String) -> AsyncStream<RecognitionProgress> {
        AsyncStream { continuation in
            continuations[projectID] = continuation
            continuation.onTermination = { @Sendable [weak self] _ in
                Task { await self?.removeContinuation(projectID: projectID) }
            }
        }
    }

    public func cancel(projectID: String) {
        operations.removeValue(forKey: projectID)?.cancel()
        continuations[projectID]?.yield(
            .init(phase: "canceled", completed: 0, total: 0, message: "识别已停止")
        )
    }

    /// Registering work centrally prevents one project from gaining competing
    /// cancellation owners as UI routes are recreated.
    public func register(projectID: String, operation: Task<Void, Never>) throws {
        guard operations[projectID] == nil else {
            throw SlateSyncError(code: "RECOGNITION_BUSY", message: "当前项目正在识别", retryable: true)
        }
        operations[projectID] = operation
    }

    public func publish(projectID: String, progress: RecognitionProgress) {
        continuations[projectID]?.yield(progress)
    }

    public func finish(projectID: String) {
        operations.removeValue(forKey: projectID)
        continuations[projectID]?.finish()
        continuations.removeValue(forKey: projectID)
    }

    private func removeContinuation(projectID: String) {
        continuations.removeValue(forKey: projectID)
    }
}

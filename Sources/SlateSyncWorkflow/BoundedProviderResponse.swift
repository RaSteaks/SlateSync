import Foundation
import SlateSyncDomain
import Synchronization

/// A per-request delegate enforces the receive budget before appending bytes.
/// Completion remains owned by URLSession's terminal callback, so cancellation
/// and transport close also join delegate cleanup rather than just signaling it.
final class BoundedProviderResponse: Sendable {
    private struct State {
        var body = Data()
        var response: URLResponse?
        var task: URLSessionDataTask?
        var continuation: CheckedContinuation<(Data, URLResponse), Error>?
        var failure: (any Error)?
        var canceled = false
    }
    private let state = Mutex(State())
    private let maximumBytes: Int

    init(maximumBytes: Int) { self.maximumBytes = maximumBytes }

    func receive(_ request: URLRequest, session: URLSession, registry: ProviderResponseRegistry) async throws -> (
        Data, URLResponse
    ) {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let task = session.dataTask(with: request)
                registry.register(self, for: task.taskIdentifier)
                let start = state.withLock { value in
                    guard !value.canceled else { return false }
                    value.task = task
                    value.continuation = continuation
                    return true
                }
                if start {
                    task.resume()
                } else {
                    registry.remove(task.taskIdentifier)
                    task.cancel()
                    continuation.resume(throwing: CancellationError())
                }
            }
        } onCancel: {
            let task = self.state.withLock { value in
                value.canceled = true
                return value.task
            }
            task?.cancel()
        }
    }

    func urlSession(
        _ session: URLSession, dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void
    ) {
        let allowed = state.withLock { value in
            value.response = response
            if response.expectedContentLength > Int64(maximumBytes) { value.failure = Self.sizeError }
            return value.failure == nil && !value.canceled
        }
        // Explicit task cancellation also produces a terminal callback for
        // custom URLProtocol transports that stall after delivering headers.
        completionHandler(.allow)
        if !allowed { dataTask.cancel() }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        let cancel = state.withLock { value in
            guard value.failure == nil, !value.canceled else { return true }
            // Subtraction avoids overflow and bounds retained data even when
            // a server omits Content-Length or sends more than it declared.
            guard data.count <= maximumBytes - value.body.count else {
                value.failure = Self.sizeError
                return true
            }
            value.body.append(data)
            return false
        }
        if cancel { dataTask.cancel() }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        let completion = state.withLock {
            value -> (CheckedContinuation<(Data, URLResponse), Error>?, Result<(Data, URLResponse), Error>) in
            let continuation = value.continuation
            value.continuation = nil
            value.task = nil
            let result: Result<(Data, URLResponse), Error>
            if let failure = value.failure {
                result = .failure(failure)
            } else if value.canceled {
                result = .failure(CancellationError())
            } else if let error {
                result = .failure(error)
            } else if let response = value.response {
                result = .success((value.body, response))
            } else {
                result = .failure(RecognitionFailure.invalidResponse)
            }
            value.body = Data()
            return (continuation, result)
        }
        completion.0?.resume(with: completion.1)
    }

    private static var sizeError: SlateSyncError {
        .init(code: "MODEL_RESPONSE_SIZE", message: "模型服务响应超过大小限制", status: 502, providerError: true)
    }
}

/// One session delegate routes callbacks to strongly retained request owners.
/// Owners are removed only by the matching terminal callback or canceled admission.
final class ProviderResponseRegistry: NSObject, URLSessionDataDelegate, Sendable {
    private let receivers = Mutex<[Int: BoundedProviderResponse]>([:])
    func register(_ receiver: BoundedProviderResponse, for id: Int) { receivers.withLock { $0[id] = receiver } }
    @discardableResult func remove(_ id: Int) -> BoundedProviderResponse? {
        receivers.withLock { $0.removeValue(forKey: id) }
    }
    func urlSession(
        _ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
        completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void
    ) {
        guard let receiver = receivers.withLock({ $0[dataTask.taskIdentifier] }) else {
            completionHandler(.cancel)
            return
        }
        receiver.urlSession(session, dataTask: dataTask, didReceive: response, completionHandler: completionHandler)
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        receivers.withLock { $0[dataTask.taskIdentifier] }?.urlSession(session, dataTask: dataTask, didReceive: data)
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        remove(task.taskIdentifier)?.urlSession(session, task: task, didCompleteWithError: error)
    }
}

final class ProviderResponseSession: Sendable {
    private let registry: ProviderResponseRegistry
    private let session: URLSession
    init(configuration: URLSessionConfiguration) {
        let registry = ProviderResponseRegistry()
        self.registry = registry
        session = URLSession(configuration: configuration, delegate: registry, delegateQueue: nil)
    }
    func receive(_ request: URLRequest, maximumBytes: Int) async throws -> (Data, URLResponse) {
        try await BoundedProviderResponse(maximumBytes: maximumBytes).receive(
            request, session: session, registry: registry)
    }
    func invalidateAndCancel() { session.invalidateAndCancel() }
}

import Foundation
import SlateSyncDomain

/// URLSession is the only production provider network path. Each public send
/// owns one Task that is registered until all URLSession callbacks drain, so
/// cancellation and close never leave an unobserved request running.
public actor URLSessionProviderTransport: ProviderHTTPTransporting {
    public static let maximumResponseBytes = 16 * 1024 * 1024

    private let session: URLSession
    private let credentials: any ProviderCredentialReading
    private let clock: any ProviderClock
    private var active: [UUID: Task<ProviderTransportResponse, Error>] = [:]
    private var closed = false
    private var closeTask: Task<Void, Never>?

    public init(
        credentials: any ProviderCredentialReading,
        configuration: URLSessionConfiguration = .ephemeral,
        clock: any ProviderClock = SystemProviderClock()
    ) {
        let safeConfiguration = configuration.copy() as? URLSessionConfiguration ?? .ephemeral
        safeConfiguration.urlCache = nil
        safeConfiguration.requestCachePolicy = .reloadIgnoringLocalCacheData
        safeConfiguration.httpCookieStorage = nil
        safeConfiguration.httpShouldSetCookies = false
        safeConfiguration.waitsForConnectivity = false
        self.session = URLSession(configuration: safeConfiguration)
        self.credentials = credentials
        self.clock = clock
    }

    public func send(_ request: ProviderTransportRequest) async throws -> ProviderTransportResponse {
        guard !closed else { throw RecognitionFailure.closed }
        let id = UUID()
        let session = session
        let credentials = credentials
        let clock = clock
        let task = Task {
            try await Self.perform(request, session: session, credentials: credentials, clock: clock)
        }
        active[id] = task
        defer { active.removeValue(forKey: id) }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    public func close() async {
        if let closeTask { await closeTask.value; return }
        closed = true
        let tasks = Array(active.values)
        let session = session
        let drain = Task {
            tasks.forEach { $0.cancel() }
            for task in tasks { _ = try? await task.value }
            session.invalidateAndCancel()
        }
        closeTask = drain
        await drain.value
        active.removeAll()
    }

    public func activeRequestCount() -> Int { active.count }

    private nonisolated static func perform(
        _ input: ProviderTransportRequest,
        session: URLSession,
        credentials: any ProviderCredentialReading,
        clock: any ProviderClock
    ) async throws -> ProviderTransportResponse {
        let retryCount = min(3, max(0, input.maximumTimeoutRetries))
        var lastError: SlateSyncError = RecognitionFailure.timeout
        for attemptIndex in 0...retryCount {
            try Task.checkCancellation()
            do {
                let response = try await attempt(input, session: session, credentials: credentials, clock: clock)
                return ProviderTransportResponse(status: response.status, headers: response.headers, body: response.body, attemptCount: attemptIndex + 1)
            } catch is CancellationError {
                throw RecognitionFailure.canceled
            } catch let error as SlateSyncError {
                lastError = error
                if error.code != RecognitionFailure.timeout.code || attemptIndex == retryCount { throw error }
            } catch {
                throw mapped(error)
            }
        }
        throw lastError
    }

    private nonisolated static func attempt(
        _ input: ProviderTransportRequest,
        session: URLSession,
        credentials: any ProviderCredentialReading,
        clock: any ProviderClock
    ) async throws -> ProviderTransportResponse {
        let url = try input.provider.endpoint(for: input.purpose)
        var request = URLRequest(url: url)
        request.httpMethod = input.method.rawValue
        request.httpBody = input.body
        request.timeoutInterval = TimeInterval(input.timeoutMilliseconds) / 1_000
        if input.method == .get {
            request.setValue("application/json", forHTTPHeaderField: "Accept")
        } else {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }

        let credential = try await credentials.credential(for: input.provider.id)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if input.provider.credentialRequired, credential?.isEmpty != false {
            throw RecognitionFailure.providerNotConfigured
        }
        if let credential, !credential.isEmpty {
            request.setValue("Bearer \(credential)", forHTTPHeaderField: "Authorization")
        }
        if input.provider.id == "openrouter" {
            request.setValue("SlateSync", forHTTPHeaderField: "X-Title")
            if let site = input.provider.openRouterSiteURL?.trimmingCharacters(in: .whitespacesAndNewlines), !site.isEmpty {
                request.setValue(site, forHTTPHeaderField: "HTTP-Referer")
            }
        }
        // Freeze the fully constructed value before it is sent into the
        // deadline race; no mutable URLRequest storage is shared by children.
        let finalRequest = request

        do {
            return try await withThrowingTaskGroup(of: ProviderTransportResponse.self) { group in
                group.addTask {
                    let (body, response) = try await session.data(for: finalRequest)
                    guard let http = response as? HTTPURLResponse else { throw RecognitionFailure.invalidResponse }
                    guard !body.isEmpty, body.count <= maximumResponseBytes else {
                        throw SlateSyncError(code: "MODEL_RESPONSE_SIZE", message: body.isEmpty ? "模型服务返回空响应" : "模型服务响应超过大小限制", status: 502, providerError: true)
                    }
                    let headers: [String: String] = Dictionary(uniqueKeysWithValues: http.allHeaderFields.compactMap { key, value -> (String, String)? in
                        guard let key = key as? String else { return nil }
                        return (key, String(describing: value))
                    })
                    try validateProviderResponse(status: http.statusCode, body: body, secret: credential)
                    return ProviderTransportResponse(status: http.statusCode, headers: headers, body: body)
                }
                group.addTask {
                    try await clock.sleep(milliseconds: max(1, input.timeoutMilliseconds))
                    throw RecognitionFailure.timeout
                }
                defer { group.cancelAll() }
                guard let first = try await group.next() else { throw RecognitionFailure.invalidResponse }
                return first
            }
        } catch is CancellationError {
            throw RecognitionFailure.canceled
        } catch let error as SlateSyncError {
            throw error
        } catch {
            throw mapped(error)
        }
    }

    private nonisolated static func validateProviderResponse(status: Int, body: Data, secret: String?) throws {
        let value = try? JSONDecoder().decode(JSONValue.self, from: body)
        var message: String?
        if case .object(let root) = value {
            if let error = root["error"] { message = errorMessage(error) }
            if message == nil, case .array(let choices)? = root["choices"] {
                for choice in choices {
                    if case .object(let fields) = choice, let error = fields["error"] {
                        message = errorMessage(error)
                        break
                    }
                }
            }
        }
        guard (200..<300).contains(status), message == nil else {
            let fallback = "模型服务返回 HTTP \(status)"
            throw RecognitionFailure.provider(message: redact(message ?? fallback, secret: secret), status: status)
        }
    }

    private nonisolated static func errorMessage(_ value: JSONValue) -> String? {
        switch value {
        case .string(let text): return text
        case .object(let object):
            if case .string(let text)? = object["message"] { return text }
            if case .string(let text)? = object["detail"] { return text }
            return nil
        default: return nil
        }
    }

    private nonisolated static func redact(_ value: String, secret: String?) -> String {
        var output = StructuredLogRedactor.redactText(value)
        if let secret, !secret.isEmpty { output = output.replacingOccurrences(of: secret, with: "[REDACTED]") }
        return String(output.prefix(1_000))
    }

    private nonisolated static func mapped(_ error: any Error) -> SlateSyncError {
        if let known = error as? SlateSyncError { return known }
        if let url = error as? URLError {
            if url.code == .cancelled { return Task.isCancelled ? RecognitionFailure.canceled : RecognitionFailure.connection }
            if url.code == .timedOut { return RecognitionFailure.timeout }
        }
        return RecognitionFailure.connection
    }
}

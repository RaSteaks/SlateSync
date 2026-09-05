import Foundation
import SlateSyncDomain
@testable import SlateSyncWorkflow
import Synchronization
import XCTest

private final class SM07URLProtocol: URLProtocol {
    enum Action: Sendable { case response(Int, Data), stall, redirect(String) }
    struct Capture: Sendable { let url: String; let method: String; let headers: [String: String]; let body: Data? }
    struct State: Sendable { var action: Action = .response(200, Data("{}".utf8)); var captures: [Capture] = []; var stops = 0; var redirected = false }
    static let state = Mutex(State())
    static func configure(_ action: Action) { state.withLock { $0 = State(action: action) } }
    static func snapshot() -> State { state.withLock { $0 } }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let capture = Capture(url: request.url?.absoluteString ?? "", method: request.httpMethod ?? "", headers: request.allHTTPHeaderFields ?? [:], body: request.httpBody)
        let action = Self.state.withLock { value -> Action in
            value.captures.append(capture)
            if case .redirect = value.action, value.redirected { return .response(200, Data("{}".utf8)) }
            if case .redirect = value.action { value.redirected = true }
            return value.action
        }
        if case .redirect(let destination) = action {
            let response = HTTPURLResponse(url: request.url!, statusCode: 302, httpVersion: "HTTP/1.1", headerFields: ["Location": destination])!
            var redirected = URLRequest(url: URL(string: destination)!)
            redirected.httpMethod = request.httpMethod
            client?.urlProtocol(self, wasRedirectedTo: redirected, redirectResponse: response)
            return
        }
        guard case .response(let status, let body) = action else { return }
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() { Self.state.withLock { $0.stops += 1 } }
}

private struct SM07SlowClock: ProviderClock {
    func nowMilliseconds() -> Double { 0 }
    func sleep(milliseconds: Int) async throws { try await Task.sleep(for: .seconds(60)) }
}
private struct SM07ImmediateClock: ProviderClock {
    func nowMilliseconds() -> Double { 0 }
    // Give URLProtocol enough time to observe each attempt before the injected
    // deadline fires; production timing is not involved in this test.
    func sleep(milliseconds: Int) async throws { try await Task.sleep(for: .milliseconds(20)) }
}
private final class SM07ManualClock: ProviderClock, Sendable {
    private let value = Mutex<Double>(0)
    func nowMilliseconds() -> Double { value.withLock { $0 } }
    func sleep(milliseconds: Int) async throws { try await Task.sleep(for: .seconds(60)) }
    func advance(_ milliseconds: Double) { value.withLock { $0 += milliseconds } }
}
private actor SM07TestCredentials: ProviderCredentialReading {
    let values: [String: String]
    init(_ values: [String: String]) { self.values = values }
    func credential(for providerID: String) -> String? { values[providerID] }
    func isCredentialConfigured(for providerID: String) -> Bool { values[providerID]?.isEmpty == false }
}

private actor SM07FakeTransport: ProviderHTTPTransporting {
    var responses: [Result<Data, SlateSyncError>]
    var requests: [ProviderTransportRequest] = []
    var calls = 0
    var closed = false
    init(_ responses: [Result<Data, SlateSyncError>]) { self.responses = responses }
    func send(_ request: ProviderTransportRequest) async throws -> ProviderTransportResponse {
        calls += 1; requests.append(request)
        let result = responses.isEmpty ? .success(Data("{}".utf8)) : responses.removeFirst()
        return .init(status: 200, body: try result.get())
    }
    func close() { closed = true }
}

private actor SM07ProbeSaveLog {
    var ids: [String] = []
    func record(_ results: [ModelCapabilityProbeResult]) { ids = results.map(\.model) }
}

@MainActor final class SM07TransportDiscoveryTests: XCTestCase {
    private func configuration() -> URLSessionConfiguration { let value = URLSessionConfiguration.ephemeral; value.protocolClasses = [SM07URLProtocol.self]; return value }
    private func provider(id: String = "openrouter", required: Bool = true) -> ProviderDescriptor { .init(id: id, label: id, kind: .builtin, baseURL: URL(string: "https://example.com/v1")!, transport: .chatCompletions, credentialRequired: required, openRouterSiteURL: "https://slatesync.example") }

    func testNET02URLSessionHeadersAndSuccessDrain() async throws {
        SM07URLProtocol.configure(.response(200, Data(#"{"ok":true}"#.utf8)))
        let transport = URLSessionProviderTransport(credentials: SM07TestCredentials(["openrouter": "secret"]), configuration: configuration(), clock: SM07SlowClock())
        let response = try await transport.send(.init(provider: provider(), purpose: .recognition, method: .post, body: Data("{}".utf8), timeoutMilliseconds: 1_000))
        let activeCount = await transport.activeRequestCount()
        XCTAssertEqual(response.status, 200); XCTAssertEqual(activeCount, 0)
        let capture = try XCTUnwrap(SM07URLProtocol.snapshot().captures.first)
        XCTAssertEqual(capture.url, "https://example.com/v1/chat/completions"); XCTAssertEqual(capture.method, "POST")
        XCTAssertEqual(capture.headers["Authorization"], "Bearer secret"); XCTAssertEqual(capture.headers["X-Title"], "SlateSync"); XCTAssertEqual(capture.headers["HTTP-Referer"], "https://slatesync.example")
        await transport.close()
    }

    func testNET03NET04TimeoutRetriesAndDrain() async throws {
        SM07URLProtocol.configure(.stall)
        let transport = URLSessionProviderTransport(credentials: SM07TestCredentials(["openrouter": "secret"]), configuration: configuration(), clock: SM07ImmediateClock())
        do { _ = try await transport.send(.init(provider: provider(), purpose: .recognition, method: .post, body: Data("{}".utf8), timeoutMilliseconds: 30_000, maximumTimeoutRetries: 1)); XCTFail() }
        catch { XCTAssertEqual((error as? SlateSyncError)?.code, "MODEL_TIMEOUT") }
        let activeCount = await transport.activeRequestCount()
        XCTAssertEqual(SM07URLProtocol.snapshot().captures.count, 2); XCTAssertGreaterThanOrEqual(SM07URLProtocol.snapshot().stops, 2); XCTAssertEqual(activeCount, 0)
        await transport.close()
    }

    func testNET05NET06NET08ProviderFailuresDoNotRetry() async throws {
        let secret = "top-secret"
        SM07URLProtocol.configure(.response(401, Data(#"{"error":{"message":"bad top-secret"}}"#.utf8)))
        let transport = URLSessionProviderTransport(credentials: SM07TestCredentials(["openrouter": secret]), configuration: configuration(), clock: SM07SlowClock())
        do { _ = try await transport.send(.init(provider: provider(), purpose: .recognition, method: .post, body: Data("{}".utf8), timeoutMilliseconds: 30_000, maximumTimeoutRetries: 3)); XCTFail() }
        catch { let value = error as? SlateSyncError; XCTAssertEqual(value?.status, 401); XCTAssertFalse(value?.message.contains(secret) ?? true) }
        XCTAssertEqual(SM07URLProtocol.snapshot().captures.count, 1)
        await transport.close()
    }

    func testNET10CloseCancelsAndRejectsNewRequests() async throws {
        SM07URLProtocol.configure(.stall)
        let transport = URLSessionProviderTransport(credentials: SM07TestCredentials(["openrouter": "secret"]), configuration: configuration(), clock: SM07SlowClock())
        let task = Task { try await transport.send(.init(provider: provider(), purpose: .recognition, method: .post, body: Data("{}".utf8), timeoutMilliseconds: 30_000)) }
        while SM07URLProtocol.snapshot().captures.isEmpty { await Task.yield() }
        await transport.close(); await transport.close()
        do { _ = try await task.value; XCTFail() } catch { XCTAssertEqual((error as? SlateSyncError)?.code, "RECOGNITION_CANCELED") }
        do { _ = try await transport.send(.init(provider: provider(), purpose: .discovery, method: .get, timeoutMilliseconds: 30_000)); XCTFail() } catch { XCTAssertEqual((error as? SlateSyncError)?.code, "RECOGNITION_CLOSED") }
    }

    func testNET09CrossOriginRedirectDoesNotLeakAuthorization() async throws {
        SM07URLProtocol.configure(.redirect("https://redirected.invalid/v1/chat/completions"))
        let transport = URLSessionProviderTransport(credentials: SM07TestCredentials(["openrouter": "redirect-secret"]), configuration: configuration(), clock: SM07SlowClock())
        _ = try await transport.send(.init(provider: provider(), purpose: .recognition, method: .post, body: Data("{}".utf8), timeoutMilliseconds: 1_000))
        let captures = SM07URLProtocol.snapshot().captures
        XCTAssertEqual(captures.map(\.url), ["https://example.com/v1/chat/completions", "https://redirected.invalid/v1/chat/completions"])
        XCTAssertEqual(captures.first?.headers["Authorization"], "Bearer redirect-secret")
        XCTAssertNil(captures.last?.headers["Authorization"])
        await transport.close()
    }

    func testDIS01DIS02DIS06DiscoveryClassificationAndCache() async throws {
        let payload = Data(#"{"data":[{"id":"openai/gpt-5.6-luna","architecture":{"input_modalities":["image","text"],"output_modalities":["text"]},"supported_parameters":["response_format"]},{"id":"anthropic/claude-4-sonnet","architecture":{"input_modalities":["image","text"],"output_modalities":["text"]},"supported_parameters":["response_format"],"pricing":{"prompt":"0.000003","completion":"0.000015"}},{"id":"text-only","architecture":{"input_modalities":["text"],"output_modalities":["text"]}}]}"#.utf8)
        let transport = SM07FakeTransport([.success(payload), .success(payload), .success(payload)])
        let registry = ProviderRegistry(credentials: SM07TestCredentials(["openrouter": "key"]))
        let clock = SM07ManualClock(), service = ModelDiscoveryService(registry: registry, transport: transport, clock: clock, now: { Date(timeIntervalSince1970: 0) })
        let first = try await service.discover(providerID: "openrouter")
        XCTAssertEqual(first.models.map(\.id), ["openai/gpt-5.6-luna", "anthropic/claude-4-sonnet"]); XCTAssertEqual(first.unsupportedModelCount, 1)
        let priced = try XCTUnwrap(first.models.first { $0.id == "anthropic/claude-4-sonnet" })
        XCTAssertNotNil(priced.valueScore); XCTAssertEqual(priced.valueSource, "接口实时价格")
        let publicJSON = String(data: try JSONEncoder().encode(priced), encoding: .utf8) ?? ""
        XCTAssertFalse(publicJSON.contains("pricing")); XCTAssertFalse(publicJSON.contains("pricePerMillion")); XCTAssertFalse(publicJSON.contains("cost"))
        _ = try await service.discover(providerID: "openrouter")
        let cachedCalls = await transport.calls
        XCTAssertEqual(cachedCalls, 1)
        _ = try await service.discover(providerID: "openrouter", forceRefresh: true)
        let refreshedCalls = await transport.calls
        XCTAssertEqual(refreshedCalls, 2)
        clock.advance(300_000)
        _ = try await service.discover(providerID: "openrouter")
        let expiredCalls = await transport.calls
        XCTAssertEqual(expiredCalls, 3)
    }

    func testDIS03DIS04DIS05CustomPendingFailedAndUnavailable() async throws {
        let id = "openai-compatible:123e4567-e89b-42d3-a456-426614174000"
        let custom = CustomProviderConfiguration(id: id, name: "Custom", baseUrl: "http://localhost:9000/v1", manualModelIds: ["manual", "failed"], revision: 2, capabilityCache: ["failed": .init(status: .failed, revision: 2, message: "no vision")])
        let unavailable = SlateSyncError(code: "PROVIDER_ERROR", message: "not found", status: 404, providerError: true)
        let service = ModelDiscoveryService(registry: ProviderRegistry(customProviders: [custom]), transport: SM07FakeTransport([.failure(unavailable)]))
        let result = try await service.discover(providerID: id)
        XCTAssertFalse(result.modelsEndpointAvailable ?? true); XCTAssertTrue(result.pendingModels?.contains(where: { $0.id == "manual" }) == true); XCTAssertTrue(result.pendingModels?.contains(where: { $0.id == "failed" }) == false)
    }

    func testPRB01PRB02PRB03SyntheticProbePersistsInputOrder() async throws {
        let id = "openai-compatible:123e4567-e89b-42d3-a456-426614174000"
        let custom = CustomProviderConfiguration(id: id, name: "Custom", baseUrl: "http://localhost:9000/v1", transport: .chatCompletions, manualModelIds: ["b", "a"], revision: 2)
        let body = Data(#"{"choices":[{"message":{"content":"{\"ok\":true,\"marker\":\"ss-7q\"}"}}]}"#.utf8)
        let transport = SM07FakeTransport([.success(body), .success(body)])
        let registry = ProviderRegistry(customProviders: [custom])
        let log = SM07ProbeSaveLog()
        let service = ModelCapabilityProbeService(registry: registry, client: ProviderRecognitionClient(transport: transport), save: { _, _, results in await log.record(results) }, now: { Date(timeIntervalSince1970: 0) })
        let result = try await service.probe(providerID: id, modelIDs: ["b", "a", "b", "bad id"])
        let savedIDs = await log.ids
        let canceled = await service.cancel(providerID: id)
        let requestBodies = await transport.requests.compactMap { $0.body.flatMap { String(data: $0, encoding: .utf8) } }
        XCTAssertEqual(result.results.map(\.model), ["b", "a"]); XCTAssertTrue(result.results.allSatisfy(\.supported)); XCTAssertEqual(savedIDs, ["b", "a"])
        XCTAssertEqual(requestBodies.count, 2); XCTAssertTrue(requestBodies.allSatisfy { $0.contains("data:image/png;base64,") && !$0.contains(ModelCapabilityProbeService.marker) })
        XCTAssertFalse(canceled); await service.close()
    }

    func testPRB01RejectsWrongVisualMarker() async throws {
        let id = "openai-compatible:123e4567-e89b-42d3-a456-426614174000"
        let custom = CustomProviderConfiguration(id: id, name: "Custom", baseUrl: "http://localhost:9000/v1", transport: .chatCompletions, manualModelIds: ["vision-model"], revision: 2)
        let body = Data(#"{"choices":[{"message":{"content":"{\"ok\":true,\"marker\":\"echoed-prompt\"}"}}]}"#.utf8)
        let service = ModelCapabilityProbeService(
            registry: ProviderRegistry(customProviders: [custom]),
            client: ProviderRecognitionClient(transport: SM07FakeTransport([.success(body)])),
            now: { Date(timeIntervalSince1970: 0) }
        )
        let result = try await service.probe(providerID: id, modelIDs: ["vision-model"])
        XCTAssertEqual(result.results.count, 1)
        XCTAssertFalse(result.results[0].supported)
        XCTAssertEqual(result.results[0].capabilityStatus, .failed)
        await service.close()
    }

    func testPRB02CancellationDrainsBatchWithoutSaving() async throws {
        SM07URLProtocol.configure(.stall)
        let id = "openai-compatible:123e4567-e89b-42d3-a456-426614174000"
        let custom = CustomProviderConfiguration(id: id, name: "Custom", baseUrl: "https://example.com/v1", transport: .chatCompletions, manualModelIds: ["a", "b"], revision: 2)
        let transport = URLSessionProviderTransport(credentials: SM07TestCredentials([:]), configuration: configuration(), clock: SM07SlowClock())
        let log = SM07ProbeSaveLog()
        let service = ModelCapabilityProbeService(
            registry: ProviderRegistry(customProviders: [custom]),
            client: ProviderRecognitionClient(transport: transport),
            save: { _, _, results in await log.record(results) },
            now: { Date(timeIntervalSince1970: 0) }
        )
        let task = Task { try await service.probe(providerID: id, modelIDs: ["a", "b"]) }
        while SM07URLProtocol.snapshot().captures.isEmpty { await Task.yield() }
        let didCancel = await service.cancel(providerID: id)
        XCTAssertTrue(didCancel)
        let result = try await task.value
        let savedIDs = await log.ids
        let activeCount = await transport.activeRequestCount()
        XCTAssertTrue(result.canceled)
        XCTAssertTrue(result.results.allSatisfy { $0.capabilityStatus == .canceled })
        XCTAssertTrue(savedIDs.isEmpty)
        XCTAssertEqual(activeCount, 0)
        await service.close()
        await transport.close()
    }
}

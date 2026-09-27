import Foundation
import SlateSyncDomain
@testable import SlateSyncWorkflow
import XCTest

/// Real discovery classification with an offline transport, including the former custom fallback bug.
final class ProviderDiscoveryFailureTests: XCTestCase {
    func testCustomFailuresPreserveTheirCause() async throws {
        let provider = try CustomProviderValidator.normalizeRequest(.init(name: "Test", baseUrl: "https://example.invalid/v1", manualModelIds: ["vision"]))
        for status in [400, 401, 402, 403, 429, 500, 502, 504] {
            let failure = SlateSyncError(code: "TEST_\(status)", message: "Service failure", status: status)
            let service = ModelDiscoveryService(registry: ProviderRegistry(customProviders: [provider]), transport: DiscoveryFailureTransport(error: failure))
            do { _ = try await service.discover(providerID: provider.id); XCTFail("Status \(status) must not become missing /models") }
            catch { XCTAssertEqual((error as? SlateSyncError)?.code, failure.code) }
        }
    }

    func testOnlyUnavailableModelsEndpointUsesManualFallback() async throws {
        let provider = try CustomProviderValidator.normalizeRequest(.init(name: "Test", baseUrl: "https://example.invalid/v1", manualModelIds: ["manual-vision"]))
        for status in [404, 405, 501] {
            let service = ModelDiscoveryService(registry: ProviderRegistry(customProviders: [provider]),
                transport: DiscoveryFailureTransport(error: .init(code: "ENDPOINT", message: "Unavailable", status: status)))
            let result = try await service.discover(providerID: provider.id)
            XCTAssertEqual(result.source, .staticFallback)
            XCTAssertEqual(result.modelsEndpointAvailable, false)
            XCTAssertEqual(result.pendingModels?.map(\.id), ["manual-vision"])
            XCTAssertNil(result.availableModelCount)
        }
    }

    func testMalformedResponsesDoNotClaimEndpointUnavailable() async throws {
        let provider = try CustomProviderValidator.normalizeRequest(.init(name: "Test", baseUrl: "https://example.invalid/v1"))
        for id in [provider.id, "openai"] {
            for body in ["not json", "{}", "[]"] {
                let service = ModelDiscoveryService(registry: ProviderRegistry(customProviders: [provider]), transport: DiscoveryFailureTransport(body: body))
                do { _ = try await service.discover(providerID: id); XCTFail("Malformed response must fail") }
                catch { XCTAssertEqual((error as? SlateSyncError)?.code, RecognitionFailure.invalidResponse.code) }
            }
        }
    }

    func testBuiltinNetworkFailureKeepsExplicitOfflineCatalog() async throws {
        let service = ModelDiscoveryService(registry: ProviderRegistry(), transport: DiscoveryFailureTransport(error: RecognitionFailure.timeout))
        let result = try await service.discover(providerID: "openai")
        XCTAssertEqual(result.source, .staticFallback)
        XCTAssertNotNil(result.warning)
    }
}

private actor DiscoveryFailureTransport: ProviderHTTPTransporting {
    let error: SlateSyncError?
    let body: String
    init(error: SlateSyncError? = nil, body: String = "{}") { self.error = error; self.body = body }
    func send(_ request: ProviderTransportRequest) async throws -> ProviderTransportResponse {
        if let error { throw error }
        return .init(status: 200, body: Data(body.utf8))
    }
    func close() async {}
}

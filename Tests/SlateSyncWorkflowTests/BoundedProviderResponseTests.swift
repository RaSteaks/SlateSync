import Foundation
import SlateSyncDomain
import Synchronization
import XCTest

@testable import SlateSyncWorkflow

/// Chunked oversized bodies deliberately never finish. Header tests send a
/// short body so rejecting the advertised size cannot rely on actual byte count.
private final class OversizedProtocol: URLProtocol {
    static let advertised = Mutex(false)
    static let stops = Mutex(0)
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let hasLength = Self.advertised.withLock { $0 }
        let headers = hasLength ? ["Content-Length": "33554432"] : [:]
        let response = HTTPURLResponse(
            url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if hasLength {
            client?.urlProtocol(self, didLoad: Data([65]))
            client?.urlProtocolDidFinishLoading(self)
        } else {
            let chunk = Data(repeating: 65, count: 1024 * 1024)
            for _ in 0..<17 { client?.urlProtocol(self, didLoad: chunk) }
        }
    }
    override func stopLoading() { Self.stops.withLock { $0 += 1 } }
}
private struct NoCredentials: ProviderCredentialReading {
    func credential(for providerID: String) async throws -> String? { nil }
    func isCredentialConfigured(for providerID: String) async throws -> Bool { false }
}
@MainActor
final class BoundedProviderResponseTests: XCTestCase {
    func testOversizedHeadersAndChunkedBodiesCancelBeforeCompletion() async throws {
        for advertised in [true, false] {
            OversizedProtocol.advertised.withLock { $0 = advertised }
            OversizedProtocol.stops.withLock { $0 = 0 }
            let config = URLSessionConfiguration.ephemeral
            config.protocolClasses = [OversizedProtocol.self]
            let transport = URLSessionProviderTransport(credentials: NoCredentials(), configuration: config)
            let provider = ProviderDescriptor(
                id: "fixture", label: "Fixture", origin: .custom,
                baseURL: URL(string: "https://fixture.invalid/v1")!, transport: .chatCompletions,
                credentialRequired: false)
            do {
                _ = try await transport.send(
                    .init(
                        provider: provider, purpose: .recognition, method: .post,
                        body: Data(), timeoutMilliseconds: 2_000, maximumTimeoutRetries: 0))
                XCTFail("Oversized responses must be canceled")
            } catch {
                XCTAssertEqual((error as? SlateSyncError)?.code, "MODEL_RESPONSE_SIZE", "advertised=\(advertised)")
            }
            await transport.close()
            XCTAssertGreaterThan(OversizedProtocol.stops.withLock { $0 }, 0)
            let active = await transport.activeRequestCount()
            XCTAssertEqual(active, 0)
        }
    }
}

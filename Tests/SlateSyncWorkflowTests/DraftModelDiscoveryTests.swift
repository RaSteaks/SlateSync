import Foundation
import SlateSyncDomain
@testable import SlateSyncWorkflow
import XCTest

final class DraftModelDiscoveryTests: XCTestCase {
    func testListsAllValidIDsWithoutClaimingVisionSupport() async throws {
        let transport = DraftListTransport(body: #"{"data":[{"id":"deepseek-chat"},{"id":"vision-model"},{"id":"deepseek-chat"},{"id":""},{"id":" bad id "}]}"#)
        let ids = try await DraftModelDiscovery.fetch(baseURL: "https://example.test/v1/", transport: transport)
        XCTAssertEqual(ids, ["deepseek-chat", "vision-model"])
        let request = await transport.request
        XCTAssertEqual(try request?.provider.endpoint(for: .discovery).absoluteString, "https://example.test/v1/models")
        XCTAssertEqual(request?.method, .get)
        XCTAssertNil(request?.body)
    }

    func testAlternateEnvelopeAndEmptyList() async throws {
        let alternate = try await DraftModelDiscovery.fetch(baseURL: "https://example.test", transport: DraftListTransport(body: #"{"models":["alpha",{"name":"beta"},{"model":"alpha"}]}"#))
        XCTAssertEqual(alternate, ["alpha", "beta"])
        let empty = try await DraftModelDiscovery.fetch(baseURL: "https://example.test", transport: DraftListTransport(body: #"{"data":[]}"#))
        XCTAssertEqual(empty, [])
    }

    func testMalformedAndAuthenticationErrorsAreNotEmptySuccess() async {
        for body in ["not json", "{}", "[]"] {
            do {
                _ = try await DraftModelDiscovery.fetch(baseURL: "https://example.test", transport: DraftListTransport(body: body))
                XCTFail("Malformed response must fail")
            } catch { XCTAssertEqual((error as? SlateSyncError)?.code, RecognitionFailure.invalidResponse.code) }
        }
        do {
            _ = try await DraftModelDiscovery.fetch(baseURL: "https://example.test", transport: DraftListTransport(body: "", failure: .init(code: "AUTH", message: "Unauthorized", status: 401)))
            XCTFail("Authentication must fail")
        } catch { XCTAssertEqual((error as? SlateSyncError)?.status, 401) }
    }

    func testCancellationDiscardsTransportResult() async {
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await DraftModelDiscovery.fetch(baseURL: "https://example.test", transport: DraftListTransport(body: #"{"data":["late"]}"#))
        }
        do { _ = try await task.value; XCTFail("Canceled response must not publish") }
        catch { XCTAssertTrue(error is CancellationError) }
    }
}

/// Records the GET contract without sending secrets or requests to a real service.
private actor DraftListTransport: ProviderHTTPTransporting {
    let body: String
    let failure: SlateSyncError?
    var request: ProviderTransportRequest?
    init(body: String, failure: SlateSyncError? = nil) { self.body = body; self.failure = failure }
    func send(_ request: ProviderTransportRequest) async throws -> ProviderTransportResponse {
        self.request = request
        if let failure { throw failure }
        return .init(status: 200, body: Data(body.utf8))
    }
    func close() async {}
}

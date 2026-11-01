import Foundation
import SlateSyncDomain
import SlateSyncWorkflow
import XCTest

// Exercise extraction and real pipeline routing without a remote provider.
@MainActor
final class RecognitionFallbackRegressionTests: XCTestCase {
    func testLengthTruncationRetriesOnlyAffectedPageOnVerifiedBackup() async throws {
        let primaryID = "openai-compatible:123e4567-e89b-42d3-a456-426614174000"
        let backupID = "openai-compatible:123e4567-e89b-42d3-a456-426614174001"
        let registry = ProviderRegistry(customProviders: [primaryID, backupID].map { id in
            .init(id: id, name: id, baseUrl: "https://example.com/v1", manualModelIds: ["vision"], revision: 1,
                capabilityCache: ["vision": .init(status: .verified, revision: 1, jsonMode: .jsonSchema)])
        })
        let provider = try await registry.descriptor(providerID: primaryID)
        let model = try await registry.resolveModel(providerID: primaryID, modelID: "vision")
        let transport = ReviewTruncationTransport(primary: primaryID)
        let client = ProviderRecognitionClient(transport: transport)
        let image = try PreparedImage(jpeg: Data([255, 216, 255, 217]), width: 1, height: 1)
        do {
            _ = try await RecognitionPagePipeline(client: client).run(
                pages: (1...2).map { .init(pageNumber: $0, views: [.init(viewIndex: 0, viewType: .full, image: image)]) },
                provider: provider, model: model, accuracy: .standard, formats: .init(),
                prompts: ("p", "a", "r"), pageConcurrency: 1, filename: "fixture", candidates: [
                    .init(providerID: primaryID, modelID: "vision"), .init(providerID: backupID, modelID: "vision")
                ], registry: registry, failoverState: RecognitionFailoverState())
        } catch { XCTFail("Verified backup should recover a primary-only output limit: \(error)") }
        let calls = await transport.calls
        XCTAssertEqual(calls, [primaryID, backupID, primaryID], "Truncation must not disable the provider for other pages")
        await client.close()
    }
}

private actor ReviewTruncationTransport: ProviderHTTPTransporting {
    let primary: String
    var calls: [String] = []
    init(primary: String) { self.primary = primary }
    func send(_ request: ProviderTransportRequest) async throws -> ProviderTransportResponse {
        calls.append(request.provider.id)
        let sheet = #"{"sheetTitle":"fixture","records":[],"warnings":[]}"#
        let root: JSONValue = .object(["choices": .array([.object([
            "finish_reason": .string(request.provider.id == primary && calls.count == 1 ? "length" : "stop"),
            "message": .object(["content": .string(sheet)])
        ])])])
        return .init(status: 200, body: try JSONEncoder().encode(root))
    }
    func close() {}
}

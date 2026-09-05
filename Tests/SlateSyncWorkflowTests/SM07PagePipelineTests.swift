import Foundation
import SlateSyncDomain
@testable import SlateSyncWorkflow
import XCTest

private actor SM07PipelineTransport: ProviderHTTPTransporting {
    var calls = 0
    var active = 0
    var maximumActive = 0
    func send(_ request: ProviderTransportRequest) async throws -> ProviderTransportResponse {
        calls += 1; active += 1; maximumActive = max(maximumActive, active)
        defer { active -= 1 }
        try await Task.sleep(for: .milliseconds(5))
        let bodyText = String(data: request.body ?? Data(), encoding: .utf8) ?? ""
        let scene = bodyText.contains("冲突复核") ? "003" : bodyText.contains("核心字段查漏") ? "002" : "001"
        let content = #"{"sheetTitle":"sheet","records":[{"cardNumber":"A001","videoCode":"C001","scene":"SCENE","shot":"1","take":"1","takeStatus":"过","description":null,"comments":null,"shotSize":null,"cameraPosition":null,"confidence":"high"}],"warnings":[]}"#.replacingOccurrences(of: "SCENE", with: scene)
        let response = #"{"output_text":"TEXT","usage":{"input_tokens":1,"output_tokens":2}}"#.replacingOccurrences(of: "TEXT", with: content.replacingOccurrences(of: "\"", with: "\\\""))
        return .init(status: 200, body: Data(response.utf8))
    }
    func close() {}
}

@MainActor final class SM07PagePipelineTests: XCTestCase {
    private func image() throws -> PreparedImage { try .init(jpeg: Data([0xff, 0xd8, 0xff, 0xd9]), width: 1, height: 1) }
    private func provider() -> ProviderDescriptor { .init(id: "openai", label: "OpenAI", kind: .builtin, baseURL: URL(string: "https://example.com/v1")!, transport: .responses) }
    private func model() -> ResolvedModel { .init(publicID: "m", apiID: "m", providerID: "openai", label: "m") }

    func testPAG01PAG07StandardBoundedAndOrdered() async throws {
        let transport = SM07PipelineTransport(), pipeline = RecognitionPagePipeline(client: ProviderRecognitionClient(transport: transport))
        let pages = try (1...5).map { RecognitionPageInput(pageNumber: $0, views: [.init(viewIndex: 0, viewType: .full, image: try image())]) }
        let output = try await pipeline.run(pages: pages, provider: provider(), model: model(), accuracy: .standard, formats: .init(), prompts: ("p", "a", "r"), pageConcurrency: 2, filename: "slate")
        let calls = await transport.calls
        let maximumActive = await transport.maximumActive
        XCTAssertEqual(output.pages.map(\.pageNumber), [1, 2, 3, 4, 5]); XCTAssertEqual(output.stageCount, 5); XCTAssertEqual(calls, 5); XCTAssertLessThanOrEqual(maximumActive, 2)
        XCTAssertEqual(output.result.records.map(\.sourcePage), [1, 2, 3, 4, 5])
    }

    func testPAG02PAG03PAG04PAG05HighRunsAuditAndTargetReview() async throws {
        let transport = SM07PipelineTransport(), pipeline = RecognitionPagePipeline(client: ProviderRecognitionClient(transport: transport))
        let views: [PreparedMediaView] = try [
            .init(viewIndex: 0, viewType: .full, image: image()),
            .init(viewIndex: 1, viewType: .coreDetail, image: image())
        ]
        let output = try await pipeline.run(pages: [.init(pageNumber: 1, views: views)], provider: provider(), model: model(), accuracy: .high, formats: .init(), prompts: ("p", "a", "r"), filename: "slate")
        let calls = await transport.calls
        XCTAssertEqual(output.stageCount, 3); XCTAssertEqual(calls, 3); XCTAssertEqual(output.result.records.first?.scene, "003"); XCTAssertEqual(output.usage?.inputTokens, 3)
    }

    func testPAG06CancellationDrainsSiblings() async throws {
        let transport = SM07PipelineTransport(), pipeline = RecognitionPagePipeline(client: ProviderRecognitionClient(transport: transport))
        let pages = try (1...6).map { RecognitionPageInput(pageNumber: $0, views: [.init(viewIndex: 0, viewType: .full, image: try image())]) }
        let task = Task { try await pipeline.run(pages: pages, provider: provider(), model: model(), accuracy: .standard, formats: .init(), prompts: ("p", "a", "r"), pageConcurrency: 2, filename: "slate") }
        task.cancel()
        do { _ = try await task.value; XCTFail() } catch { XCTAssertEqual((error as? SlateSyncError)?.code, "RECOGNITION_CANCELED") }
        let active = await transport.active
        XCTAssertEqual(active, 0)
    }
}

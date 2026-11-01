import Foundation
import SlateSyncDomain
@testable import SlateSyncWorkflow
import XCTest

final class DeepSeekCompatibilityTests: XCTestCase {
    func testOfficialHostUsesDocumentedBodyBudgetWithoutAffectingGateways() {
        func request(_ host: String, limit: Int = 80 * 1024 * 1024) -> RecognitionStageRequest {
            .init(provider: .init(id: "custom", label: "DeepSeek", origin: .custom,
                baseURL: URL(string: "https://\(host)/v1")!, transport: .chatCompletions),
                model: .init(publicID: "deepseek-flash", apiID: "deepseek-flash", providerID: "custom", label: "Flash"),
                stage: .primary, filename: "fixture", images: [], systemPrompt: "JSON", schema: .object([:]), maximumRequestBytes: limit)
        }
        XCTAssertEqual(ProviderPayloadBuilder.requestByteLimit(request("api.deepseek.com")), 48 * 1024 * 1024)
        XCTAssertEqual(ProviderPayloadBuilder.requestByteLimit(request("api.deepseek.com", limit: 1000)), 1000)
        XCTAssertEqual(ProviderPayloadBuilder.requestByteLimit(request("api.deepseek.com.example.org")), 80 * 1024 * 1024)
    }

    func testOfficialVisionTranscriptionDisablesThinkingOnlyOnDeepSeek() throws {
        for (host, disabled) in [("api.deepseek.com", true), ("gateway.example.org", false)] {
            let request = RecognitionStageRequest(provider: .init(id: "custom", label: "DeepSeek", origin: .custom,
                baseURL: URL(string: "https://\(host)/v1")!, transport: .chatCompletions),
                model: .init(publicID: "deepseek-flash", apiID: "deepseek-flash", providerID: "custom", label: "Flash"),
                stage: .primary, filename: "fixture", images: [], systemPrompt: "Return JSON", schema: .object([:]))
            let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: ProviderPayloadBuilder.payload(request, mode: .jsonObject)) as? [String: Any])
            XCTAssertEqual((payload["thinking"] as? [String: String])?["type"], disabled ? "disabled" : nil)
            XCTAssertEqual(payload["max_tokens"] as? Int, 16000)
            XCTAssertEqual((payload["response_format"] as? [String: String])?["type"], "json_object")
        }
    }

    func testValidLookingJSONWithLengthFinishIsRejected() throws {
        let body = Data(#"{"choices":[{"finish_reason":"length","message":{"content":"{\"records\":[]}"}}]}"#.utf8)
        XCTAssertThrowsError(try ProviderRecognitionClient.extract(body, transport: .chatCompletions, mode: .jsonObject)) {
            XCTAssertEqual(($0 as? SlateSyncError)?.code, "MODEL_OUTPUT_TRUNCATED")
        }
        let complete = Data(#"{"choices":[{"finish_reason":"stop","message":{"content":"{\"records\":[]}"}}]}"#.utf8)
        XCTAssertEqual(try ProviderRecognitionClient.extract(complete, transport: .chatCompletions, mode: .jsonObject).text, #"{"records":[]}"#)
    }

    func testProviderStatusIsActionableWithoutExposingResponseBody() {
        let error = ProductPrivacy.error(SlateSyncError(code: "PROVIDER_FAILOVER_EXHAUSTED", message: "private-token-and-image-text", status: 402, providerError: true))
        XCTAssertTrue(error.message.contains("余额不足"))
        XCTAssertTrue(error.message.contains("402"))
        XCTAssertFalse(error.message.contains("private-token"))
        let unknown = ProductPrivacy.error(SlateSyncError(code: "PROVIDER_ERROR", message: "private-token", providerError: true))
        XCTAssertFalse(unknown.message.contains("private-token"))
    }
}

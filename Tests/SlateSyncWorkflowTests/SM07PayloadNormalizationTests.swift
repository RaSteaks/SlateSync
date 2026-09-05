import CryptoKit
import Foundation
import SlateSyncDomain
@testable import SlateSyncWorkflow
import XCTest

@MainActor final class SM07PayloadNormalizationTests: XCTestCase {
    private func image() throws -> PreparedImage { try .init(jpeg: Data([0xff, 0xd8, 0xff, 0xd9]), width: 1, height: 1) }
    private func provider(_ transport: ProviderTransport = .responses, id: String = "openai") -> ProviderDescriptor { .init(id: id, label: id, kind: .builtin, baseURL: URL(string: "https://example.com/v1")!, transport: transport, jsonMode: .jsonSchema, credentialRequired: true) }
    private func model(mode: ProviderJSONMode = .jsonSchema) -> ResolvedModel { .init(publicID: "public", apiID: "physical", providerID: "openai", label: "model", imageDetail: .original, jsonMode: mode) }

    func testPRM01PRM02PRM03PRM04PromptOrderAndSchemas() throws {
        let prompt = RecognitionPrompts.compose(base: "SYSTEM", customPrompt: "  中文😀  ", slateCSV: [.init(materialKey: "A:1:2", scene: "001", shot: "02", take: "03", comments: .passed)], fieldFormats: .init(scene: "XXXX", shot: "X", take: "XXXXXX"), comments: .init(goodTake: "GOOD", holdTake: "KEEP"), scenarioInstruction: "\n\nSCENARIO")
        let ordered = ["SYSTEM", "项目背景补充", "中文😀", "高可信度场记记录", "素材=A:1:2", "输出位宽配置", "Resolve Comments", "SCENARIO"]
        var last = prompt.startIndex
        for token in ordered { let range = try XCTUnwrap(prompt.range(of: token, range: last..<prompt.endIndex)); last = range.upperBound }
        guard case .object(let full) = RecognitionSchemas.full, case .object(let core) = RecognitionSchemas.core else { return XCTFail() }
        XCTAssertNotNil(full["properties"]); XCTAssertNotNil(core["properties"])
        XCTAssertTrue(RecognitionPrompts.review.hasPrefix(RecognitionPrompts.audit))
        XCTAssertEqual(Self.digest(Data(RecognitionPrompts.system.utf8)), "d186b8dcfdca3ac9cefb738cea19d3088240691ded895e033a5385b7f35b8326")
        XCTAssertEqual(Self.digest(Data(RecognitionPrompts.audit.utf8)), "f9914fbbb5308b932f763cba9823b40de15681f1dc6df3c82a70a49f40768c94")
        XCTAssertEqual(Self.digest(Data(RecognitionPrompts.review.utf8)), "f16ffa2dc3db30a1dcb75354de4e003fa53f00c419d291be3655266bac99d732")
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        XCTAssertEqual(Self.digest(try encoder.encode(RecognitionSchemas.full)), "c4972a5d82bc4ce0ef93885af5c21e96ba0c53ee716f157c6883f31d87f27d60")
        XCTAssertEqual(Self.digest(try encoder.encode(RecognitionSchemas.core)), "da8ef9fa078efca75c6bdd3632ac584950b7052c02edad53826b5866186d827c")
    }

    func testNET01NET02PRM05PayloadShapesAndPromptFallback() throws {
        let responseRequest = RecognitionStageRequest(provider: provider(), model: model(), stage: .primary, filename: "中文.pdf", images: [try image()], systemPrompt: "system", schema: RecognitionSchemas.full)
        let response = try JSONDecoder().decode(JSONValue.self, from: ProviderPayloadBuilder.payload(responseRequest, mode: .jsonSchema))
        guard case .object(let fields) = response else { return XCTFail() }
        XCTAssertEqual(fields["store"], .boolean(false)); XCTAssertEqual(fields["max_output_tokens"], .number(16_000)); XCTAssertNotNil(fields["text"])

        let chatProvider = provider(.chatCompletions, id: "openrouter")
        let chatRequest = RecognitionStageRequest(provider: chatProvider, model: model(mode: .jsonObject), stage: .audit, filename: "page", images: [try image(), try image()], systemPrompt: "system", userInstruction: "evidence", schema: RecognitionSchemas.core)
        let chat = try JSONDecoder().decode(JSONValue.self, from: ProviderPayloadBuilder.payload(chatRequest, mode: .prompt))
        guard case .object(let chatFields) = chat else { return XCTFail() }
        XCTAssertEqual(chatFields["stream"], .boolean(false)); XCTAssertEqual(chatFields["max_tokens"], .number(16_000)); XCTAssertNil(chatFields["response_format"]); XCTAssertEqual(chatFields["provider"], .object(["require_parameters": .boolean(true)]))
        XCTAssertTrue(ProviderPayloadBuilder.userText(chatRequest).contains("2 张图")); XCTAssertTrue(ProviderPayloadBuilder.userText(chatRequest).contains("核心字段"))
    }

    func testNET07FallbackClassifierIsNarrow() {
        XCTAssertEqual(ProviderRecognitionClient.nextMode(.jsonSchema, error: .init(code: "PROVIDER_ERROR", message: "response_format json_schema unsupported", status: 400)), .jsonObject)
        XCTAssertEqual(ProviderRecognitionClient.nextMode(.jsonObject, error: .init(code: "PROVIDER_ERROR", message: "json_object unsupported", status: 422)), .prompt)
        XCTAssertNil(ProviderRecognitionClient.nextMode(.jsonSchema, error: .init(code: "PROVIDER_ERROR", message: "invalid key", status: 401)))
        XCTAssertNil(ProviderRecognitionClient.nextMode(.jsonSchema, error: .init(code: "PROVIDER_ERROR", message: "server", status: 500)))
    }

    func testNET08ResponseExtractionAndCodeFences() throws {
        let responses = Data(#"{"id":"r","model":"m","output":[{"content":[{"type":"output_text","text":"{\"records\":[],\"warnings\":[],\"sheetTitle\":null}"}]}],"usage":{"input_tokens":2,"output_tokens":3}}"#.utf8)
        let extracted = try ProviderRecognitionClient.extract(responses, transport: .responses, mode: .jsonSchema)
        XCTAssertEqual(extracted.usage?.inputTokens, 2)
        let fenced = try ProviderRecognitionClient.structuredJSON(from: "```json\n{\"records\":[],\"warnings\":[]}\n```")
        guard case .object = fenced else { return XCTFail() }
        let chat = Data(#"{"choices":[{"message":{"content":[{"type":"text","text":"{\"records\":[]}"}]}}]}"#.utf8)
        XCTAssertEqual(try ProviderRecognitionClient.extract(chat, transport: .chatCompletions, mode: .jsonObject).text, #"{"records":[]}"#)
        XCTAssertThrowsError(try ProviderRecognitionClient.extract(Data("{}".utf8), transport: .responses, mode: .jsonSchema))
    }

    func testNOR01NOR02NOR04NormalizationCompatibility() throws {
        let value: JSONValue = .object(["sheetTitle": .string(" 标题 "), "records": .array([
            .object(["cardNumber": .string("ａ-10"), "videoCode": .string("C 15"), "scene": .string("第十一场/12a"), "shot": .string("十一"), "take": .string("9"), "takeStatus": .string("✓"), "confidence": .string("invalid"), "extra": .string("ignored")]),
            .object(["cardNumber": .string("A1"), "videoCode": .string("C115"), "goodTake": .boolean(false), "confidence": .string("high")]),
        ]), "warnings": .array([.string("ok"), .number(1)])])
        let sheet = try RecognitionNormalizer.normalize(value, pageNumber: 2)
        XCTAssertEqual(sheet.sheetTitle, "标题"); XCTAssertEqual(sheet.records[0].cardNumber, "A010"); XCTAssertEqual(sheet.records[0].videoCode, "C015")
        XCTAssertEqual(sheet.records[0].scene, "11 / 12A"); XCTAssertEqual(sheet.records[0].shot, "11"); XCTAssertEqual(sheet.records[0].take, "09")
        XCTAssertEqual(sheet.records[0].takeStatus, .passed); XCTAssertEqual(sheet.records[0].confidence, .low); XCTAssertEqual(sheet.records[0].sourcePage, 2)
        XCTAssertNil(sheet.records[1].videoCode); XCTAssertEqual(sheet.records[1].takeStatus, .hold); XCTAssertEqual(sheet.warnings, ["ok"])
    }

    func testNOR05NOR06NOR07NOR08MergeRepairAndUsage() {
        func record(_ id: String, _ clip: String, _ shot: String?, _ take: String?) -> RecognitionRecord { .init(id: id, sourcePage: 1, cardNumber: "A001", videoCode: clip, scene: "001", shot: shot, take: take, confidence: .high) }
        let first = RecognitionSheet(records: [record("a", "C001", "17", "01"), record("b", "C002", "99", "99"), record("c", "C003", "17", "03")])
        let second = RecognitionSheet(records: [record("d", "C005", nil, "01")])
        let droppedTen = RecognitionSheet(records: [record("e", "C010", "17", "09"), record("f", "C011", "08", "01"), record("g", "C012", "08", "02")])
        let merged = RecognitionPostprocessor.mergePages([(2, second), (3, droppedTen), (1, first)], accuracy: .standard, formats: .init())
        XCTAssertEqual(Array(merged.records.prefix(4)).map(\.sourcePage), [1, 1, 1, 2]); XCTAssertEqual(merged.records[1].shot, "17"); XCTAssertEqual(merged.records[1].take, "02")
        XCTAssertEqual(merged.records[3].shot, "17"); XCTAssertEqual(merged.records.first { $0.videoCode == "C011" }?.shot, "18"); XCTAssertEqual(merged.records.first { $0.videoCode == "C012" }?.shot, "18")
        XCTAssertTrue(merged.warnings.contains { $0.contains("漏写十位") }); XCTAssertTrue(merged.warnings.contains { $0.contains("缺口") }); XCTAssertTrue(merged.warnings.contains { $0.contains("快速模式") })
        let usage = RecognitionNormalizer.aggregateUsage([.init(inputTokens: 2, outputTokens: 3), .init(inputTokens: 4, outputTokens: 5)])
        XCTAssertEqual(usage?.inputTokens, 6); XCTAssertEqual(usage?.outputTokens, 8)
        let encoded = try? JSONEncoder().encode(usage); XCTAssertFalse(String(data: encoded ?? Data(), encoding: .utf8)?.contains("cost") ?? true)
    }

    func testPAG03PAG04PAG05HighAccuracyMergeAndReview() {
        let p = RecognitionRecord(id: "p", cardNumber: "A001", videoCode: "C001", scene: "001", shot: "01", take: "01", confidence: .high)
        let a = RecognitionRecord(id: "a", cardNumber: "A001", videoCode: "C001", scene: "002", shot: "01", take: "01", confidence: .high)
        let extra = RecognitionRecord(id: "x", cardNumber: "A001", videoCode: "C002", scene: "002", shot: "02", take: "01", confidence: .high)
        let merge = RecognitionPostprocessor.mergeHighAccuracy(.init(records: [p]), .init(records: [a, extra]))
        XCTAssertEqual(merge.conflicts.count, 1); XCTAssertEqual(merge.auditOnlyKeys, ["A001C002"])
        let reviewed = RecognitionPostprocessor.applyReview(merge, review: .init(records: [.init(id: "r", cardNumber: "A001", videoCode: "C001", scene: "003", shot: "01", take: "01", confidence: .high)]))
        XCTAssertEqual(reviewed.records.count, 1); XCTAssertEqual(reviewed.records[0].scene, "003"); XCTAssertEqual(reviewed.records[0].confidence, .medium)
    }

    private static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

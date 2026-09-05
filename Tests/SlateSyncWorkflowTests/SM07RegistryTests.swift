import Foundation
import SlateSyncDomain
@testable import SlateSyncWorkflow
import XCTest

private actor SM07Credentials: ProviderCredentialReading {
    var values: [String: String]
    init(_ values: [String: String] = [:]) { self.values = values }
    func credential(for providerID: String) -> String? { values[providerID] }
    func isCredentialConfigured(for providerID: String) -> Bool { !(values[providerID] ?? "").isEmpty }
}

@MainActor final class SM07RegistryTests: XCTestCase {
    func testREG01BuiltinsAndPhysicalModelRouting() async throws {
        XCTAssertEqual(ProviderCatalog.definitions.map(\.id), ["openai", "openrouter", "tokenplan", "dashscope", "openai-compatible"])
        let registry = ProviderRegistry(settings: .init([.openAICompatibleBaseUrl: "http://localhost:8080/v1", .openAICompatibleModel: "local/vision"]), credentials: SM07Credentials(["openai": "key", "openrouter": "key", "tokenplan": "key", "dashscope": "key", "openai-compatible": "key"]))
        let openAI = try await registry.descriptor(providerID: "openai")
        let openRouter = try await registry.descriptor(providerID: "openrouter")
        let direct = try await registry.resolveModel(providerID: "openai", modelID: "openai/gpt-5.6-luna")
        let routed = try await registry.resolveModel(providerID: "openrouter", modelID: "openai/gpt-5.6-luna")
        let compatible = try await registry.resolveModel(providerID: "openai-compatible", modelID: "openai-compatible/custom")
        XCTAssertEqual(try openAI.endpoint(for: .recognition).absoluteString, "https://api.openai.com/v1/responses")
        XCTAssertEqual(try openRouter.endpoint(for: .recognition).absoluteString, "https://openrouter.ai/api/v1/chat/completions")
        XCTAssertEqual(direct.apiID, "gpt-5.6-luna")
        XCTAssertEqual(routed.apiID, "openai/gpt-5.6-luna")
        XCTAssertEqual(compatible.apiID, "local/vision")
        await XCTAssertThrowsErrorAsync { _ = try await registry.descriptor(providerID: "unknown") }
    }

    func testREG02REG03LegacyAndUUIDCapabilities() async throws {
        let uuid = "openai-compatible:123e4567-e89b-42d3-a456-426614174000"
        let provider = CustomProviderConfiguration(id: uuid, name: "Local", baseUrl: "http://127.0.0.1:9000/v1", manualModelIds: ["pending", "verified"], revision: 7, capabilityCache: ["verified": .init(status: .verified, revision: 7)])
        let legacy = CustomProviderConfiguration(id: "openai-compatible", name: "Legacy", baseUrl: "https://legacy.example/v1", manualModelIds: ["persisted/model"], revision: 3)
        let registry = ProviderRegistry(settings: .init([.openAICompatibleBaseUrl: "https://env.example/v1", .openAICompatibleModel: "env/model"]), customProviders: [provider, legacy], credentials: SM07Credentials())
        let compatible = try await registry.resolveModel(providerID: "openai-compatible", modelID: "openai-compatible/custom")
        let verified = try await registry.resolveModel(providerID: uuid, modelID: "verified")
        let descriptor = try await registry.descriptor(providerID: uuid)
        XCTAssertEqual(compatible.apiID, "persisted/model")
        XCTAssertEqual(verified.capabilityStatus, .verified)
        await XCTAssertThrowsErrorAsync { _ = try await registry.resolveModel(providerID: uuid, modelID: "pending") }
        XCTAssertFalse(descriptor.credentialRequired)
    }

    func testREG04RevisionInvalidatesLateRegistration() async throws {
        let uuid = "openai-compatible:123e4567-e89b-42d3-a456-426614174000"
        func provider(_ revision: Int) -> CustomProviderConfiguration { .init(id: uuid, name: "Local", baseUrl: "http://localhost:9000/v1", manualModelIds: [], revision: revision) }
        let registry = ProviderRegistry(customProviders: [provider(1)])
        let model = ResolvedModel(publicID: "dynamic", apiID: "dynamic", providerID: uuid, label: "dynamic", capabilityStatus: .declared, revision: 1)
        await registry.register([model], providerID: uuid, revision: 1)
        let dynamic = try await registry.resolveModel(providerID: uuid, modelID: "dynamic")
        XCTAssertEqual(dynamic.apiID, "dynamic")
        await registry.replace(settings: .init(), customProviders: [provider(2)])
        await registry.register([model], providerID: uuid, revision: 1)
        await XCTAssertThrowsErrorAsync { _ = try await registry.resolveModel(providerID: uuid, modelID: "dynamic") }
    }

    func testREG05PublicProjectionRedactsSecretsAndPrices() async throws {
        let uuid = "openai-compatible:123e4567-e89b-42d3-a456-426614174000", secret = "sk-secret-123"
        let provider = CustomProviderConfiguration(id: uuid, name: "Local", baseUrl: "https://example.com/v1", manualModelIds: ["vision"], revision: 1, capabilityCache: ["vision": .init(status: .failed, revision: 1, checkedAt: secret, capabilitySource: secret, message: "Authorization: Bearer \(secret)")])
        let registry = ProviderRegistry(customProviders: [provider], credentials: SM07Credentials([uuid: secret]))
        let data = try JSONEncoder().encode(await registry.publicModels())
        let text = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertFalse(text.contains(secret)); XCTAssertFalse(text.lowercased().contains("pricepermillion")); XCTAssertFalse(text.lowercased().contains("cost"))
    }

    func testNOR03StatusAliasesAndRuntimeBounds() {
        for value in ["过", "过条", "好条", "ok", "PASS", "☑", "☑️", "✅", "√", "✓", "✔"] { XCTAssertEqual(LegacyTakeStatusAdapter.status(from: value), .passed) }
        for value in ["保", "保条", "hold", "三角", "三角形", "triangle", "△", "▲"] { XCTAssertEqual(LegacyTakeStatusAdapter.status(from: value), .hold) }
        for value in ["废条", "废", "ng", "x", "×", "✕", "✖"] { XCTAssertEqual(LegacyTakeStatusAdapter.status(from: value), .rejected) }
        XCTAssertNil(LegacyTakeStatusAdapter.status(from: "")); XCTAssertNil(LegacyTakeStatusAdapter.status(from: "maybe"))
        XCTAssertEqual(LegacyTakeStatusAdapter.status(value: nil, legacyGoodTake: false), .hold)
        XCTAssertEqual(LegacyTakeStatusAdapter.status(fromResolveComment: "GOOD", comments: .init(goodTake: "GOOD", holdTake: "KEEP")), .passed)
        XCTAssertEqual(RecognitionRuntimeOptions.timeoutMilliseconds("29999"), 30_000)
        XCTAssertEqual(RecognitionRuntimeOptions.timeoutMilliseconds("3600001"), 3_600_000)
        XCTAssertEqual(RecognitionRuntimeOptions.maximumTimeoutRetries("4"), 1)
        XCTAssertEqual(RecognitionRuntimeOptions.pageConcurrency("6"), 6)
        XCTAssertEqual(RecognitionRuntimeOptions.globalConcurrency("0"), 1)
    }
}

@MainActor private func XCTAssertThrowsErrorAsync(_ expression: @MainActor () async throws -> Void, file: StaticString = #filePath, line: UInt = #line) async {
    do { try await expression(); XCTFail("Expected error", file: file, line: line) } catch {}
}

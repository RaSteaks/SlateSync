import Foundation
import SlateSyncDomain
@testable import SlateSyncWorkflow
import XCTest

private actor BetterProviderTransport: ProviderHTTPTransporting {
    let failingProvider: String?
    let failingBackupProvider: String?
    let canceledProvider: String?
    let malformedFirst: Bool
    let failPageTwoOnce: Bool
    private(set) var calls: [String: Int] = [:]
    private(set) var pageCalls: [Int: Int] = [:]

    init(failingProvider: String? = nil, failingBackupProvider: String? = nil,
         canceledProvider: String? = nil, malformedFirst: Bool = false,
         failPageTwoOnce: Bool = false) {
        self.failingProvider = failingProvider
        self.failingBackupProvider = failingBackupProvider
        self.canceledProvider = canceledProvider
        self.malformedFirst = malformedFirst
        self.failPageTwoOnce = failPageTwoOnce
    }

    func send(_ request: ProviderTransportRequest) throws -> ProviderTransportResponse {
        let id = request.provider.id
        calls[id, default: 0] += 1
        let body = request.body.flatMap { String(data: $0, encoding: .utf8) } ?? ""
        let page = body.contains("第 2/2 页") ? 2 : 1
        pageCalls[page, default: 0] += 1
        if id == canceledProvider { throw RecognitionFailure.canceled }
        if id == failingProvider || id == failingBackupProvider { throw RecognitionFailure.timeout }
        if failPageTwoOnce, page == 2, pageCalls[2] == 1 { throw RecognitionFailure.timeout }
        let content = malformedFirst && calls[id] == 1
            ? "{broken"
            : #"{"records":[{"cardNumber":"A1","videoCode":"C001","scene":"1","shot":"2","take":"3"}],"warnings":[]}"#
        let envelope: JSONValue = .object([
            "choices": .array([.object(["message": .object(["content": .string(content)])])])
        ])
        return .init(status: 200, body: try JSONEncoder().encode(envelope))
    }

    func close() {}
}

private actor BetterProviderProbeTransport: ProviderHTTPTransporting {
    private(set) var modes: [ProviderJSONMode] = []

    func send(_ request: ProviderTransportRequest) throws -> ProviderTransportResponse {
        let body = request.body.flatMap { String(data: $0, encoding: .utf8) } ?? ""
        let mode: ProviderJSONMode = body.contains("json_schema") ? .jsonSchema
            : body.contains("json_object") ? .jsonObject : .prompt
        modes.append(mode)
        if mode == .jsonSchema {
            throw SlateSyncError(code: "PROVIDER_ERROR", message: "response_format json_schema unsupported", status: 400)
        }
        let envelope: JSONValue = .object(["choices": .array([.object([
            "message": .object(["content": .string(#"{"ok":true,"marker":"ss-7q"}"#)])
        ])])])
        return .init(status: 200, body: try JSONEncoder().encode(envelope))
    }

    func close() {}
}

private actor BetterProviderLateTransport: ProviderHTTPTransporting {
    let primaryID: String
    private(set) var primaryCalls = 0
    private(set) var backupCalls = 0

    init(primaryID: String) { self.primaryID = primaryID }

    func send(_ request: ProviderTransportRequest) async throws -> ProviderTransportResponse {
        let card: String
        if request.provider.id == primaryID {
            primaryCalls += 1
            if primaryCalls == 1 {
                try? await Task.sleep(for: .milliseconds(10))
                throw RecognitionFailure.timeout
            }
            // Simulate a transport that still delivers a body after its
            // sibling stage has failed and canceled this attempt.
            try? await Task.sleep(for: .milliseconds(60))
            card = "OLD"
        } else {
            backupCalls += 1
            card = "NEW"
        }
        let text = #"{"records":[{"cardNumber":"\#(card)","videoCode":"C001","scene":"1","shot":"2","take":"3"}],"warnings":[]}"#
        let envelope: JSONValue = .object(["choices": .array([.object([
            "message": .object(["content": .string(text)])
        ])])])
        return .init(status: 200, body: try JSONEncoder().encode(envelope))
    }

    func close() {}
}

final class BetterProviderTests: XCTestCase {
    func testRepairPreservesStringLiteralsAndRejectsAmbiguousObjects() throws {
        let source = "\u{FEFF}```json\n{“records”:[{“description”:“brace {, } and comma , inside”,}],}\n```"
        let result = try TolerantStructuredJSON.decode(source)
        XCTAssertEqual(result.actions, [.removedBOM, .removedMarkdownFence,
            .normalizedStructuralQuotes, .removedTrailingCommas])
        guard case .object(let root) = result.value,
              case .array(let rows)? = root["records"],
              case .object(let row) = rows[0] else { return XCTFail() }
        XCTAssertEqual(row["description"], .string("brace {, } and comma , inside"))
        XCTAssertThrowsError(try TolerantStructuredJSON.decode(#"{"a":1} {"b":2}"#))
        XCTAssertThrowsError(try TolerantStructuredJSON.decode(#"{"a":1"#))
    }

    func testNormalizationReportMarksOnlyNonemptyFailedFields() throws {
        let value: JSONValue = .object(["records": .array([.object([
            "cardNumber": .string("A1"), "videoCode": .string("C9999"),
            "scene": .null, "shot": .string("???"), "take": .string(""),
        ])])])
        var report = RecognitionNormalizationReport()
        let sheet = try RecognitionNormalizer.normalize(value, pageNumber: 1, report: &report)
        XCTAssertEqual(report.degradedFields["record-page-1-0"], ["shot", "videoCode"])
        XCTAssertEqual(sheet.records[0].reviewRequiredFields, ["shot", "videoCode"])
        XCTAssertNil(sheet.records[0].shot)
    }

    func testPresetAndChainInvariants() throws {
        XCTAssertEqual(ProviderPresets.all.count, 11)
        XCTAssertEqual(Set(ProviderPresets.all.map(\.id)).count, 11)
        for preset in ProviderPresets.all {
            XCTAssertNoThrow(try CustomProviderValidator.normalizeBaseURL(preset.baseURL))
            XCTAssertEqual(preset.transport, .chatCompletions)
        }
        let primary = ProviderModelSelection(providerID: "one", modelID: "a")
        let backup = ProviderModelSelection(providerID: "two", modelID: "b")
        XCTAssertEqual(FailoverChain.plan(primary: primary, chain: [primary, backup, backup]), [primary, backup])
        XCTAssertThrowsError(try ProviderModelSelection.decodeAndValidateChain(#"[{"providerID":"two","modelID":"b"},{"providerID":"two","modelID":"b"}]"#))
        XCTAssertEqual(FailoverErrorClassifier.disposition(RecognitionFailure.timeout), .provider)
        XCTAssertEqual(FailoverErrorClassifier.disposition(RecognitionFailure.invalidStructuredJSON), .page)
        XCTAssertEqual(FailoverErrorClassifier.disposition(RecognitionFailure.canceled), .none)
        let explicit = ProviderModelSelection(providerID: "request", modelID: "model-a")
        let project = ProviderModelSelection(providerID: "project", modelID: "model-b")
        let global = GlobalSettingValues([.defaultProviderID: "global", .defaultModelID: "model-c"])
        XCTAssertEqual(try RecognitionRouteResolver.resolve(request: explicit, project: project, global: global), explicit)
        XCTAssertEqual(try RecognitionRouteResolver.resolve(request: nil, project: project, global: global), project)
        XCTAssertEqual(try RecognitionRouteResolver.resolve(request: nil, project: nil, global: global),
            .init(providerID: "global", modelID: "model-c"))
        XCTAssertThrowsError(try RecognitionRouteResolver.resolve(request: nil, project: nil,
            global: .init([.defaultProviderID: "orphan"])))
    }

    func testProbeRecordsEffectiveModeAndRegistryUsesIt() async throws {
        let id = "openai-compatible:123e4567-e89b-42d3-a456-426614174000"
        let original = CustomProviderConfiguration(id: id, name: "Gateway",
            baseUrl: "https://example.com/v1", manualModelIds: ["vision"], revision: 1)
        let registry = ProviderRegistry(customProviders: [original])
        let transport = BetterProviderProbeTransport()
        let probe = ModelCapabilityProbeService(registry: registry,
            client: ProviderRecognitionClient(transport: transport))
        let result = try await probe.probe(providerID: id, modelIDs: ["vision"])
        XCTAssertEqual(result.results[0].jsonMode, .jsonObject)
        let modes = await transport.modes
        XCTAssertEqual(modes, [.jsonSchema, .jsonObject])
        let updated = CustomProviderConfiguration(id: id, name: original.name,
            baseUrl: original.baseUrl, manualModelIds: ["vision"], revision: 1,
            capabilityCache: ["vision": .init(status: .verified, revision: 1,
                jsonMode: result.results[0].jsonMode)])
        await registry.refreshCapabilities(updated)
        let model = try await registry.resolveModel(providerID: id, modelID: "vision")
        XCTAssertEqual(model.jsonMode, .jsonObject)
        await probe.close()
    }

    func testLegacyCompatibleAliasUsesVerifiedCacheMode() async throws {
        let custom = CustomProviderConfiguration(id: "openai-compatible", name: "Legacy",
            baseUrl: "https://example.com/v1", manualModelIds: ["vision"], revision: 2,
            capabilityCache: ["vision": .init(status: .verified, revision: 2,
                jsonMode: .jsonObject)])
        let registry = ProviderRegistry(customProviders: [custom])
        let model = try await registry.resolveModel(providerID: custom.id,
            modelID: "openai-compatible/custom")
        XCTAssertEqual(model.capabilityStatus, .verified)
        XCTAssertEqual(model.jsonMode, .jsonObject)
    }

    func testFailoverStateResetsForNewBatchAndSkipsUnverifiedBackup() async throws {
        let state = RecognitionFailoverState()
        await state.markUnavailable("primary")
        let unavailable = await state.isAvailable("primary")
        XCTAssertFalse(unavailable)
        await state.reset()
        let restored = await state.isAvailable("primary")
        XCTAssertTrue(restored)

        let primaryID = "openai-compatible:123e4567-e89b-42d3-a456-426614174000"
        let backupID = "openai-compatible:123e4567-e89b-42d3-a456-426614174001"
        let primaryConfig = CustomProviderConfiguration(id: primaryID, name: "Primary",
            baseUrl: "https://example.com/v1", manualModelIds: ["vision"], revision: 1,
            capabilityCache: ["vision": .init(status: .verified, revision: 1)])
        let backupConfig = CustomProviderConfiguration(id: backupID, name: "Backup",
            baseUrl: "https://example.com/v1", manualModelIds: ["vision"], revision: 1)
        let registry = ProviderRegistry(customProviders: [primaryConfig, backupConfig])
        let transport = BetterProviderTransport(failingProvider: primaryID)
        let pipeline = RecognitionPagePipeline(client: ProviderRecognitionClient(transport: transport))
        let descriptor = try await registry.descriptor(providerID: primaryID)
        let model = try await registry.resolveModel(providerID: primaryID, modelID: "vision")
        let image = try PreparedImage(jpeg: Data([0xff, 0xd8, 0xff, 0xd9]), width: 1, height: 1)
        let page = RecognitionPageInput(pageNumber: 1,
            views: [.init(viewIndex: 0, viewType: .full, image: image)])
        do {
            _ = try await pipeline.run(pages: [page],
                provider: descriptor, model: model,
                accuracy: .standard, formats: .init(), prompts: ("primary", "audit", "review"),
                filename: "fixture.jpg", candidates: [
                    .init(providerID: primaryID, modelID: "vision"),
                    .init(providerID: backupID, modelID: "vision")
                ], registry: registry, failoverState: state)
            XCTFail("Unverified backup must not dispatch")
        } catch let error as SlateSyncError {
            XCTAssertEqual(error.code, "PROVIDER_FAILOVER_EXHAUSTED")
        }
        let calls = await transport.calls
        XCTAssertNil(calls[backupID])
    }

    func testCancellationNeverFallsBackAndExhaustionHasExplicitMessage() async throws {
        let primaryID = "openai-compatible:123e4567-e89b-42d3-a456-426614174000"
        let backupID = "openai-compatible:123e4567-e89b-42d3-a456-426614174001"
        let configs = [primaryID, backupID].map { id in
            CustomProviderConfiguration(id: id, name: id, baseUrl: "https://example.com/v1",
                manualModelIds: ["vision"], revision: 1,
                capabilityCache: ["vision": .init(status: .verified, revision: 1)])
        }
        let registry = ProviderRegistry(customProviders: configs)
        let provider = try await registry.descriptor(providerID: primaryID)
        let model = try await registry.resolveModel(providerID: primaryID, modelID: "vision")
        let image = try PreparedImage(jpeg: Data([0xff, 0xd8, 0xff, 0xd9]), width: 1, height: 1)
        let page = RecognitionPageInput(pageNumber: 1,
            views: [.init(viewIndex: 0, viewType: .full, image: image)])
        let candidates = [ProviderModelSelection(providerID: primaryID, modelID: "vision"),
            .init(providerID: backupID, modelID: "vision")]

        let canceledTransport = BetterProviderTransport(canceledProvider: primaryID)
        let canceledPipeline = RecognitionPagePipeline(client: ProviderRecognitionClient(transport: canceledTransport))
        do {
            _ = try await canceledPipeline.run(pages: [page], provider: provider, model: model,
                accuracy: .standard, formats: .init(), prompts: ("primary", "audit", "review"),
                filename: "fixture.jpg", candidates: candidates, registry: registry,
                failoverState: RecognitionFailoverState())
            XCTFail("Cancellation must stop the task")
        } catch let error as SlateSyncError {
            XCTAssertEqual(error.code, RecognitionFailure.canceled.code)
        }
        let canceledCalls = await canceledTransport.calls
        XCTAssertNil(canceledCalls[backupID])

        let failedTransport = BetterProviderTransport(failingProvider: primaryID,
            failingBackupProvider: backupID)
        let failedPipeline = RecognitionPagePipeline(client: ProviderRecognitionClient(transport: failedTransport))
        do {
            _ = try await failedPipeline.run(pages: [page], provider: provider, model: model,
                accuracy: .standard, formats: .init(), prompts: ("primary", "audit", "review"),
                filename: "fixture.jpg", candidates: candidates, registry: registry,
                failoverState: RecognitionFailoverState())
            XCTFail("All failed services must leave the task incomplete")
        } catch let error as SlateSyncError {
            XCTAssertEqual(error.code, "PROVIDER_FAILOVER_EXHAUSTED")
            XCTAssertEqual(error.message, "主服务与备用服务均不可用，请稍后重试或检查设置")
        }
    }

    func testStageParsingResendsAtMostOnce() async throws {
        let transport = BetterProviderTransport(malformedFirst: true)
        let client = ProviderRecognitionClient(transport: transport)
        let provider = descriptor("primary")
        let request = try stageRequest(provider)
        let result = try await client.recognizeStructured(request) { value in
            try RecognitionNormalizer.normalize(value, pageNumber: 1)
        }
        XCTAssertEqual(result.value.records.count, 1)
        let count = await transport.calls["primary"]
        XCTAssertEqual(count, 2)
    }

    func testServiceFailureMovesQueuedPagesToVerifiedBackup() async throws {
        let primaryID = "openai-compatible:123e4567-e89b-42d3-a456-426614174000"
        let backupID = "openai-compatible:123e4567-e89b-42d3-a456-426614174001"
        func configuration(_ id: String) -> CustomProviderConfiguration {
            .init(id: id, name: id, baseUrl: "https://example.com/v1",
                manualModelIds: ["vision"], revision: 1,
                capabilityCache: ["vision": .init(status: .verified, revision: 1, jsonMode: .jsonSchema)])
        }
        let registry = ProviderRegistry(customProviders: [configuration(primaryID), configuration(backupID)])
        let primary = try await registry.descriptor(providerID: primaryID)
        let model = try await registry.resolveModel(providerID: primaryID, modelID: "vision")
        let transport = BetterProviderTransport(failingProvider: primaryID)
        let pipeline = RecognitionPagePipeline(client: ProviderRecognitionClient(transport: transport))
        let image = try PreparedImage(jpeg: Data([0xff, 0xd8, 0xff, 0xd9]), width: 1, height: 1)
        let pages = (1...2).map { number in
            RecognitionPageInput(pageNumber: number, views: [.init(viewIndex: 0, viewType: .full, image: image)])
        }
        let output = try await pipeline.run(
            pages: pages, provider: primary, model: model, accuracy: .standard,
            formats: .init(), prompts: ("primary", "audit", "review"), pageConcurrency: 1,
            filename: "fixture.jpg", candidates: [
                .init(providerID: primaryID, modelID: "vision"),
                .init(providerID: backupID, modelID: "vision")
            ], registry: registry, failoverState: RecognitionFailoverState()
        )
        XCTAssertEqual(output.pages.count, 2)
        let calls = await transport.calls
        XCTAssertEqual(calls[primaryID], 1)
        XCTAssertEqual(calls[backupID], 2)
    }

    func testConcurrentProviderFailureDispatchesEachPageOnceOnBackup() async throws {
        let primaryID = "openai-compatible:123e4567-e89b-42d3-a456-426614174000"
        let backupID = "openai-compatible:123e4567-e89b-42d3-a456-426614174001"
        let configs = [primaryID, backupID].map { id in
            CustomProviderConfiguration(id: id, name: id, baseUrl: "https://example.com/v1",
                manualModelIds: ["vision"], revision: 1,
                capabilityCache: ["vision": .init(status: .verified, revision: 1)])
        }
        let registry = ProviderRegistry(customProviders: configs)
        let provider = try await registry.descriptor(providerID: primaryID)
        let model = try await registry.resolveModel(providerID: primaryID, modelID: "vision")
        let transport = BetterProviderTransport(failingProvider: primaryID)
        let image = try PreparedImage(jpeg: Data([0xff, 0xd8, 0xff, 0xd9]), width: 1, height: 1)
        let pages = (1...2).map { number in
            RecognitionPageInput(pageNumber: number,
                views: [.init(viewIndex: 0, viewType: .full, image: image)])
        }
        let output = try await RecognitionPagePipeline(client: ProviderRecognitionClient(transport: transport))
            .run(pages: pages, provider: provider, model: model, accuracy: .standard,
                formats: .init(), prompts: ("primary", "audit", "review"),
                pageConcurrency: 2, filename: "fixture.jpg", candidates: [
                    .init(providerID: primaryID, modelID: "vision"),
                    .init(providerID: backupID, modelID: "vision")
                ], registry: registry, failoverState: RecognitionFailoverState())
        XCTAssertEqual(output.pages.map(\.pageNumber), [1, 2])
        let calls = await transport.calls
        XCTAssertEqual(calls[backupID], 2)
        XCTAssertTrue((1...2).contains(calls[primaryID] ?? 0))
    }

    func testRetryReusesSuccessfulPageWithoutCommittingPartialResult() async throws {
        let provider = descriptor("primary")
        let model = ResolvedModel(publicID: "vision", apiID: "vision", providerID: "primary",
            label: "vision", capabilityStatus: .verified)
        let transport = BetterProviderTransport(failPageTwoOnce: true)
        let pipeline = RecognitionPagePipeline(client: ProviderRecognitionClient(transport: transport))
        let cache = RecognitionRecoveryCache()
        let image = try PreparedImage(jpeg: Data([0xff, 0xd8, 0xff, 0xd9]), width: 1, height: 1)
        let pages = (1...2).map { number in
            RecognitionPageInput(pageNumber: number, views: [.init(viewIndex: 0, viewType: .full, image: image)])
        }
        func run() async throws -> RecognitionPagePipeline.Output {
            try await pipeline.run(pages: pages, provider: provider, model: model,
                accuracy: .standard, formats: .init(), prompts: ("primary", "audit", "review"),
                pageConcurrency: 1, filename: "fixture.jpg", recoveryCache: cache,
                recoveryID: "project:task")
        }
        do { _ = try await run(); XCTFail("First attempt must remain incomplete") }
        catch let error as SlateSyncError { XCTAssertEqual(error.code, RecognitionFailure.timeout.code) }
        let second = try await run()
        XCTAssertEqual(second.pages.count, 2)
        let counts = await transport.pageCalls
        XCTAssertEqual(counts[1], 1)
        XCTAssertEqual(counts[2], 2)
    }

    func testHighAccuracyFailoverRestartsBothStagesOnBackup() async throws {
        let primaryID = "openai-compatible:123e4567-e89b-42d3-a456-426614174000"
        let backupID = "openai-compatible:123e4567-e89b-42d3-a456-426614174001"
        let providers = [primaryID, backupID].map { id in
            CustomProviderConfiguration(id: id, name: id, baseUrl: "https://example.com/v1",
                manualModelIds: ["vision"], revision: 1,
                capabilityCache: ["vision": .init(status: .verified, revision: 1)])
        }
        let registry = ProviderRegistry(customProviders: providers)
        let primary = try await registry.descriptor(providerID: primaryID)
        let model = try await registry.resolveModel(providerID: primaryID, modelID: "vision")
        let transport = BetterProviderTransport(failingProvider: primaryID)
        let pipeline = RecognitionPagePipeline(client: ProviderRecognitionClient(transport: transport))
        let image = try PreparedImage(jpeg: Data([0xff, 0xd8, 0xff, 0xd9]), width: 1, height: 1)
        let page = RecognitionPageInput(pageNumber: 1, views: [
            .init(viewIndex: 0, viewType: .full, image: image),
            .init(viewIndex: 1, viewType: .coreDetail, image: image),
        ])
        let result = try await pipeline.run(pages: [page], provider: primary, model: model,
            accuracy: .high, formats: .init(), prompts: ("primary", "audit", "review"),
            filename: "fixture.jpg", candidates: [
                .init(providerID: primaryID, modelID: "vision"),
                .init(providerID: backupID, modelID: "vision")
            ], registry: registry, failoverState: RecognitionFailoverState())
        XCTAssertEqual(result.stageCount, 2)
        let calls = await transport.calls
        XCTAssertEqual(calls[backupID], 2)
        XCTAssertEqual(result.pages.count, 1)
    }

    func testLateOldStageCannotOverwriteCompletedBackupPage() async throws {
        let primaryID = "openai-compatible:123e4567-e89b-42d3-a456-426614174000"
        let backupID = "openai-compatible:123e4567-e89b-42d3-a456-426614174001"
        let configs = [primaryID, backupID].map { id in
            CustomProviderConfiguration(id: id, name: id, baseUrl: "https://example.com/v1",
                manualModelIds: ["vision"], revision: 1,
                capabilityCache: ["vision": .init(status: .verified, revision: 1)])
        }
        let registry = ProviderRegistry(customProviders: configs)
        let provider = try await registry.descriptor(providerID: primaryID)
        let model = try await registry.resolveModel(providerID: primaryID, modelID: "vision")
        let transport = BetterProviderLateTransport(primaryID: primaryID)
        let image = try PreparedImage(jpeg: Data([0xff, 0xd8, 0xff, 0xd9]), width: 1, height: 1)
        let page = RecognitionPageInput(pageNumber: 1, views: [
            .init(viewIndex: 0, viewType: .full, image: image),
            .init(viewIndex: 1, viewType: .coreDetail, image: image),
        ])
        let output = try await RecognitionPagePipeline(client: ProviderRecognitionClient(transport: transport))
            .run(pages: [page], provider: provider, model: model, accuracy: .high,
                formats: .init(), prompts: ("primary", "audit", "review"),
                filename: "fixture.jpg", candidates: [
                    .init(providerID: primaryID, modelID: "vision"),
                    .init(providerID: backupID, modelID: "vision")
                ], registry: registry, failoverState: RecognitionFailoverState())
        XCTAssertEqual(output.result.records.first?.cardNumber, "NEW")
        XCTAssertEqual(output.pages.count, 1)
        let backupCalls = await transport.backupCalls
        XCTAssertEqual(backupCalls, 2)
    }

    private func descriptor(_ id: String) -> ProviderDescriptor {
        .init(id: id, label: id, origin: .custom,
            baseURL: URL(string: "https://example.com/v1")!,
            transport: .chatCompletions, credentialRequired: false)
    }

    private func stageRequest(_ provider: ProviderDescriptor) throws -> RecognitionStageRequest {
        let image = try PreparedImage(jpeg: Data([0xff, 0xd8, 0xff, 0xd9]), width: 1, height: 1)
        let model = ResolvedModel(publicID: "vision", apiID: "vision", providerID: provider.id,
            label: "vision", capabilityStatus: .verified)
        return .init(provider: provider, model: model, stage: .primary,
            filename: "fixture.jpg", images: [image], systemPrompt: "JSON",
            schema: RecognitionSchemas.full)
    }
}

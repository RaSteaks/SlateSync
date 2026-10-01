import Foundation
import SlateSyncDomain
import SlateSyncPersistence
@testable import SlateSyncWorkflow
import XCTest

/// Exercise curated discovery and explicit user probes through the production registry and persistence.
/// All model responses and data roots are synthetic; no external API or user credentials are used.
@MainActor
final class OpenRouterCatalogTests: XCTestCase {
    private let curated: Set<String> = ["qwen/qwen3.7-flash", "openai/gpt-5.6-luna", "openai/gpt-5.6-terra"]
    private let manualID = "example/manual-vision"

    func testOpenRouterDefaultsContainOnlyRequestedModelsWithoutChangingOpenAI() {
        XCTAssertEqual(Set(ProviderCatalog.fixedModels(providerID: "openrouter").map(\.id)), curated)
        XCTAssertTrue(ProviderCatalog.fixedModels(providerID: "openai").contains { $0.apiId == "gpt-4o-mini" })
    }

    func testDiscoveryDoesNotAutomaticallyAddOtherOpenRouterModels() async throws {
        let registry = ProviderRegistry()
        let discovery = ModelDiscoveryService(registry: registry, transport: ReviewCatalogTransport())
        let result = try await discovery.discover(providerID: "openrouter", forceRefresh: true)
        XCTAssertEqual(Set((result.models + (result.pendingModels ?? [])).map(\.id)), curated)
        XCTAssertEqual(result.unsupportedModels?.isEmpty, true, "Excluded catalog entries must not flood the setup list")
        let projected = await registry.publicModels().filter { $0.providers == ["openrouter"] }
        XCTAssertEqual(Set(projected.map(\.id)), curated)
        do {
            _ = try await registry.resolveModel(providerID: "openrouter", modelID: manualID)
            XCTFail("A directory entry alone must not admit an additional OpenRouter model")
        } catch { XCTAssertEqual((error as? SlateSyncError)?.code, RecognitionFailure.unsupportedModel.code) }
    }

    func testManualProbeSupportsRecognitionDiscoveryRefreshAndRestart() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "openrouter-manual-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let facade = makeFacade(root: root, transport: ReviewCatalogTransport())
        let probe = try await facade.probeModels(providerID: "openrouter", modelIDs: [manualID], progress: { _ in })
        XCTAssertEqual(probe.results.first?.capabilityStatus, .verified)
        _ = try await facade.saveGlobalSettings(values: .init([
            .defaultProviderID: "openrouter", .defaultModelID: manualID,
            .visionOCREnabled: "false", .paddleOCREnabled: "false"]), customProviders: [])
        _ = try await facade.discoverModels(providerID: "openrouter", forceRefresh: true)
        try await facade.drain()

        // A manual model is restored from its committed proof, not a transient /models response.
        let restarted = makeFacade(root: root, transport: ReviewCatalogTransport())
        let registry = try await restarted.modelRegistry()
        let resolved = try await registry.resolveModel(providerID: "openrouter", modelID: manualID)
        XCTAssertEqual(resolved.capabilityStatus, .verified)
        let projection = try await restarted.globalSettings()
        XCTAssertEqual(projection.values[.defaultModelID], manualID)
        XCTAssertTrue(projection.models.contains { $0.id == manualID && $0.capabilityStatus == .verified })
        let project = try await restarted.createProject(name: "Manual model review", description: "")
        let task = try await restarted.saveTask(projectID: project.id, taskID: nil, task: .init(status: "draft"))
        let image = try PreparedImage(jpeg: Data([0xff, 0xd8, 0xff, 0xd9]), width: 1, height: 1)
        let document = PreparedDocument(filename: "review.jpg", pages: [
            .init(pageNumber: 1, views: [.init(viewIndex: 0, viewType: .full, image: image)])])
        var settings = ProjectSettings()
        settings.accuracyMode = .standard
        let recognition = try await restarted.recognize(.init(projectID: project.id,
            input: .bytes(image.jpeg, filename: document.filename), filename: document.filename,
            taskID: task, providerID: "openrouter", modelID: manualID,
            settings: settings, preparedDocument: document))
        XCTAssertEqual(recognition.model, manualID)
        try await restarted.drain()
    }

    func testFailedManualProbeCannotBecomeUsableAfterDiscoveryRefresh() async throws {
        let registry = ProviderRegistry()
        let transport = ReviewCatalogTransport(failsProbe: true)
        let client = ProviderRecognitionClient(transport: transport)
        let probe = ModelCapabilityProbeService(registry: registry, client: client)
        let result = try await probe.probe(providerID: "openrouter", modelIDs: [manualID])
        XCTAssertEqual(result.results.first?.capabilityStatus, .failed)
        let discovery = ModelDiscoveryService(registry: registry, transport: transport)
        _ = try await discovery.discover(providerID: "openrouter", forceRefresh: true)
        do {
            _ = try await registry.resolveModel(providerID: "openrouter", modelID: manualID)
            XCTFail("Remote vision metadata cannot replace a failed explicit probe")
        } catch { XCTAssertEqual((error as? SlateSyncError)?.code, RecognitionFailure.unsupportedModel.code) }
    }

    func testCustomEndpointStillDiscoversAdditionalModels() async throws {
        let provider = try CustomProviderValidator.normalizeRequest(.init(name: "Custom review",
            baseUrl: "https://openrouter.ai/api/v1"))
        let registry = ProviderRegistry(customProviders: [provider])
        let discovery = ModelDiscoveryService(registry: registry, transport: ReviewCatalogTransport())
        let result = try await discovery.discover(providerID: provider.id)
        XCTAssertTrue((result.models + (result.pendingModels ?? [])).contains { $0.id == manualID })
    }

    private func makeFacade(root: URL, transport: ReviewCatalogTransport) -> SlateSyncWorkflowFacade {
        let locator = ApplicationSupportLocator(root: root)
        let runtime = SlateSyncRuntime(locator: locator, environment: [:])
        let library = ProjectLibraryStartupService(locator: locator, machineSettings: runtime.machineSettingsStore,
            environment: [:], forceIsolatedRoot: true)
        return SlateSyncWorkflowFacade(library: library, runtime: runtime,
            logs: LocalLogStore(directory: root.appending(path: "logs")),
            paddleInstaller: PaddleOCRInstallerService(userDataRoot: root, requirementsURL: root.appending(path: "unused.txt")),
            providerTransportFactory: { transport })
    }
}

private struct ReviewCatalogTransport: ProviderHTTPTransporting {
    var failsProbe = false

    func send(_ request: ProviderTransportRequest) async throws -> ProviderTransportResponse {
        if request.method == .get {
            let ids = ["qwen/qwen3.7-flash", "openai/gpt-5.6-luna", "openai/gpt-5.6-terra",
                "openai/gpt-4o-mini", "example/manual-vision"]
            let entries = ids.map { id in JSONValue.object(["id": .string(id), "architecture": .object([
                "input_modalities": .array([.string("image"), .string("text")]),
                "output_modalities": .array([.string("text")])])]) }
            return .init(status: 200, body: try JSONEncoder().encode(JSONValue.object(["data": .array(entries)])))
        }
        let content = request.purpose == .probe
            ? (failsProbe ? #"{"ok":false,"marker":"wrong"}"# : #"{"ok":true,"marker":"ss-7q"}"#)
            : #"{"sheetTitle":"Review","records":[],"warnings":[]}"#
        return .init(status: 200, body: try JSONEncoder().encode(JSONValue.object([
            "choices": .array([.object(["message": .object(["content": .string(content)])])])])))
    }

    func close() async {}
}

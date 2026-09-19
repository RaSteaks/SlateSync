import Foundation
import SlateSyncDomain
import SlateSyncPersistence
@testable import SlateSyncWorkflow
import XCTest

/// Real façade composition with synthetic HTTP and a secret-free Keychain.
/// No provider, login Keychain, model download or production library is used.
@MainActor
final class ModelCatalogIntegrationTests: XCTestCase {
    func testDiscoveryAndProbeReachAnAlreadyCreatedRecognitionCoordinator() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "catalog-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let locator = ApplicationSupportLocator(root: root)
        let runtime = SlateSyncRuntime(locator: locator, environment: [:], keychainBackend: EmptyCatalogKeychain())
        let library = ProjectLibraryStartupService(locator: locator, machineSettings: runtime.machineSettingsStore,
            environment: [:], forceIsolatedRoot: true)
        let transport = CatalogTransport()
        let facade = SlateSyncWorkflowFacade(library: library, runtime: runtime,
            logs: LocalLogStore(directory: root.appending(path: "logs")),
            paddleInstaller: PaddleOCRInstallerService(userDataRoot: root,
                requirementsURL: root.appending(path: "unused.txt")),
            providerTransportFactory: { transport })
        let provider = try CustomProviderValidator.normalizeRequest(.init(name: "Offline catalog",
            baseUrl: "https://example.invalid/v1", manualModelIds: ["probe-vision"]))
        _ = try await facade.saveGlobalSettings(values: .init([.visionOCREnabled: "false", .paddleOCREnabled: "false"]),
            customProviders: [provider])
        let project = try await facade.createProject(name: "Offline", description: "")
        let taskID = try await facade.saveTask(projectID: project.id, taskID: nil, task: TaskData(status: "draft"))
        // Force coordinator construction before either catalog update. Its
        // retained registry must observe subsequent discovery and probe results.
        let stream = await facade.recognitionProgress(projectID: project.id)
        let observer = Task { for await _ in stream {} }
        let before = try await facade.modelRegistry()
        let discovered = try await facade.discoverModels(providerID: provider.id, forceRefresh: true)
        XCTAssertTrue(discovered.models.contains { $0.id == "remote-vision" })
        var projection = try await facade.globalSettings()
        XCTAssertTrue(projection.models.contains { $0.id == "remote-vision" && $0.verifiedAvailable == true })

        let image = try PreparedImage(jpeg: Data([0xff, 0xd8, 0xff, 0xd9]), width: 1, height: 1)
        let document = PreparedDocument(filename: "offline.jpg", pages: [
            .init(pageNumber: 1, views: [.init(viewIndex: 0, viewType: .full, image: image)])
        ])
        func request(_ model: String) -> NativeRecognitionRequest {
            var settings = ProjectSettings()
            settings.accuracyMode = .standard
            return .init(projectID: project.id, input: .bytes(image.jpeg, filename: document.filename),
                filename: document.filename, taskID: taskID, providerID: provider.id, modelID: model,
                settings: settings, preparedDocument: document)
        }
        let remote = try await facade.recognize(request("remote-vision"))
        XCTAssertEqual(remote.model, "remote-vision")
        let probe = try await facade.probeModels(providerID: provider.id, modelIDs: ["probe-vision"], progress: { _ in })
        XCTAssertEqual(probe.results.first?.capabilityStatus, .verified)
        projection = try await facade.globalSettings()
        XCTAssertTrue(projection.models.contains { $0.id == "probe-vision" && $0.verifiedAvailable == true })
        XCTAssertTrue(projection.models.contains { $0.id == "remote-vision" && $0.verifiedAvailable == true })
        let after = try await facade.modelRegistry()
        XCTAssertTrue(before === after)
        let verified = try await facade.recognize(request("probe-vision"))
        XCTAssertEqual(verified.model, "probe-vision")

        // A later failed probe revokes eligibility for the same cached owner.
        await transport.failProbe()
        _ = try await facade.probeModels(providerID: provider.id, modelIDs: ["probe-vision"], progress: { _ in })
        do {
            _ = try await before.resolveModel(providerID: provider.id, modelID: "probe-vision")
            XCTFail("Failed verification must revoke the cached model")
        } catch { XCTAssertEqual((error as? SlateSyncError)?.code, "MODEL_UNSUPPORTED") }
        observer.cancel()
        await observer.value
        try await facade.drain()
    }

    func testCanceledDiscoveryDoesNotEraseSharedRegistration() async throws {
        let provider = try CustomProviderValidator.normalizeRequest(.init(name: "Canceled discovery",
            baseUrl: "https://example.invalid/v1"))
        let registry = ProviderRegistry(customProviders: [provider])
        let model = ResolvedModel(publicID: "remote", apiID: "remote", providerID: provider.id,
            label: "remote", revision: provider.revision)
        await registry.register([model], providerID: provider.id, revision: provider.revision)
        let discovery = ModelDiscoveryService(registry: registry, transport: CanceledDiscoveryTransport())
        do {
            _ = try await discovery.discover(providerID: provider.id)
            XCTFail("A canceled discovery must not publish fallback success")
        } catch { XCTAssertEqual((error as? SlateSyncError)?.code, RecognitionFailure.canceled.code) }
        let retained = try await registry.resolveModel(providerID: provider.id, modelID: "remote")
        XCTAssertEqual(retained, model)
    }

    func testOldBuiltinGenerationCannotRegisterAfterConfigurationChange() async throws {
        let registry = ProviderRegistry()
        let generation = await registry.currentGeneration()
        let model = ResolvedModel(publicID: "dynamic", apiID: "dynamic", providerID: "openrouter", label: "dynamic")
        await registry.replace(settings: .init([.openRouterBaseUrl: "https://example.invalid/v1"]), customProviders: [])
        // Built-in revisions are nil on both sides, so revision equality alone
        // cannot reject this response from the previous endpoint.
        await registry.register([model], providerID: "openrouter", revision: nil, generation: generation)
        do {
            _ = try await registry.resolveModel(providerID: "openrouter", modelID: "dynamic")
            XCTFail("Old endpoint registration must be rejected")
        } catch { XCTAssertEqual((error as? SlateSyncError)?.code, "MODEL_UNSUPPORTED") }
    }
}

private actor CatalogTransport: ProviderHTTPTransporting {
    private var probeFails = false
    func failProbe() { probeFails = true }
    func send(_ request: ProviderTransportRequest) async throws -> ProviderTransportResponse {
        if request.method == .get {
            return .init(status: 200, body: Data(#"{"data":[{"id":"remote-vision","architecture":{"input_modalities":["image","text"],"output_modalities":["text"]}}]}"#.utf8))
        }
        let content = request.purpose == .probe
            ? (probeFails ? #"{"ok":false,"marker":"wrong"}"# : #"{"ok":true,"marker":"ss-7q"}"#)
            : #"{"sheetTitle":"offline","records":[],"warnings":[]}"#
        return .init(status: 200, body: try JSONEncoder().encode(JSONValue.object([
            "choices": .array([.object(["message": .object(["content": .string(content)])])])
        ])))
    }
    // The fixture factory reuses a stateless transport across runtime rebuilds.
    func close() async {}
}

private struct EmptyCatalogKeychain: KeychainBackend {
    func status(service: String, account: String) async -> CredentialStatus { .missing }
    func read(service: String, account: String) async throws -> Data? { nil }
    func write(_ data: Data, service: String, account: String) async throws { throw CancellationError() }
    func createIfAbsent(_ data: Data, service: String, account: String) async throws -> KeychainCreateResult { throw CancellationError() }
    func delete(service: String, account: String) async throws { throw CancellationError() }
    func deleteIfMatching(_ expected: Data, service: String, account: String, ownership: Data?) async throws -> KeychainConditionalDeleteResult { .notFound }
}

private struct CanceledDiscoveryTransport: ProviderHTTPTransporting {
    func send(_ request: ProviderTransportRequest) async throws -> ProviderTransportResponse { throw RecognitionFailure.canceled }
    func close() async {}
}

import Foundation
import SlateSyncDomain
import SlateSyncPersistence
@testable import SlateSyncWorkflow
import XCTest

/// Exercise the real persistence/facade boundary with offline HTTP and Keychain.
@MainActor
final class BuiltinProviderCapabilityTests: XCTestCase {
    func testSequentialProbesKeepAliasesAndSurviveDiscoveryAndRestart() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "builtin-proofs-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let transport = BuiltinProofTransport()
        let facade = makeFacade(root: root, transport: transport)
        _ = try await facade.probeModels(providerID: "openai", modelIDs: ["gpt-4o-mini"], progress: { _ in })
        _ = try await facade.probeModels(providerID: "openai", modelIDs: ["gpt-5.6-luna"], progress: { _ in })
        let registry = try await facade.modelRegistry()
        try await assertVerifiedAliases(registry)
        // Refreshing /models must not downgrade explicit probe results.
        _ = try await facade.discoverModels(providerID: "openai", forceRefresh: true)
        try await assertVerifiedAliases(registry)
        let chain = try ProviderModelSelection.encodeChain([
            .init(providerID: "openai", modelID: "openai/gpt-5.6-luna")])
        _ = try await facade.saveGlobalSettings(values: .init([
            .defaultProviderID: "openai", .defaultModelID: "openai/gpt-4o-mini",
            .recognitionFailoverChain: chain]), customProviders: [])
        try await facade.drain()

        // Rebuild every owner from disk; no new probe is performed.
        let restarted = makeFacade(root: root, transport: BuiltinProofTransport())
        try await assertVerifiedAliases(try await restarted.modelRegistry())
        let projection = try await restarted.globalSettings()
        XCTAssertEqual(projection.values[.defaultModelID], "openai/gpt-4o-mini")
        XCTAssertEqual(projection.values[.recognitionFailoverChain], chain)
        try await restarted.drain()
    }

    func testFailedReprobeRevokesOnlyTargetModelAndPersists() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "builtin-negative-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let transport = BuiltinProofTransport()
        let facade = makeFacade(root: root, transport: transport)
        _ = try await facade.probeModels(providerID: "openai", modelIDs: ["gpt-4o-mini", "gpt-5.6-luna"], progress: { _ in })
        await transport.failProbes()
        _ = try await facade.probeModels(providerID: "openai", modelIDs: ["gpt-4o-mini"], progress: { _ in })
        try await facade.drain()
        let restarted = makeFacade(root: root, transport: BuiltinProofTransport())
        let registry = try await restarted.modelRegistry()
        do {
            _ = try await registry.resolveModel(providerID: "openai", modelID: "openai/gpt-4o-mini")
            XCTFail("A failed proof must not fall back to catalog declarations")
        } catch { XCTAssertEqual((error as? SlateSyncError)?.code, RecognitionFailure.unsupportedModel.code) }
        let other = try await registry.resolveModel(providerID: "openai", modelID: "openai/gpt-5.6-luna")
        XCTAssertEqual(other.capabilityStatus, .verified)
        let models = await registry.publicModels()
        XCTAssertEqual(models.first { $0.providers == ["openai"] && $0.apiId == "gpt-4o-mini" }?.capabilityStatus, .failed)
        try await restarted.drain()
    }

    func testRouteAndCredentialChangesInvalidateDurableProofs() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "builtin-invalidate-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let facade = makeFacade(root: root, transport: BuiltinProofTransport())
        _ = try await facade.probeModels(providerID: "openai", modelIDs: ["gpt-4o-mini"], progress: { _ in })
        _ = try await facade.saveGlobalSettings(values: .init([.openAIBaseUrl: "https://other.invalid/v1"]), customProviders: [])
        // Switching back must not resurrect the original proof.
        _ = try await facade.saveGlobalSettings(values: .init(), customProviders: [])
        let registry = try await facade.modelRegistry()
        let invalidated = try await registry.resolveModel(providerID: "openai", modelID: "gpt-4o-mini")
        XCTAssertEqual(invalidated.capabilityStatus, .declared)
        _ = try await facade.probeModels(providerID: "openai", modelIDs: ["gpt-4o-mini"], progress: { _ in })
        do {
            try await facade.setProviderCredential("synthetic", providerID: "openai")
            XCTFail("The offline Keychain rejects writes")
        } catch { /* Even denied credential writes revoke proofs before mutation. */ }
        try await facade.drain()
        let restarted = makeFacade(root: root, transport: BuiltinProofTransport())
        let model = try await restarted.modelRegistry().resolveModel(providerID: "openai", modelID: "gpt-4o-mini")
        XCTAssertEqual(model.capabilityStatus, .declared)
        try await restarted.drain()
    }

    func testRestoredProofRejectsChangedRuntimeRouteAndLatePublication() async throws {
        let original = ProviderRegistry(settings: .init([.openRouterAppTitle: "Original"]))
        let provider = try await original.descriptor(providerID: "openrouter")
        let generation = await original.currentGeneration()
        let result = ModelCapabilityProbeResult(supported: true, model: "openai/gpt-4o-mini",
            transport: provider.transport, checkedAt: "offline", message: "verified",
            capabilityStatus: .verified, jsonMode: .jsonObject)
        let pending = await original.mergingBuiltinProbeResults(provider: provider,
            results: [result], generation: generation)
        let proof = try XCTUnwrap(pending)
        let changed = GlobalSettingValues([.openRouterAppTitle: "Changed"])
        // Environment-derived headers are absent from persisted overrides but
        // must still fence restored and in-flight proofs by effective route.
        let restarted = ProviderRegistry(settings: changed, builtinCapabilities: ["openrouter": proof])
        let cold = try await restarted.resolveModel(providerID: "openrouter", modelID: result.model)
        XCTAssertEqual(cold.capabilityStatus, .declared)
        await original.replace(settings: changed, customProviders: [])
        await original.restoreBuiltinCapabilities(proof, generation: generation)
        let late = try await original.resolveModel(providerID: "openrouter", modelID: result.model)
        XCTAssertEqual(late.capabilityStatus, .declared)
    }

    private func assertVerifiedAliases(_ registry: ProviderRegistry) async throws {
        for apiID in ["gpt-4o-mini", "gpt-5.6-luna"] {
            let direct = try await registry.resolveModel(providerID: "openai", modelID: apiID)
            let alias = try await registry.resolveModel(providerID: "openai", modelID: "openai/" + apiID)
            XCTAssertEqual(direct, alias)
            XCTAssertEqual(alias.capabilityStatus, .verified)
            XCTAssertEqual(alias.jsonMode, .jsonObject)
            let models = await registry.publicModels().filter { $0.providers == ["openai"] && $0.apiId == apiID }
            XCTAssertEqual(models.count, 1)
            XCTAssertEqual(models.first?.id, "openai/" + apiID)
            XCTAssertEqual(models.first?.capabilityStatus, .verified)
        }
    }

    private func makeFacade(root: URL, transport: BuiltinProofTransport) -> SlateSyncWorkflowFacade {
        let locator = ApplicationSupportLocator(root: root)
        let runtime = SlateSyncRuntime(locator: locator, environment: [:], keychainBackend: ProofKeychain())
        let library = ProjectLibraryStartupService(locator: locator, machineSettings: runtime.machineSettingsStore,
            environment: [:], forceIsolatedRoot: true)
        return SlateSyncWorkflowFacade(library: library, runtime: runtime,
            logs: LocalLogStore(directory: root.appending(path: "logs")),
            paddleInstaller: PaddleOCRInstallerService(userDataRoot: root, requirementsURL: root.appending(path: "unused.txt")),
            providerTransportFactory: { transport })
    }
}

private actor BuiltinProofTransport: ProviderHTTPTransporting {
    private var failed = false
    func failProbes() { failed = true }
    func send(_ request: ProviderTransportRequest) throws -> ProviderTransportResponse {
        if request.method == .get {
            return .init(status: 200, body: Data(#"{"data":[{"id":"gpt-4o-mini"},{"id":"gpt-5.6-luna"}]}"#.utf8))
        }
        if String(data: request.body ?? Data(), encoding: .utf8)?.contains("json_schema") == true {
            throw RecognitionFailure.provider(message: "response_format json_schema unsupported", status: 400)
        }
        let content = failed ? #"{"ok":false,"marker":"wrong"}"# : #"{"ok":true,"marker":"ss-7q"}"#
        let envelope: JSONValue = request.provider.transport == .responses
            ? .object(["output_text": .string(content)])
            : .object(["choices": .array([.object(["message": .object(["content": .string(content)])])])])
        return .init(status: 200, body: try JSONEncoder().encode(envelope))
    }
    func close() {}
}

private struct ProofKeychain: KeychainBackend {
    func status(service: String, account: String) async -> CredentialStatus { .missing }
    func read(service: String, account: String) async throws -> Data? { nil }
    func write(_ data: Data, service: String, account: String) async throws { throw CancellationError() }
    func createIfAbsent(_ data: Data, service: String, account: String) async throws -> KeychainCreateResult { throw CancellationError() }
    func delete(service: String, account: String) async throws { throw CancellationError() }
    func deleteIfMatching(_ expected: Data, service: String, account: String, ownership: Data?) async throws -> KeychainConditionalDeleteResult { .notFound }
}

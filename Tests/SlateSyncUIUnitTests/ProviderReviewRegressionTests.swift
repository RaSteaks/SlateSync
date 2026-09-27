import SlateSyncDomain
@testable import SlateSyncUI
import XCTest

/// Reproduce review findings with deterministic asynchronous boundaries, never real service requests.
@MainActor
final class ProviderReviewRegressionTests: XCTestCase {
    func testExplicitUnsupportedWinsOverStaticCatalog() {
        let model = ModelData(id: "openai/vision", label: "Vision", description: "", providers: ["openai"],
            apiId: "vision", fixed: true, capabilityStatus: .declared)
        let result = ModelDiscoveryResult(provider: "openai", source: .api, refreshedAt: "", availableModelCount: 1,
            visionModelCount: 0, fixedModelCount: 0, models: [],
            unsupportedModels: [.init(id: "vision", reason: "Text only", capabilityStatus: .unsupported)])
        let displayed = ProviderPresentation.models(providerID: "openai", snapshot: reviewProjection(models: [model]), discovery: result)
        XCTAssertEqual(displayed.first?.capabilityStatus, .unsupported)
        XCTAssertEqual(displayed.first?.apiId, "vision")
        XCTAssertEqual(displayed.first?.id, model.id, "Retain the public alias even when discovery rejects the physical model")
    }

    func testUnsupportedManualModelNeedsActualProofToOverrideDiscovery() {
        let custom = reviewCustom(status: nil)
        let result = ModelDiscoveryResult(provider: custom.id, source: .api, refreshedAt: "", availableModelCount: 1,
            visionModelCount: 0, fixedModelCount: 0, models: [],
            unsupportedModels: [.init(id: "vision", reason: "Text only", capabilityStatus: .unsupported)])
        let unverified = ProviderPresentation.models(providerID: custom.id,
            snapshot: reviewProjection(custom: custom), discovery: result)
        XCTAssertEqual(unverified.first?.capabilityStatus, .unsupported)
        let verified = ProviderPresentation.models(providerID: custom.id,
            snapshot: reviewProjection(custom: reviewCustom(status: .verified)), discovery: result)
        XCTAssertEqual(verified.first?.capabilityStatus, .verified)
    }

    func testDiscoveryClearsTransientProbeFeedbackButKeepsProof() async throws {
        let service = ReviewSettingsFake()
        let model = GlobalSettingsModel(service: service)
        await model.load()
        _ = await model.probe(providerID: "openai", modelIDs: ["vision"])
        XCTAssertNotNil(model.probeResults["openai"])
        _ = await model.discover(providerID: "openai")
        XCTAssertNil(model.probeResults["openai"], "Latest discovery must not be hidden by an old green probe summary")
        XCTAssertEqual(model.discoveryResults["openai"]?.source, .staticFallback)
        XCTAssertTrue(ProviderPresentation.isVerified(.init(providerID: "openai", modelID: "openai/vision"), in: try XCTUnwrap(model.live)))
        await service.blockNextDiscovery()
        let request = Task { await model.discover(providerID: "openai") }
        await service.waitForDiscovery()
        await model.cancelProbe(providerID: "openai")
        _ = await request.value
        XCTAssertNil(model.probeResults["openai"])
        XCTAssertEqual(model.providerOperations["openai"], .canceled)
    }

    func testCredentialFailureAndRefreshRetryCanRestoreOriginalRoles() async throws {
        for failWrite in [true, false] {
            let service = ReviewSettingsFake()
            let model = GlobalSettingsModel(service: service)
            await model.load()
            let original = ProviderSelections(try XCTUnwrap(model.live).values)
            // This is the same pre-mutation baseline retained by the editor.
            let expected = original.removing("openai")
            await service.configureCredentialFailure(write: failWrite, refresh: !failWrite)
            let first = await model.saveBuiltinProviderConfiguration(providerID: "openai", values: [:], apiKey: "synthetic")
            XCTAssertTrue(first.configurationSaved)
            XCTAssertFalse(first.isComplete)
            XCTAssertEqual(first.credentialSaved, !failWrite)
            await service.configureCredentialFailure(write: false)
            if failWrite {
                let retried = await model.saveBuiltinProviderConfiguration(providerID: "openai", values: [:], apiKey: "synthetic")
                XCTAssertTrue(retried.isComplete)
            } else {
                let refreshed = await model.refresh()
                XCTAssertTrue(refreshed)
            }
            _ = await model.probe(providerID: "openai", modelIDs: ["vision"])
            let restored = await model.commitProviderChange(.restore(providerID: "openai", original: original, expected: expected))
            XCTAssertTrue(restored)
            XCTAssertEqual(ProviderSelections(try XCTUnwrap(model.live).values), original)
            let writes = await service.keyWrites
            XCTAssertEqual(writes, failWrite ? 2 : 1, "Refreshing a successful key write never re-submits its secret")
        }
    }

    func testCustomCredentialWriteFailureRetainsRecoverableRoles() async throws {
        let service = ReviewSettingsFake()
        await service.useCustomAsDefault()
        let model = GlobalSettingsModel(service: service)
        await model.load()
        let old = try XCTUnwrap(model.live?.customProviders.first)
        let original = ProviderSelections(try XCTUnwrap(model.live).values)
        let expected = original.removing(old.id)
        await service.configureCredentialFailure(write: true)
        let first = await model.saveCustomProviderConfiguration(existing: old, name: old.name, baseURL: old.baseUrl,
            modelIDs: "vision", transport: old.transport, jsonMode: old.jsonMode, imageDetail: old.imageDetail,
            notes: nil, sourcePresetID: nil, apiKey: "synthetic")
        XCTAssertTrue(first.configurationSaved); XCTAssertFalse(first.credentialSaved)
        XCTAssertNil(ProviderSelections(try XCTUnwrap(model.live).values).primary)
        await service.configureCredentialFailure(write: false)
        let current = try XCTUnwrap(model.live?.customProviders.first)
        let retried = await model.saveCustomProviderConfiguration(existing: current, name: current.name, baseURL: current.baseUrl,
            modelIDs: "vision", transport: current.transport, jsonMode: current.jsonMode, imageDetail: current.imageDetail,
            notes: nil, sourcePresetID: nil, apiKey: "synthetic")
        XCTAssertTrue(retried.isComplete)
        _ = await model.probe(providerID: old.id, modelIDs: ["vision"])
        let restored = await model.commitProviderChange(.restore(providerID: old.id, original: original, expected: expected))
        XCTAssertTrue(restored)
        XCTAssertEqual(ProviderSelections(try XCTUnwrap(model.live).values), original)
    }

    func testFailedCredentialRemovalRefreshesCommittedRevocation() async throws {
        let service = ReviewSettingsFake()
        let model = GlobalSettingsModel(service: service)
        await model.load()
        _ = await model.probe(providerID: "openai", modelIDs: ["vision"])
        await service.configureCredentialFailure(write: true)
        do { try await model.removeProviderCredential(providerID: "openai"); XCTFail("Synthetic deletion must fail") }
        catch { XCTAssertEqual((error as? SlateSyncError)?.code, "KEY_FAILURE") }
        XCTAssertNil(ProviderSelections(try XCTUnwrap(model.live).values).primary)
        XCTAssertNil(model.probeResults["openai"])
        XCTAssertFalse(ProviderPresentation.isVerified(.init(providerID: "openai", modelID: "openai/vision"), in: try XCTUnwrap(model.live)))
    }

    func testRestorationBaselineDoesNotOverwriteInterveningRoleChange() async throws {
        let original = ProviderSelections(.init([.defaultProviderID: "openai", .defaultModelID: "openai/vision"]))
        let expected = original.removing("openai")
        let changed = reviewProjection(values: .init([.defaultProviderID: "openrouter", .defaultModelID: "another-model"]))
        XCTAssertThrowsError(try ProviderSelectionChange.restore(providerID: "openai", original: original, expected: expected).applying(to: changed)) { error in
            XCTAssertEqual((error as? SlateSyncError)?.code, "PROVIDER_SELECTION_CHANGED")
        }
    }

    func testMissingKeyGatePreservesAnonymousCustomEndpoints() {
        XCTAssertFalse(ProviderPresentation.canUseModels(requiresCredential: true, hasSavedCredential: false))
        XCTAssertFalse(ProviderPresentation.canUseModels(requiresCredential: true, hasSavedCredential: false, draftKey: "  "))
        XCTAssertTrue(ProviderPresentation.canUseModels(requiresCredential: true, hasSavedCredential: false, draftKey: "synthetic"))
        XCTAssertTrue(ProviderPresentation.canUseModels(requiresCredential: true, hasSavedCredential: true))
        XCTAssertTrue(ProviderPresentation.canUseModels(requiresCredential: false, hasSavedCredential: false))
    }

    func testOldProbeCannotOverrideNewSnapshotState() {
        let current = ModelData(id: "openai/vision", label: "Vision", description: "", providers: ["openai"],
            apiId: "vision", verifiedAvailable: false, capabilityStatus: .failed)
        let old = ModelProbeResult(canceled: false, results: [.init(supported: true, model: "vision", transport: .responses,
            checkedAt: "", message: "old success", capabilityStatus: .verified)], completed: 1, total: 1)
        let displayed = ProviderPresentation.models(providerID: "openai", snapshot: reviewProjection(models: [current]), discovery: nil, probe: old)
        XCTAssertEqual(displayed.first?.capabilityStatus, .failed)
        XCTAssertEqual(displayed.first?.verifiedAvailable, false)
    }

    func testFullPageSaveUsesTheSameCurrentProofAsImmediateSelection() async throws {
        let service = ReviewSettingsFake()
        let model = GlobalSettingsModel(service: service)
        await model.load()
        let custom = reviewCustom(status: .verified)
        let pair = ProviderModelSelection(providerID: custom.id, modelID: "vision")
        model.customProviders = [custom]
        model.setValue(pair.providerID, for: .defaultProviderID)
        model.setValue(pair.modelID, for: .defaultModelID)
        XCTAssertTrue(ProviderPresentation.isVerified(pair, in: try XCTUnwrap(model.live), customProviders: [custom]))
        await model.save()
        guard case .succeeded = model.operation else { return XCTFail("Valid draft proof should save") }
        let stale = CustomProviderConfiguration(id: custom.id, name: custom.name, baseUrl: custom.baseUrl,
            manualModelIds: custom.manualModelIds, revision: 2, capabilityCache: custom.capabilityCache)
        model.customProviders = [stale]
        XCTAssertFalse(ProviderPresentation.isVerified(pair, in: try XCTUnwrap(model.live), customProviders: [stale]))
        await model.save()
        guard case .failed(let error) = model.operation else { return XCTFail("Stale draft proof must be rejected") }
        XCTAssertEqual(error.code, "MODEL_NOT_VERIFIED")
    }

    func testFailedDeletionEndsCanceledDiscoveryWithoutRemovingProvider() async throws {
        let service = ReviewSettingsFake()
        let model = GlobalSettingsModel(service: service)
        await model.load()
        let providerID = reviewCustom(status: nil).id
        await service.blockNextDiscovery()
        await service.rejectSave()
        let request = Task { await model.discover(providerID: providerID) }
        await service.waitForDiscovery()
        let deleted = await model.removeCustomProvider(id: providerID)
        _ = await request.value
        XCTAssertFalse(deleted)
        XCTAssertTrue(model.customProviders.contains { $0.id == providerID })
        XCTAssertFalse(model.providerOperations[providerID]?.isRunning == true)
        XCTAssertFalse(model.probingProviderIDs.contains(providerID))
    }
    func testFailedDeletionAlsoEndsCanceledProbe() async {
        let service = ReviewSettingsFake()
        let model = GlobalSettingsModel(service: service)
        await model.load()
        let providerID = reviewCustom(status: nil).id
        await service.blockNextProbe()
        await service.rejectSave()
        let request = Task { await model.probe(providerID: providerID, modelIDs: ["vision"]) }
        await service.waitForDiscovery()
        let deleted = await model.removeCustomProvider(id: providerID)
        _ = await request.value
        XCTAssertFalse(deleted)
        XCTAssertFalse(model.providerOperations[providerID]?.isRunning == true)
        XCTAssertFalse(model.probingProviderIDs.contains(providerID))
        XCTAssertTrue(model.customProviders.contains { $0.id == providerID })
    }

}

private func reviewCustom(status: ModelCapabilityStatus?) -> CustomProviderConfiguration {
    .init(id: "openai-compatible:123e4567-e89b-42d3-a456-426614174000", name: "Review", baseUrl: "https://example.invalid/v1",
        manualModelIds: ["vision"], capabilityCache: status.map { ["vision": .init(status: $0, revision: 1)] })
}

private func reviewProjection(values: GlobalSettingValues = .init(), models: [ModelData] = [], custom: CustomProviderConfiguration? = nil, customProviders: [CustomProviderConfiguration]? = nil) -> GlobalSettingsProjection {
    .init(values: values, customProviders: customProviders ?? [custom ?? reviewCustom(status: nil)], providers: [], models: models,
        configuredCredentialProviderIDs: ["openai"], visionAvailable: false, paddleAvailable: false,
        runtime: .init(resolvedSettingCount: 0, globalConfigVersion: 2, environmentFileLoaded: false))
}

private actor ReviewSettingsFake: GlobalSettingsWorkflowServing {
    var values = GlobalSettingValues([.defaultProviderID: "openai", .defaultModelID: "openai/vision"])
    var proof = true
    var providers = [reviewCustom(status: nil)]
    var keyFails = false
    var refreshFails = false
    var saveFails = false
    var blocked = false
    var blockedProbe = false
    var probeResponse: CheckedContinuation<ModelProbeResult, Error>?
    var started = false
    var keyWrites = 0
    var response: CheckedContinuation<ModelDiscoveryResult, Error>?
    var entered: CheckedContinuation<Void, Never>?
    func useCustomAsDefault() {
        providers = [reviewCustom(status: .verified)]
        values[.defaultProviderID] = providers[0].id; values[.defaultModelID] = "vision"
    }
    func rejectSave() { saveFails = true }
    func blockNextProbe() { blockedProbe = true; started = false }
    func blockNextDiscovery() { blocked = true; started = false }
    func waitForDiscovery() async { if !started { await withCheckedContinuation { entered = $0 } } }
    func configureCredentialFailure(write: Bool, refresh: Bool = false) { keyFails = write; refreshFails = refresh }
    func globalSettings() async throws -> GlobalSettingsProjection {
        if refreshFails && keyWrites > 0 { throw SlateSyncError(code: "REFRESH_FAILURE", message: "Synthetic refresh failure") }
        return reviewProjection(values: values, models: [.init(id: "openai/vision", label: "Vision", description: "", providers: ["openai"],
            apiId: "vision", verifiedAvailable: proof, capabilityStatus: proof ? .verified : .pending)], customProviders: providers)
    }
    func saveGlobalSettings(values: GlobalSettingValues, customProviders: [CustomProviderConfiguration]) async throws -> GlobalSettingsProjection {
        if saveFails { throw SlateSyncError(code: "SAVE_FAILURE", message: "Synthetic save failure") }
        self.values = values; providers = customProviders
        return try await globalSettings()
    }
    func setProviderCredential(_ value: String?, providerID: String) async throws {
        // The real facade revokes proof and roles before attempting a credential write.
        if values[.defaultProviderID] == providerID { values[.defaultProviderID] = nil; values[.defaultModelID] = nil }
        let chain = try ProviderModelSelection.decodeAndValidateChain(values[.recognitionFailoverChain] ?? "[]")
        values[.recognitionFailoverChain] = try ProviderModelSelection.encodeChain(chain.filter { $0.providerID != providerID })
        if let index = providers.firstIndex(where: { $0.id == providerID }) {
            let old = providers[index]
            providers[index] = .init(id: old.id, name: old.name, baseUrl: old.baseUrl,
                manualModelIds: old.manualModelIds, revision: old.revision + 1, capabilityCache: nil)
        }
        proof = false; keyWrites += 1
        if keyFails { throw SlateSyncError(code: "KEY_FAILURE", message: "Synthetic key failure") }
    }
    func discoverModels(providerID: String, forceRefresh: Bool) async throws -> ModelDiscoveryResult {
        if blocked {
            started = true; entered?.resume(); entered = nil
            return try await withCheckedThrowingContinuation { response = $0 }
        }
        return .init(provider: providerID, source: .staticFallback, refreshedAt: "", availableModelCount: nil,
            visionModelCount: 0, fixedModelCount: 0, models: [], warning: "Synthetic network timeout")
    }
    func probeModels(providerID: String, modelIDs: [String], progress: @escaping @Sendable (ModelProbeProgress) -> Void) async throws -> ModelProbeResult {
        if blockedProbe {
            started = true; entered?.resume(); entered = nil
            return try await withCheckedThrowingContinuation { probeResponse = $0 }
        }
        proof = true
        if let index = providers.firstIndex(where: { $0.id == providerID }) {
            let old = providers[index]
            providers[index] = .init(id: old.id, name: old.name, baseUrl: old.baseUrl,
                manualModelIds: old.manualModelIds, revision: old.revision,
                capabilityCache: ["vision": .init(status: .verified, revision: old.revision)])
        }
        return .init(canceled: false, results: [.init(supported: true, model: "vision", transport: .responses,
            checkedAt: "", message: "", capabilityStatus: .verified)], completed: 1, total: 1)
    }
    func cancelModelProbe(providerID: String) async {
        response?.resume(throwing: CancellationError()); response = nil
        probeResponse?.resume(throwing: CancellationError()); probeResponse = nil
    }
    func installPaddleOCR(progress: @escaping @Sendable (PaddleOcrInstallProgress) -> Void) async throws -> PaddleOcrInstallResult { throw SlateSyncError(code: "UNUSED", message: "Not exercised") }
    func cancelPaddleOCRInstallation() async {}
}

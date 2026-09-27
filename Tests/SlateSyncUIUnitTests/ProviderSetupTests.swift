import SlateSyncDomain
@testable import SlateSyncUI
import XCTest

@MainActor
final class ProviderSetupTests: XCTestCase {
    func testImmediateSelectionRebasesAndPreservesOtherDraftsAcrossRestart() async throws {
        let service = SetupSettingsFake()
        let model = GlobalSettingsModel(service: service)
        await model.load()
        model.setValue("12345", for: .modelRequestTimeoutMS)
        await service.setExternalTimeout("240000")
        let first = ProviderModelSelection(providerID: "openai", modelID: "vision-a")
        let second = ProviderModelSelection(providerID: "openai", modelID: "vision-b")
        let defaultSaved = await model.commitProviderChange(.setDefault(first))
        XCTAssertTrue(defaultSaved)
        _ = await model.commitProviderChange(.addBackup(first))
        _ = await model.commitProviderChange(.addBackup(second))
        _ = await model.commitProviderChange(.addBackup(second))
        _ = await model.commitProviderChange(.moveBackup(second, -1))
        XCTAssertEqual(ProviderSelections(try XCTUnwrap(model.live).values).backups, [second, first])
        _ = await model.commitProviderChange(.removeBackup(first))
        let stored = try await service.globalSettings()
        XCTAssertEqual(stored.values[.modelRequestTimeoutMS], "240000")
        XCTAssertEqual(model.value(.modelRequestTimeoutMS), "12345")
        let reopened = GlobalSettingsModel(service: service)
        await reopened.load()
        XCTAssertEqual(ProviderSelections(try XCTUnwrap(reopened.live).values).primary, first)
        XCTAssertEqual(ProviderSelections(try XCTUnwrap(reopened.live).values).backups, [second])
    }

    func testSelectionFailureKeepsCommittedStateAndRejectsUnverifiedModels() async throws {
        let service = SetupSettingsFake()
        let model = GlobalSettingsModel(service: service)
        await model.load()
        _ = await model.setDefaultPair(providerID: "openai", modelID: "vision-a")
        let before = model.live
        await service.setFailure(true)
        let failed = await model.setDefaultPair(providerID: "openai", modelID: "vision-b")
        XCTAssertFalse(failed)
        XCTAssertEqual(model.live, before)
        await service.setFailure(false)
        let unverified = await model.setDefaultPair(providerID: "openai", modelID: "inferred")
        XCTAssertFalse(unverified)
        XCTAssertEqual(model.live, before)
    }

    func testDeletionSavesReferencesAndFailureKeepsService() async throws {
        let custom = Self.custom()
        let service = SetupSettingsFake(custom: custom)
        let model = GlobalSettingsModel(service: service)
        await model.load()
        let pair = ProviderModelSelection(providerID: custom.id, modelID: "manual")
        _ = await model.commitProviderChange(.setDefault(pair))
        _ = await model.commitProviderChange(.addBackup(pair))
        await service.setFailure(true)
        let failed = await model.removeCustomProvider(id: custom.id)
        XCTAssertFalse(failed)
        XCTAssertEqual(model.customProviders.map(\.id), [custom.id])
        await service.setFailure(false)
        let removed = await model.removeCustomProvider(id: custom.id)
        XCTAssertTrue(removed)
        let stored = try await service.globalSettings()
        XCTAssertTrue(stored.customProviders.isEmpty)
        XCTAssertNil(ProviderSelections(stored.values).primary)
        XCTAssertTrue(ProviderSelections(stored.values).backups.isEmpty)
    }

    func testRestorationRequiresUnchangedRolesAndCurrentProof() throws {
        let custom = Self.custom()
        var original = ProviderSelections(.init())
        let good = ProviderModelSelection(providerID: custom.id, modelID: "manual")
        let failed = ProviderModelSelection(providerID: custom.id, modelID: "failed")
        original.primary = good; original.backups = [failed, good]
        let empty = ProviderSelections(.init())
        let snapshot = Self.snapshot(custom: custom)
        let restored = try ProviderSelectionChange.restore(providerID: custom.id, original: original, expected: empty).applying(to: snapshot)
        XCTAssertEqual(ProviderSelections(restored.values).primary, good)
        XCTAssertEqual(ProviderSelections(restored.values).backups, [good])
        var changed = snapshot.values
        changed[.defaultProviderID] = "openai"; changed[.defaultModelID] = "vision-a"
        XCTAssertThrowsError(try ProviderSelectionChange.restore(providerID: custom.id, original: original, expected: empty).applying(to: Self.snapshot(values: changed, custom: custom)))
        let stale = CustomProviderConfiguration(id: custom.id, name: custom.name, baseUrl: custom.baseUrl,
            manualModelIds: custom.manualModelIds, revision: 2, capabilityCache: custom.capabilityCache)
        XCTAssertFalse(ProviderPresentation.isVerified(good, in: Self.snapshot(custom: stale)))
    }

    func testDiscoveryDoesNotGrantEligibilityAndCanceledBatchDoesNotPublishProof() {
        let inferred = ModelData(id: "inferred", label: "Inferred", description: "", providers: ["openai"], capabilityStatus: .inferred)
        let discovered = ModelDiscoveryResult(provider: "openai", source: .api, refreshedAt: "", availableModelCount: 1,
            visionModelCount: 1, fixedModelCount: 0, models: [inferred])
        let probe = ModelProbeResult(canceled: true, results: [.init(supported: true, model: "inferred", transport: .responses,
            checkedAt: "", message: "", capabilityStatus: .verified)], completed: 1, total: 2)
        let models = ProviderPresentation.models(providerID: "openai", snapshot: nil, discovery: discovered, probe: probe)
        XCTAssertEqual(models.first?.capabilityStatus, .inferred)
        XCTAssertFalse(ProviderPresentation.isVerified(.init(providerID: "openai", modelID: "inferred"), in: Self.snapshot()))
        XCTAssertEqual(ProviderPresentation.status(.inferred), ProviderPresentation.status(.pending))
    }

    func testLegacyPublicAliasSurvivesSharedModelPresentation() {
        let provider = CustomProviderConfiguration(id: "openai-compatible", name: "Legacy", baseUrl: "https://example.invalid/v1",
            manualModelIds: ["physical"], capabilityCache: ["physical": .init(status: .verified, revision: 1)])
        let alias = ModelData(id: "openai-compatible/custom", label: "Legacy model", description: "", providers: [provider.id],
            apiId: "physical", capabilityStatus: .verified)
        let snapshot = GlobalSettingsProjection(values: .init(), customProviders: [provider], providers: [], models: [alias],
            configuredCredentialProviderIDs: [], visionAvailable: false, paddleAvailable: false,
            runtime: .init(resolvedSettingCount: 0, globalConfigVersion: 2, environmentFileLoaded: false))
        let models = ProviderPresentation.models(providerID: provider.id, snapshot: snapshot, discovery: nil)
        XCTAssertEqual(models.map(\.id), [alias.id])
        XCTAssertTrue(ProviderPresentation.isVerified(.init(providerID: provider.id, modelID: alias.id), in: snapshot))
    }

    func testBuiltinRefreshFailurePreservesCredentialWriteFact() async {
        let service = SetupSettingsFake()
        await service.failRefreshAfterCredential()
        let model = GlobalSettingsModel(service: service)
        await model.load()
        let result = await model.saveBuiltinProviderConfiguration(providerID: "openai", values: [.openAIBaseUrl: "https://example.invalid/v1"], apiKey: "synthetic")
        XCTAssertTrue(result.configurationSaved)
        XCTAssertTrue(result.credentialSaved)
        XCTAssertFalse(result.isComplete)
        XCTAssertNotNil(result.error)
        let writes = await service.keyWrites
        XCTAssertEqual(writes, 1)
    }

    func testMetadataOnlyCustomEditPreservesProof() async throws {
        let custom = Self.custom()
        let service = SetupSettingsFake(custom: custom)
        let model = GlobalSettingsModel(service: service)
        await model.load()
        let result = await model.saveCustomProviderConfiguration(existing: custom, name: "Renamed", baseURL: custom.baseUrl,
            modelIDs: custom.manualModelIds.joined(separator: ","), transport: custom.transport, jsonMode: custom.jsonMode,
            imageDetail: custom.imageDetail, notes: "Updated note", sourcePresetID: nil, apiKey: nil)
        XCTAssertTrue(result.isComplete)
        XCTAssertEqual(result.provider?.revision, custom.revision)
        XCTAssertEqual(result.provider?.capabilityCache, custom.capabilityCache)
    }

    fileprivate static func custom() -> CustomProviderConfiguration {
        .init(id: "openai-compatible:123e4567-e89b-42d3-a456-426614174000", name: "Custom", baseUrl: "https://example.invalid/v1",
              manualModelIds: ["manual", "failed"], capabilityCache: ["manual": .init(status: .verified, revision: 1, capabilitySource: "probe"), "failed": .init(status: .failed, revision: 1, capabilitySource: "probe")])
    }
    fileprivate static func snapshot(values: GlobalSettingValues = .init(), custom: CustomProviderConfiguration? = nil) -> GlobalSettingsProjection {
        let models = ["vision-a", "vision-b", "inferred"].map {
            ModelData(id: $0, label: $0, description: "", providers: ["openai"], capabilityStatus: $0 == "inferred" ? .inferred : .verified)
        }
        return .init(values: values, customProviders: custom.map { [$0] } ?? [], providers: [], models: models,
            configuredCredentialProviderIDs: [], visionAvailable: false, paddleAvailable: false,
            runtime: .init(resolvedSettingCount: 0, globalConfigVersion: 2, environmentFileLoaded: false))
    }
}

/// Mutable committed storage makes failures/restarts observable; it never contacts a provider.
private actor SetupSettingsFake: GlobalSettingsWorkflowServing {
    var values = GlobalSettingValues()
    var providers: [CustomProviderConfiguration]
    var fails = false
    var refreshFails = false
    var keyWrites = 0
    init(custom: CustomProviderConfiguration? = nil) { providers = custom.map { [$0] } ?? [] }
    func setExternalTimeout(_ value: String) { values[.modelRequestTimeoutMS] = value }
    func setFailure(_ value: Bool) { fails = value }
    func failRefreshAfterCredential() { refreshFails = true }
    func globalSettings() async throws -> GlobalSettingsProjection {
        if refreshFails && keyWrites > 0 { throw SlateSyncError(code: "REFRESH", message: "Refresh failed") }
        return await ProviderSetupTests.snapshot(values: values, custom: providers.first)
    }
    func saveGlobalSettings(values: GlobalSettingValues, customProviders: [CustomProviderConfiguration]) async throws -> GlobalSettingsProjection {
        if fails { throw SlateSyncError(code: "SAVE", message: "Save failed") }
        self.values = values; providers = customProviders
        return try await globalSettings()
    }
    func setProviderCredential(_ value: String?, providerID: String) async throws { keyWrites += 1 }
    func discoverModels(providerID: String, forceRefresh: Bool) async throws -> ModelDiscoveryResult { throw unused() }
    func probeModels(providerID: String, modelIDs: [String], progress: @escaping @Sendable (ModelProbeProgress) -> Void) async throws -> ModelProbeResult { throw unused() }
    func cancelModelProbe(providerID: String) async {}
    func installPaddleOCR(progress: @escaping @Sendable (PaddleOcrInstallProgress) -> Void) async throws -> PaddleOcrInstallResult { throw unused() }
    func cancelPaddleOCRInstallation() async {}
    private func unused() -> SlateSyncError { .init(code: "UNUSED", message: "Not exercised") }
}

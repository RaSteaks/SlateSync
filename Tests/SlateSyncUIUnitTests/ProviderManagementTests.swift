import SlateSyncDomain
@testable import SlateSyncUI
import XCTest

@MainActor
final class ProviderManagementTests: XCTestCase {
    func testCredentialReadFailureKeepsProviderVisible() {
        let builtin = ProviderSummary(id: "openai", label: "OpenAI", configured: false, type: .builtin, editable: true)
        XCTAssertTrue(ProviderListPresentation.isAdded(builtin, credentialStatus: .unavailable))
        XCTAssertTrue(ProviderListPresentation.isAdded(builtin, credentialStatus: .authorizationRequired))
        XCTAssertFalse(ProviderListPresentation.isAdded(builtin, credentialStatus: .missing))
        let custom = ProviderSummary(id: "custom", label: "Custom", configured: false, type: .custom, editable: true)
        XCTAssertTrue(ProviderListPresentation.isAdded(custom, credentialStatus: .missing))
    }

    func testTransientCredentialNoticeNeverSuggestsReset() {
        let transient = ProviderListPresentation.credentialNotice(.temporarilyUnavailable)
        XCTAssertNotNil(transient)
        XCTAssertNotEqual(transient, ProviderListPresentation.credentialNotice(.unreadable))
        let builtin = ProviderSummary(id: "openai", label: "OpenAI", configured: false, type: .builtin, editable: true)
        XCTAssertTrue(ProviderListPresentation.isAdded(builtin, credentialStatus: .temporarilyUnavailable))
        XCTAssertTrue(ProviderListPresentation.isAdded(builtin, credentialStatus: .unreadable))
        XCTAssertEqual(CredentialChip(.temporarilyUnavailable).symbol, "clock")
    }

    func testLocalSearchIncludesNotesAndClearsImmediately() {
        XCTAssertTrue(ProviderListPresentation.matches(query: "  vision  ", name: "Service", url: "https://example.test", notes: "VISION models"))
        XCTAssertTrue(ProviderListPresentation.matches(query: "example", name: "Service", url: "https://example.test", notes: nil))
        XCTAssertTrue(ProviderListPresentation.matches(query: "", name: "Service", url: "", notes: nil))
        XCTAssertFalse(ProviderListPresentation.matches(query: "absent", name: "Service", url: "", notes: nil))
    }

    func testCredentialFailureRetriesSameIdentityAndPreservesOtherDrafts() async throws {
        let service = ProviderSaveFake()
        let model = GlobalSettingsModel(service: service)
        await model.load()
        model.setValue("12345", for: .modelRequestTimeoutMS)
        let first = await save(model, key: "test-key")
        XCTAssertTrue(first.configurationSaved)
        XCTAssertFalse(first.credentialSaved)
        XCTAssertFalse(first.isComplete)
        let id = try XCTUnwrap(first.provider?.id)
        await service.allowCredentialWrite()
        let retried = await save(model, existing: first.provider, key: "test-key")
        XCTAssertTrue(retried.isComplete)
        XCTAssertEqual(retried.provider?.id, id)
        let stored = await service.providers
        XCTAssertEqual(stored.count, 1)
        XCTAssertEqual(model.value(.modelRequestTimeoutMS), "12345")
        let values = await service.values
        XCTAssertNil(values[.modelRequestTimeoutMS])
    }

    func testConfigurationFailureNeverWritesKeyAndWhitespaceFailsBeforeSave() async {
        let service = ProviderSaveFake(failConfiguration: true)
        let model = GlobalSettingsModel(service: service)
        await model.load()
        let whitespace = await save(model, key: "   ")
        XCTAssertFalse(whitespace.isComplete)
        let initialWrites = await service.saves
        XCTAssertEqual(initialWrites, 0)
        let failed = await save(model, key: "test-key")
        XCTAssertFalse(failed.configurationSaved)
        XCTAssertTrue(model.customProviders.isEmpty, "Cancel after failed save must not leave a phantom draft entry")
        let keyWrites = await service.keyWrites
        XCTAssertEqual(keyWrites, 0)
    }

    func testBlankInputPreservesExistingCredential() async {
        let service = ProviderSaveFake()
        let model = GlobalSettingsModel(service: service)
        await model.load()
        let result = await save(model, key: nil)
        XCTAssertTrue(result.isComplete)
        let writes = await service.keyWrites
        XCTAssertEqual(writes, 0)
    }

    func testCredentialFailurePreservesSanitizedReason() async {
        let service = ProviderSaveFake()
        let model = GlobalSettingsModel(service: service)
        await model.load()
        _ = await save(model, key: "test-key")
        guard case let .failed(error) = model.operation else { return XCTFail("Expected credential failure") }
        XCTAssertEqual(error.code, "TEST_KEY")
        XCTAssertTrue(error.message.contains("Key write failed"))
    }

    func testRefreshFailureDoesNotReportSuccessfulWriteAsFailed() async {
        let service = ProviderSaveFake(failRefreshAfterWrite: true)
        await service.allowCredentialWrite()
        let model = GlobalSettingsModel(service: service)
        await model.load()
        let result = await save(model, key: "test-key")
        XCTAssertTrue(result.configurationSaved)
        XCTAssertTrue(result.credentialSaved)
        XCTAssertFalse(result.isComplete, "Keep the editor open to explain the failed refresh")
        guard case let .failed(error) = model.operation else { return XCTFail("Expected refresh failure") }
        XCTAssertEqual(error.code, "TEST_REFRESH")
        let writes = await service.keyWrites
        XCTAssertEqual(writes, 1)
    }

    func testCustomProviderEditUsesProductionSavePathAndInvalidatesRevision() async throws {
        let service = ProviderSaveFake()
        let model = GlobalSettingsModel(service: service)
        await model.load()
        let initial = await save(model, key: nil)
        let created = try XCTUnwrap(initial.provider)
        XCTAssertTrue(initial.isComplete)
        XCTAssertTrue(created.id.hasPrefix(CustomProviderValidator.idPrefix))
        let result = await model.saveCustomProviderConfiguration(existing: created, name: "Renamed",
            baseURL: "http://localhost:11434/v1/", modelIDs: "vision-test, vision-backup",
            transport: .responses, jsonMode: .jsonObject, imageDetail: .original,
            notes: nil, sourcePresetID: nil, apiKey: nil)
        XCTAssertTrue(result.isComplete)
        XCTAssertEqual(result.provider?.id, created.id)
        XCTAssertEqual(result.provider?.baseUrl, "http://localhost:11434/v1")
        XCTAssertEqual(result.provider?.revision, created.revision + 1)
        XCTAssertNil(result.provider?.capabilityCache)
        XCTAssertEqual(result.provider?.manualModelIds, ["vision-test", "vision-backup"])
        let stored = await service.providers
        XCTAssertEqual(stored, [try XCTUnwrap(result.provider)])
    }

    private func save(_ model: GlobalSettingsModel, existing: CustomProviderConfiguration? = nil, key: String?) async -> CustomProviderSaveResult {
        await model.saveCustomProviderConfiguration(existing: existing, name: "Test Service", baseURL: "https://example.test/v1",
            modelIDs: "vision-model", transport: .chatCompletions, jsonMode: .jsonSchema, imageDetail: .high,
            notes: nil, sourcePresetID: nil, apiKey: key)
    }
}

/// Stateful fake exercises partial transactions rather than assuming every save
/// returns a pre-canned success projection. No real key or network is involved.
private actor ProviderSaveFake: GlobalSettingsWorkflowServing {
    var providers: [CustomProviderConfiguration] = []
    var values = GlobalSettingValues()
    var saves = 0
    var keyWrites = 0
    private let failConfiguration: Bool
    private var failCredential = true
    private let failRefreshAfterWrite: Bool
    init(failConfiguration: Bool = false, failRefreshAfterWrite: Bool = false) {
        self.failConfiguration = failConfiguration
        self.failRefreshAfterWrite = failRefreshAfterWrite
    }
    func allowCredentialWrite() { failCredential = false }
    func globalSettings() async throws -> GlobalSettingsProjection {
        // Simulate a projection failure after the irreversible write completed.
        if failRefreshAfterWrite && keyWrites > 0 { throw SlateSyncError(code: "TEST_REFRESH", message: "Refresh failed") }
        return .init(values: values, customProviders: providers, providers: [], models: [], configuredCredentialProviderIDs: [],
              visionAvailable: false, paddleAvailable: false,
              runtime: .init(resolvedSettingCount: 0, globalConfigVersion: 2, environmentFileLoaded: false))
    }
    func saveGlobalSettings(values: GlobalSettingValues, customProviders: [CustomProviderConfiguration]) async throws -> GlobalSettingsProjection {
        saves += 1
        if failConfiguration { throw SlateSyncError(code: "TEST_SAVE", message: "Save failed") }
        self.values = values; providers = customProviders
        return try await globalSettings()
    }
    func setProviderCredential(_ value: String?, providerID: String) async throws {
        keyWrites += 1
        if failCredential { throw SlateSyncError(code: "TEST_KEY", message: "Key write failed") }
    }


    func discoverModels(providerID: String, forceRefresh: Bool) async throws -> ModelDiscoveryResult { throw unused() }
    func probeModels(providerID: String, modelIDs: [String], progress: @escaping @Sendable (ModelProbeProgress) -> Void) async throws -> ModelProbeResult { throw unused() }
    func cancelModelProbe(providerID: String) async {}
    func installPaddleOCR(progress: @escaping @Sendable (PaddleOcrInstallProgress) -> Void) async throws -> PaddleOcrInstallResult { throw unused() }
    func cancelPaddleOCRInstallation() async {}
    private func unused() -> SlateSyncError { .init(code: "UNUSED", message: "Not exercised") }
}

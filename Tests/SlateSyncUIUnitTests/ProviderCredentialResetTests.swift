import Foundation
import SlateSyncDomain
import SlateSyncPersistence
@testable import SlateSyncUI
@testable import SlateSyncWorkflow
import XCTest

/// Real configuration, encrypted files and registry; no HTTP or user data.
@MainActor
final class ProviderCredentialResetTests: XCTestCase {
    func testFailedResetKeepsDiskRegistryAndEditedSettingsProofsRevoked() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "credential-reset-review-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let locator = ApplicationSupportLocator(root: root)
        let runtime = SlateSyncRuntime(locator: locator, environment: [:])
        let provider = CustomProviderConfiguration(
            id: "openai-compatible:00000000-0000-4000-8000-000000000002",
            name: "Gateway", baseUrl: "https://example.invalid/v1",
            manualModelIds: ["vision"], revision: 7,
            capabilityCache: ["vision": .init(status: .verified, revision: 7)]
        )
        _ = try await runtime.globalConfigStore.save(values: [
            .defaultProviderID: provider.id, .defaultModelID: "vision",
            .recognitionFailoverChain: try ProviderModelSelection.encodeChain([
                .init(providerID: provider.id, modelID: "vision"),
            ]),
        ], customProviders: [provider])
        try await runtime.setProviderKey("synthetic-key", for: provider.id)
        let facade = SlateSyncWorkflowFacade(
            library: ProjectLibraryStartupService(locator: locator, machineSettings: runtime.machineSettingsStore,
                environment: [:], forceIsolatedRoot: true),
            runtime: runtime, logs: LocalLogStore(directory: root.appending(path: "logs")),
            paddleInstaller: PaddleOCRInstallerService(userDataRoot: root,
                requirementsURL: root.appending(path: "unused.txt")),
            allowsExternalOperations: false
        )
        let model = GlobalSettingsModel(service: facade)
        await model.load()
        let registry = try await facade.modelRegistry()
        let verified = try await registry.resolveModel(providerID: provider.id, modelID: "vision")
        XCTAssertEqual(verified.capabilityStatus, .verified)
        model.setValue("140", for: .maxBodyMB)
        // Preserve an unrelated Provider edit across failure recovery. A plain
        // three-way refresh would otherwise retain its obsolete proof as well.
        model.customProviders = [.init(id: provider.id, name: provider.name, baseUrl: provider.baseUrl,
            manualModelIds: provider.manualModelIds, revision: provider.revision,
            capabilityCache: provider.capabilityCache, notes: "Unsaved note")]

        // A non-file lock makes the credential transaction fail deterministically
        // after the ordinary configuration has committed its proof revocation.
        let lock = root.appending(path: "Credentials/.credentials.lock")
        try FileManager.default.removeItem(at: lock)
        try FileManager.default.createDirectory(at: lock, withIntermediateDirectories: false)
        await model.resetLocalCredentials()

        guard case .failed(let error) = model.operation else { return XCTFail("Reset must report the file failure") }
        XCTAssertEqual(error.code, "CREDENTIAL_ACCESS")
        let disk = try await GlobalConfigStore(applicationSupportRoot: root).load()
        XCTAssertEqual(disk.customProviders.first?.revision, 8)
        XCTAssertNil(disk.customProviders.first?.capabilityCache)
        do {
            _ = try await registry.resolveModel(providerID: provider.id, modelID: "vision")
            XCTFail("A failed key reset cannot retain the revoked in-memory proof")
        } catch {
            XCTAssertEqual((error as? SlateSyncError)?.code, RecognitionFailure.unsupportedModel.code)
        }
        XCTAssertEqual(model.live?.customProviders.first?.revision, 8)
        XCTAssertEqual(model.customProviders.first?.revision, 8)
        XCTAssertNil(model.customProviders.first?.capabilityCache)
        XCTAssertEqual(model.customProviders.first?.notes, "Unsaved note")
        XCTAssertEqual(model.draft[.maxBodyMB], "140")
        XCTAssertNil(ProviderSelections(model.draft).primary)
        XCTAssertEqual(model.draft[.recognitionFailoverChain], "[]")

        // Recover the disposable lock and save the remaining draft: neither an
        // old capability nor a revoked default may be written back by the UI.
        try FileManager.default.removeItem(at: lock)
        await model.save()
        guard case .succeeded = model.operation else { return XCTFail("Unrelated draft remains saveable") }
        let saved = try await GlobalConfigStore(applicationSupportRoot: root).load()
        XCTAssertNil(saved.customProviders.first?.capabilityCache)
        XCTAssertEqual(saved.customProviders.first?.notes, "Unsaved note")
        XCTAssertNil(ProviderSelections(saved.values).primary)

        // A successful retry adopts the one durable revision bump rather than
        // advancing the draft again after the live snapshot has refreshed.
        await model.resetLocalCredentials()
        guard case .succeeded = model.operation else { return XCTFail("Reset remains retryable") }
        let retried = try await GlobalConfigStore(applicationSupportRoot: root).load()
        XCTAssertEqual(retried.customProviders.first?.revision, 9)
        XCTAssertEqual(model.customProviders.first?.revision, 9)
        XCTAssertNil(model.customProviders.first?.capabilityCache)
        let credentialStatus = try await facade.globalSettings().credentialStatuses[provider.id]
        XCTAssertEqual(credentialStatus, .missing)
        await model.drain()
        try await facade.drain()
    }
}

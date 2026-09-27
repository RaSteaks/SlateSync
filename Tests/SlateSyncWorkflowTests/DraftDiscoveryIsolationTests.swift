import Foundation
import SlateSyncDomain
import SlateSyncPersistence
@testable import SlateSyncWorkflow
import XCTest

/// Real facade composition with injected transports; failure cases cannot accidentally dispatch HTTP.
@MainActor
final class DraftDiscoveryIsolationTests: XCTestCase {
    func testInjectedDraftTransportReceivesDraftAndSavedCredentials() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "draft-isolation-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let runtime = SlateSyncRuntime(locator: .init(root: root), environment: [:])
        try await runtime.credentialStore.setValue("saved-synthetic", providerID: "openai")
        let recorder = DraftIsolationRecorder()
        let facade = makeFacade(root: root, runtime: runtime, recorder: recorder, allowInjected: true, includeDraft: true)
        let first = try await facade.discoverDraftModelIDs(baseURL: "https://example.invalid/v1/", apiKey: "typed-synthetic", savedProviderID: "openai")
        let second = try await facade.discoverDraftModelIDs(baseURL: "https://example.invalid/v1/", apiKey: "", savedProviderID: "openai")
        XCTAssertEqual(first, ["vision"]); XCTAssertEqual(second, first)
        let seen = await recorder.credentials
        XCTAssertEqual(seen, ["typed-synthetic", "saved-synthetic"])
        let urls = await recorder.urls
        XCTAssertEqual(urls, ["https://example.invalid/v1/models", "https://example.invalid/v1/models"])
        let closed = await recorder.closed
        XCTAssertEqual(closed, 2)
        // Enabling synthetic models must not grant installation/network privileges.
        do { _ = try await facade.installPaddleOCR(progress: { _ in }); XCTFail("Installer must remain blocked") }
        catch { XCTAssertEqual((error as? SlateSyncError)?.code, "ISOLATED_OPERATION") }
        try await facade.drain()
    }

    func testIsolationRequiresExplicitOptInAndBothFactories() async throws {
        for (allow, includeDraft) in [(true, false), (false, true)] {
            let root = FileManager.default.temporaryDirectory.appending(path: "draft-denied-\(UUID())")
            defer { try? FileManager.default.removeItem(at: root) }
            let runtime = SlateSyncRuntime(locator: .init(root: root), environment: [:])
            let recorder = DraftIsolationRecorder()
            let facade = makeFacade(root: root, runtime: runtime, recorder: recorder, allowInjected: allow, includeDraft: includeDraft)
            // Invalid local inputs make this test safe even if admission accidentally regresses.
            do { _ = try await facade.discoverDraftModelIDs(baseURL: "invalid", apiKey: "synthetic", savedProviderID: nil); XCTFail("Must deny admission") }
            catch { XCTAssertEqual((error as? SlateSyncError)?.code, "ISOLATED_OPERATION") }
            do { _ = try await facade.discoverModels(providerID: "unknown-fixture", forceRefresh: true); XCTFail("Must deny admission") }
            catch { XCTAssertEqual((error as? SlateSyncError)?.code, "ISOLATED_OPERATION") }
            let seen = await recorder.credentials
            XCTAssertTrue(seen.isEmpty)
            try await facade.drain()
        }
    }

    func testInvalidURLIsRejectedBeforeCreatingDraftTransport() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "draft-invalid-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let runtime = SlateSyncRuntime(locator: .init(root: root), environment: [:])
        let recorder = DraftIsolationRecorder()
        let facade = makeFacade(root: root, runtime: runtime, recorder: recorder, allowInjected: true, includeDraft: true)
        do { _ = try await facade.discoverDraftModelIDs(baseURL: "file:///private", apiKey: "synthetic", savedProviderID: nil); XCTFail("Invalid URL must fail") }
        catch { XCTAssertNotEqual((error as? SlateSyncError)?.code, "ISOLATED_OPERATION") }
        let seen = await recorder.credentials
        let closed = await recorder.closed
        XCTAssertTrue(seen.isEmpty); XCTAssertEqual(closed, 0)
        try await facade.drain()
    }

    private func makeFacade(root: URL, runtime: SlateSyncRuntime, recorder: DraftIsolationRecorder,
                            allowInjected: Bool, includeDraft: Bool) -> SlateSyncWorkflowFacade {
        let locator = ApplicationSupportLocator(root: root)
        let factory: @Sendable (any ProviderCredentialReading) -> any ProviderHTTPTransporting = { credentials in
            DraftIsolationTransport(credentials: credentials, recorder: recorder)
        }
        let draft = includeDraft ? factory : nil
        return SlateSyncWorkflowFacade(
            library: ProjectLibraryStartupService(locator: locator, machineSettings: runtime.machineSettingsStore,
                environment: [:], forceIsolatedRoot: true), runtime: runtime,
            logs: LocalLogStore(directory: root.appending(path: "logs")),
            paddleInstaller: PaddleOCRInstallerService(userDataRoot: root, requirementsURL: root.appending(path: "unused.txt")),
            allowsExternalOperations: false,
            providerTransportFactory: { DraftIsolationTransport(credentials: runtime.credentialStore, recorder: recorder) },
            draftProviderTransportFactory: draft, allowsInjectedProviderOperations: allowInjected)
    }
}

private actor DraftIsolationRecorder {
    var credentials: [String] = []
    var urls: [String] = []
    var closed = 0
    func record(key: String, url: String) { credentials.append(key); urls.append(url) }
    func close() { closed += 1 }
}
private actor DraftIsolationTransport: ProviderHTTPTransporting {
    let credentials: any ProviderCredentialReading
    let recorder: DraftIsolationRecorder
    init(credentials: any ProviderCredentialReading, recorder: DraftIsolationRecorder) { self.credentials = credentials; self.recorder = recorder }
    func send(_ request: ProviderTransportRequest) async throws -> ProviderTransportResponse {
        let key = try await credentials.credential(for: request.provider.id) ?? ""
        await recorder.record(key: key, url: try request.provider.endpoint(for: request.purpose).absoluteString)
        return .init(status: 200, body: Data(#"{"data":["vision"]}"#.utf8))
    }
    func close() async { await recorder.close() }
}

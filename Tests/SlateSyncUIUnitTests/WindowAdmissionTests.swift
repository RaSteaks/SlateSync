import Foundation
import Synchronization
import SlateSyncDomain
@testable import SlateSyncUI
import XCTest

/// SM-09 #12: admission is split per feature. Media and metadata edits stay
/// usable while recognition runs; only CSV import waits for it. A shared
/// media/CSV predicate would block media edits for a CSV-shaped reason.
@MainActor
final class WindowAdmissionTests: XCTestCase {
    private func awaitTrue(_ condition: @MainActor () async -> Bool) async throws {
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if await condition() { return }
            await Task.yield()
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("等待条件超时")
    }

    func testRecognitionRunningKeepsMediaAndMetadataEditableButBlocksCSVImport() async throws {
        let service = AdmissionWorkspaceFake()
        let termination = TerminationCoordinator(lifecycle: AdmissionLifecycle())
        let workspace = WorkspaceModel(service: service)
        let recognition = RecognitionModel(service: service, settings: AdmissionSettingsFake())
        let csv = ResolveCSVModel(service: service)
        let media = MediaInputModel(service: service)
        let metadata = MetadataScanModel(service: service)
        // The composition root wires exactly these predicates (WindowAdmission
        // is the production factory; this is not a re-implementation).
        workspace.permitsNewOperation = WindowAdmission.shared(termination)
        csv.permitsNewOperation = WindowAdmission.csv(termination, recognition: recognition)
        media.permitsNewOperation = WindowAdmission.media(termination)
        metadata.permitsNewOperation = WindowAdmission.metadata(termination)
        recognition.permitsNewOperation = WindowAdmission.recognition(termination, workspace: workspace)

        await recognition.loadOptions()
        recognition.recognize(
            NativeRecognitionRequest(
                projectID: "p1",
                input: .bytes(Data(), filename: "a.jpg"),
                filename: "a.jpg",
                providerID: "custom-test",
                modelID: "vision-test"
            ),
            flush: {}
        )
        try await awaitTrue {
            let entered = await service.recognitionEntered
            return entered && recognition.operation.isRunning
        }
        XCTAssertTrue(recognition.operation.isRunning)

        // Independent editors continue during recognition.
        XCTAssertTrue(media.canAcceptInput)
        media.select(URL(fileURLWithPath: "/tmp/admission-fixture.jpg"))
        try await awaitTrue { await service.prepareCount == 1 }
        metadata.scan(URL(fileURLWithPath: "/tmp/admission-fixture"))
        try await awaitTrue { await service.scanCount == 1 }

        // CSV import is the one feature recognition blocks.
        await csv.importData(Data(), filename: "a.csv")
        await csv.drain()
        let decodeCount = await service.decodeCount
        XCTAssertEqual(decodeCount, 0)

        // After recognition drains, the CSV path admits work again.
        await service.releaseRecognition()
        await recognition.drain()
        XCTAssertFalse(recognition.operation.isRunning)
        await csv.importData(Data(), filename: "a.csv")
        await csv.drain()
        let decodeAfter = await service.decodeCount
        XCTAssertEqual(decodeAfter, 1)
    }

    func testSharedFreezeBlocksEveryFeatureAdmission() async throws {
        let service = AdmissionWorkspaceFake()
        let termination = TerminationCoordinator(lifecycle: AdmissionLifecycle())
        let workspace = WorkspaceModel(service: service)
        let recognition = RecognitionModel(service: service, settings: AdmissionSettingsFake())
        let csv = ResolveCSVModel(service: service)
        let media = MediaInputModel(service: service)
        let metadata = MetadataScanModel(service: service)
        workspace.permitsNewOperation = WindowAdmission.shared(termination)
        csv.permitsNewOperation = WindowAdmission.csv(termination, recognition: recognition)
        media.permitsNewOperation = WindowAdmission.media(termination)
        metadata.permitsNewOperation = WindowAdmission.metadata(termination)
        recognition.permitsNewOperation = WindowAdmission.recognition(termination, workspace: workspace)

        // A restart-required failure freezes every feature.
        termination.requireRestart()
        XCTAssertFalse(WindowAdmission.shared(termination)())
        XCTAssertFalse(media.canAcceptInput)
        XCTAssertFalse(WindowAdmission.csv(termination, recognition: recognition)())
        XCTAssertFalse(WindowAdmission.recognition(termination, workspace: workspace)())
        media.select(URL(fileURLWithPath: "/tmp/admission-fixture.jpg"))
        metadata.scan(URL(fileURLWithPath: "/tmp/admission-fixture"))
        await csv.importData(Data(), filename: "a.csv")
        await csv.drain()
        let prepareCount = await service.prepareCount
        let scanCount = await service.scanCount
        let decodeCount = await service.decodeCount
        XCTAssertEqual(prepareCount, 0)
        XCTAssertEqual(scanCount, 0)
        XCTAssertEqual(decodeCount, 0)
    }
}

/// Once-only gate for holding the injected recognition inside its service.
/// Both fields share one mutex so a release racing a first wait cannot strand
/// a continuation.
private final class AdmissionGate: Sendable {
    private let state = Mutex<(released: Bool, pending: [CheckedContinuation<Void, Never>])>((false, []))

    func wait() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let resumeNow = state.withLock { st -> Bool in
                if st.released { return true }
                st.pending.append(continuation)
                return false
            }
            if resumeNow { continuation.resume() }
        }
    }

    func release() {
        let pending = state.withLock { st -> [CheckedContinuation<Void, Never>] in
            st.released = true
            let pending = st.pending
            st.pending = []
            return pending
        }
        for continuation in pending { continuation.resume() }
    }
}

/// Idle service that records which features actually reached their owner.
private actor AdmissionWorkspaceFake: WorkspaceWorkflowServing, MediaInputWorkflowServing {
    private let recognitionGate = AdmissionGate()
    private(set) var recognitionEntered = false
    private(set) var prepareCount = 0
    private(set) var scanCount = 0
    private(set) var decodeCount = 0

    func releaseRecognition() { recognitionGate.release() }

    func listTasks(projectID: String) async throws -> [TaskListItem] { [] }
    func loadTask(projectID: String, taskID: String) async throws -> TaskData {
        TaskData(id: taskID, projectId: projectID, customPrompt: "")
    }
    func saveTask(projectID: String, taskID: String?, task: TaskData) async throws -> String { taskID ?? "generated" }
    func deleteTask(projectID: String, taskID: String) async throws {}
    func decodeResolveCSV(_ data: Data) async throws -> ResolveCSVTable {
        decodeCount += 1
        return ResolveCSVTable(headers: [], rows: [], format: ResolveCSVFormat())
    }
    func encodeResolveCSV(_ table: ResolveCSVTable) async throws -> Data { Data() }
    func resolveMaterialKeys(in table: ResolveCSVTable) async throws -> [String] { [] }
    func scanMetadata(directory: URL, options: SlateMetadataScanOptions) async throws -> ScanResult {
        scanCount += 1
        return ScanResult(
            metadata: [], warnings: [],
            stats: ScanStats(
                visitedDirectories: 0, prunedDirectories: 0, skippedDeepDirectories: 0,
                discoveredSlateFiles: 0, readSlateFiles: 0, learnedStructures: 0
            ),
            missingKeys: []
        )
    }
    func recognize(_ request: NativeRecognitionRequest) async throws -> RecognitionData {
        recognitionEntered = true
        await recognitionGate.wait()
        throw SlateSyncError(code: "TEST_RECOGNITION", message: "注入识别结束")
    }
    func recognitionProgress(projectID: String) async -> AsyncStream<RecognitionProgress> { AsyncStream { $0.finish() } }
    func cancelRecognition(projectID: String) async {}
    func closeProject(id: String) async throws {}
    func prepareInput(_ input: MediaInput) async throws -> PreparedDocument {
        prepareCount += 1
        return PreparedDocument(filename: "a.jpg", pages: [])
    }
    func restoreInput(groups: [[String]], filename: String) async throws -> PreparedDocument {
        throw SlateSyncError(code: "TEST", message: "unused")
    }
}

/// Frozen offline provider/model projection: "custom-test"/"vision-test".
private actor AdmissionSettingsFake: GlobalSettingsWorkflowServing {
    private nonisolated static let model = ModelData(
        id: "vision-test",
        label: "Vision Test",
        description: "offline fixture",
        providers: ["custom-test"],
        verifiedAvailable: true,
        capabilityStatus: .verified
    )
    private nonisolated static let projection = GlobalSettingsProjection(
        values: .init(),
        customProviders: [],
        providers: [.init(id: "custom-test", label: "Custom Test", configured: true)],
        models: [model],
        configuredCredentialProviderIDs: [],
        visionAvailable: true,
        paddleAvailable: false,
        runtime: .init(
            resolvedSettingCount: 0,
            globalConfigVersion: 1,
            environmentFileLoaded: false,
            migrationStatus: .sourceMissing
        )
    )

    func globalSettings() async throws -> GlobalSettingsProjection { Self.projection }
    func saveGlobalSettings(values: GlobalSettingValues, customProviders: [CustomProviderConfiguration]) async throws -> GlobalSettingsProjection {
        Self.projection
    }
    func setProviderCredential(_ value: String?, providerID: String) async throws {}
    func retryLegacyCredentialMigration() async throws -> GlobalSettingsProjection { Self.projection }
    func discoverModels(providerID: String, forceRefresh: Bool) async throws -> ModelDiscoveryResult {
        throw SlateSyncError(code: "TEST", message: "unused")
    }
    func probeModels(providerID: String, modelIDs: [String], progress: @escaping @Sendable (ModelProbeProgress) -> Void) async throws -> ModelProbeResult {
        throw SlateSyncError(code: "TEST", message: "unused")
    }
    func cancelModelProbe(providerID: String) async {}
    func installPaddleOCR(progress: @escaping @Sendable (PaddleOcrInstallProgress) -> Void) async throws -> PaddleOcrInstallResult {
        throw SlateSyncError(code: "TEST", message: "unused")
    }
    func cancelPaddleOCRInstallation() async {}
}

private struct AdmissionLifecycle: ProductLifecycleServing {
    func drain() async throws {}
}

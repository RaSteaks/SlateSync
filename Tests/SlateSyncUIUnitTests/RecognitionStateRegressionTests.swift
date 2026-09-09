import SlateSyncDomain
@testable import SlateSyncUI
import XCTest

/// Regression freeze for review finding #7: the recognition state machine
/// must clear its operationID when an operation finishes (success or cancel),
/// so a late cancel or progress event can never adopt or repaint a finished
/// operation — e.g. a cancel that lands while finishOperation is still
/// draining the progress task must not overwrite .succeeded with .canceled.
@MainActor
final class RecognitionStateRegressionTests: XCTestCase {
    private func startRecognition(_ model: RecognitionModel) {
        model.recognize(
            .init(projectID: "p1", input: .bytes(Data([0x01]), filename: "a.jpg"), filename: "a.jpg",
                providerID: "custom-test", modelID: "vision-test"),
            flush: {})
    }

    private func waitForTerminalState(_ model: RecognitionModel) async {
        for _ in 0..<1000 where model.operation.isRunning { await Task.yield() }
    }

    func testFinishOperationClearsOperationIDOnSuccess() async throws {
        let service = RecognitionStateFake()
        let model = RecognitionModel(service: service, settings: RecognitionSettingsFake())
        await model.loadOptions()
        XCTAssertTrue(model.canRecognize(providerID: "custom-test", modelID: "vision-test"))
        startRecognition(model)
        // Yield the main actor until the operation task parks at the service
        // gate, then let the service return success.
        for _ in 0..<16 { await Task.yield() }
        await service.openRecognize()
        await waitForTerminalState(model)
        guard case .succeeded = model.operation else { return XCTFail("识别应成功完成：\(model.operation)") }
        XCTAssertNotNil(model.result)
        // A finished operation owns no identity anymore: a late cancel or
        // progress event must not be able to adopt it.
        XCTAssertNil(model.operationID, "完成的操作必须清空 operationID")
        // Cancelling a finished operation is a no-op and cannot repaint it.
        model.cancel()
        guard case .succeeded = model.operation else { return XCTFail("已完成操作不得被取消改写：\(model.operation)") }
    }

    func testFinishOperationClearsOperationIDOnCancel() async throws {
        let service = RecognitionStateFake()
        let model = RecognitionModel(service: service, settings: RecognitionSettingsFake())
        await model.loadOptions()
        startRecognition(model)
        for _ in 0..<16 { await Task.yield() }
        model.cancel()
        // The operation task observes cancellation and writes .canceled
        // itself; finishOperation then clears the identity.
        for _ in 0..<1000 where model.operationID != nil { await Task.yield() }
        XCTAssertNil(model.operationID, "取消完成的操作必须清空 operationID")
        await service.openCancel()
        for _ in 0..<100 { await Task.yield() }
        guard case .canceled = model.operation else { return XCTFail("取消后应为 canceled 状态：\(model.operation)") }
        // Admission has recovered: a fresh recognition runs to completion.
        await service.openRecognize()
        startRecognition(model)
        await waitForTerminalState(model)
        guard case .succeeded = model.operation else { return XCTFail("取消后应能再次识别：\(model.operation)") }
        XCTAssertNil(model.operationID)
    }
}

private final class RecognitionGate: @unchecked Sendable {
    private let lock = NSLock()
    private var opened = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    var isOpen: Bool { lock.withLock { opened } }

    func wait() async {
        guard !lock.withLock({ opened }) else { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            lock.withLock {
                if opened { continuation.resume(); return }
                waiters.append(continuation)
            }
        }
    }

    func open() {
        let current: [CheckedContinuation<Void, Never>] = lock.withLock {
            opened = true
            let current = waiters
            waiters.removeAll()
            return current
        }
        current.forEach { $0.resume() }
    }
}

/// Service double whose recognition suspends on explicit gates so the test
/// can order completion against cancel deterministically.
private actor RecognitionStateFake: WorkspaceWorkflowServing {
    let recognizeGate = RecognitionGate()
    let cancelGate = RecognitionGate()

    func openRecognize() { recognizeGate.open() }
    func openCancel() { cancelGate.open() }

    static let data = RecognitionData(
        provider: "custom-test", model: "vision-test", durationMs: 1, pageCount: 1,
        accuracyMode: .standard,
        ocr: .init(enabled: false, available: false, used: false, cacheHit: false, engine: "none",
            pageCount: 1, viewCount: 1, blockCount: 0, lowConfidenceBlockCount: 0, durationMs: 0),
        result: .init(sheetTitle: "t", records: [], warnings: [])
    )

    func recognize(_ request: NativeRecognitionRequest) async throws -> RecognitionData {
        // A real provider transport observes cancellation while a request is
        // in flight; emulate that instead of parking past cancellation.
        while !recognizeGate.isOpen {
            try Task.checkCancellation()
            await Task.yield()
        }
        return Self.data
    }

    func cancelRecognition(projectID: String) async { await cancelGate.wait() }

    func recognitionProgress(projectID: String) async -> AsyncStream<RecognitionProgress> {
        AsyncStream { $0.finish() }
    }

    func listTasks(projectID: String) async throws -> [TaskListItem] { [] }
    func loadTask(projectID: String, taskID: String) async throws -> TaskData { TaskData() }
    func saveTask(projectID: String, taskID: String?, task: TaskData) async throws -> String { taskID ?? "fake" }
    func deleteTask(projectID: String, taskID: String) async throws {}
    func decodeResolveCSV(_ data: Data) async throws -> ResolveCSVTable {
        throw SlateSyncError(code: "TEST_UNREACHABLE", message: "not part of this fixture", status: 500)
    }
    func encodeResolveCSV(_ table: ResolveCSVTable) async throws -> Data {
        throw SlateSyncError(code: "TEST_UNREACHABLE", message: "not part of this fixture", status: 500)
    }
    func resolveMaterialKeys(in table: ResolveCSVTable) async throws -> [String] {
        throw SlateSyncError(code: "TEST_UNREACHABLE", message: "not part of this fixture", status: 500)
    }
    func scanMetadata(directory: URL, options: SlateMetadataScanOptions) async throws -> ScanResult {
        throw SlateSyncError(code: "TEST_UNREACHABLE", message: "not part of this fixture", status: 500)
    }
    func closeProject(id: String) async throws {}
}

private struct RecognitionSettingsFake: GlobalSettingsWorkflowServing {
    private static let projection = GlobalSettingsProjection(
        values: .init(),
        customProviders: [],
        providers: [.init(id: "custom-test", label: "Custom Test", configured: true)],
        models: [Self.model],
        configuredCredentialProviderIDs: [],
        visionAvailable: true,
        paddleAvailable: false,
        runtime: .init(resolvedSettingCount: 0, globalConfigVersion: 1, environmentFileLoaded: false, migrationStatus: .sourceMissing)
    )

    private static let model = ModelData(
        id: "vision-test", label: "Vision Test", description: "offline fixture",
        providers: ["custom-test"], verifiedAvailable: true, capabilityStatus: .verified
    )

    func globalSettings() async throws -> GlobalSettingsProjection { Self.projection }
    func saveGlobalSettings(values: GlobalSettingValues, customProviders: [CustomProviderConfiguration]) async throws -> GlobalSettingsProjection { Self.projection }
    func setProviderCredential(_ value: String?, providerID: String) async throws {}
    func retryLegacyCredentialMigration() async throws -> GlobalSettingsProjection { Self.projection }
    func discoverModels(providerID: String, forceRefresh: Bool) async throws -> ModelDiscoveryResult {
        throw SlateSyncError(code: "TEST_UNREACHABLE", message: "not part of this fixture", status: 500)
    }
    func probeModels(providerID: String, modelIDs: [String], progress: @escaping @Sendable (ModelProbeProgress) -> Void) async throws -> ModelProbeResult {
        throw SlateSyncError(code: "TEST_UNREACHABLE", message: "not part of this fixture", status: 500)
    }
    func cancelModelProbe(providerID: String) async {}
    func installPaddleOCR(progress: @escaping @Sendable (PaddleOcrInstallProgress) -> Void) async throws -> PaddleOcrInstallResult {
        throw SlateSyncError(code: "TEST_UNREACHABLE", message: "not part of this fixture", status: 500)
    }
    func cancelPaddleOCRInstallation() async {}
}

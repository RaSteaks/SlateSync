import Foundation
import Synchronization
import SlateSyncDomain
@testable import SlateSyncUI
import XCTest

/// SM-09 #11: window close and application Quit must execute the same
/// coordinator-owned teardown order. A writer added to teardown joins the
/// shared WindowSession pipeline; it can no longer join only one path.
/// Thread-safe order log shared by every teardown step, the application
/// drain and the lifecycle drain.
private final class TeardownRecorder: Sendable {
    private let entries = Mutex<[String]>([])
    func record(_ name: String) { entries.withLock { $0.append(name) } }
    var list: [String] { entries.withLock { $0 } }
}

@MainActor
final class WindowSessionTeardownTests: XCTestCase {
    private final class CloseFailures: Sendable {
        private let remaining = Mutex<Int>(0)
        init(_ remaining: Int) { self.remaining.withLock { $0 = remaining } }
        /// Returns true exactly `remaining` times, then stops failing.
        func take() -> Bool {
            remaining.withLock { state -> Bool in
                guard state > 0 else { return false }
                state -= 1
                return true
            }
        }
    }

    /// The drain prefix is the frozen window teardown; close continues with
    /// runtime close and logs stop. Names mirror the production wiring.
    private func recordingSession(_ recorder: TeardownRecorder, closeFailures: CloseFailures = CloseFailures(0)) -> WindowSession {
        WindowSession(
            drainSteps: [
                (name: "selection-stability", action: { recorder.record("selection-stability") }),
                (name: "settings-flush", action: { recorder.record("settings-flush") }),
                (name: "csv-drain", action: { recorder.record("csv-drain") }),
                (name: "recognition-drain", action: { recorder.record("recognition-drain") }),
                (name: "metadata-drain", action: { recorder.record("metadata-drain") }),
                (name: "media-drain", action: { recorder.record("media-drain") }),
                (name: "workspace-flush", action: { recorder.record("workspace-flush") }),
            ],
            closeSteps: [
                (name: "runtime-close", action: {
                    recorder.record("runtime-close")
                    if closeFailures.take() {
                        throw SlateSyncError(code: "TEST_CLOSE", message: "注入窗口关闭失败", retryable: true)
                    }
                }),
                (name: "logs-stop", action: { recorder.record("logs-stop") }),
            ]
        )
    }

    private static let drainOrder = [
        "selection-stability", "settings-flush", "csv-drain", "recognition-drain",
        "metadata-drain", "media-drain", "workspace-flush",
    ]

    func testWindowCloseAndQuitShareOneTeardownOrder() async throws {
        // Separate logs keep the close evidence and the Quit evidence apart.
        let closeRecorder = TeardownRecorder()
        let quitRecorder = TeardownRecorder()
        let termination = TerminationCoordinator(lifecycle: RecordingLifecycle(recorder: quitRecorder))
        let closeID = UUID()
        await termination.registerSession(id: closeID, session: recordingSession(closeRecorder))

        try await termination.closeWindow(id: closeID)

        XCTAssertEqual(closeRecorder.list, Self.drainOrder + ["runtime-close", "logs-stop"])

        let quitID = UUID()
        await termination.registerSession(id: quitID, session: recordingSession(quitRecorder))
        termination.applicationDrain = { quitRecorder.record("application-drain") }
        let result = await termination.requestTermination()

        XCTAssertTrue(result)
        // Quit reuses the same window drain, then drains the application and
        // runtime; it never runs the close-only steps.
        XCTAssertEqual(quitRecorder.list, Self.drainOrder + ["application-drain", "lifecycle-drain"])
    }

    func testCloseWindowFailureKeepsRegistrationAndRetries() async throws {
        let recorder = TeardownRecorder()
        let termination = TerminationCoordinator(lifecycle: RecordingLifecycle(recorder: recorder))
        let id = UUID()
        await termination.registerSession(
            id: id,
            session: recordingSession(recorder, closeFailures: CloseFailures(1))
        )

        do {
            try await termination.closeWindow(id: id)
            XCTFail("注入的关闭失败必须上抛")
        } catch {
            XCTAssertEqual((error as? SlateSyncError)?.code, "TEST_CLOSE")
        }
        // The failed close stops after runtime-close; the window keeps its
        // registration so a retry reaches a terminal state.
        XCTAssertEqual(recorder.list, Self.drainOrder + ["runtime-close"])

        try await termination.closeWindow(id: id)
        XCTAssertEqual(
            recorder.list,
            Self.drainOrder + ["runtime-close"] + Self.drainOrder + ["runtime-close", "logs-stop"]
        )

        // A closed window is unregistered; a stale second close is a no-op.
        try await termination.closeWindow(id: id)
        XCTAssertEqual(recorder.list.count, 17)
    }

    func testRegisterWindowWiresRealModelsIntoSharedPipeline() async throws {
        let recorder = TeardownRecorder()
        let termination = TerminationCoordinator(lifecycle: RecordingLifecycle(recorder: recorder))
        let service = TeardownWorkspaceFake()
        let workspace = WorkspaceModel(service: service)
        workspace.acquireProject = { _ in }
        workspace.releaseProject = { _ in recorder.record("workspace-release") }
        try await workspace.activate(projectID: "p1")
        // Activation flushes too; only the close-path editor commit is under
        // test here, so the recording seam is attached after activation.
        workspace.flushEditor = { recorder.record("workspace-flush-editor") }
        let id = UUID()

        await termination.registerWindow(
            id: id,
            workspace: workspace,
            recognition: RecognitionModel(service: service, settings: TeardownSettingsFake()),
            csv: ResolveCSVModel(service: service),
            metadata: MetadataScanModel(service: service),
            media: MediaInputModel(service: service),
            logs: LogsModel(service: service)
        )
        try await termination.closeWindow(id: id)

        // The real wiring reaches the close tail in the frozen order: the
        // drain's workspace flush commits the editor once, then the runtime
        // close flushes twice more (before and after the selection barrier),
        // releases the project, and the window is gone afterwards.
        XCTAssertEqual(recorder.list, [
            "workspace-flush-editor", "workspace-flush-editor",
            "workspace-flush-editor", "workspace-release",
        ])
        try await termination.closeWindow(id: id)
        XCTAssertEqual(recorder.list, [
            "workspace-flush-editor", "workspace-flush-editor",
            "workspace-flush-editor", "workspace-release",
        ])
    }
}

/// ProductLifecycleServing probe that records into the shared order log.
private final class RecordingLifecycle: ProductLifecycleServing {
    private let recorder: TeardownRecorder
    init(recorder: TeardownRecorder) { self.recorder = recorder }
    func drain() async throws { recorder.record("lifecycle-drain") }
}

/// Idle workspace/media/log service shared by the wiring test's real models.
private actor TeardownWorkspaceFake: WorkspaceWorkflowServing, MediaInputWorkflowServing, LogWorkflowServing {
    func listTasks(projectID: String) async throws -> [TaskListItem] { [] }
    func loadTask(projectID: String, taskID: String) async throws -> TaskData {
        TaskData(id: taskID, projectId: projectID, customPrompt: "")
    }
    func saveTask(projectID: String, taskID: String?, task: TaskData) async throws -> String { taskID ?? "generated" }
    func deleteTask(projectID: String, taskID: String) async throws {}
    func decodeResolveCSV(_ data: Data) async throws -> ResolveCSVTable {
        ResolveCSVTable(headers: [], rows: [], format: ResolveCSVFormat())
    }
    func encodeResolveCSV(_ table: ResolveCSVTable) async throws -> Data { Data() }
    func resolveMaterialKeys(in table: ResolveCSVTable) async throws -> [String] { [] }
    func scanMetadata(directory: URL, options: SlateMetadataScanOptions) async throws -> ScanResult {
        ScanResult(
            metadata: [], warnings: [],
            stats: ScanStats(
                visitedDirectories: 0, prunedDirectories: 0, skippedDeepDirectories: 0,
                discoveredSlateFiles: 0, readSlateFiles: 0, learnedStructures: 0
            ),
            missingKeys: []
        )
    }
    func recognize(_ request: NativeRecognitionRequest) async throws -> RecognitionData {
        throw SlateSyncError(code: "TEST", message: "unused")
    }
    func recognitionProgress(projectID: String) async -> AsyncStream<RecognitionProgress> { AsyncStream { $0.finish() } }
    func cancelRecognition(projectID: String) async {}
    func closeProject(id: String) async throws {}
    func prepareInput(_ input: MediaInput) async throws -> PreparedDocument {
        throw SlateSyncError(code: "TEST", message: "unused")
    }
    func restoreInput(groups: [[String]], filename: String) async throws -> PreparedDocument {
        throw SlateSyncError(code: "TEST", message: "unused")
    }
    func logEntries(limit: Int, severities: Set<ProductLogSeverity>, category: String?) async -> [ProductLogEntry] { [] }
    func recordLog(_ entry: ProductLogEntry) async {}
    func logsDirectory() async -> URL { FileManager.default.temporaryDirectory }
}

/// RecognitionModel only requires this type at construction; teardown drains
/// never touch it, so every method stays unused.
private actor TeardownSettingsFake: GlobalSettingsWorkflowServing {
    func globalSettings() async throws -> GlobalSettingsProjection {
        throw SlateSyncError(code: "TEST", message: "unused")
    }
    func saveGlobalSettings(values: GlobalSettingValues, customProviders: [CustomProviderConfiguration]) async throws -> GlobalSettingsProjection {
        throw SlateSyncError(code: "TEST", message: "unused")
    }
    func setProviderCredential(_ value: String?, providerID: String) async throws {}
    func retryLegacyCredentialMigration() async throws -> GlobalSettingsProjection {
        throw SlateSyncError(code: "TEST", message: "unused")
    }
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

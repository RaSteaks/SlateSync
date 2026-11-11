import Foundation
import SlateSyncDomain
import SlateSyncPersistence
import SlateSyncWorkflow
import XCTest

@testable import SlateSyncUI

/// A slow save must be visible at once and must never turn repeated clicks into
/// repeated tasks: the creating flag is raised before the first suspension, a
/// second click during the save is dropped, and the flag clears afterwards.
/// The real-store case also checks durable ownership and autosave under the returned ID.
@MainActor
final class TaskCreationFeedbackTests: XCTestCase {
    // Keep durable creation and feedback ownership in one suite; this path uses an isolated real store.
    func testCreationPublishesDurableDataAndAutosavesUnderItsReturnedID() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "SlateSync-create-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let locator = ApplicationSupportLocator(root: root)
        let runtime = SlateSyncRuntime(locator: locator, environment: [:])
        let library = ProjectLibraryStartupService(locator: locator, machineSettings: runtime.machineSettingsStore,
            environment: [:], forceIsolatedRoot: true)
        let service = SlateSyncWorkflowFacade(library: library, runtime: runtime,
            logs: LocalLogStore(directory: root.appending(path: "logs")),
            paddleInstaller: PaddleOCRInstallerService(userDataRoot: root, requirementsURL: root.appending(path: "unused.txt")),
            allowsExternalOperations: false)
        let projection = try await service.projectLibrary()
        let projectID = try XCTUnwrap(projection.active.first?.id)
        // A caller's draft cannot choose ownership; the runtime stamps it.
        let initial = try await service.createTask(projectID: projectID,
            task: TaskData(projectId: "wrong-project", status: "draft", filename: "Existing", customPrompt: ""))
        XCTAssertEqual(initial.task.projectId, projectID)

        let workspace = WorkspaceModel(service: service)
        try await workspace.activate(projectID: projectID)
        await workspace.createTask()
        let created = try XCTUnwrap(workspace.selectedTask)
        let id = try XCTUnwrap(created.id)
        XCTAssertNotEqual(id, initial.task.id)
        XCTAssertEqual(workspace.tasks.count, 2)
        XCTAssertEqual(created.projectId, projectID)
        XCTAssertNotNil(created.createdAt)
        XCTAssertEqual(created.projectSettingsSnapshot, workspace.projectSettings)
        let stored = try await service.loadTask(projectID: projectID, taskID: id)
        XCTAssertEqual(created, stored)

        workspace.customPrompt = "Saved on the newly created task"
        try await workspace.flush()
        let edited = try await service.loadTask(projectID: projectID, taskID: id)
        XCTAssertEqual(edited.customPrompt, workspace.customPrompt)
        XCTAssertEqual(edited.createdAt, created.createdAt)
        try await workspace.close()
        try await library.close()
    }

    func testCreatingFlagIsImmediateAndSecondClickIsDropped() async throws {
        let service = GatedCreateService()
        let workspace = WorkspaceModel(service: service)
        workspace.acquireProject = { _ in }
        workspace.releaseProject = { _ in }
        try await workspace.activate(projectID: "p1")
        XCTAssertFalse(workspace.isCreatingTask)

        let first = Task { await workspace.createTask() }
        // The very first turn of the main actor already shows the pending state.
        await Task.yield()
        XCTAssertTrue(workspace.isCreatingTask, "The click must be acknowledged before any save completes")

        // Wait until the save is actually in flight, then click again.
        try await waitForCreation(service)
        await workspace.createTask()
        let savesWhileInFlight = await service.saveEntered
        XCTAssertEqual(savesWhileInFlight, 1, "A click during creation is dropped, not queued")

        await service.release()
        await first.value
        XCTAssertFalse(workspace.isCreatingTask)
        let totalSaves = await service.saveEntered
        XCTAssertEqual(totalSaves, 1)
        XCTAssertEqual(workspace.tasks.count, 1)
        // The returned snapshot is canonical; creation must not list/load again.
        let reads = await service.readCounts
        XCTAssertEqual(reads.list, 1, "Only initial activation reads the list")
        XCTAssertEqual(reads.load, 0)
        XCTAssertEqual(workspace.selectedTaskID, "t1")
        XCTAssertEqual(workspace.selectedTask?.createdAt, "2026-10-23T00:00:00.000Z")
        XCTAssertEqual(workspace.tasks.first?.updatedAt, workspace.selectedTask?.updatedAt)
        try await workspace.close()
    }

    func testFailureKeepsPreviousSelectionAndAllowsRetry() async throws {
        let service = GatedCreateService()
        let workspace = WorkspaceModel(service: service)
        try await workspace.activate(projectID: "p1")
        await service.release()
        await workspace.createTask()
        let before = workspace.selectedTask
        let tasks = workspace.tasks
        let generation = workspace.generation

        await service.failNextCreation()
        await workspace.createTask()
        XCTAssertFalse(workspace.isCreatingTask)
        XCTAssertFalse(workspace.isTransitioning)
        XCTAssertEqual(workspace.selectedTask, before)
        XCTAssertEqual(workspace.tasks, tasks)
        XCTAssertEqual(workspace.generation, generation)
        guard case .failed(let error) = workspace.operation else { return XCTFail("Expected failed creation") }
        XCTAssertEqual(error.code, "TEST_WRITE")

        await workspace.createTask()
        XCTAssertEqual(workspace.tasks.count, 2)
        XCTAssertNotEqual(workspace.selectedTaskID, before?.id)
        try await workspace.close()
    }

    func testBothFlushBarriersStillSaveThePreviousTaskBeforeCreating() async throws {
        let service = GatedCreateService()
        let workspace = WorkspaceModel(service: service)
        try await workspace.activate(projectID: "p1")
        await service.release()
        await workspace.createTask()
        workspace.customPrompt = "before drain"
        workspace.prepareSelectionChange = { workspace.customPrompt = "after drain" }
        await workspace.createTask()
        let saves = await service.savedPrompts
        XCTAssertEqual(saves, ["before drain", "after drain"])
        XCTAssertEqual(workspace.selectedTaskID, "t2")
        workspace.prepareSelectionChange = nil
        try await workspace.close()
    }

    func testFailedFlushDoesNotCreateAndAllowsRetry() async throws {
        let service = GatedCreateService()
        let workspace = WorkspaceModel(service: service)
        try await workspace.activate(projectID: "p1")
        workspace.flushEditor = { throw SlateSyncError(code: "TEST_FLUSH", message: "Draft cannot be saved") }
        await workspace.createTask()
        let calls = await service.saveEntered
        XCTAssertEqual(calls, 0)
        XCTAssertTrue(workspace.tasks.isEmpty)
        XCTAssertFalse(workspace.isCreatingTask)
        XCTAssertFalse(workspace.isTransitioning)

        workspace.flushEditor = nil
        await service.release()
        await workspace.createTask()
        XCTAssertEqual(workspace.tasks.count, 1)
        try await workspace.close()
    }

    func testDeactivationDuringCreationDoesNotPublishIntoAnotherContext() async throws {
        let service = GatedCreateService()
        let workspace = WorkspaceModel(service: service)
        try await workspace.activate(projectID: "p1")
        let creation = Task { await workspace.createTask() }
        try await waitForCreation(service)
        await workspace.deactivate()
        await service.release()
        await creation.value
        XCTAssertNil(workspace.projectID)
        XCTAssertNil(workspace.selectedTask)
        XCTAssertTrue(workspace.tasks.isEmpty)
        XCTAssertFalse(workspace.isCreatingTask)
        try await workspace.close()
    }

    private func waitForCreation(_ service: GatedCreateService) async throws {
        // A regression to the old save path must fail instead of hanging CI.
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while await service.saveEntered == 0 {
            guard ContinuousClock.now < deadline else {
                throw SlateSyncError(code: "TEST_TIMEOUT", message: "Combined creation was not called")
            }
            try await Task.sleep(for: .milliseconds(5))
        }
    }
}

/// Gate the combined creation call; count standalone reads to catch accidental
/// regressions to save/list/load while keeping autosave independent of the gate.
private actor GatedCreateService: WorkspaceWorkflowServing, ProjectContextWorkflowServing {
    private(set) var saveEntered = 0
    private(set) var readCounts = (list: 0, load: 0)
    private(set) var savedPrompts: [String] = []
    private var released = false
    private var shouldFail = false
    private var stored: [TaskListItem] = []

    func release() { released = true }
    func failNextCreation() { shouldFail = true }

    func listTasks(projectID: String) async throws -> [TaskListItem] {
        readCounts.list += 1
        return stored
    }
    func loadTask(projectID: String, taskID: String) async throws -> TaskData {
        readCounts.load += 1
        return TaskData(id: taskID, projectId: projectID, customPrompt: "")
    }
    func saveTask(projectID: String, taskID: String?, task: TaskData) async throws -> String {
        savedPrompts.append(task.customPrompt ?? "")
        return taskID ?? "unexpected-save"
    }
    func createTask(projectID: String, task: TaskData) async throws -> TaskCreationResult {
        saveEntered += 1
        while !released { try await Task.sleep(for: .milliseconds(5)) }
        if shouldFail {
            shouldFail = false
            throw SlateSyncError(code: "TEST_WRITE", message: "Injected creation failure")
        }
        let id = "t\(stored.count + 1)"
        let timestamp = "2026-10-23T00:00:00.000Z"
        let saved = TaskData(id: id, projectId: projectID, projectSettingsSnapshot: task.projectSettingsSnapshot,
            status: "draft", filename: task.filename, customPrompt: "", createdAt: timestamp, updatedAt: timestamp)
        stored.insert(TaskListItem(id: id, filename: saved.filename, recordCount: 0, status: "draft",
            createdAt: timestamp, updatedAt: timestamp), at: 0)
        return TaskCreationResult(task: saved, tasks: stored)
    }
    func deleteTask(projectID: String, taskID: String) async throws {}
    func decodeResolveCSV(_ data: Data) async throws -> ResolveCSVTable {
        throw SlateSyncError(code: "TEST", message: "unused")
    }
    func encodeResolveCSV(_ table: ResolveCSVTable) async throws -> Data { Data() }
    func resolveMaterialKeys(in table: ResolveCSVTable) async throws -> [String] { [] }
    func scanMetadata(directory: URL, options: SlateMetadataScanOptions) async throws -> ScanResult {
        throw SlateSyncError(code: "TEST", message: "unused")
    }
    func recognize(_ request: NativeRecognitionRequest) async throws -> RecognitionData {
        throw SlateSyncError(code: "TEST", message: "unused")
    }
    func recognitionProgress(projectID: String) async -> AsyncStream<RecognitionProgress> { AsyncStream { $0.finish() } }
    func cancelRecognition(projectID: String) async {}
    func closeProject(id: String) async throws {}
    func project(id: String) async throws -> ProjectData {
        ProjectData(summary: ProjectSummary(
            id: id, name: "p", relativePath: id, createdAt: "2026-01-01T00:00:00Z", updatedAt: "2026-01-01T00:00:00Z"))
    }
    func listScenarios(projectID: String) async throws -> [ScenarioSummary] { [] }
}

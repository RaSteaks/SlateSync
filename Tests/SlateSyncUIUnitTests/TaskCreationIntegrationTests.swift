import Foundation
import SlateSyncDomain
import SlateSyncPersistence
import SlateSyncWorkflow
import XCTest

@testable import SlateSyncUI

/// Exercise the production façade/runtime/store path without windows, network
/// requests, or the operator's real Library and Keychain.
@MainActor
final class TaskCreationIntegrationTests: XCTestCase {
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
}

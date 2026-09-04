import Foundation
import SlateSyncDomain
import XCTest
@testable import SlateSyncPersistence

final class ProjectLibraryTransferTests: XCTestCase {
    func testArchivedProjectPackageKeepsArchiveStateAcrossImport() async throws {
        let container = try PersistenceTestSupport.temporaryRoot("project-transfer-archive")
        defer { try? FileManager.default.removeItem(at: container) }
        let libraryRoot = container.appending(path: "Archive.slatesync-library", directoryHint: .isDirectory)
        let library = try ProjectLibraryStore(libraryRoot: libraryRoot)
        let project = try await library.createProject(name: "归档传输", description: "")
        let archived = try await library.archiveProject(project.id)
        let packageURL = container.appending(path: "Archived.slatesync-project", directoryHint: .isDirectory)
        _ = try await library.exportProject(project.id, to: packageURL)
        let package = try await ProjectLibraryTransfer.validateProjectPackage(at: packageURL)
        XCTAssertEqual(package.project.archivedAt, archived.archivedAt)
        let importedResult = try await library.importProject(from: packageURL)
        let imported = try XCTUnwrap(importedResult.project)
        XCTAssertEqual(imported.archivedAt, archived.archivedAt)
        try await library.close()
    }

    func testOpenProjectPackageRoundTripRebindsOwnershipAndPreservesSource() async throws {
        let container = try PersistenceTestSupport.temporaryRoot("project-transfer")
        defer { try? FileManager.default.removeItem(at: container) }
        let libraryRoot = container.appending(path: "Source.slatesync-library", directoryHint: .isDirectory)
        let library = try ProjectLibraryStore(libraryRoot: libraryRoot)
        let project = try await library.createProject(name: "片名 Day 01", description: "完整传输")
        let libraryID = try await library.libraryInfo().id
        let runtime = ProjectRuntime(library: library)
        let task = try PersistenceTestSupport.jsonData([
            "id": "transfer-task",
            "projectId": project.id,
            "libraryId": libraryID,
            "status": "completed",
            "unknownV1": ["retained": true],
        ])
        _ = try await runtime.saveTask(projectID: project.id, taskID: "transfer-task", payload: task)
        _ = try await runtime.saveDiagnostic(
            projectID: project.id,
            sessionID: "transfer-diagnostic",
            payload: try PersistenceTestSupport.jsonData([
                "id": "transfer-diagnostic",
                "projectId": project.id,
                "libraryId": libraryID,
                "result": ["records": []],
            ])
        )
        _ = try await runtime.importScenario(
            projectID: project.id,
            profile: PersistenceTestSupport.scenarioProfile(fingerprint: "transfer-profile")
        )
        let sourceProjectDirectory = libraryRoot.appending(path: project.relativePath, directoryHint: .isDirectory)
        let malformedSnapshot = Data("{ legacy snapshot is malformed".utf8)
        try malformedSnapshot.write(to: sourceProjectDirectory.appending(path: "tasks/legacy-broken.json"))
        try Data("unfinished".utf8).write(
            to: sourceProjectDirectory.appending(path: "tasks/legacy-broken.json.tmp")
        )

        let packageURL = container.appending(path: "Film.slatesync-project", directoryHint: .isDirectory)
        let exportResult = try await library.exportProject(project.id, to: packageURL)
        XCTAssertEqual(exportResult.project?.id, project.id)
        XCTAssertEqual(exportResult.path, packageURL.path)
        let package = try await ProjectLibraryTransfer.validateProjectPackage(at: packageURL)
        XCTAssertEqual(package.taskCount, 1)
        XCTAssertEqual(package.diagnosticCount, 1)
        XCTAssertEqual(package.project.id, project.id)
        XCTAssertFalse(FileManager.default.fileExists(atPath: packageURL.appending(path: "project.sqlite-wal").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: packageURL.appending(path: "project.sqlite-shm").path))
        XCTAssertEqual(try Data(contentsOf: packageURL.appending(path: "tasks/legacy-broken.json")), malformedSnapshot)
        XCTAssertFalse(FileManager.default.fileExists(atPath: packageURL.appending(path: "tasks/legacy-broken.json.tmp").path))
        let manifestObject = try XCTUnwrap(
            try JSONSerialization.jsonObject(
                with: Data(contentsOf: packageURL.appending(path: ProjectLibraryTransfer.projectPackageManifest))
            ) as? [String: Any]
        )
        let manifestProject = try XCTUnwrap(manifestObject["project"] as? [String: Any])
        XCTAssertTrue(manifestProject["archivedAt"] is NSNull)

        let firstImportResult = try await library.importProject(from: packageURL)
        let imported = try XCTUnwrap(firstImportResult.project)
        XCTAssertNotEqual(imported.id, project.id)
        XCTAssertEqual(imported.name, project.name)
        let importedTask = try PersistenceTestSupport.jsonObject(
            await runtime.loadTask(projectID: imported.id, taskID: "transfer-task")
        )
        XCTAssertEqual(importedTask["projectId"] as? String, imported.id)
        XCTAssertEqual(importedTask["libraryId"] as? String, libraryID)
        XCTAssertEqual((importedTask["unknownV1"] as? [String: Bool])?["retained"], true)
        let importedScenarios = try await runtime.listScenarios(projectID: imported.id)
        XCTAssertEqual(importedScenarios.count, 1)

        let importedDirectory = libraryRoot.appending(path: imported.relativePath, directoryHint: .isDirectory)
        XCTAssertEqual(
            try Data(contentsOf: importedDirectory.appending(path: "tasks/legacy-broken.json")),
            malformedSnapshot
        )
        let diagnostics = try DiagnosticsStore(projectDirectory: importedDirectory)
        let importedDiagnostic = try PersistenceTestSupport.jsonObject(
            await diagnostics.loadSession("transfer-diagnostic")
        )
        XCTAssertEqual(importedDiagnostic["projectId"] as? String, imported.id)
        XCTAssertEqual(importedDiagnostic["libraryId"] as? String, libraryID)
        try await diagnostics.close()

        let secondImportResult = try await library.importProject(from: packageURL)
        let second = try XCTUnwrap(secondImportResult.project)
        XCTAssertNotEqual(second.id, imported.id)
        let sourceTask = try PersistenceTestSupport.jsonObject(
            await runtime.loadTask(projectID: project.id, taskID: "transfer-task")
        )
        XCTAssertEqual(sourceTask["projectId"] as? String, project.id)
        try await runtime.close()
        try await library.close()
    }

    func testProjectPackageValidationRejectsFutureVersionLinksAndUnsafeDestinations() async throws {
        let container = try PersistenceTestSupport.temporaryRoot("project-transfer-invalid")
        defer { try? FileManager.default.removeItem(at: container) }
        let libraryRoot = container.appending(path: "Source.slatesync-library", directoryHint: .isDirectory)
        let library = try ProjectLibraryStore(libraryRoot: libraryRoot)
        let project = try await library.createProject(name: "安全边界", description: "")
        let packageURL = container.appending(path: "Safe.slatesync-project", directoryHint: .isDirectory)
        _ = try await library.exportProject(project.id, to: packageURL)

        let manifestURL = packageURL.appending(path: ProjectLibraryTransfer.projectPackageManifest)
        var manifest = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(contentsOf: manifestURL)) as? [String: Any]
        )
        manifest["formatVersion"] = 999
        try JSONSerialization.data(withJSONObject: manifest).write(to: manifestURL)
        do {
            _ = try await ProjectLibraryTransfer.validateProjectPackage(at: packageURL)
            XCTFail("future packages must be rejected")
        } catch let error as SlateSyncError {
            XCTAssertEqual(error.code, "INVALID_PROJECT_PACKAGE")
        }
        manifest["formatVersion"] = 1
        try JSONSerialization.data(withJSONObject: manifest).write(to: manifestURL)

        let outside = container.appending(path: "outside.json")
        try Data("{}".utf8).write(to: outside)
        let link = packageURL.appending(path: "tasks/linked.json")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        do {
            _ = try await ProjectLibraryTransfer.validateProjectPackage(at: packageURL)
            XCTFail("symbolic links must be rejected")
        } catch let error as SlateSyncError {
            XCTAssertEqual(error.code, "INVALID_PROJECT_PACKAGE")
        }
        try FileManager.default.removeItem(at: link)

        let invalidOwner = packageURL.appending(path: "tasks/invalid-owner.json")
        try JSONSerialization.data(withJSONObject: ["projectId": 42]).write(to: invalidOwner)
        do {
            _ = try await ProjectLibraryTransfer.validateProjectPackage(at: packageURL)
            XCTFail("non-string ownership must not be treated as an absent field")
        } catch let error as SlateSyncError {
            XCTAssertEqual(error.code, "INVALID_PROJECT_PACKAGE")
        }
        try FileManager.default.removeItem(at: invalidOwner)

        do {
            _ = try await library.exportProject(project.id, to: container.appending(path: "wrong.zip"))
            XCTFail("project exports require the portable package suffix")
        } catch let error as SlateSyncError {
            XCTAssertEqual(error.code, "INVALID_PROJECT_PACKAGE")
        }

        let existing = container.appending(path: "Existing.slatesync-project", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: existing, withIntermediateDirectories: true)
        do {
            _ = try await library.exportProject(project.id, to: existing)
            XCTFail("existing destinations must not be replaced")
        } catch let error as SlateSyncError {
            XCTAssertEqual(error.code, "PROJECT_DESTINATION_EXISTS")
        }
        let nested = libraryRoot.appending(path: project.relativePath).appending(path: "nested.slatesync-project")
        do {
            _ = try await library.exportProject(project.id, to: nested)
            XCTFail("a project cannot export inside itself")
        } catch let error as SlateSyncError {
            XCTAssertEqual(error.code, "INVALID_PROJECT_DESTINATION")
        }
        try await library.close()
    }

    func testOpenLibraryExportUsesStandaloneSQLiteBackups() async throws {
        let container = try PersistenceTestSupport.temporaryRoot("library-transfer")
        defer { try? FileManager.default.removeItem(at: container) }
        let sourceRoot = container.appending(path: "Source", directoryHint: .isDirectory)
        let source = try ProjectLibraryStore(libraryRoot: sourceRoot)
        let project = try await source.createProject(name: "可移植项目", description: "")
        let runtime = ProjectRuntime(library: source)
        _ = try await runtime.saveTask(
            projectID: project.id,
            taskID: "portable-task",
            payload: try PersistenceTestSupport.jsonData(["filename": "slate.png", "status": "completed"])
        )

        let target = container.appending(path: "Exported.slatesync-library", directoryHint: .isDirectory)
        let exported = try await source.exportLibrary(to: target)
        XCTAssertEqual(exported.library?.projectCount, 2)
        let validation = try await ProjectLibraryTransfer.validateLibrary(at: target)
        XCTAssertEqual(validation.projectCount, 2)
        let sidecarsBeforeOpen = FileManager.default.enumerator(atPath: target.path)?.allObjects
            .compactMap { $0 as? String }
            .filter { $0.hasSuffix("-wal") || $0.hasSuffix("-shm") } ?? []
        XCTAssertTrue(sidecarsBeforeOpen.isEmpty)

        let copied = try ProjectLibraryStore(libraryRoot: target)
        let copiedRuntime = ProjectRuntime(library: copied)
        let copiedTask = try PersistenceTestSupport.jsonObject(
            await copiedRuntime.loadTask(projectID: project.id, taskID: "portable-task")
        )
        XCTAssertEqual(copiedTask["filename"] as? String, "slate.png")
        let sourceTask = try PersistenceTestSupport.jsonObject(
            await runtime.loadTask(projectID: project.id, taskID: "portable-task")
        )
        XCTAssertEqual(sourceTask["filename"] as? String, "slate.png")
        try await copiedRuntime.close()
        try await copied.close()
        try await runtime.close()
        try await source.close()
    }

    func testLibraryActivationPersistsPathAndClosesOutgoingConnections() async throws {
        let container = try PersistenceTestSupport.temporaryRoot("library-activation")
        defer { try? FileManager.default.removeItem(at: container) }
        let outgoingRoot = container.appending(path: "Outgoing.slatesync-library", directoryHint: .isDirectory)
        let outgoing = try ProjectLibraryStore(libraryRoot: outgoingRoot)
        let outgoingProject = try await outgoing.createProject(name: "当前项目", description: "")
        let runtime = ProjectRuntime(library: outgoing)
        _ = try await runtime.listTasks(projectID: outgoingProject.id)

        let incomingRoot = container.appending(path: "Incoming.slatesync-library", directoryHint: .isDirectory)
        let incoming = try ProjectLibraryStore(libraryRoot: incomingRoot)
        _ = try await incoming.libraryInfo()
        try await incoming.close()
        let machineStore = MachineSettingsStore(applicationSupportRoot: container.appending(path: "Machine"))
        let coordinator = ProjectLibraryActivationCoordinator(
            library: outgoing,
            projectRuntime: runtime,
            machineSettings: machineStore
        )
        let result = try await coordinator.importLibrary(at: incomingRoot)
        XCTAssertTrue(result.restartRequired)
        XCTAssertEqual(result.library?.path, incomingRoot.path)
        let savedSettings = try await machineStore.load()
        XCTAssertEqual(savedSettings.libraryPath, incomingRoot.path)

        do {
            _ = try await runtime.listTasks(projectID: outgoingProject.id)
            XCTFail("outgoing project runtime must be terminal after activation")
        } catch let error as SlateSyncError {
            XCTAssertEqual(error.code, "PROJECT_RUNTIME_CLOSED")
        }
        do {
            _ = try await outgoing.listProjects()
            XCTFail("outgoing Library database must be closed before restart")
        } catch let error as SlateSyncError {
            XCTAssertEqual(error.code, "SQLITE_CLOSED")
        }
    }
}

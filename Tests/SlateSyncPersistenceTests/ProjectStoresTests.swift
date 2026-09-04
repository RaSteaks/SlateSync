import Foundation
import SlateSyncDomain
import XCTest
@testable import SlateSyncPersistence

final class ProjectStoresTests: XCTestCase {
    func testProjectRuntimeExposesCompleteStoreMutationSurface() async throws {
        let root = try PersistenceTestSupport.temporaryRoot("runtime-store-surface")
        defer { try? FileManager.default.removeItem(at: root) }
        let libraryRoot = root.appending(path: "Runtime.slatesync-library", directoryHint: .isDirectory)
        let library = try ProjectLibraryStore(libraryRoot: libraryRoot)
        let project = try await library.createProject(name: "Runtime", description: "")
        let runtime = ProjectRuntime(library: library)

        _ = try await runtime.saveTask(
            projectID: project.id,
            taskID: "runtime-task",
            payload: try PersistenceTestSupport.jsonData([
                "createdAt": "2020-01-01T00:00:00.000Z",
                "status": "created",
                "unknownV1": "kept",
            ])
        )
        _ = try await runtime.updateTask(
            projectID: project.id,
            taskID: "runtime-task",
            patch: try PersistenceTestSupport.jsonData([
                "projectId": "project-wrong",
                "status": "completed",
            ])
        )
        let updated = try PersistenceTestSupport.jsonObject(
            await runtime.loadTask(projectID: project.id, taskID: "runtime-task")
        )
        XCTAssertEqual(updated["projectId"] as? String, project.id)
        XCTAssertEqual(updated["createdAt"] as? String, "2020-01-01T00:00:00.000Z")
        XCTAssertEqual(updated["unknownV1"] as? String, "kept")
        XCTAssertEqual(updated["status"] as? String, "completed")

        _ = try await runtime.saveDiagnostic(
            projectID: project.id,
            sessionID: "runtime-diagnostic",
            payload: try PersistenceTestSupport.jsonData(["filename": "runtime.pdf"])
        )
        let diagnostics = try await runtime.listDiagnostics(projectID: project.id)
        XCTAssertEqual(diagnostics.map(\.id), ["runtime-diagnostic"])
        let diagnostic = try PersistenceTestSupport.jsonObject(
            await runtime.loadDiagnostic(projectID: project.id, sessionID: "runtime-diagnostic")
        )
        XCTAssertEqual(diagnostic["projectId"] as? String, project.id)
        try await runtime.deleteDiagnostic(projectID: project.id, sessionID: "runtime-diagnostic")
        let remainingDiagnostics = try await runtime.listDiagnostics(projectID: project.id)
        XCTAssertTrue(remainingDiagnostics.isEmpty)

        let profile = try await runtime.importScenario(
            projectID: project.id,
            profile: PersistenceTestSupport.scenarioProfile(fingerprint: "runtime-profile")
        )
        _ = try await runtime.recordScenarioObservation(
            projectID: project.id,
            profileID: profile.id,
            fingerprintVersion: profile.fingerprintVersion,
            fingerprint: profile.fingerprint,
            payload: try PersistenceTestSupport.jsonData(["match": "reused"])
        )
        let observed = try await runtime.loadScenario(projectID: project.id, scenarioID: profile.id)
        XCTAssertEqual(observed.sampleCount, 1)
        try await runtime.close()
        try await library.close()
    }

    func testTaskStorePreservesUnknownPayloadAndSnapshotAcrossReopen() async throws {
        let root = try PersistenceTestSupport.temporaryRoot("tasks")
        defer { try? FileManager.default.removeItem(at: root) }
        let project = root.appending(path: "project-task", directoryHint: .isDirectory)
        let payload = try PersistenceTestSupport.jsonData([
            "id": "task-one",
            "status": "completed",
            "filename": "slate.pdf",
            "provider": "openai",
            "model": "gpt-test",
            "unknownFutureField": ["kept": true],
            "result": ["records": [["id": "record-one"]]],
        ])
        let first = try ProjectTaskStore(projectDirectory: project)
        let savedID = try await first.saveTask(payload)
        XCTAssertEqual(savedID, "task-one")
        let snapshot = project.appending(path: "tasks/task-one.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: snapshot.path))
        let saved = try PersistenceTestSupport.jsonObject(await first.loadTask("task-one"))
        XCTAssertEqual((saved["unknownFutureField"] as? [String: Bool])?["kept"], true)
        let listedTasks = try await first.listTasks()
        XCTAssertEqual(listedTasks.first?.recordCount, 1)
        try await first.close()

        let reopened = try ProjectTaskStore(projectDirectory: project)
        let loaded = try PersistenceTestSupport.jsonObject(await reopened.loadTask("task-one"))
        XCTAssertEqual(loaded["id"] as? String, "task-one")
        XCTAssertNotNil(loaded["createdAt"] as? String)
        XCTAssertNotNil(loaded["updatedAt"] as? String)
        try await reopened.deleteTask("task-one")
        XCTAssertFalse(FileManager.default.fileExists(atPath: snapshot.path))
        try await reopened.close()
    }

    func testLegacyTaskSnapshotImportIgnoresMalformedSibling() async throws {
        let root = try PersistenceTestSupport.temporaryRoot("task-import")
        defer { try? FileManager.default.removeItem(at: root) }
        let project = root.appending(path: "project-import", directoryHint: .isDirectory)
        let snapshots = project.appending(path: "tasks", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: snapshots, withIntermediateDirectories: true)
        try Data(#"{"id":"legacy-task","status":"completed","createdAt":"2020-01-01T00:00:00.000Z"}"#.utf8)
            .write(to: snapshots.appending(path: "legacy-task.json"))
        try Data("not-json".utf8).write(to: snapshots.appending(path: "broken.json"))

        let store = try ProjectTaskStore(projectDirectory: project)
        let tasks = try await store.listTasks()
        XCTAssertEqual(tasks.map(\.id), ["legacy-task"])
        try await store.close()
    }

    func testDiagnosticsRetainsNewestTwentyRowsAndSnapshots() async throws {
        let root = try PersistenceTestSupport.temporaryRoot("diagnostics")
        defer { try? FileManager.default.removeItem(at: root) }
        let project = root.appending(path: "project-diagnostics", directoryHint: .isDirectory)
        let store = try DiagnosticsStore(projectDirectory: project)
        for index in 0..<22 {
            let payload = try PersistenceTestSupport.jsonData([
                "id": "session-\(index)",
                "filename": "\(index).pdf",
                "result": ["records": []],
            ])
            _ = try await store.saveSession(payload)
        }
        let sessions = try await store.listSessions()
        XCTAssertEqual(sessions.count, DiagnosticsStore.maximumSessionCount)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: project.appending(path: "diagnostics/session-0.json").path
        ))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: project.appending(path: "diagnostics/session-21.json").path
        ))
        try await store.close()
    }

    func testScenarioProfileAndObservationRemainProjectScoped() async throws {
        let root = try PersistenceTestSupport.temporaryRoot("scenarios")
        defer { try? FileManager.default.removeItem(at: root) }
        let firstProject = root.appending(path: "project-one", directoryHint: .isDirectory)
        let secondProject = root.appending(path: "project-two", directoryHint: .isDirectory)
        let first = try ScenarioStore(projectDirectory: firstProject)
        let second = try ScenarioStore(projectDirectory: secondProject)
        let profile = PersistenceTestSupport.scenarioProfile()

        let imported = try await first.importProfile(profile)
        XCTAssertTrue(imported.id.hasPrefix("scenario-"))
        XCTAssertEqual(imported.id.count, "scenario-".count + 16)
        let firstProfiles = try await first.listProfiles()
        let secondProfiles = try await second.listProfiles()
        XCTAssertEqual(firstProfiles.count, 1)
        XCTAssertEqual(secondProfiles.count, 0)
        let observation = try PersistenceTestSupport.jsonData(["fingerprint": profile.fingerprint])
        _ = try await first.recordObservation(
            profileID: imported.id,
            fingerprintVersion: 1,
            fingerprint: profile.fingerprint,
            payload: observation
        )
        let reused = try await first.getProfile(imported.id)
        XCTAssertEqual(reused.sampleCount, 1)

        let database = try SQLiteDatabase(
            url: firstProject.appending(path: SQLiteV1.projectDatabaseFilename)
        )
        try await database.execute("DELETE FROM scenario_profiles WHERE id = ?;", bindings: [imported.id])
        let deletedProfileID = try await database.scalar(
            "SELECT profile_id FROM scenario_observations LIMIT 1;"
        )
        XCTAssertNil(deletedProfileID)
        try await database.close()
        try await first.close()
        try await second.close()
    }

    func testConcurrentScenarioImportReturnsOneCanonicalProfile() async throws {
        let root = try PersistenceTestSupport.temporaryRoot("scenario-import-single-flight")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try ScenarioStore(
            projectDirectory: root.appending(path: "project", directoryHint: .isDirectory)
        )
        let profile = PersistenceTestSupport.scenarioProfile(fingerprint: "concurrent-profile")

        let imported = try await withThrowingTaskGroup(of: ScenarioData.self) { group in
            for _ in 0..<16 {
                group.addTask { try await store.importProfile(profile) }
            }
            var values: [ScenarioData] = []
            for try await value in group { values.append(value) }
            return values
        }

        XCTAssertEqual(Set(imported.map(\.id)).count, 1)
        let stored = try await store.listProfiles()
        XCTAssertEqual(stored.count, 1)
        try await store.close()
    }
}

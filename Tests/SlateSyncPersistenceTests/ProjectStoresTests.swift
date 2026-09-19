import Foundation
import SlateSyncDomain
import XCTest
@testable import SlateSyncPersistence

final class ProjectStoresTests: XCTestCase {
    func testConcurrentTaskPatchesPreserveEveryFieldAcrossConnections() async throws {
        for encrypted in [false, true] {
            let root = try PersistenceTestSupport.temporaryRoot("atomic-task-patches")
            defer { try? FileManager.default.removeItem(at: root) }
            if encrypted { try await LocalProjectEncryption.prepare(at: root, backend: InMemoryKeychainBackend()) }
            let first = try ProjectTaskStore(projectDirectory: root)
            _ = try await first.saveTask(Data(#"{"createdAt":"2020-01-01T00:00:00.000Z","nested":{"keep":1}}"#.utf8), taskID: "task")
            let second = try ProjectTaskStore(projectDirectory: root)
            _ = try await second.listTasks()
            // Independent database actors exercise SQLite transactions and the
            // encrypted cross-process lock, not only a store's actor executor.
            try await withThrowingTaskGroup(of: Void.self) { group in
                for index in 0..<30 {
                    let store = index.isMultiple(of: 2) ? first : second
                    group.addTask {
                        _ = try await store.updateTask("task", patch: Data("{\"field\(index)\":\(index)}".utf8))
                    }
                }
                try await group.waitForAll()
            }
            _ = try await first.updateTask("task", patch: Data(#"{"id":"wrong","createdAt":"wrong","nested":null}"#.utf8))
            let bytes = try await first.loadTask("task")
            let object = try PersistenceTestSupport.jsonObject(bytes)
            for index in 0..<30 { XCTAssertEqual(object["field\(index)"] as? Int, index) }
            XCTAssertEqual(object["id"] as? String, "task")
            XCTAssertEqual(object["createdAt"] as? String, "2020-01-01T00:00:00.000Z")
            XCTAssertTrue(object["nested"] is NSNull)
            XCTAssertEqual(try LocalProjectEncryption.read(from: root.appending(path: "tasks/task.json")), bytes)
            try await first.deleteTask("task")
            do {
                _ = try await second.updateTask("task", patch: Data(#"{"status":"completed"}"#.utf8))
                XCTFail("A patch must not recreate a deleted task")
            } catch { XCTAssertEqual((error as? SlateSyncError)?.code, "ENOENT") }
            try await first.close()
            try await second.close()
            let reopened = try ProjectTaskStore(projectDirectory: root)
            let remaining = try await reopened.listTasks()
            XCTAssertTrue(remaining.isEmpty)
            try await reopened.close()
        }
    }

    func testReopeningEncryptedDiagnosticsDoesNotRewriteAndImportsMissingSnapshots() async throws {
        let root = try PersistenceTestSupport.temporaryRoot("diagnostics-reopen")
        defer { try? FileManager.default.removeItem(at: root) }
        try await LocalProjectEncryption.prepare(at: root, backend: InMemoryKeychainBackend())
        let store = try DiagnosticsStore(projectDirectory: root)
        _ = try await store.saveSession(Data(#"{"filename":"authoritative.pdf"}"#.utf8), sessionID: "existing")
        try await store.close()
        let url = root.appending(path: SQLiteV1.projectDatabaseFilename)
        let before = try Data(contentsOf: url)
        // Reopening saved JSON must not reseal an unchanged database.
        let reopened = try DiagnosticsStore(projectDirectory: root)
        let sessions = try await reopened.listSessions()
        XCTAssertEqual(sessions.count, 1)
        try await reopened.close()
        XCTAssertEqual(try Data(contentsOf: url), before)
        let directory = root.appending(path: "diagnostics")
        try Data(#"{"id":"existing","filename":"stale.pdf"}"#.utf8).write(to: directory.appending(path: "existing.json"))
        try Data(#"{"id":"missing","filename":"recovered.pdf"}"#.utf8).write(to: directory.appending(path: "legacy-name.json"))
        let importing = try DiagnosticsStore(projectDirectory: root)
        let imported = try await importing.listSessions()
        XCTAssertEqual(Set(imported.compactMap(\.id)), ["existing", "missing"])
        XCTAssertEqual(imported.first { $0.id == "existing" }?.filename, "authoritative.pdf")
        try await importing.close()
        let afterImport = try Data(contentsOf: url)
        let final = try DiagnosticsStore(projectDirectory: root)
        _ = try await final.listSessions()
        try await final.close()
        XCTAssertEqual(try Data(contentsOf: url), afterImport)
    }

    func testReopeningManyEncryptedTasksDoesNotRewriteDatabase() async throws {
        let root = try PersistenceTestSupport.temporaryRoot("many-task-reopen")
        defer { try? FileManager.default.removeItem(at: root) }
        try await LocalProjectEncryption.prepare(at: root, backend: InMemoryKeychainBackend())
        let store = try ProjectTaskStore(projectDirectory: root)
        for index in 0..<32 {
            _ = try await store.saveTask(PersistenceTestSupport.jsonData([
                "id": "task-\(index)", "filename": "场记单-\(index).pdf",
                "imageDataUrls": [String(repeating: "A", count: 64 * 1024)],
            ]))
        }
        let expected = try await store.listTasks()
        try await store.close()
        let before = try Data(contentsOf: store.databaseURL)
        var durations: [Duration] = []
        for _ in 0..<5 {
            let start = ContinuousClock.now
            let reopened = try ProjectTaskStore(projectDirectory: root)
            let actual = try await reopened.listTasks()
            _ = try await reopened.loadTask("task-0")
            durations.append(start.duration(to: .now))
            XCTAssertEqual(actual, expected)
            try await reopened.close()
        }
        print("Encrypted project reopen, 32 × 64 KiB, median of 5: \(durations.sorted()[2])")
        // A changed nonce would expose even a logically identical rewrite.
        XCTAssertEqual(try Data(contentsOf: store.databaseURL), before)
    }

    func testTaskExistenceProbeDoesNotRequireFullPayload() async throws {
        let root = try PersistenceTestSupport.temporaryRoot("task-existence-probe")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try ProjectTaskStore(projectDirectory: root)
        _ = try await store.saveTask(PersistenceTestSupport.jsonData([
            "id": "large-task",
            "imageDataUrls": [String(repeating: "A", count: 512 * 1024)],
        ]))

        // The production query selects only a constant for this large row.
        try await store.requireTaskExists("large-task")
        do {
            try await store.requireTaskExists("missing-task")
            XCTFail("A missing task must fail the same ownership guard")
        } catch {
            XCTAssertEqual((error as? SlateSyncError)?.code, "ENOENT")
        }
        try await store.close()
    }

    func testReopenImportsMissingSnapshotsWithoutReplacingAuthoritativeRows() async throws {
        let root = try PersistenceTestSupport.temporaryRoot("task-missing-snapshot-import")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try ProjectTaskStore(projectDirectory: root)
        _ = try await store.saveTask(Data(#"{"id":"existing","status":"completed"}"#.utf8))
        try await store.close()
        let snapshots = root.appending(path: "tasks")
        try Data(#"{"id":"existing","status":"stale"}"#.utf8).write(to: snapshots.appending(path: "existing.json"))
        // Noncanonical legacy filenames still use the embedded ID on import.
        try Data(#"{"id":"missing","status":"draft"}"#.utf8).write(to: snapshots.appending(path: "legacy-name.json"))
        let reopened = try ProjectTaskStore(projectDirectory: root)
        let tasks = try await reopened.listTasks()
        XCTAssertEqual(Set(tasks.compactMap(\.id)), ["existing", "missing"])
        XCTAssertEqual(tasks.first { $0.id == "existing" }?.status, "completed")
        try await reopened.close()
        // Even a filename matching another SQLite row cannot hide a distinct
        // embedded legacy ID; filename-only shortcuts would lose this task.
        try Data(#"{"id":"embedded","status":"draft"}"#.utf8).write(to: snapshots.appending(path: "existing.json"))
        let legacy = try ProjectTaskStore(projectDirectory: root)
        let recovered = try await legacy.listTasks()
        XCTAssertEqual(Set(recovered.compactMap(\.id)), ["existing", "missing", "embedded"])
        try await legacy.close()
    }

    func testLibraryListingDoesNotRewriteEncryptedProjectSnapshots() async throws {
        let root = try PersistenceTestSupport.temporaryRoot("readonly-library-statistics")
        defer { try? FileManager.default.removeItem(at: root) }
        try await LocalProjectEncryption.prepare(at: root, backend: InMemoryKeychainBackend())
        let library = try ProjectLibraryStore(libraryRoot: root)
        let project = try await library.createProject(name: "统计只读", description: "")
        let store = try ProjectTaskStore(projectDirectory: root.appending(path: project.relativePath))
        _ = try await store.saveTask(Data(#"{"id":"sample","status":"draft"}"#.utf8))
        try await store.close()
        // An encrypted rewrite uses a new nonce even for identical content;
        // exact bytes prove that listing did not re-encrypt the project DB.
        let before = try Data(contentsOf: store.databaseURL)
        let projects = try await library.listProjects()
        XCTAssertEqual(projects.first { $0.id == project.id }?.taskCount, 1)
        XCTAssertEqual(try Data(contentsOf: store.databaseURL), before)
        try await library.close()
    }

    func testTaskListProjectionMatchesLegacyWithLargeMediaAndIrregularRecords() async throws {
        let root = try PersistenceTestSupport.temporaryRoot("task-projection-performance")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try ProjectTaskStore(projectDirectory: root)
        // Exercise empty edited arrays, malformed edited values and fallback
        // result counts while retaining large media and unknown payload fields.
        for index in 0..<24 {
            let edited: Any = index % 3 == 0 ? [] : index % 3 == 1 ? NSNull() : "invalid"
            _ = try await store.saveTask(PersistenceTestSupport.jsonData([
                "id": "task-\(index)", "filename": "长中文场记单-\(index).pdf",
                "provider": "test", "model": "fixture", "pageCount": 2,
                "status": "completed", "editedRecords": edited,
                "result": ["records": [["id": "one"], ["id": "two"]]],
                "imageDataUrls": [String(repeating: "A", count: 512 * 1024)],
                "futureField": ["preserved": true],
            ]))
        }
        let database = try SQLiteDatabase(url: store.databaseURL)
        let start = ContinuousClock.now
        let rows = try await database.rows("SELECT data_json FROM tasks ORDER BY updated_at DESC;")
        let expected = try rows.map { row -> TaskListItem in
            let object = try PersistenceTestSupport.jsonObject(Data(try XCTUnwrap(row["data_json"] ?? nil).utf8))
            return TaskListItem(
                id: PersistenceJSON.string(object["id"]), filename: PersistenceJSON.string(object["filename"]),
                provider: PersistenceJSON.string(object["provider"]), model: PersistenceJSON.string(object["model"]),
                pageCount: PersistenceJSON.int(object["pageCount"]), scenarioId: PersistenceJSON.string(object["scenarioId"]),
                recordCount: (object["editedRecords"] as? [Any])?.count ?? ((object["result"] as? [String: Any])?["records"] as? [Any])?.count ?? 0,
                status: PersistenceJSON.string(object["status"]) ?? "unknown",
                createdAt: PersistenceJSON.string(object["createdAt"]), updatedAt: PersistenceJSON.string(object["updatedAt"])
            )
        }
        let legacyTime = start.duration(to: .now)
        let projectedStart = ContinuousClock.now
        let actual = try await store.listTasks()
        let projectedTime = projectedStart.duration(to: .now)
        XCTAssertEqual(actual, expected)
        let preserved = try PersistenceTestSupport.jsonObject(await store.loadTask("task-0"))
        XCTAssertEqual((preserved["imageDataUrls"] as? [String])?.first?.count, 512 * 1024)
        // Report comparative local timing without a flaky wall-clock assertion.
        print("Task list 24 × 512 KiB: legacy=\(legacyTime), projection=\(projectedTime)")
        try await database.close()
        try await store.close()
    }

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

import CryptoKit
import Foundation
import SlateSyncDomain
import XCTest
@testable import SlateSyncPersistence

final class ProjectLibraryStoreTests: XCTestCase {
    func testPortableLibraryRenamePreservesSuffixAndOpenSQLiteIdentity() async throws {
        let container = try PersistenceTestSupport.temporaryRoot("library-rename")
        defer { try? FileManager.default.removeItem(at: container) }
        let originalRoot = container.appending(path: "Original.slatesync-library", directoryHint: .isDirectory)
        let library = try ProjectLibraryStore(libraryRoot: originalRoot)
        let originalInfo = try await library.libraryInfo()
        let beforeRename = try await library.createProject(name: "改名前", description: "")

        let renamed = try await library.renameLibrary("存档库")
        let renamedRoot = container.appending(path: "存档库.slatesync-library", directoryHint: .isDirectory)
        XCTAssertEqual(renamed.path, renamedRoot.path)
        XCTAssertEqual(renamed.id, originalInfo.id)
        XCTAssertFalse(FileManager.default.fileExists(atPath: originalRoot.path))
        let restoredBeforeRename = try await library.getProject(beforeRename.id)
        XCTAssertEqual(restoredBeforeRename.name, "改名前")
        let afterRename = try await library.createProject(name: "改名后", description: "")
        let restoredAfterRename = try await library.getProject(afterRename.id)
        XCTAssertEqual(restoredAfterRename.name, "改名后")
        try await library.close()

        let reopened = try ProjectLibraryStore(libraryRoot: renamedRoot)
        let reopenedInfo = try await reopened.libraryInfo()
        let reopenedProject = try await reopened.getProject(beforeRename.id)
        XCTAssertEqual(reopenedInfo.name, "存档库")
        XCTAssertEqual(reopenedProject.name, "改名前")
        try await reopened.close()
    }

    func testProjectLifecycleAndMetadataSurviveCloseAndReopen() async throws {
        let container = try PersistenceTestSupport.temporaryRoot("library-lifecycle")
        defer { try? FileManager.default.removeItem(at: container) }
        let libraryRoot = container.appending(path: "Production.slatesync-library", directoryHint: .isDirectory)
        let first = try ProjectLibraryStore(libraryRoot: libraryRoot)
        try await first.bootstrap()
        let initialInfo = try await first.libraryInfo()
        let defaultProject = try await first.getProject(ProjectLibraryStore.defaultProjectID)
        XCTAssertEqual(initialInfo.formatVersion, 1)
        XCTAssertEqual(defaultProject.id, ProjectLibraryStore.defaultProjectID)

        let created = try await first.createProject(
            name: "  测试项目  ",
            description: "  初始描述  ",
            settings: ProjectSettings(providerId: "openai", modelId: "gpt-test")
        )
        XCTAssertEqual(created.name, "测试项目")
        XCTAssertEqual(created.description, "初始描述")
        let updated = try await first.updateProject(created.id, name: "更新项目", description: "新描述")
        XCTAssertEqual(updated.settings.providerId, "openai")
        XCTAssertEqual(updated.name, "更新项目")
        let archived = try await first.archiveProject(created.id)
        let activeProjects = try await first.listProjects()
        let allProjects = try await first.listProjects(includeArchived: true)
        let restoredArchive = try await first.restoreProject(created.id)
        XCTAssertNotNil(archived.archivedAt)
        XCTAssertFalse(activeProjects.contains { $0.id == created.id })
        XCTAssertTrue(allProjects.contains { $0.id == created.id })
        XCTAssertNil(restoredArchive.archivedAt)
        try await first.close()

        let reopened = try ProjectLibraryStore(libraryRoot: libraryRoot)
        let restored = try await reopened.getProject(created.id)
        XCTAssertEqual(restored.name, "更新项目")
        XCTAssertEqual(restored.settings.modelId, "gpt-test")
        XCTAssertEqual(restored.canArchive, true)
        let reopenedDefault = try await reopened.getProject(ProjectLibraryStore.defaultProjectID)
        XCTAssertEqual(reopenedDefault.canArchive, false)
        try await reopened.close()
    }

    func testCopiedV1LibrarySurvivesReadWriteCloseAndReopenWithoutSemanticDrift() async throws {
        let container = try PersistenceTestSupport.temporaryRoot("library-copy")
        defer { try? FileManager.default.removeItem(at: container) }
        let sourceRoot = container.appending(path: "Source.slatesync-library", directoryHint: .isDirectory)
        let source = try ProjectLibraryStore(libraryRoot: sourceRoot)
        let project = try await source.createProject(name: "复制项目", description: "v1")
        let sourceRuntime = ProjectRuntime(library: source)
        let taskPayload = try PersistenceTestSupport.jsonData([
            "id": "copied-task",
            "status": "completed",
            "filename": "copy.pdf",
            "provider": "openai",
            "model": "gpt-test",
            "unknownV1": ["retained": "yes"],
            "result": ["records": [["id": "one"]]],
        ])
        _ = try await sourceRuntime.saveTask(projectID: project.id, taskID: nil, payload: taskPayload)
        let sourceInfo = try await source.libraryInfo()
        try await sourceRuntime.close()
        try await source.close()

        let copiedRoot = container.appending(path: "Copied.slatesync-library", directoryHint: .isDirectory)
        try FileManager.default.copyItem(at: sourceRoot, to: copiedRoot)
        let copied = try ProjectLibraryStore(libraryRoot: copiedRoot)
        let copiedInfo = try await copied.libraryInfo()
        XCTAssertEqual(copiedInfo.id, sourceInfo.id)
        XCTAssertEqual(copiedInfo.formatVersion, sourceInfo.formatVersion)
        let copiedProject = try await copied.getProject(project.id)
        XCTAssertEqual(copiedProject.name, project.name)
        XCTAssertEqual(copiedProject.taskCount, 1)
        let copiedRuntime = ProjectRuntime(library: copied)
        let loaded = try PersistenceTestSupport.jsonObject(
            await copiedRuntime.loadTask(projectID: project.id, taskID: "copied-task")
        )
        XCTAssertEqual((loaded["unknownV1"] as? [String: String])?["retained"], "yes")
        _ = try await copiedRuntime.saveTask(
            projectID: project.id,
            taskID: "copied-task",
            payload: try PersistenceTestSupport.jsonData(loaded.merging(["status": "reviewed"]) { _, next in next })
        )
        try await copiedRuntime.close()
        try await copied.close()

        let final = try ProjectLibraryStore(libraryRoot: copiedRoot)
        let finalRuntime = ProjectRuntime(library: final)
        let finalTask = try PersistenceTestSupport.jsonObject(
            await finalRuntime.loadTask(projectID: project.id, taskID: "copied-task")
        )
        XCTAssertEqual(finalTask["status"] as? String, "reviewed")
        XCTAssertEqual((finalTask["unknownV1"] as? [String: String])?["retained"], "yes")
        try await finalRuntime.close()
        try await final.close()
    }

    func testDeleteRestoresDirectoryWhenLibraryIndexRejectsDeletion() async throws {
        let container = try PersistenceTestSupport.temporaryRoot("delete-rollback")
        defer { try? FileManager.default.removeItem(at: container) }
        let libraryRoot = container.appending(path: "Rollback.slatesync-library", directoryHint: .isDirectory)
        let library = try ProjectLibraryStore(libraryRoot: libraryRoot)
        let project = try await library.createProject(name: "不能半删", description: "")
        let projectDirectory = libraryRoot.appending(path: project.relativePath, directoryHint: .isDirectory)
        let probe = try SQLiteDatabase(url: libraryRoot.appending(path: SQLiteV1.libraryDatabaseFilename))
        try await probe.executeScript(
            """
            CREATE TRIGGER reject_project_delete BEFORE DELETE ON projects
            BEGIN SELECT RAISE(ABORT, 'forced delete rejection'); END;
            """
        )

        do {
            _ = try await library.deleteProject(project.id)
            XCTFail("forced index failure must reject deletion")
        } catch let error as SlateSyncError {
            XCTAssertEqual(error.code, "SQLITE_CONSTRAINT")
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: projectDirectory.path))
        let recovered = try await library.getProject(project.id)
        XCTAssertEqual(recovered.name, "不能半删")
        try await probe.executeScript("DROP TRIGGER reject_project_delete;")
        try await probe.close()
        try await library.close()
    }

    func testRuntimeClosesProjectStoresBeforeTombstoneDeletion() async throws {
        let container = try PersistenceTestSupport.temporaryRoot("runtime-delete")
        defer { try? FileManager.default.removeItem(at: container) }
        let libraryRoot = container.appending(path: "Delete.slatesync-library", directoryHint: .isDirectory)
        let library = try ProjectLibraryStore(libraryRoot: libraryRoot)
        let project = try await library.createProject(name: "待删除", description: "")
        let runtime = ProjectRuntime(library: library, writer: DelayedAtomicWriter(delay: 0.2))
        let payload = try PersistenceTestSupport.jsonData(["status": "created"])
        async let pendingSave = runtime.saveTask(
            projectID: project.id,
            taskID: "delete-task",
            payload: payload
        )
        // Let saveTask acquire its project lease and enter the deliberately
        // delayed snapshot write before deletion publishes PROJECT_DELETING.
        try await Task.sleep(for: .milliseconds(30))
        let deletedID = try await runtime.deleteProject(project.id)
        let savedID = try await pendingSave
        XCTAssertEqual(savedID, "delete-task")
        XCTAssertEqual(deletedID, project.id)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: libraryRoot.appending(path: project.relativePath).path
        ))
        do {
            _ = try await runtime.loadTask(projectID: project.id, taskID: "delete-task")
            XCTFail("deleted project must not reopen")
        } catch let error as SlateSyncError {
            XCTAssertEqual(error.code, "ENOENT")
        }
        try await runtime.close()
        try await library.close()
    }

    func testLegacyMigrationIsIdempotentAndLeavesSourceUntouched() async throws {
        let container = try PersistenceTestSupport.temporaryRoot("legacy-migration")
        defer { try? FileManager.default.removeItem(at: container) }
        let legacyRoot = container.appending(path: "legacy", directoryHint: .isDirectory)
        let sourceDatabaseURL = legacyRoot.appending(path: SQLiteV1.legacyDatabaseFilename)
        let source = try SQLiteDatabase(url: sourceDatabaseURL)
        try await SQLiteV1.bootstrapProject(source)
        let profile = PersistenceTestSupport.scenarioProfile(fingerprint: "legacy-fingerprint")
        let profileJSON = try XCTUnwrap(String(data: JSONEncoder().encode(profile), encoding: .utf8))
        try await source.execute(
            """
            INSERT INTO scenario_profiles
              (id, schema_version, fingerprint_version, fingerprint, profile_json,
               sample_count, created_at, updated_at, last_used_at)
            VALUES (?, '1', '1', ?, ?, '1', ?, ?, ?);
            """,
            bindings: ["scenario-0011223344556677", profile.fingerprint, profileJSON, "2020-01-01T00:00:00.000Z", "2020-01-01T00:00:00.000Z", "2020-01-01T00:00:00.000Z"]
        )
        try await source.execute(
            """
            INSERT INTO scenario_observations
              (id, profile_id, fingerprint_version, fingerprint, observation_json, created_at)
            VALUES ('observation-legacy', 'scenario-0011223344556677', '1', ?, '{}', '2020-01-01T00:00:00.000Z');
            """,
            bindings: [profile.fingerprint]
        )
        try await source.execute(
            "INSERT INTO tasks VALUES ('legacy-task', ?, '2020-01-01T00:00:00.000Z', '2020-01-01T00:00:00.000Z');",
            bindings: [#"{"id":"legacy-task","status":"completed"}"#]
        )
        try await source.execute(
            "INSERT INTO diagnostic_sessions VALUES ('legacy-diagnostic', ?, '2020-01-01T00:00:00.000Z');",
            bindings: [#"{"id":"legacy-diagnostic"}"#]
        )
        try await source.checkpoint()
        try await source.close()
        let sourceHash = SHA256.hash(data: try Data(contentsOf: sourceDatabaseURL))

        let taskSnapshots = legacyRoot.appending(path: "tasks", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: taskSnapshots, withIntermediateDirectories: true)
        let malformed = Data("{malformed-v1".utf8)
        try malformed.write(to: taskSnapshots.appending(path: "damaged.json"))

        let libraryRoot = container.appending(path: "Native.slatesync-library", directoryHint: .isDirectory)
        let library = try ProjectLibraryStore(libraryRoot: libraryRoot)
        let first = try await library.migrateLegacyData(from: legacyRoot)
        XCTAssertEqual(first.counts.tasks, 1)
        XCTAssertEqual(first.counts.diagnostics, 1)
        XCTAssertEqual(first.counts.scenarios, 1)
        XCTAssertEqual(first.counts.observations, 1)
        XCTAssertEqual(first.counts.snapshots, 1)
        let second = try await library.migrateLegacyData(from: legacyRoot)
        XCTAssertEqual(second, first)
        XCTAssertEqual(SHA256.hash(data: try Data(contentsOf: sourceDatabaseURL)), sourceHash)

        let defaultProject = try await library.getProject(ProjectLibraryStore.defaultProjectID)
        let runtime = ProjectRuntime(library: library)
        let task = try PersistenceTestSupport.jsonObject(
            await runtime.loadTask(projectID: defaultProject.id, taskID: "legacy-task")
        )
        XCTAssertEqual(task["projectId"] as? String, ProjectLibraryStore.defaultProjectID)
        let migratedMalformed = libraryRoot
            .appending(path: defaultProject.relativePath)
            .appending(path: "tasks/damaged.json")
        XCTAssertEqual(try Data(contentsOf: migratedMalformed), malformed)
        try await runtime.close()
        try await library.close()
    }
}

private struct DelayedAtomicWriter: AtomicFileWriting {
    let delay: TimeInterval

    func writeAtomically(_ data: Data, to url: URL, permissions: Int) throws {
        Thread.sleep(forTimeInterval: delay)
        try FileManagerAtomicFileWriter().writeAtomically(data, to: url, permissions: permissions)
    }
}

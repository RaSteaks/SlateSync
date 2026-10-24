import Foundation
import SlateSyncDomain
import XCTest

@testable import SlateSyncPersistence

@MainActor
final class TaskSnapshotTransactionTests: XCTestCase {
    func testCombinedCreationReturnsCommittedTaskAndFreshList() async throws {
        for encrypted in [false, true] {
            let root = try PersistenceTestSupport.temporaryRoot("combined-creation")
            defer { try? FileManager.default.removeItem(at: root) }
            if encrypted { try await LocalProjectEncryption.prepare(at: root, backend: InMemoryKeychainBackend()) }
            let store = try ProjectTaskStore(projectDirectory: root)
            _ = try await store.saveTask(Data(#"{"id":"existing","customPrompt":"keep"}"#.utf8))
            _ = try await store.listTasks()
            // A fresh list must include writes from another connection, even
            // when that connection was opened after this store's last refresh.
            let other = try ProjectTaskStore(projectDirectory: root)
            _ = try await other.saveTask(Data(#"{"id":"external","filename":"External"}"#.utf8))
            try await other.close()
            let result = try await store.createTask(Data(#"{"id":"existing","status":"draft","filename":"New","customPrompt":"new"}"#.utf8))
            let id = try XCTUnwrap(result.task.id)
            XCTAssertNotEqual(id, "existing", "A stale draft ID must not replace another task")
            XCTAssertNotNil(result.task.createdAt)
            XCTAssertEqual(result.task.createdAt, result.task.updatedAt)
            let items = try await store.listTasks()
            XCTAssertEqual(result.tasks, items)
            XCTAssertEqual(Set(result.tasks.compactMap(\.id)), ["existing", "external", id])
            let summary = try XCTUnwrap(result.tasks.first { $0.id == id })
            XCTAssertEqual(summary.filename, result.task.filename)
            XCTAssertEqual(summary.updatedAt, result.task.updatedAt)
            XCTAssertEqual(summary.status, "draft")
            let mirror = try LocalProjectEncryption.read(from: root.appending(path: "tasks/\(id).json"))
            XCTAssertEqual(try JSONDecoder().decode(TaskData.self, from: mirror), result.task)
            try await store.close()

            let reopened = try ProjectTaskStore(projectDirectory: root)
            let loaded = try await reopened.loadTask(id)
            XCTAssertEqual(try JSONDecoder().decode(TaskData.self, from: loaded), result.task)
            let preserved = try await reopened.loadTask("existing")
            XCTAssertEqual(try JSONDecoder().decode(TaskData.self, from: preserved).customPrompt, "keep")
            try await reopened.close()
        }
    }

    func testCombinedCreationFailureLeavesNoOrphansAndCanRetry() async throws {
        for encrypted in [false, true] {
            for replaceFirst in [false, true] {
                let root = try PersistenceTestSupport.temporaryRoot("combined-creation-failure")
                defer { try? FileManager.default.removeItem(at: root) }
                if encrypted { try await LocalProjectEncryption.prepare(at: root, backend: InMemoryKeychainBackend()) }
                let store = try ProjectTaskStore(projectDirectory: root, writer: RejectSnapshotWriter(replaceFirst: replaceFirst))
                do {
                    _ = try await store.createTask(Data(#"{"filename":"draft"}"#.utf8))
                    XCTFail("Expected injected failure")
                } catch { XCTAssertEqual((error as? SlateSyncError)?.code, "TEST_WRITE") }
                let items = try await store.listTasks()
                XCTAssertTrue(items.isEmpty)
                let files = try FileManager.default.contentsOfDirectory(atPath: root.appending(path: "tasks").path)
                XCTAssertFalse(files.contains { $0.hasSuffix(".json") || $0.hasSuffix(".pending") })
                try await store.close()

                let reopened = try ProjectTaskStore(projectDirectory: root)
                let afterRestart = try await reopened.listTasks()
                XCTAssertTrue(afterRestart.isEmpty)
                let result = try await reopened.createTask(Data(#"{"filename":"retry"}"#.utf8))
                XCTAssertEqual(result.tasks.compactMap(\.id), [try XCTUnwrap(result.task.id)])
                try await reopened.close()
            }
        }
    }

    func testFailedCreatesLeaveNoRowsOrImportableSnapshots() async throws {
        let root = try PersistenceTestSupport.temporaryRoot("snapshot-failure")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try ProjectTaskStore(projectDirectory: root, writer: RejectSnapshotWriter())
        for _ in 0..<2 {
            do {
                _ = try await store.saveTask(Data(#"{"filename":"draft"}"#.utf8))
                XCTFail("Expected injected failure")
            } catch { XCTAssertEqual((error as? SlateSyncError)?.code, "TEST_WRITE") }
        }
        let items = try await store.listTasks()
        XCTAssertTrue(items.isEmpty)
        try await store.close()
        let reopened = try ProjectTaskStore(projectDirectory: root)
        let afterRestart = try await reopened.listTasks()
        XCTAssertTrue(afterRestart.isEmpty)
        _ = try await reopened.saveTask(Data(#"{"filename":"draft"}"#.utf8))
        let afterRetry = try await reopened.listTasks()
        XCTAssertEqual(afterRetry.count, 1)
        try await reopened.close()
    }

    func testFailedPatchRestoresRowAndMirrorEvenWhenWriterThrowsAfterReplacement() async throws {
        let root = try PersistenceTestSupport.temporaryRoot("snapshot-patch")
        defer { try? FileManager.default.removeItem(at: root) }
        let initial = try ProjectTaskStore(projectDirectory: root)
        _ = try await initial.saveTask(Data(#"{"id":"draft","customPrompt":"old"}"#.utf8))
        let before = try await initial.loadTask("draft")
        try await initial.close()
        let failing = try ProjectTaskStore(projectDirectory: root, writer: RejectSnapshotWriter(replaceFirst: true))
        do {
            _ = try await failing.updateTask("draft", patch: Data(#"{"customPrompt":"new"}"#.utf8))
            XCTFail("Expected injected failure")
        } catch { XCTAssertEqual((error as? SlateSyncError)?.code, "TEST_WRITE") }
        let after = try await failing.loadTask("draft")
        XCTAssertEqual(after, before)
        XCTAssertEqual(try Data(contentsOf: root.appending(path: "tasks/draft.json")), before)
        try await failing.close()
    }

    func testEncryptedSnapshotFailureRollsBackAndReopens() async throws {
        let root = try PersistenceTestSupport.temporaryRoot("encrypted-snapshot-failure")
        defer { try? FileManager.default.removeItem(at: root) }
        try await LocalProjectEncryption.prepare(at: root, backend: InMemoryKeychainBackend())
        let initial = try ProjectTaskStore(projectDirectory: root)
        _ = try await initial.saveTask(Data(#"{"id":"draft","customPrompt":"old"}"#.utf8))
        let before = try await initial.loadTask("draft")
        try await initial.close()
        let failing = try ProjectTaskStore(projectDirectory: root, writer: RejectSnapshotWriter(replaceFirst: true))
        do {
            _ = try await failing.updateTask("draft", patch: Data(#"{"customPrompt":"new"}"#.utf8))
            XCTFail("Expected failure")
        } catch { XCTAssertEqual((error as? SlateSyncError)?.code, "TEST_WRITE") }
        try await failing.close()
        let reopened = try ProjectTaskStore(projectDirectory: root)
        let after = try await reopened.loadTask("draft")
        XCTAssertEqual(after, before)
        XCTAssertEqual(try LocalProjectEncryption.read(from: root.appending(path: "tasks/draft.json")), before)
        try await reopened.close()
    }

    func testNativeEditsPreserveSQLTimestampWhenLegacyJSONOmitsIt() async throws {
        let root = try PersistenceTestSupport.temporaryRoot("legacy-task-timestamp")
        defer { try? FileManager.default.removeItem(at: root) }
        let snapshots = root.appending(path: "tasks")
        try FileManager.default.createDirectory(at: snapshots, withIntermediateDirectories: true)
        for (id, timestamp) in [("missing", ""), ("null", ",\"createdAt\":null")] {
            let json = "{\"id\":\"\(id)\",\"unknownFutureField\":true\(timestamp)}"
            try Data(json.utf8).write(to: snapshots.appending(path: "\(id).json"))
        }
        let store = try ProjectTaskStore(projectDirectory: root)
        for id in ["missing", "null"] {
            let original = try await store.loadTask(id)
            let typed = try JSONDecoder().decode(TaskData.self, from: original)
            XCTAssertNil(typed.createdAt)
            // The import keeps an authoritative timestamp in SQLite even when
            // the legacy JSON projection omitted it or explicitly stored null.
            if id == "null" {
                _ = try await store.updateTask(id, patch: Data(#"{"customPrompt":"edited"}"#.utf8))
            } else {
                _ = try await store.saveTask(JSONEncoder().encode(TaskData(id: id, customPrompt: "edited")),
                    taskID: id, replacingKeys: TaskData.persistenceFieldNames)
            }
            let bytes = try await store.loadTask(id)
            let object = try PersistenceTestSupport.jsonObject(bytes)
            XCTAssertEqual(object["createdAt"] as? String, "1970-01-01T00:00:00.000Z")
            XCTAssertEqual(object["unknownFutureField"] as? Bool, true)
            XCTAssertEqual(object["customPrompt"] as? String, "edited")
        }
        try await store.close()
    }

    func testInterruptedSnapshotIsReconciledBeforeLegacyImport() async throws {
        let root = try PersistenceTestSupport.temporaryRoot("snapshot-recovery")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try ProjectTaskStore(projectDirectory: root)
        _ = try await store.saveTask(Data(#"{"id":"existing","customPrompt":"committed"}"#.utf8))
        try await store.close()
        for id in ["existing", "uncommitted"] {
            try Data("{\"id\":\"\(id)\",\"customPrompt\":\"uncommitted\"}".utf8).write(
                to: root.appending(path: "tasks/\(id).json"))
            try Data().write(to: root.appending(path: "tasks/\(id).json.pending"))
        }
        let reopened = try ProjectTaskStore(projectDirectory: root)
        let items = try await reopened.listTasks()
        XCTAssertEqual(items.compactMap(\.id), ["existing"])
        let bytes = try await reopened.loadTask("existing")
        XCTAssertEqual(try JSONDecoder().decode(TaskData.self, from: bytes).customPrompt, "committed")
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appending(path: "tasks/uncommitted.json").path))
        try await reopened.close()
    }
}

/// Exercise errors both before and after the filesystem replacement boundary.
private struct RejectSnapshotWriter: AtomicFileWriting {
    var replaceFirst = false
    func writeAtomically(_ data: Data, to url: URL, permissions: Int) throws {
        if replaceFirst { try FileManagerAtomicFileWriter().writeAtomically(data, to: url, permissions: permissions) }
        throw SlateSyncError(code: "TEST_WRITE", message: "Injected snapshot write failure")
    }
}

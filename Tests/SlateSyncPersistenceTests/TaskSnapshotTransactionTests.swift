import Foundation
import SlateSyncDomain
import XCTest

@testable import SlateSyncPersistence

@MainActor
final class TaskSnapshotTransactionTests: XCTestCase {
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

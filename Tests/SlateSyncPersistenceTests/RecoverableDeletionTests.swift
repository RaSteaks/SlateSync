import Foundation
import SlateSyncDomain
import XCTest
@testable import SlateSyncPersistence

/// Freeze for the recoverable deletion contract: the SQLite row is confirmed
/// first, the JSON snapshot is removed second, the row is deleted last. A
/// failed snapshot removal or a failed row delete must leave the record
/// fully intact across a restart — SQLite stays authoritative at every step.
final class RecoverableDeletionTests: XCTestCase {
    private final class BlockingRemover: FileRemoving {
        let blocked: Set<String>
        init(blocked: Set<String>) { self.blocked = blocked }
        func removeItem(at url: URL) throws {
            if blocked.contains(url.lastPathComponent) {
                throw SlateSyncError(code: "TEST_REMOVE_DENIED", message: "注入的删除失败")
            }
            try FileManager.default.removeItem(at: url)
        }
    }

    private func taskPayload() throws -> Data {
        try PersistenceTestSupport.jsonData([
            "createdAt": "2020-01-01T00:00:00.000Z",
            "status": "completed",
            "filename": "a.pdf",
        ])
    }

    private func diagnosticPayload() throws -> Data {
        try PersistenceTestSupport.jsonData(["filename": "a.pdf"])
    }

    private func expectFailure(
        _ message: String,
        _ operation: () async throws -> Void
    ) async {
        do { try await operation(); XCTFail(message) } catch { /* 预期的失败 */ }
    }

    private func exists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    func testSnapshotRemovalFailureKeepsTaskAcrossReopen() async throws {
        let root = try PersistenceTestSupport.temporaryRoot("recoverable-task-remove")
        defer { try? FileManager.default.removeItem(at: root) }
        let projectDirectory = root.appending(path: "P.project", directoryHint: .isDirectory)
        let store = try ProjectTaskStore(projectDirectory: projectDirectory)
        _ = try await store.saveTask(try taskPayload(), taskID: "t1")
        let snapshotURL = projectDirectory.appending(path: "tasks/t1.json")
        let original = try Data(contentsOf: snapshotURL)

        let denied = try ProjectTaskStore(
            projectDirectory: projectDirectory,
            remover: BlockingRemover(blocked: ["t1.json"])
        )
        await expectFailure("快照删除失败必须返回错误") { try await denied.deleteTask("t1") }

        XCTAssertEqual(try Data(contentsOf: snapshotURL), original, "删除失败后快照必须原样保留")
        let reopened = try ProjectTaskStore(projectDirectory: projectDirectory)
        let loaded = try PersistenceTestSupport.jsonObject(await reopened.loadTask("t1"))
        XCTAssertEqual(loaded["id"] as? String, "t1", "删除失败后重启，记录必须仍然存在")
    }

    func testDatabaseFailureDuringRowDeleteRestoresSnapshot() async throws {
        let root = try PersistenceTestSupport.temporaryRoot("recoverable-task-database")
        defer { try? FileManager.default.removeItem(at: root) }
        let projectDirectory = root.appending(path: "P.project", directoryHint: .isDirectory)
        let store = try ProjectTaskStore(projectDirectory: projectDirectory)
        _ = try await store.saveTask(try taskPayload(), taskID: "t1")
        let snapshotURL = projectDirectory.appending(path: "tasks/t1.json")
        let original = try Data(contentsOf: snapshotURL)

        // Hold the write lock on a second connection: the store's existence
        // SELECT (WAL reader) still succeeds while its row DELETE fails after
        // the frozen busy timeout — a real mid-flow database failure.
        let blocker = try SQLiteDatabase(
            url: projectDirectory.appending(path: SQLiteV1.projectDatabaseFilename),
            mode: .readWriteExisting
        )
        try await blocker.execute("BEGIN IMMEDIATE;")
        await expectFailure("行删除失败必须返回错误") { try await store.deleteTask("t1") }
        try await blocker.execute("ROLLBACK;")
        try await blocker.close()

        XCTAssertEqual(try Data(contentsOf: snapshotURL), original, "行删除失败必须恢复原快照字节")
        let reopened = try ProjectTaskStore(projectDirectory: projectDirectory)
        let loaded = try PersistenceTestSupport.jsonObject(await reopened.loadTask("t1"))
        XCTAssertEqual(loaded["id"] as? String, "t1", "数据库删除失败后重启，记录必须仍然存在")
    }

    func testSuccessfulTaskDeleteStaysDeletedAfterReopen() async throws {
        let root = try PersistenceTestSupport.temporaryRoot("recoverable-task-success")
        defer { try? FileManager.default.removeItem(at: root) }
        let projectDirectory = root.appending(path: "P.project", directoryHint: .isDirectory)
        let store = try ProjectTaskStore(projectDirectory: projectDirectory)
        _ = try await store.saveTask(try taskPayload(), taskID: "t1")
        _ = try await store.saveTask(try taskPayload(), taskID: "t2")

        try await store.deleteTask("t1")
        await expectFailure("删除后的任务必须不存在") { try await store.loadTask("t1") }
        XCTAssertFalse(exists(projectDirectory.appending(path: "tasks/t1.json")))

        let reopened = try ProjectTaskStore(projectDirectory: projectDirectory)
        await expectFailure("成功删除后重启，记录必须不存在") { try await reopened.loadTask("t1") }
        _ = try await reopened.loadTask("t2")
    }

    func testDiagnosticSnapshotFailureKeepsSessionAndFailsPrune() async throws {
        let root = try PersistenceTestSupport.temporaryRoot("recoverable-diagnostic-remove")
        defer { try? FileManager.default.removeItem(at: root) }
        let projectDirectory = root.appending(path: "P.project", directoryHint: .isDirectory)
        let store = try DiagnosticsStore(projectDirectory: projectDirectory)
        for index in 0..<20 {
            _ = try await store.saveSession(try diagnosticPayload(), sessionID: "d\(index)")
            try await Task.sleep(for: .milliseconds(2))
        }
        let snapshotURL = projectDirectory.appending(path: "diagnostics/d0.json")
        let original = try Data(contentsOf: snapshotURL)

        // The retention prune reuses the recoverable flow: removing the
        // expired snapshot fails, so the prune — and with it the save — must
        // surface the error instead of silently swallowing it.
        let denied = try DiagnosticsStore(
            projectDirectory: projectDirectory,
            remover: BlockingRemover(blocked: ["d0.json"])
        )
        await expectFailure("prune 的快照删除失败必须返回错误") {
            _ = try await denied.saveSession(try self.diagnosticPayload(), sessionID: "d20")
        }

        XCTAssertEqual(try Data(contentsOf: snapshotURL), original, "prune 删除失败后快照必须原样保留")
        let reopened = try DiagnosticsStore(projectDirectory: projectDirectory)
        let sessions = try await reopened.listSessions()
        XCTAssertEqual(sessions.count, 21, "prune 失败后所有记录必须仍然存在")
        XCTAssertTrue(sessions.contains { $0.id == "d0" }, "删除失败后重启，记录必须仍然存在")
        XCTAssertTrue(sessions.contains { $0.id == "d20" }, "保存本身已落库的会话必须仍然存在")
    }

    func testPruneTrimsToRetentionLimitWithRecoverableFlow() async throws {
        let root = try PersistenceTestSupport.temporaryRoot("recoverable-diagnostic-prune")
        defer { try? FileManager.default.removeItem(at: root) }
        let projectDirectory = root.appending(path: "P.project", directoryHint: .isDirectory)
        let store = try DiagnosticsStore(projectDirectory: projectDirectory)
        for index in 0..<22 {
            _ = try await store.saveSession(try diagnosticPayload(), sessionID: "d\(index)")
            try await Task.sleep(for: .milliseconds(2))
        }
        let sessions = try await store.listSessions()
        XCTAssertEqual(sessions.count, DiagnosticsStore.maximumSessionCount)
        XCTAssertEqual(Set(sessions.map(\.id)), Set((2..<22).map { "d\($0)" }), "最旧的两条会话必须被修剪")
        XCTAssertFalse(exists(projectDirectory.appending(path: "diagnostics/d0.json")))
        XCTAssertFalse(exists(projectDirectory.appending(path: "diagnostics/d1.json")))
    }

    func testSuccessfulDiagnosticDeleteStaysDeletedAfterReopen() async throws {
        let root = try PersistenceTestSupport.temporaryRoot("recoverable-diagnostic-success")
        defer { try? FileManager.default.removeItem(at: root) }
        let projectDirectory = root.appending(path: "P.project", directoryHint: .isDirectory)
        let store = try DiagnosticsStore(projectDirectory: projectDirectory)
        _ = try await store.saveSession(try diagnosticPayload(), sessionID: "d1")
        _ = try await store.saveSession(try diagnosticPayload(), sessionID: "d2")

        try await store.deleteSession("d1")
        await expectFailure("删除后的诊断会话必须不存在") { try await store.loadSession("d1") }
        XCTAssertFalse(exists(projectDirectory.appending(path: "diagnostics/d1.json")))

        let reopened = try DiagnosticsStore(projectDirectory: projectDirectory)
        await expectFailure("成功删除后重启，记录必须不存在") { try await reopened.loadSession("d1") }
        _ = try await reopened.loadSession("d2")
    }
}

import Foundation
import SlateSyncDomain
import XCTest
@testable import SlateSyncPersistence

final class SQLiteDatabaseTests: XCTestCase {
    func testV1SchemaPragmasIndexesAndForeignKeyRemainExact() async throws {
        let root = try PersistenceTestSupport.temporaryRoot("schema")
        defer { try? FileManager.default.removeItem(at: root) }
        let library = try SQLiteDatabase(url: root.appending(path: SQLiteV1.libraryDatabaseFilename))
        let project = try SQLiteDatabase(url: root.appending(path: SQLiteV1.projectDatabaseFilename))
        try await SQLiteV1.bootstrapLibrary(library)
        try await SQLiteV1.bootstrapProject(project)

        let journalMode = try await library.scalar("PRAGMA journal_mode;")
        let foreignKeys = try await project.scalar("PRAGMA foreign_keys;")
        let busyTimeout = try await project.scalar("PRAGMA busy_timeout;")
        let libraryTables = Set(try await library.rows(
            "SELECT name FROM sqlite_master WHERE type = 'table';"
        ).compactMap { $0["name"] ?? nil })
        let projectTables = Set(try await project.rows(
            "SELECT name FROM sqlite_master WHERE type = 'table';"
        ).compactMap { $0["name"] ?? nil })
        let foreignKeyRows = try await project.rows("PRAGMA foreign_key_list(scenario_observations);")
        let foreignKey = try XCTUnwrap(foreignKeyRows.first)
        XCTAssertEqual(journalMode, "wal")
        XCTAssertEqual(foreignKeys, "1")
        XCTAssertEqual(busyTimeout, "5000")
        XCTAssertEqual(libraryTables, ["library_meta", "projects"])
        XCTAssertEqual(
            projectTables,
            ["app_meta", "project_meta", "tasks", "diagnostic_sessions", "scenario_profiles", "scenario_observations"]
        )
        XCTAssertEqual(foreignKey["from"] ?? nil, "profile_id")
        XCTAssertEqual(foreignKey["table"] ?? nil, "scenario_profiles")
        XCTAssertEqual(foreignKey["on_delete"] ?? nil, "SET NULL")

        try await library.close()
        try await project.close()
        let permissions = try FileManager.default.attributesOfItem(
            atPath: root.appending(path: SQLiteV1.projectDatabaseFilename).path
        )[.posixPermissions] as? NSNumber
        XCTAssertEqual((permissions?.intValue ?? 0) & 0o777, 0o600)
    }

    func testRowsRejectsStepFailureInsteadOfReturningPartialResults() async throws {
        let root = try PersistenceTestSupport.temporaryRoot("row-step")
        defer { try? FileManager.default.removeItem(at: root) }
        let database = try SQLiteDatabase(url: root.appending(path: "step.sqlite"))

        do {
            // json_each prepares successfully, then reports malformed JSON from
            // sqlite3_step. This is the tracked SM-04 regression boundary.
            _ = try await database.rows("SELECT value FROM json_each('[1,');")
            XCTFail("row-step failure must not return a partial result")
        } catch let error as SlateSyncError {
            XCTAssertEqual(error.code, "SQLITE_ROWS")
            XCTAssertFalse(error.retryable)
        }
        try await database.close()
    }

    func testTransactionRollsBackEveryEarlierCommandOnConstraintFailure() async throws {
        let root = try PersistenceTestSupport.temporaryRoot("transaction")
        defer { try? FileManager.default.removeItem(at: root) }
        let database = try SQLiteDatabase(url: root.appending(path: "transaction.sqlite"))
        try await database.executeScript("CREATE TABLE values_v1 (id TEXT PRIMARY KEY, value TEXT NOT NULL);")
        do {
            try await database.transaction([
                SQLiteCommand("INSERT INTO values_v1 VALUES (?, ?);", bindings: ["one", "first"]),
                SQLiteCommand("INSERT INTO values_v1 VALUES (?, ?);", bindings: ["one", "duplicate"]),
            ])
            XCTFail("duplicate primary key must fail")
        } catch let error as SlateSyncError {
            XCTAssertEqual(error.code, "SQLITE_CONSTRAINT")
        }
        let count = try await database.scalar("SELECT COUNT(*) FROM values_v1;")
        XCTAssertEqual(count, "0")
        try await database.close()
    }
}

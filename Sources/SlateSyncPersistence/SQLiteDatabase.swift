import Foundation
import SQLite3
import SlateSyncDomain

private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

public actor SQLiteDatabase {
    // SQLite is opened in FULLMUTEX mode and every operation remains actor-isolated.
    // `nonisolated(unsafe)` is limited to storage so deinit can close the C handle.
    nonisolated(unsafe) private var handle: OpaquePointer?

    public init(url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        guard sqlite3_open_v2(
            url.path,
            &handle,
            SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX,
            nil
        ) == SQLITE_OK else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "无法打开数据库"
            if let handle { sqlite3_close(handle) }
            throw SlateSyncError(code: "SQLITE_OPEN", message: message)
        }
        try Self.execute(handle, sql: "PRAGMA journal_mode = WAL;")
        try Self.execute(handle, sql: "PRAGMA foreign_keys = ON;")
        try Self.execute(handle, sql: "PRAGMA busy_timeout = 5000;")
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    deinit {
        if let handle { sqlite3_close(handle) }
    }

    public func execute(_ sql: String, bindings: [String?] = []) throws {
        guard let handle else { throw SlateSyncError(code: "SQLITE_CLOSED", message: "数据库已关闭") }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else {
            throw databaseError(handle, code: "SQLITE_PREPARE")
        }
        defer { sqlite3_finalize(statement) }
        try bind(bindings, to: statement, handle: handle)
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw databaseError(handle, code: "SQLITE_EXECUTE")
        }
    }

    public func rows(_ sql: String, bindings: [String?] = []) throws -> [[String: String?]] {
        guard let handle else { throw SlateSyncError(code: "SQLITE_CLOSED", message: "数据库已关闭") }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else {
            throw databaseError(handle, code: "SQLITE_PREPARE")
        }
        defer { sqlite3_finalize(statement) }
        try bind(bindings, to: statement, handle: handle)
        var result: [[String: String?]] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            var row: [String: String?] = [:]
            for index in 0..<sqlite3_column_count(statement) {
                let name = String(cString: sqlite3_column_name(statement, index))
                if sqlite3_column_type(statement, index) == SQLITE_NULL {
                    row[name] = .some(nil)
                } else if let text = sqlite3_column_text(statement, index) {
                    row[name] = String(cString: text)
                }
            }
            result.append(row)
        }
        return result
    }

    private func bind(_ values: [String?], to statement: OpaquePointer?, handle: OpaquePointer) throws {
        for (offset, value) in values.enumerated() {
            let index = Int32(offset + 1)
            let status = value.map { sqlite3_bind_text(statement, index, $0, -1, sqliteTransient) }
                ?? sqlite3_bind_null(statement, index)
            guard status == SQLITE_OK else { throw databaseError(handle, code: "SQLITE_BIND") }
        }
    }

    private static func execute(_ handle: OpaquePointer?, sql: String) throws {
        var message: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(handle, sql, nil, nil, &message) == SQLITE_OK else {
            let detail = message.map { String(cString: $0) } ?? "SQLite 执行失败"
            sqlite3_free(message)
            throw SlateSyncError(code: "SQLITE_EXECUTE", message: detail)
        }
    }

    private func databaseError(_ handle: OpaquePointer, code: String) -> SlateSyncError {
        SlateSyncError(code: code, message: String(cString: sqlite3_errmsg(handle)))
    }
}

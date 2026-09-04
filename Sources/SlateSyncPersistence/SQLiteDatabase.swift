import Foundation
import SQLite3
import SlateSyncDomain

private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// One prepared command that can participate in an actor-isolated transaction.
/// Bindings stay text-or-null because every v1 SlateSync payload is stored as
/// TEXT and SQLite applies INTEGER affinity to the scenario metadata columns.
public struct SQLiteCommand: Sendable {
    public let sql: String
    public let bindings: [String?]

    public init(_ sql: String, bindings: [String?] = []) {
        self.sql = sql
        self.bindings = bindings
    }
}

/// Small system-SQLite owner used by every native persistence actor.
///
/// The handle never leaves this actor. FULLMUTEX is retained as a second line
/// of defense for C-library callbacks and teardown, while actor isolation is
/// the application's actual single-writer boundary.
public actor SQLiteDatabase {
    public enum OpenMode: Sendable {
        case readWriteCreate
        case readWriteExisting
        case readOnly
    }

    public nonisolated let url: URL

    // `nonisolated(unsafe)` is restricted to storage so deinit can close the C
    // handle. All operational access remains actor-isolated.
    nonisolated(unsafe) private var handle: OpaquePointer?

    public init(url: URL, mode: OpenMode = .readWriteCreate) throws {
        self.url = url.standardizedFileURL
        if mode != .readOnly {
            try SecureFilePermissions.prepareDirectory(at: url.deletingLastPathComponent())
        }

        let flags: Int32 = switch mode {
        case .readWriteCreate:
            SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX
        case .readWriteExisting:
            SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX
        case .readOnly:
            SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX
        }
        let status = sqlite3_open_v2(url.path, &handle, flags, nil)
        guard status == SQLITE_OK else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "无法打开数据库"
            if let handle { sqlite3_close(handle) }
            handle = nil
            throw SlateSyncError(code: "SQLITE_OPEN", message: message)
        }

        do {
            if mode == .readWriteCreate {
                // These values are part of the frozen Electron v1 on-disk contract.
                try Self.executeScript(handle, sql: "PRAGMA journal_mode = WAL;")
            }
            try Self.executeScript(handle, sql: "PRAGMA foreign_keys = ON;")
            try Self.executeScript(handle, sql: "PRAGMA busy_timeout = 5000;")
            if mode != .readOnly {
                try SecureFilePermissions.repairFile(at: url, permissions: 0o600)
            }
        } catch {
            if let handle { sqlite3_close(handle) }
            handle = nil
            throw error
        }
    }

    deinit {
        if let handle { sqlite3_close(handle) }
    }

    @discardableResult
    public func execute(_ sql: String, bindings: [String?] = []) throws -> Int {
        let handle = try openHandle()
        return try executePrepared(SQLiteCommand(sql, bindings: bindings), handle: handle)
    }

    /// Executes schema SQL containing multiple statements. User values must use
    /// `execute`/`transaction` bindings; this entry point is only for constants.
    public func executeScript(_ sql: String) throws {
        try Self.executeScript(try openHandle(), sql: sql)
    }

    /// Executes all commands under one immediate transaction without yielding
    /// the database actor between BEGIN and COMMIT. Rollback is attempted for
    /// every failure and the original stable SQLite error remains authoritative.
    @discardableResult
    public func transaction(_ commands: [SQLiteCommand]) throws -> [Int] {
        guard !commands.isEmpty else { return [] }
        let handle = try openHandle()
        try Self.executeScript(handle, sql: "BEGIN IMMEDIATE;")
        do {
            var changes: [Int] = []
            for command in commands {
                changes.append(try executePrepared(command, handle: handle))
            }
            try Self.executeScript(handle, sql: "COMMIT;")
            return changes
        } catch {
            try? Self.executeScript(handle, sql: "ROLLBACK;")
            throw error
        }
    }

    public func rows(_ sql: String, bindings: [String?] = []) throws -> [[String: String?]] {
        let handle = try openHandle()
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else {
            throw databaseError(handle, fallbackCode: "SQLITE_PREPARE")
        }
        defer { sqlite3_finalize(statement) }
        try bind(bindings, to: statement, handle: handle)

        var result: [[String: String?]] = []
        while true {
            let status = sqlite3_step(statement)
            switch status {
            case SQLITE_ROW:
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
            case SQLITE_DONE:
                return result
            default:
                // A row loop is successful only at SQLITE_DONE. Returning the
                // prefix here would hide BUSY, corrupt JSON virtual tables, I/O
                // errors, and other failures as a complete application result.
                throw databaseError(handle, status: status, fallbackCode: "SQLITE_ROWS")
            }
        }
    }

    public func scalar(_ sql: String, bindings: [String?] = []) throws -> String? {
        try rows(sql, bindings: bindings).first?.values.first ?? nil
    }

    /// Checkpointing before a copy makes the main database file a complete v1
    /// snapshot while leaving WAL mode enabled for the next open.
    public func checkpoint() throws {
        try Self.executeScript(try openHandle(), sql: "PRAGMA wal_checkpoint(TRUNCATE);")
    }

    /// Writes a transactionally consistent, standalone SQLite copy while this
    /// actor keeps owning the source handle. The destination is switched to the
    /// rollback journal so a portable package never depends on WAL sidecars.
    public func backup(to destinationURL: URL) throws {
        let source = try openHandle()
        let destination = destinationURL.standardizedFileURL
        guard !FileManager.default.fileExists(atPath: destination.path) else {
            throw SlateSyncError(code: "SQLITE_BACKUP_EXISTS", message: "SQLite 备份目标已存在")
        }
        try SecureFilePermissions.prepareDirectory(at: destination.deletingLastPathComponent())

        var destinationHandle: OpaquePointer?
        var removeFailedBackup = false
        let openStatus = sqlite3_open_v2(
            destination.path,
            &destinationHandle,
            SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX,
            nil
        )
        guard openStatus == SQLITE_OK, destinationHandle != nil else {
            let detail = destinationHandle.map { String(cString: sqlite3_errmsg($0)) } ?? "无法创建 SQLite 备份"
            if let destinationHandle { sqlite3_close(destinationHandle) }
            throw Self.mappedError(status: openStatus, fallbackCode: "SQLITE_BACKUP", message: detail)
        }
        defer {
            if let destinationHandle { sqlite3_close(destinationHandle) }
            if removeFailedBackup {
                try? FileManager.default.removeItem(at: destination)
                try? FileManager.default.removeItem(at: URL(fileURLWithPath: destination.path + "-wal"))
                try? FileManager.default.removeItem(at: URL(fileURLWithPath: destination.path + "-shm"))
            }
        }

        do {
            guard let openedDestination = destinationHandle else {
                throw SlateSyncError(code: "SQLITE_BACKUP", message: "SQLite 备份连接意外丢失")
            }
            guard let backup = sqlite3_backup_init(openedDestination, "main", source, "main") else {
                throw databaseError(openedDestination, fallbackCode: "SQLITE_BACKUP")
            }
            let deadline = DispatchTime.now().uptimeNanoseconds + 5_000_000_000
            var stepStatus: Int32
            repeat {
                stepStatus = sqlite3_backup_step(backup, 128)
                if stepStatus == SQLITE_BUSY || stepStatus == SQLITE_LOCKED {
                    guard DispatchTime.now().uptimeNanoseconds < deadline else { break }
                    // Match the database busy timeout while allowing an active
                    // project writer to finish its current WAL transaction.
                    sqlite3_sleep(10)
                }
            } while stepStatus == SQLITE_OK || stepStatus == SQLITE_BUSY || stepStatus == SQLITE_LOCKED
            let finishStatus = sqlite3_backup_finish(backup)
            guard stepStatus == SQLITE_DONE, finishStatus == SQLITE_OK else {
                let status = finishStatus == SQLITE_OK ? stepStatus : finishStatus
                throw databaseError(openedDestination, status: status, fallbackCode: "SQLITE_BACKUP")
            }
            try Self.executeScript(openedDestination, sql: "PRAGMA journal_mode = DELETE;")
            guard sqlite3_close(openedDestination) == SQLITE_OK else {
                throw SlateSyncError(code: "SQLITE_BACKUP", message: "无法关闭 SQLite 备份")
            }
            destinationHandle = nil
            // SQLite can leave empty shared-memory sidecars after changing a
            // backed-up WAL database to DELETE mode. They carry no committed
            // data and are deliberately excluded from the portable artifact.
            try? FileManager.default.removeItem(at: URL(fileURLWithPath: destination.path + "-wal"))
            try? FileManager.default.removeItem(at: URL(fileURLWithPath: destination.path + "-shm"))
            try SecureFilePermissions.repairFile(at: destination, permissions: 0o600)
        } catch {
            // Close the destination handle in defer before removing every
            // artifact; deleting an open main file can otherwise leave sidecars.
            removeFailedBackup = true
            throw error
        }
    }

    public func close() throws {
        guard let handle else { return }
        let status = sqlite3_close(handle)
        guard status == SQLITE_OK else {
            throw databaseError(handle, status: status, fallbackCode: "SQLITE_CLOSE")
        }
        self.handle = nil
    }

    private func openHandle() throws -> OpaquePointer {
        guard let handle else {
            throw SlateSyncError(code: "SQLITE_CLOSED", message: "数据库已关闭")
        }
        return handle
    }

    private func executePrepared(_ command: SQLiteCommand, handle: OpaquePointer) throws -> Int {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, command.sql, -1, &statement, nil) == SQLITE_OK else {
            throw databaseError(handle, fallbackCode: "SQLITE_PREPARE")
        }
        defer { sqlite3_finalize(statement) }
        try bind(command.bindings, to: statement, handle: handle)
        let status = sqlite3_step(statement)
        guard status == SQLITE_DONE else {
            throw databaseError(handle, status: status, fallbackCode: "SQLITE_EXECUTE")
        }
        return Int(sqlite3_changes(handle))
    }

    private func bind(_ values: [String?], to statement: OpaquePointer?, handle: OpaquePointer) throws {
        for (offset, value) in values.enumerated() {
            let index = Int32(offset + 1)
            let status = value.map { sqlite3_bind_text(statement, index, $0, -1, sqliteTransient) }
                ?? sqlite3_bind_null(statement, index)
            guard status == SQLITE_OK else {
                throw databaseError(handle, status: status, fallbackCode: "SQLITE_BIND")
            }
        }
    }

    private static func executeScript(_ handle: OpaquePointer?, sql: String) throws {
        var message: UnsafeMutablePointer<CChar>?
        let status = sqlite3_exec(handle, sql, nil, nil, &message)
        guard status == SQLITE_OK else {
            let detail = message.map { String(cString: $0) }
                ?? handle.map { String(cString: sqlite3_errmsg($0)) }
                ?? "SQLite 执行失败"
            sqlite3_free(message)
            throw mappedError(status: status, fallbackCode: "SQLITE_EXECUTE", message: detail)
        }
    }

    private func databaseError(
        _ handle: OpaquePointer,
        status: Int32? = nil,
        fallbackCode: String
    ) -> SlateSyncError {
        let resolvedStatus = status ?? sqlite3_extended_errcode(handle)
        return Self.mappedError(
            status: resolvedStatus,
            fallbackCode: fallbackCode,
            message: String(cString: sqlite3_errmsg(handle))
        )
    }

    private static func mappedError(status: Int32, fallbackCode: String, message: String) -> SlateSyncError {
        switch status & 0xFF {
        case SQLITE_BUSY, SQLITE_LOCKED:
            return SlateSyncError(code: "SQLITE_BUSY", message: message, retryable: true)
        case SQLITE_CONSTRAINT:
            return SlateSyncError(code: "SQLITE_CONSTRAINT", message: message)
        case SQLITE_CORRUPT, SQLITE_NOTADB:
            return SlateSyncError(code: "SQLITE_CORRUPT", message: message)
        case SQLITE_READONLY:
            return SlateSyncError(code: "SQLITE_READONLY", message: message)
        default:
            return SlateSyncError(code: fallbackCode, message: message)
        }
    }
}

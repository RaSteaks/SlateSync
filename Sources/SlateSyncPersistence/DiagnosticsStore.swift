import Foundation
import SlateSyncDomain

public struct DiagnosticSessionSummary: Codable, Hashable, Sendable {
    public let id: String?
    public let filename: String?
    public let provider: String?
    public let model: String?
    public let pageCount: Int?
    public let recordCount: Int
    public let durationMs: Int?
    public let savedAt: String?
}

/// Project-scoped diagnostic evidence with the same 20-session retention and
/// snapshot behavior as the Electron store.
public actor DiagnosticsStore {
    public static let maximumSessionCount = 20

    public nonisolated let sessionsDirectory: URL
    private let database: SQLiteDatabase
    private let writer: any AtomicFileWriting
    private var didBootstrap = false

    public init(
        projectDirectory: URL,
        writer: any AtomicFileWriting = FileManagerAtomicFileWriter()
    ) throws {
        sessionsDirectory = projectDirectory.appending(path: "diagnostics", directoryHint: .isDirectory)
        database = try SQLiteDatabase(
            url: projectDirectory.appending(path: SQLiteV1.projectDatabaseFilename)
        )
        self.writer = writer
    }

    @discardableResult
    public func saveSession(_ payload: Data, sessionID explicitID: String? = nil) async throws -> String {
        try await bootstrap()
        var object = try PersistenceJSON.object(from: payload, errorCode: "DIAGNOSTIC_INVALID")
        let suppliedID = explicitID ?? PersistenceJSON.string(object["id"])
        let candidate = suppliedID.flatMap { $0.isEmpty ? nil : $0 }
            ?? PersistenceJSON.sha256Prefix("\(Date().timeIntervalSince1970):\(UUID())", count: 12)
        let id = try PersistenceIdentifiers.diagnostic(candidate)
        let savedAt = PersistenceJSON.timestamp()
        object["id"] = id
        object["savedAt"] = savedAt
        let data = try PersistenceJSON.data(from: object, errorCode: "DIAGNOSTIC_INVALID")
        let text = try PersistenceJSON.string(from: data, errorCode: "DIAGNOSTIC_INVALID")
        try await database.execute(
            """
            INSERT INTO diagnostic_sessions (id, data_json, saved_at)
            VALUES (?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
              data_json = excluded.data_json,
              saved_at = excluded.saved_at;
            """,
            bindings: [id, text, savedAt]
        )
        try writer.writeAtomically(data, to: snapshotURL(id), permissions: 0o600)
        try await pruneSessions()
        return id
    }

    public func loadSession(_ id: String) async throws -> Data {
        try await bootstrap()
        let sessionID = try PersistenceIdentifiers.diagnostic(id)
        guard let text = try await database.rows(
            "SELECT data_json FROM diagnostic_sessions WHERE id = ?;",
            bindings: [sessionID]
        ).first?["data_json"] ?? nil else {
            throw SlateSyncError(code: "ENOENT", message: "诊断会话不存在")
        }
        return try PersistenceJSON.data(from: text, errorCode: "DIAGNOSTIC_INVALID")
    }

    public func listSessions() async throws -> [DiagnosticSessionSummary] {
        try await bootstrap()
        return try await database.rows(
            "SELECT data_json FROM diagnostic_sessions ORDER BY saved_at DESC;"
        ).compactMap { row in
            guard
                let text = row["data_json"] ?? nil,
                let data = text.data(using: .utf8),
                let object = try? PersistenceJSON.object(from: data, errorCode: "DIAGNOSTIC_INVALID")
            else { return nil }
            let result = object["result"] as? [String: Any]
            return DiagnosticSessionSummary(
                id: PersistenceJSON.string(object["id"]),
                filename: PersistenceJSON.string(object["filename"]),
                provider: PersistenceJSON.string(object["provider"]),
                model: PersistenceJSON.string(object["model"]),
                pageCount: PersistenceJSON.int(object["pageCount"]),
                recordCount: (result?["records"] as? [Any])?.count ?? 0,
                durationMs: PersistenceJSON.int(object["durationMs"]),
                savedAt: PersistenceJSON.string(object["savedAt"])
            )
        }
    }

    public func deleteSession(_ id: String) async throws {
        try await bootstrap()
        let sessionID = try PersistenceIdentifiers.diagnostic(id)
        guard try await database.execute(
            "DELETE FROM diagnostic_sessions WHERE id = ?;",
            bindings: [sessionID]
        ) > 0 else {
            throw SlateSyncError(code: "ENOENT", message: "诊断会话不存在")
        }
        try? FileManager.default.removeItem(at: snapshotURL(sessionID))
    }

    public func close() async throws {
        try await database.close()
    }

    private func bootstrap() async throws {
        guard !didBootstrap else { return }
        try SecureFilePermissions.prepareDirectory(at: sessionsDirectory)
        try await SQLiteV1.bootstrapProject(database)
        try await importSnapshots()
        didBootstrap = true
    }

    private func importSnapshots() async throws {
        let entries = try FileManager.default.contentsOfDirectory(
            at: sessionsDirectory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ).filter { $0.pathExtension.lowercased() == "json" }
        var commands: [SQLiteCommand] = []
        for url in entries {
            guard
                let data = try? Data(contentsOf: url),
                var object = try? PersistenceJSON.object(from: data, errorCode: "DIAGNOSTIC_INVALID"),
                let id = try? PersistenceIdentifiers.diagnostic(
                    PersistenceJSON.string(object["id"]) ?? url.deletingPathExtension().lastPathComponent
                )
            else { continue }
            object["id"] = id
            let savedAt = PersistenceJSON.string(object["savedAt"]) ?? "1970-01-01T00:00:00.000Z"
            guard
                let normalized = try? PersistenceJSON.data(from: object, errorCode: "DIAGNOSTIC_INVALID"),
                let text = String(data: normalized, encoding: .utf8)
            else { continue }
            commands.append(SQLiteCommand(
                "INSERT OR IGNORE INTO diagnostic_sessions (id, data_json, saved_at) VALUES (?, ?, ?);",
                bindings: [id, text, savedAt]
            ))
        }
        try await database.transaction(commands)
    }

    private func pruneSessions() async throws {
        let expired = try await database.rows(
            "SELECT id FROM diagnostic_sessions ORDER BY saved_at DESC LIMIT -1 OFFSET ?;",
            bindings: [String(Self.maximumSessionCount)]
        ).compactMap { $0["id"] ?? nil }
        guard !expired.isEmpty else { return }
        try await database.transaction(expired.map {
            SQLiteCommand("DELETE FROM diagnostic_sessions WHERE id = ?;", bindings: [$0])
        })
        for id in expired { try? FileManager.default.removeItem(at: snapshotURL(id)) }
    }

    private func snapshotURL(_ id: String) -> URL {
        sessionsDirectory.appending(path: "\(id).json")
    }
}

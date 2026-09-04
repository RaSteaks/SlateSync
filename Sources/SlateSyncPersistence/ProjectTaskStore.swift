import Foundation
import SlateSyncDomain

/// Project-scoped v1 task persistence. SQLite is authoritative and the JSON
/// sibling is an atomic compatibility snapshot for Electron-era tooling.
public actor ProjectTaskStore {
    public nonisolated let projectDirectory: URL
    public nonisolated let tasksDirectory: URL
    public nonisolated let databaseURL: URL

    private let database: SQLiteDatabase
    private let writer: any AtomicFileWriting
    private var didBootstrap = false

    public init(
        projectDirectory: URL,
        writer: any AtomicFileWriting = FileManagerAtomicFileWriter()
    ) throws {
        self.projectDirectory = projectDirectory.standardizedFileURL
        tasksDirectory = projectDirectory.appending(path: "tasks", directoryHint: .isDirectory)
        databaseURL = projectDirectory.appending(path: SQLiteV1.projectDatabaseFilename)
        database = try SQLiteDatabase(url: databaseURL)
        self.writer = writer
    }

    @discardableResult
    public func saveTask(_ payload: Data, taskID explicitID: String? = nil) async throws -> String {
        try await bootstrap()
        var object = try PersistenceJSON.object(from: payload, errorCode: "TASK_INVALID")
        let suppliedID = explicitID ?? PersistenceJSON.string(object["id"])
        let candidate = suppliedID.flatMap { $0.isEmpty ? nil : $0 }
            ?? PersistenceJSON.sha256Prefix("\(Date().timeIntervalSince1970):\(UUID())", count: 12)
        let id = try PersistenceIdentifiers.task(candidate)
        let now = PersistenceJSON.timestamp()
        object["id"] = id
        object["createdAt"] = PersistenceJSON.string(object["createdAt"]) ?? now
        object["updatedAt"] = now
        let data = try PersistenceJSON.data(from: object, errorCode: "TASK_INVALID")
        let text = try PersistenceJSON.string(from: data, errorCode: "TASK_INVALID")
        try await database.execute(
            """
            INSERT INTO tasks (id, data_json, created_at, updated_at)
            VALUES (?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
              data_json = excluded.data_json,
              created_at = excluded.created_at,
              updated_at = excluded.updated_at;
            """,
            bindings: [id, text, object["createdAt"] as? String, now]
        )
        try writer.writeAtomically(data, to: snapshotURL(id), permissions: 0o600)
        return id
    }

    public func loadTask(_ id: String) async throws -> Data {
        try await bootstrap()
        let taskID = try PersistenceIdentifiers.task(id)
        guard let text = try await database.rows(
            "SELECT data_json FROM tasks WHERE id = ?;",
            bindings: [taskID]
        ).first?["data_json"] ?? nil else {
            throw SlateSyncError(code: "ENOENT", message: "任务不存在")
        }
        return try PersistenceJSON.data(from: text, errorCode: "TASK_INVALID")
    }

    public func updateTask(_ id: String, patch: Data) async throws -> String {
        let taskID = try PersistenceIdentifiers.task(id)
        let existing = try PersistenceJSON.object(
            from: await loadTask(taskID),
            errorCode: "TASK_INVALID"
        )
        let changes = try PersistenceJSON.object(from: patch, errorCode: "TASK_INVALID")
        var merged = existing
        for (key, value) in changes { merged[key] = value }
        merged["id"] = taskID
        merged["createdAt"] = existing["createdAt"]
        return try await saveTask(
            PersistenceJSON.data(from: merged, errorCode: "TASK_INVALID"),
            taskID: taskID
        )
    }

    public func listTasks() async throws -> [TaskListItem] {
        try await bootstrap()
        let rows = try await database.rows(
            "SELECT data_json FROM tasks ORDER BY updated_at DESC;"
        )
        return rows.compactMap { row in
            guard
                let text = row["data_json"] ?? nil,
                let data = text.data(using: .utf8),
                let object = try? PersistenceJSON.object(from: data, errorCode: "TASK_INVALID")
            else { return nil }
            let editedCount = (object["editedRecords"] as? [Any])?.count
            let result = object["result"] as? [String: Any]
            let resultCount = (result?["records"] as? [Any])?.count
            return TaskListItem(
                id: PersistenceJSON.string(object["id"]),
                filename: PersistenceJSON.string(object["filename"]),
                provider: PersistenceJSON.string(object["provider"]),
                model: PersistenceJSON.string(object["model"]),
                pageCount: PersistenceJSON.int(object["pageCount"]),
                scenarioId: PersistenceJSON.string(object["scenarioId"]),
                recordCount: editedCount ?? resultCount ?? 0,
                status: PersistenceJSON.string(object["status"]) ?? "unknown",
                createdAt: PersistenceJSON.string(object["createdAt"]),
                updatedAt: PersistenceJSON.string(object["updatedAt"])
            )
        }
    }

    public func deleteTask(_ id: String) async throws {
        try await bootstrap()
        let taskID = try PersistenceIdentifiers.task(id)
        guard try await database.execute(
            "DELETE FROM tasks WHERE id = ?;",
            bindings: [taskID]
        ) > 0 else {
            throw SlateSyncError(code: "ENOENT", message: "任务不存在")
        }
        try? FileManager.default.removeItem(at: snapshotURL(taskID))
    }

    public func close() async throws {
        try await database.close()
    }

    private func bootstrap() async throws {
        guard !didBootstrap else { return }
        try SecureFilePermissions.prepareDirectory(at: tasksDirectory)
        try await SQLiteV1.bootstrapProject(database)
        try await importSnapshots()
        didBootstrap = true
    }

    private func importSnapshots() async throws {
        let entries = try FileManager.default.contentsOfDirectory(
            at: tasksDirectory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ).filter { $0.pathExtension.lowercased() == "json" }
        var commands: [SQLiteCommand] = []
        for url in entries {
            // One malformed legacy snapshot must not prevent project startup.
            guard
                let data = try? Data(contentsOf: url),
                var object = try? PersistenceJSON.object(from: data, errorCode: "TASK_INVALID"),
                let id = try? PersistenceIdentifiers.task(
                    PersistenceJSON.string(object["id"]) ?? url.deletingPathExtension().lastPathComponent
                )
            else { continue }
            object["id"] = id
            let createdAt = PersistenceJSON.string(object["createdAt"]) ?? "1970-01-01T00:00:00.000Z"
            let updatedAt = PersistenceJSON.string(object["updatedAt"]) ?? createdAt
            guard
                let normalized = try? PersistenceJSON.data(from: object, errorCode: "TASK_INVALID"),
                let text = String(data: normalized, encoding: .utf8)
            else { continue }
            commands.append(SQLiteCommand(
                "INSERT OR IGNORE INTO tasks (id, data_json, updated_at, created_at) VALUES (?, ?, ?, ?);",
                bindings: [id, text, updatedAt, createdAt]
            ))
        }
        try await database.transaction(commands)
    }

    private func snapshotURL(_ id: String) -> URL {
        tasksDirectory.appending(path: "\(id).json")
    }
}

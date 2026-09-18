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
    private let remover: any FileRemoving
    private var didBootstrap = false
    private var bootstrapTask: Task<Void, any Error>?

    public init(
        projectDirectory: URL,
        writer: any AtomicFileWriting = FileManagerAtomicFileWriter(),
        remover: any FileRemoving = FileSystemRemover()
    ) throws {
        self.projectDirectory = projectDirectory.standardizedFileURL
        tasksDirectory = projectDirectory.appending(path: "tasks", directoryHint: .isDirectory)
        databaseURL = projectDirectory.appending(path: SQLiteV1.projectDatabaseFilename)
        database = try SQLiteDatabase(url: databaseURL)
        self.writer = writer
        self.remover = remover
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

    /// Validate row ownership without materializing the task's media and
    /// recognition payload. Native recognition uses this before external work.
    public func requireTaskExists(_ id: String) async throws {
        try await bootstrap()
        let taskID = try PersistenceIdentifiers.task(id)
        let row = try await database.rows(
            "SELECT 1 AS present FROM tasks WHERE id = ? LIMIT 1;",
            bindings: [taskID]
        ).first
        guard row != nil else {
            throw SlateSyncError(code: "ENOENT", message: "任务不存在")
        }
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
        // Project only sidebar fields inside SQLite: image data URLs and full
        // recognition/CSV arrays must not cross into Swift for every task.
        // Keep the persisted JSON and ordering unchanged; malformed rows retain
        // the legacy skip behavior and only actual arrays contribute counts.
        let rows = try await database.rows("""
            SELECT CASE WHEN json_valid(data_json) THEN
                CASE WHEN json_type(data_json) = 'object' THEN json_object(
                    'id', json_extract(data_json, '$.id'),
                    'filename', json_extract(data_json, '$.filename'),
                    'provider', json_extract(data_json, '$.provider'),
                    'model', json_extract(data_json, '$.model'),
                    'pageCount', json_extract(data_json, '$.pageCount'),
                    'scenarioId', json_extract(data_json, '$.scenarioId'),
                    'status', json_extract(data_json, '$.status'),
                    'createdAt', json_extract(data_json, '$.createdAt'),
                    'updatedAt', json_extract(data_json, '$.updatedAt'),
                    'recordCount', CASE
                        WHEN json_type(data_json, '$.editedRecords') = 'array'
                            THEN json_array_length(data_json, '$.editedRecords')
                        WHEN json_type(data_json, '$.result.records') = 'array'
                            THEN json_array_length(data_json, '$.result.records')
                        ELSE 0 END
                ) END END AS data_json
            FROM tasks ORDER BY updated_at DESC;
            """)
        return rows.compactMap { row in
            guard
                let text = row["data_json"] ?? nil,
                let data = text.data(using: .utf8),
                let object = try? PersistenceJSON.object(from: data, errorCode: "TASK_INVALID")
            else { return nil }
            return TaskListItem(
                id: PersistenceJSON.string(object["id"]),
                filename: PersistenceJSON.string(object["filename"]),
                provider: PersistenceJSON.string(object["provider"]),
                model: PersistenceJSON.string(object["model"]),
                pageCount: PersistenceJSON.int(object["pageCount"]),
                scenarioId: PersistenceJSON.string(object["scenarioId"]),
                recordCount: PersistenceJSON.int(object["recordCount"]) ?? 0,
                status: PersistenceJSON.string(object["status"]) ?? "unknown",
                createdAt: PersistenceJSON.string(object["createdAt"]),
                updatedAt: PersistenceJSON.string(object["updatedAt"])
            )
        }
    }

    public func deleteTask(_ id: String) async throws {
        try await bootstrap()
        let taskID = try PersistenceIdentifiers.task(id)
        // Recoverable deletion: a failed snapshot removal or a failed row
        // delete must leave the record fully intact after a restart, so a
        // snapshot error is surfaced, never swallowed with `try?`.
        try await SnapshotDeletion.deleteRowAndSnapshot(
            database: database,
            table: "tasks",
            id: taskID,
            snapshotURL: snapshotURL(taskID),
            notFoundMessage: "任务不存在",
            remover: remover,
            writer: writer
        )
    }

    public func close() async throws {
        try await database.close()
    }

    private func bootstrap() async throws {
        guard !didBootstrap else { return }
        if let bootstrapTask {
            try await bootstrapTask.value
            return
        }
        // Concurrent first-use operations share snapshot import and schema
        // setup instead of replaying the compatibility migration reentrantly.
        let task = Task<Void, any Error> { try await self.performBootstrap() }
        bootstrapTask = task
        do {
            try await task.value
            didBootstrap = true
            bootstrapTask = nil
        } catch {
            bootstrapTask = nil
            throw error
        }
    }

    private func performBootstrap() async throws {
        try SecureFilePermissions.prepareDirectory(at: tasksDirectory)
        try await SQLiteV1.bootstrapProject(database)
        try await importSnapshots()
    }

    private func importSnapshots() async throws {
        let entries = try FileManager.default.contentsOfDirectory(
            at: tasksDirectory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ).filter { $0.pathExtension.lowercased() == "json" }
        // No legacy files means there is no reason to materialize every row ID.
        guard !entries.isEmpty else { return }
        // SQLite is authoritative. Existing tasks need neither full-payload
        // serialization nor INSERT OR IGNORE / encrypted snapshot replacement.
        // Still inspect embedded IDs: legacy filenames may not match them.
        let existingIDs = Set(try await database.rows("SELECT id FROM tasks;").compactMap { $0["id"] ?? nil })
        var commands: [SQLiteCommand] = []
        for url in entries {
            // One malformed legacy snapshot must not prevent project startup.
            guard
                let data = try? LocalProjectEncryption.read(from: url),
                var object = try? PersistenceJSON.object(from: data, errorCode: "TASK_INVALID"),
                let id = try? PersistenceIdentifiers.task(
                    PersistenceJSON.string(object["id"]) ?? url.deletingPathExtension().lastPathComponent
                )
            else { continue }
            guard !existingIDs.contains(id) else { continue }
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

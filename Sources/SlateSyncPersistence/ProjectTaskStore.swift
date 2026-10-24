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
    public func saveTask(_ payload: Data, taskID explicitID: String? = nil, replacingKeys: Set<String>? = nil) async throws -> String {
        try await bootstrap()
        let (id, data) = try prepareTask(payload, taskID: explicitID)
        // The database owner keeps the row and snapshot under one mutation lock.
        try await database.saveTaskSnapshot(id, data: data, snapshotURL: snapshotURL(id), writer: writer, replacingKeys: replacingKeys)
        return id
    }

    /// Return canonical timestamps and a fresh task list from the creation
    /// transaction, acknowledged only after the encrypted snapshot is durable.
    public func createTask(_ payload: Data) async throws -> TaskCreationResult {
        try await bootstrap()
        // Creation never overwrites an ID supplied by a stale draft.
        let newID = PersistenceJSON.sha256Prefix("\(Date().timeIntervalSince1970):\(UUID())", count: 12)
        let (id, data) = try prepareTask(payload, taskID: newID)
        return try await database.createTaskSnapshot(id, data: data, snapshotURL: snapshotURL(id), writer: writer)
    }

    private func prepareTask(_ payload: Data, taskID explicitID: String?) throws -> (id: String, data: Data) {
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
        return (id, data)
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
        try await bootstrap()
        let taskID = try PersistenceIdentifiers.task(id)
        // Atomic shallow merge preserves unknown fields and explicit JSON nulls.
        try await database.patchTask(taskID, patch: patch, snapshotURL: snapshotURL(taskID), writer: writer)
        return taskID
    }

    public func listTasks() async throws -> [TaskListItem] {
        try await bootstrap()
        return try await database.taskListItems()
    }

    public func deleteTask(_ id: String) async throws {
        try await bootstrap()
        let taskID = try PersistenceIdentifiers.task(id)
        // Share the same cross-store lock as save/patch so a late compatibility
        // snapshot cannot make an acknowledged deletion reappear on reopening.
        try await database.deleteTaskSnapshot(taskID, snapshotURL: snapshotURL(taskID), writer: writer, remover: remover)
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
        // Repair interrupted native writes before considering legacy files.
        let intents = try FileManager.default.contentsOfDirectory(at: tasksDirectory, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasSuffix(".json.pending") }
        for intent in intents {
            let snapshot = intent.deletingPathExtension()
            let id = try PersistenceIdentifiers.task(snapshot.deletingPathExtension().lastPathComponent)
            try await database.recoverTaskSnapshot(id, snapshotURL: snapshot)
        }
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

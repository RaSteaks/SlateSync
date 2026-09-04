import Foundation
import SlateSyncDomain

public struct LibraryV1Manifest: Codable, Hashable, Sendable {
    public let id: String
    public var name: String
    public let formatVersion: Int
    public let createdAt: String
}

public struct ProjectV1Manifest: Codable, Hashable, Sendable {
    public let id: String
    public let libraryId: String
    public var name: String
    public var description: String
    public let formatVersion: Int
    public let createdAt: String
    public var updatedAt: String
}

public struct LegacyMigrationReport: Codable, Hashable, Sendable {
    public struct Counts: Codable, Hashable, Sendable {
        public var tasks = 0
        public var scenarios = 0
        public var observations = 0
        public var diagnostics = 0
        public var snapshots = 0
    }

    public let version: Int
    public let projectId: String
    public let migratedAt: String
    public let counts: Counts
}

/// Native owner of the v1 Project Library index and project directories.
/// Each project keeps an independent `project.sqlite`; the Library database is
/// only a registry and never becomes a second store for project settings/tasks.
public actor ProjectLibraryStore: ProjectLibraryServing {
    public static let libraryFormatVersion = 1
    public static let projectFormatVersion = 1
    public static let defaultLibraryName = "Local SlateSync Library"
    public static let legacyDefaultLibraryName = "Local SlateSync Library.slatesync-library"
    public static let defaultProjectID = "project-default"
    public static let libraryExtension = ".slatesync-library"

    /// These URLs follow a portable Library rename. Callers cross the actor
    /// boundary rather than retaining a construction-time path that can stale.
    public var libraryRoot: URL { root }
    public var databaseURL: URL { root.appending(path: SQLiteV1.libraryDatabaseFilename) }

    private var root: URL
    private var projectsRoot: URL
    private let database: SQLiteDatabase
    private let writer: any AtomicFileWriting
    private var manifest: LibraryV1Manifest?
    private var didBootstrap = false
    private var bootstrapTask: Task<Void, any Error>?

    public init(
        applicationSupportRoot: URL? = nil,
        writer: any AtomicFileWriting = FileManagerAtomicFileWriter()
    ) throws {
        let support = try applicationSupportRoot ?? ApplicationSupportLocator.root()
        let libraryRoot = support.appending(path: Self.defaultLibraryName, directoryHint: .isDirectory)
        root = libraryRoot.standardizedFileURL
        projectsRoot = root.appending(path: "Projects", directoryHint: .isDirectory)
        database = try SQLiteDatabase(url: root.appending(path: SQLiteV1.libraryDatabaseFilename))
        self.writer = writer
    }

    /// Opens a copied or user-selected v1 Library directly rather than nesting
    /// it under the default Application Support folder.
    public init(
        libraryRoot: URL,
        writer: any AtomicFileWriting = FileManagerAtomicFileWriter()
    ) throws {
        root = libraryRoot.standardizedFileURL
        projectsRoot = root.appending(path: "Projects", directoryHint: .isDirectory)
        database = try SQLiteDatabase(url: root.appending(path: SQLiteV1.libraryDatabaseFilename))
        self.writer = writer
    }

    /// Resolves the historical default folder without ever inspecting the
    /// user's real Application Support path in tests. A failed rename keeps the
    /// existing legacy Library addressable, matching Electron startup behavior.
    public static func resolveDefaultLibraryRoot(
        applicationSupportRoot: URL,
        legacyRoots: [URL],
        preserveLegacyOnConflict: Bool = false
    ) -> URL {
        let preferred = applicationSupportRoot.appending(
            path: defaultLibraryName,
            directoryHint: .isDirectory
        )
        let preferredExists = FileManager.default.fileExists(atPath: preferred.path)
        if preferredExists && !preserveLegacyOnConflict { return preferred }
        for legacy in legacyRoots where FileManager.default.fileExists(atPath: legacy.path) {
            if preferredExists { return legacy }
            do {
                try FileManager.default.moveItem(at: legacy, to: preferred)
                return preferred
            } catch {
                return legacy
            }
        }
        return preferred
    }

    public func bootstrap() async throws {
        guard !didBootstrap else { return }
        if let bootstrapTask {
            try await bootstrapTask.value
            return
        }
        // Actor methods are reentrant at every SQLite await. Share one
        // bootstrap task so simultaneous libraryInfo/listProjects calls cannot
        // both create the permanent default project or roll back each other's
        // directory after a uniqueness conflict.
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

    /// Validates deterministic rename failures before the project runtime is
    /// drained. The actual rename repeats every check after that async gap.
    func preflightLibraryRename(_ nextName: String) async throws {
        try await bootstrap()
        let name = try validateLibraryName(nextName)
        let current = try requiredManifest()
        guard name != current.name else { return }
        let suffix = root.lastPathComponent.hasSuffix(Self.libraryExtension)
            ? Self.libraryExtension
            : ""
        let target = root.deletingLastPathComponent()
            .appending(path: "\(name)\(suffix)", directoryHint: .isDirectory)
        guard !FileManager.default.fileExists(atPath: target.path) else {
            throw SlateSyncError(code: "LIBRARY_NAME_CONFLICT", message: "该名称的项目库目录已存在，请选择其他名称")
        }
    }

    private func performBootstrap() async throws {
        try SecureFilePermissions.prepareDirectory(at: root)
        try SecureFilePermissions.prepareDirectory(at: projectsRoot)
        try await SQLiteV1.bootstrapLibrary(database)
        try await cleanupStagedProjectDirectories()
        manifest = try loadOrCreateLibraryManifest()
        _ = try await ensureDefaultProject()
    }

    public func libraryInfo() async throws -> LibraryInfo {
        try await bootstrap()
        let manifest = try requiredManifest()
        return LibraryInfo(
            id: manifest.id,
            name: manifest.name,
            formatVersion: manifest.formatVersion,
            path: root.path
        )
    }

    public func renameLibrary(_ nextName: String) async throws -> LibraryInfo {
        try await bootstrap()
        let name = try validateLibraryName(nextName)
        var current = try requiredManifest()
        guard name != current.name else { return try await libraryInfo() }
        let oldRoot = root
        let suffix = oldRoot.lastPathComponent.hasSuffix(Self.libraryExtension)
            ? Self.libraryExtension
            : ""
        let newRoot = oldRoot.deletingLastPathComponent()
            .appending(path: "\(name)\(suffix)", directoryHint: .isDirectory)
        guard !FileManager.default.fileExists(atPath: newRoot.path) else {
            throw SlateSyncError(code: "LIBRARY_NAME_CONFLICT", message: "该名称的项目库目录已存在，请选择其他名称")
        }

        try FileManager.default.moveItem(at: oldRoot, to: newRoot)
        current.name = name
        do {
            try writeJSON(current, to: newRoot.appending(path: "library.json"))
        } catch {
            do {
                try FileManager.default.moveItem(at: newRoot, to: oldRoot)
            } catch {
                throw SlateSyncError(code: "LIBRARY_RENAME_ROLLBACK", message: "项目库改名失败，且无法恢复原目录")
            }
            throw error
        }
        root = newRoot
        projectsRoot = newRoot.appending(path: "Projects", directoryHint: .isDirectory)
        manifest = current
        return try await libraryInfo()
    }

    public func listProjects(includeArchived: Bool = false) async throws -> [ProjectSummary] {
        try await bootstrap()
        let whereClause = includeArchived ? "" : "WHERE archived_at IS NULL"
        let rows = try await database.rows(
            """
            SELECT id, relative_path, name, description, archived_at, created_at, updated_at
            FROM projects
            \(whereClause)
            ORDER BY archived_at IS NOT NULL, updated_at DESC;
            """
        )
        var projects: [ProjectSummary] = []
        for row in rows {
            if let summary = try await projectSummary(row) { projects.append(summary) }
        }
        return projects
    }

    public func listProjects() async throws -> [ProjectSummary] {
        try await listProjects(includeArchived: false)
    }

    public func getProject(_ id: String, allowArchived: Bool = true) async throws -> ProjectData {
        try await bootstrap()
        guard let row = try await projectRow(id) else { throw missingProject() }
        if !allowArchived, row["archived_at"] ?? nil != nil {
            throw SlateSyncError(code: "PROJECT_ARCHIVED", message: "项目已归档")
        }
        return try await projectData(row)
    }

    public func createProject(name: String, description: String) async throws -> ProjectData {
        try await createProject(name: name, description: description, settings: .init())
    }

    public func createProject(
        name: String,
        description: String = "",
        settings: ProjectSettings = .init()
    ) async throws -> ProjectData {
        try await bootstrap()
        let normalizedName = try validateProjectName(name)
        let id = "project-\(PersistenceJSON.sha256Prefix("\(normalizedName):\(Date().timeIntervalSince1970):\(UUID())", count: 16))"
        return try await createProjectWithID(
            id,
            name: normalizedName,
            description: cleanDescription(description),
            settings: settings
        )
    }

    /// Exports one project through the portable v1 package boundary. The
    /// current Library row supplies archive/activity state while project.json
    /// and project.sqlite remain authoritative for project-local metadata.
    public func exportProject(_ id: String, to targetURL: URL) async throws -> ProjectExportResult {
        try await bootstrap()
        guard let row = try await projectRow(id) else { throw missingProject() }
        let current = try await projectData(row)
        let packageProject = ProjectPackageProject(
            id: current.id,
            libraryId: try requiredManifest().id,
            name: current.name,
            description: current.description,
            archivedAt: current.archivedAt,
            createdAt: current.createdAt,
            updatedAt: current.updatedAt
        )
        _ = try await ProjectLibraryTransfer.exportProject(
            from: checkedProjectDirectory(row),
            project: packageProject,
            to: targetURL,
            writer: writer
        )
        return .exported(project: current.summary, path: targetURL.standardizedFileURL.path)
    }

    /// Imports only after the complete external package passes validation. A
    /// fresh identity is rebound into SQLite and snapshots before the directory
    /// is exposed by the Library index, so repeated imports remain independent.
    public func importProject(from packageURL: URL) async throws -> ProjectImportResult {
        try await bootstrap()
        let package = try await ProjectLibraryTransfer.validateProjectPackage(at: packageURL)
        var projectID = importedProjectID(sourceID: package.project.id)
        while try await projectRow(projectID) != nil
            || FileManager.default.fileExists(atPath: projectsRoot.appending(path: projectID).path) {
            projectID = importedProjectID(sourceID: package.project.id)
        }
        let projectDirectory = projectsRoot.appending(path: projectID, directoryHint: .isDirectory)
        let rebound = try await ProjectLibraryTransfer.importProjectData(
            from: packageURL,
            to: projectDirectory,
            projectID: projectID,
            libraryID: try requiredManifest().id,
            writer: writer
        )
        do {
            try await database.execute(
                """
                INSERT INTO projects
                  (id, relative_path, name, description, archived_at, created_at, updated_at)
                VALUES (?, ?, ?, ?, ?, ?, ?);
                """,
                bindings: [
                    rebound.id,
                    "Projects/\(rebound.id)",
                    rebound.name,
                    rebound.description,
                    rebound.archivedAt,
                    rebound.createdAt,
                    rebound.updatedAt,
                ]
            )
        } catch {
            try? stageOrRemoveUnindexedProject(projectDirectory)
            throw error
        }
        return .imported(try await getProject(projectID))
    }

    /// Produces an independent Library copy without closing the active source;
    /// all SQLite files are backed up online and validated before publication.
    public func exportLibrary(to targetURL: URL) async throws -> LibraryExportResult {
        try await bootstrap()
        let exported = try await ProjectLibraryTransfer.exportLibrary(from: root, to: targetURL)
        return .exported(exported)
    }

    public func updateProject(
        _ id: String,
        name: String? = nil,
        description: String? = nil,
        settings: ProjectSettings? = nil
    ) async throws -> ProjectData {
        try await bootstrap()
        guard let row = try await projectRow(id) else { throw missingProject() }
        guard row["archived_at"] ?? nil == nil else {
            throw SlateSyncError(code: "PROJECT_ARCHIVED", message: "项目已归档")
        }
        let current = try await projectData(row)
        let nextName = try name.map(validateProjectName) ?? current.name
        let nextDescription = description.map(cleanDescription) ?? current.description
        let nextSettings = settings ?? current.settings
        try nextSettings.validate()
        let now = PersistenceJSON.timestamp()
        let projectDirectory = try checkedProjectDirectory(row)
        try await writeProjectMeta(
            at: projectDirectory,
            id: current.id,
            libraryID: try requiredManifest().id,
            name: nextName,
            description: nextDescription,
            settings: nextSettings,
            createdAt: current.createdAt,
            updatedAt: now,
            archivedAt: current.archivedAt
        )
        try writeJSON(
            ProjectV1Manifest(
                id: current.id,
                libraryId: try requiredManifest().id,
                name: nextName,
                description: nextDescription,
                formatVersion: Self.projectFormatVersion,
                createdAt: current.createdAt,
                updatedAt: now
            ),
            to: projectDirectory.appending(path: "project.json")
        )
        try await database.execute(
            "UPDATE projects SET name = ?, description = ?, updated_at = ? WHERE id = ?;",
            bindings: [nextName, nextDescription, now, current.id]
        )
        return try await getProject(current.id)
    }

    @discardableResult
    public func touchProjectActivity(_ id: String, at timestamp: String? = nil) async throws -> String {
        try await bootstrap()
        let timestamp = timestamp ?? PersistenceJSON.timestamp()
        guard let row = try await projectRow(id), let projectID = row["id"] ?? nil else {
            throw missingProject()
        }
        try await database.execute(
            "UPDATE projects SET updated_at = ? WHERE id = ?;",
            bindings: [timestamp, projectID]
        )
        return timestamp
    }

    public func archiveProject(_ id: String) async throws -> ProjectData {
        try await setArchived(id, archived: true)
    }

    public func restoreProject(_ id: String) async throws -> ProjectData {
        try await setArchived(id, archived: false)
    }

    /// Two-phase deletion first hides the exact validated directory behind a
    /// unique tombstone, then commits the Library row deletion. An index error
    /// restores the untouched directory; a later filesystem error leaves the
    /// unaddressable tombstone for the next bootstrap retry.
    public func deleteProject(_ id: String) async throws -> String {
        try await bootstrap()
        guard let row = try await projectRow(id), let projectID = row["id"] ?? nil else {
            throw missingProject()
        }
        guard projectID != Self.defaultProjectID else {
            throw SlateSyncError(code: "PROJECT_DEFAULT_PROTECTED", message: "默认项目不能删除")
        }
        let projectDirectory = try checkedProjectDirectory(row)
        let staged = URL(fileURLWithPath: "\(projectDirectory.path).deleting-\(UUID().uuidString.lowercased())")
        try FileManager.default.moveItem(at: projectDirectory, to: staged)
        do {
            try await database.execute("DELETE FROM projects WHERE id = ?;", bindings: [projectID])
        } catch {
            do {
                try FileManager.default.moveItem(at: staged, to: projectDirectory)
            } catch {
                throw SlateSyncError(code: "PROJECT_DELETE_ROLLBACK", message: "项目删除失败，且无法恢复原目录")
            }
            throw error
        }
        try? await removeStagedDirectory(staged)
        return projectID
    }

    /// Imports the legacy global SQLite rows and JSON snapshots once into the
    /// permanent default project. The source database/directories are read-only
    /// inputs and are never removed or rewritten.
    public func migrateLegacyData(from legacyRoot: URL) async throws -> LegacyMigrationReport {
        try await bootstrap()
        if let marker = try await database.rows(
            "SELECT value FROM library_meta WHERE key = 'legacy_migration_v1';"
        ).first?["value"] ?? nil,
           let data = marker.data(using: .utf8),
           let report = try? JSONDecoder().decode(LegacyMigrationReport.self, from: data) {
            return report
        }

        let defaultProject = try await ensureDefaultProject()
        guard let defaultRow = try await projectRow(defaultProject.id) else { throw missingProject() }
        let projectDirectory = try checkedProjectDirectory(defaultRow)
        let target = try SQLiteDatabase(
            url: projectDirectory.appending(path: SQLiteV1.projectDatabaseFilename)
        )
        try await SQLiteV1.bootstrapProject(target)
        var counts = LegacyMigrationReport.Counts()
        let sourceURL = legacyRoot.appending(path: SQLiteV1.legacyDatabaseFilename)
        if FileManager.default.fileExists(atPath: sourceURL.path) {
            let source = try SQLiteDatabase(url: sourceURL, mode: .readOnly)
            do {
                var taggedCommands: [(LegacyTable, SQLiteCommand)] = []
                taggedCommands += try await legacyCommands(
                    source: source,
                    table: .scenarios,
                    columns: ["id", "schema_version", "fingerprint_version", "fingerprint", "profile_json", "sample_count", "created_at", "updated_at", "last_used_at"]
                )
                taggedCommands += try await legacyCommands(
                    source: source,
                    table: .observations,
                    columns: ["id", "profile_id", "fingerprint_version", "fingerprint", "observation_json", "created_at"]
                )
                taggedCommands += try await legacyCommands(
                    source: source,
                    table: .tasks,
                    columns: ["id", "data_json", "created_at", "updated_at"],
                    projectID: defaultProject.id
                )
                taggedCommands += try await legacyCommands(
                    source: source,
                    table: .diagnostics,
                    columns: ["id", "data_json", "saved_at"],
                    projectID: defaultProject.id
                )
                let changes = try await target.transaction(taggedCommands.map(\.1))
                for (entry, change) in zip(taggedCommands, changes) where change > 0 {
                    switch entry.0 {
                    case .tasks: counts.tasks += change
                    case .diagnostics: counts.diagnostics += change
                    case .scenarios: counts.scenarios += change
                    case .observations: counts.observations += change
                    }
                }
                try await source.close()
            } catch {
                try? await source.close()
                try? await target.close()
                throw error
            }
        }
        try await target.close()

        counts.snapshots += try copyLegacySnapshots(
            from: legacyRoot.appending(path: "tasks", directoryHint: .isDirectory),
            to: projectDirectory.appending(path: "tasks", directoryHint: .isDirectory),
            projectID: defaultProject.id
        )
        counts.snapshots += try copyLegacySnapshots(
            from: legacyRoot.appending(path: "diagnostics", directoryHint: .isDirectory),
            to: projectDirectory.appending(path: "diagnostics", directoryHint: .isDirectory),
            projectID: defaultProject.id
        )
        let report = LegacyMigrationReport(
            version: 1,
            projectId: defaultProject.id,
            migratedAt: PersistenceJSON.timestamp(),
            counts: counts
        )
        let marker = try PersistenceJSON.string(
            from: JSONEncoder().encode(report),
            errorCode: "LEGACY_MIGRATION"
        )
        try await database.execute(
            """
            INSERT INTO library_meta (key, value) VALUES ('legacy_migration_v1', ?)
            ON CONFLICT(key) DO UPDATE SET value = excluded.value;
            """,
            bindings: [marker]
        )
        return report
    }

    public func close() async throws {
        try await database.checkpoint()
        try await database.close()
    }

    private func ensureDefaultProject() async throws -> ProjectData {
        if let row = try await projectRow(Self.defaultProjectID) {
            return try await projectData(row)
        }
        return try await createProjectWithID(
            Self.defaultProjectID,
            name: "默认项目",
            description: "从旧版 SlateSync 数据迁移的默认项目",
            settings: .init()
        )
    }

    private func createProjectWithID(
        _ id: String,
        name: String,
        description: String,
        settings: ProjectSettings
    ) async throws -> ProjectData {
        let projectID = try PersistenceIdentifiers.project(id)
        try settings.validate()
        let libraryID = try requiredManifest().id
        let projectDirectory = projectsRoot.appending(path: projectID, directoryHint: .isDirectory)
        let relativePath = "Projects/\(projectID)"
        let now = PersistenceJSON.timestamp()
        do {
            try SecureFilePermissions.prepareDirectory(at: projectDirectory)
            try SecureFilePermissions.prepareDirectory(
                at: projectDirectory.appending(path: "tasks", directoryHint: .isDirectory)
            )
            try SecureFilePermissions.prepareDirectory(
                at: projectDirectory.appending(path: "diagnostics", directoryHint: .isDirectory)
            )
            try await writeProjectMeta(
                at: projectDirectory,
                id: projectID,
                libraryID: libraryID,
                name: name,
                description: description,
                settings: settings,
                createdAt: now,
                updatedAt: now,
                archivedAt: nil
            )
            try writeJSON(
                ProjectV1Manifest(
                    id: projectID,
                    libraryId: libraryID,
                    name: name,
                    description: description,
                    formatVersion: Self.projectFormatVersion,
                    createdAt: now,
                    updatedAt: now
                ),
                to: projectDirectory.appending(path: "project.json")
            )
            try await database.execute(
                """
                INSERT INTO projects
                  (id, relative_path, name, description, archived_at, created_at, updated_at)
                VALUES (?, ?, ?, ?, NULL, ?, ?);
                """,
                bindings: [projectID, relativePath, name, description, now, now]
            )
        } catch {
            try? stageOrRemoveUnindexedProject(projectDirectory)
            throw error
        }
        guard let row = try await projectRow(projectID) else { throw missingProject() }
        return try await projectData(row)
    }

    private func projectSummary(_ row: [String: String?]) async throws -> ProjectSummary? {
        guard
            let id = row["id"] ?? nil,
            let relativePath = row["relative_path"] ?? nil,
            let name = row["name"] ?? nil,
            let createdAt = row["created_at"] ?? nil,
            let updatedAt = row["updated_at"] ?? nil
        else { return nil }
        let projectDirectory = try checkedProjectDirectory(row)
        var taskCount = 0
        var latestTaskAt: String?
        let projectDatabaseURL = projectDirectory.appending(path: SQLiteV1.projectDatabaseFilename)
        if FileManager.default.fileExists(atPath: projectDatabaseURL.path) {
            let projectDatabase = try SQLiteDatabase(url: projectDatabaseURL)
            do {
                try await SQLiteV1.bootstrapProject(projectDatabase)
                if let aggregate = try await projectDatabase.rows(
                    "SELECT COUNT(*) AS count, MAX(updated_at) AS latest FROM tasks;"
                ).first {
                    taskCount = Int((aggregate["count"] ?? nil) ?? "0") ?? 0
                    latestTaskAt = aggregate["latest"] ?? nil
                }
                try await projectDatabase.close()
            } catch {
                try? await projectDatabase.close()
                throw error
            }
        }
        return ProjectSummary(
            id: id,
            name: name,
            description: (row["description"] ?? nil) ?? "",
            relativePath: relativePath,
            archivedAt: row["archived_at"] ?? nil,
            createdAt: createdAt,
            updatedAt: updatedAt,
            taskCount: taskCount,
            latestTaskAt: latestTaskAt,
            canArchive: id != Self.defaultProjectID
        )
    }

    private func projectData(_ row: [String: String?]) async throws -> ProjectData {
        guard let summary = try await projectSummary(row) else {
            throw SlateSyncError(code: "PROJECT_INVALID", message: "项目索引记录不完整")
        }
        let projectDirectory = try checkedProjectDirectory(row)
        let projectDatabase = try SQLiteDatabase(
            url: projectDirectory.appending(path: SQLiteV1.projectDatabaseFilename)
        )
        do {
            try await SQLiteV1.bootstrapProject(projectDatabase)
            let settings = try await readProjectSettings(projectDatabase)
            let defaults = try await readLastRecognitionDefaults(projectDatabase)
            try await projectDatabase.close()
            return ProjectData(summary: summary, settings: settings, lastRecognitionDefaults: defaults)
        } catch {
            try? await projectDatabase.close()
            throw error
        }
    }

    private func setArchived(_ id: String, archived: Bool) async throws -> ProjectData {
        try await bootstrap()
        guard let row = try await projectRow(id), let projectID = row["id"] ?? nil else {
            throw missingProject()
        }
        if archived, projectID == Self.defaultProjectID {
            throw SlateSyncError(code: "PROJECT_DEFAULT_PROTECTED", message: "默认项目不能归档")
        }
        let archivedAt = archived ? PersistenceJSON.timestamp() : nil
        let now = PersistenceJSON.timestamp()
        try await database.execute(
            "UPDATE projects SET archived_at = ?, updated_at = ? WHERE id = ?;",
            bindings: [archivedAt, now, projectID]
        )
        let projectDirectory = try checkedProjectDirectory(row)
        let projectDatabase = try SQLiteDatabase(
            url: projectDirectory.appending(path: SQLiteV1.projectDatabaseFilename)
        )
        do {
            try await SQLiteV1.bootstrapProject(projectDatabase)
            let encoded = archivedAt.map { "\"\($0)\"" } ?? "null"
            try await projectDatabase.execute(
                """
                INSERT INTO project_meta (key, value) VALUES ('archived_at', ?)
                ON CONFLICT(key) DO UPDATE SET value = excluded.value;
                """,
                bindings: [encoded]
            )
            try await projectDatabase.close()
        } catch {
            try? await projectDatabase.close()
            throw error
        }
        return try await getProject(projectID)
    }

    private func writeProjectMeta(
        at directory: URL,
        id: String,
        libraryID: String,
        name: String,
        description: String,
        settings: ProjectSettings,
        createdAt: String,
        updatedAt: String,
        archivedAt: String?
    ) async throws {
        let projectDatabase = try SQLiteDatabase(
            url: directory.appending(path: SQLiteV1.projectDatabaseFilename)
        )
        do {
            try await SQLiteV1.bootstrapProject(projectDatabase)
            let settingsJSON = try PersistenceJSON.string(
                from: JSONEncoder().encode(settings),
                errorCode: "PROJECT_SETTINGS_INVALID"
            )
            let archivedJSON = archivedAt.map { "\"\($0)\"" } ?? "null"
            let values: [(String, String)] = [
                ("project_id", id),
                ("library_id", libraryID),
                ("name", name),
                ("description", description),
                ("settings", settingsJSON),
                ("created_at", createdAt),
                ("updated_at", updatedAt),
                ("archived_at", archivedJSON),
                ("schema_version", String(Self.projectFormatVersion)),
            ]
            try await projectDatabase.transaction(values.map { key, value in
                SQLiteCommand(
                    """
                    INSERT INTO project_meta (key, value) VALUES (?, ?)
                    ON CONFLICT(key) DO UPDATE SET value = excluded.value;
                    """,
                    bindings: [key, value]
                )
            })
            try await projectDatabase.close()
        } catch {
            try? await projectDatabase.close()
            throw error
        }
    }

    private func readProjectSettings(_ projectDatabase: SQLiteDatabase) async throws -> ProjectSettings {
        guard let value = try await projectDatabase.rows(
            "SELECT value FROM project_meta WHERE key = 'settings';"
        ).first?["value"] ?? nil,
              let data = value.data(using: .utf8),
              let settings = try? JSONDecoder().decode(ProjectSettings.self, from: data)
        else { return ProjectSettings() }
        return settings
    }

    private func readLastRecognitionDefaults(
        _ projectDatabase: SQLiteDatabase
    ) async throws -> RecognitionDefaults? {
        let rows = try await projectDatabase.rows(
            "SELECT data_json FROM tasks ORDER BY created_at DESC, rowid DESC;"
        )
        for row in rows {
            guard
                let text = row["data_json"] ?? nil,
                let data = text.data(using: .utf8),
                let object = try? PersistenceJSON.object(from: data, errorCode: "TASK_INVALID"),
                object["result"] is [String: Any],
                let provider = PersistenceJSON.string(object["provider"]),
                let model = PersistenceJSON.string(object["model"])
            else { continue }
            return RecognitionDefaults(
                providerId: provider,
                modelId: model,
                customPrompt: PersistenceJSON.string(object["customPrompt"]) ?? ""
            )
        }
        return nil
    }

    private func projectRow(_ id: String) async throws -> [String: String?]? {
        let projectID = try PersistenceIdentifiers.project(id)
        return try await database.rows(
            "SELECT * FROM projects WHERE id = ?;",
            bindings: [projectID]
        ).first
    }

    private func checkedProjectDirectory(_ row: [String: String?]) throws -> URL {
        guard let relativePath = row["relative_path"] ?? nil else {
            throw SlateSyncError(code: "PROJECT_INVALID", message: "项目路径缺失")
        }
        let candidate = root.appending(path: relativePath).standardizedFileURL
        let boundary = projectsRoot.standardizedFileURL.path + "/"
        guard candidate.path.hasPrefix(boundary) else {
            throw SlateSyncError(code: "PROJECT_PATH_INVALID", message: "项目路径不在当前 Project Library 中")
        }
        return candidate
    }

    private func loadOrCreateLibraryManifest() throws -> LibraryV1Manifest {
        let url = root.appending(path: "library.json")
        if FileManager.default.fileExists(atPath: url.path) {
            do {
                let manifest = try JSONDecoder().decode(
                    LibraryV1Manifest.self,
                    from: Data(contentsOf: url)
                )
                guard manifest.formatVersion == Self.libraryFormatVersion else {
                    throw SlateSyncError(code: "LIBRARY_VERSION", message: "不支持的项目库格式版本")
                }
                return manifest
            } catch let error as SlateSyncError {
                throw error
            } catch {
                throw SlateSyncError(code: "LIBRARY_MANIFEST_INVALID", message: "项目库清单无效")
            }
        }
        let manifest = LibraryV1Manifest(
            id: "library-\(PersistenceJSON.sha256Prefix(root.path, count: 16))",
            name: Self.defaultLibraryName,
            formatVersion: Self.libraryFormatVersion,
            createdAt: PersistenceJSON.timestamp()
        )
        try writeJSON(manifest, to: url)
        return manifest
    }

    private func requiredManifest() throws -> LibraryV1Manifest {
        guard let manifest else {
            throw SlateSyncError(code: "LIBRARY_NOT_READY", message: "项目库尚未初始化")
        }
        return manifest
    }

    private func writeJSON<Value: Encodable>(_ value: Value, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try writer.writeAtomically(encoder.encode(value), to: url, permissions: 0o600)
    }

    private func validateProjectName(_ value: String) throws -> String {
        let name = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            throw SlateSyncError(code: "PROJECT_NAME_REQUIRED", message: "项目名称不能为空")
        }
        guard name.utf16.count <= 80 else {
            throw SlateSyncError(code: "PROJECT_NAME_INVALID", message: "项目名称不能超过 80 个字符")
        }
        return name
    }

    private func validateLibraryName(_ value: String) throws -> String {
        let name = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            throw SlateSyncError(code: "LIBRARY_NAME_REQUIRED", message: "项目库名称不能为空")
        }
        guard name.utf16.count <= 80, name != ".", name != ".." else {
            throw SlateSyncError(code: "LIBRARY_NAME_INVALID", message: "项目库名称无效")
        }
        let forbidden = CharacterSet(charactersIn: "/\\:<>\"|?*").union(.controlCharacters)
        guard name.rangeOfCharacter(from: forbidden) == nil else {
            throw SlateSyncError(code: "LIBRARY_NAME_INVALID", message: "项目库名称不能包含特殊字符")
        }
        return name
    }

    private func cleanDescription(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return String(decoding: trimmed.utf16.prefix(500), as: UTF16.self)
    }

    private func missingProject() -> SlateSyncError {
        SlateSyncError(code: "ENOENT", message: "项目不存在")
    }

    private func importedProjectID(sourceID: String) -> String {
        "project-\(PersistenceJSON.sha256Prefix("\(sourceID):\(UUID())", count: 16))"
    }

    private func cleanupStagedProjectDirectories() async throws {
        let entries = try FileManager.default.contentsOfDirectory(
            at: projectsRoot,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )
        for entry in entries where isStagedProjectDirectory(entry.lastPathComponent) {
            try? await removeStagedDirectory(entry)
        }
    }

    private func isStagedProjectDirectory(_ name: String) -> Bool {
        name.range(
            of: #"^project-[a-zA-Z0-9_-]+\.deleting-[a-f0-9-]{36}$"#,
            options: [.regularExpression, .caseInsensitive]
        ) != nil
    }

    private func removeStagedDirectory(_ url: URL) async throws {
        var lastError: (any Error)?
        for attempt in 0..<4 {
            do {
                try FileManager.default.removeItem(at: url)
                return
            } catch {
                lastError = error
                if attempt < 3 { try await Task.sleep(for: .milliseconds(100)) }
            }
        }
        throw lastError ?? SlateSyncError(code: "PROJECT_DELETE", message: "无法清理项目目录")
    }

    private func stageOrRemoveUnindexedProject(_ url: URL) throws {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        do {
            try FileManager.default.removeItem(at: url)
        } catch {
            let staged = URL(fileURLWithPath: "\(url.path).deleting-\(UUID().uuidString.lowercased())")
            try FileManager.default.moveItem(at: url, to: staged)
        }
    }

    private enum LegacyTable: String {
        case tasks
        case diagnostics = "diagnostic_sessions"
        case scenarios = "scenario_profiles"
        case observations = "scenario_observations"
    }

    private func legacyCommands(
        source: SQLiteDatabase,
        table: LegacyTable,
        columns: [String],
        projectID: String? = nil
    ) async throws -> [(LegacyTable, SQLiteCommand)] {
        let exists = try await source.rows(
            "SELECT 1 AS present FROM sqlite_master WHERE type = 'table' AND name = ?;",
            bindings: [table.rawValue]
        ).first != nil
        guard exists else { return [] }
        return try await source.rows(
            "SELECT \(columns.joined(separator: ", ")) FROM \(table.rawValue);"
        ).map { row in
            var bindings = columns.map { row[$0] ?? nil }
            if let projectID, let dataIndex = columns.firstIndex(of: "data_json"), let text = bindings[dataIndex] {
                bindings[dataIndex] = addProjectID(to: text, projectID: projectID)
            }
            let placeholders = Array(repeating: "?", count: columns.count).joined(separator: ", ")
            return (
                table,
                SQLiteCommand(
                    "INSERT OR IGNORE INTO \(table.rawValue) (\(columns.joined(separator: ", "))) VALUES (\(placeholders));",
                    bindings: bindings
                )
            )
        }
    }

    private func addProjectID(to json: String, projectID: String) -> String {
        guard
            let data = json.data(using: .utf8),
            var object = try? PersistenceJSON.object(from: data, errorCode: "LEGACY_MIGRATION")
        else { return json }
        if PersistenceJSON.string(object["projectId"])?.isEmpty != false {
            object["projectId"] = projectID
        }
        guard let rewritten = try? PersistenceJSON.data(from: object, errorCode: "LEGACY_MIGRATION") else {
            return json
        }
        return String(data: rewritten, encoding: .utf8) ?? json
    }

    private func copyLegacySnapshots(from source: URL, to target: URL, projectID: String) throws -> Int {
        guard FileManager.default.fileExists(atPath: source.path) else { return 0 }
        try SecureFilePermissions.prepareDirectory(at: target)
        let entries = try FileManager.default.contentsOfDirectory(
            at: source,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ).filter { $0.pathExtension.lowercased() == "json" }
        var copied = 0
        for sourceURL in entries {
            let targetURL = target.appending(path: sourceURL.lastPathComponent)
            guard !FileManager.default.fileExists(atPath: targetURL.path) else { continue }
            let sourceData = try Data(contentsOf: sourceURL)
            let output: Data
            if var object = try? PersistenceJSON.object(from: sourceData, errorCode: "LEGACY_MIGRATION") {
                if PersistenceJSON.string(object["projectId"])?.isEmpty != false {
                    object["projectId"] = projectID
                }
                output = (try? PersistenceJSON.data(from: object, errorCode: "LEGACY_MIGRATION")) ?? sourceData
            } else {
                // Malformed compatibility snapshots are preserved byte-for-byte
                // for later repair, just like the Electron migration.
                output = sourceData
            }
            try writer.writeAtomically(output, to: targetURL, permissions: 0o600)
            copied += 1
        }
        return copied
    }
}

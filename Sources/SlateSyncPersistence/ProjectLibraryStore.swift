import Foundation
import SlateSyncDomain

public actor ProjectLibraryStore: ProjectLibraryServing {
    public static let defaultLibraryName = "Local SlateSync Library"
    public static let defaultProjectID = "project-default"

    private let root: URL
    private let database: SQLiteDatabase
    private let libraryID: String

    public init(applicationSupportRoot: URL? = nil) throws {
        let support = try applicationSupportRoot ?? ApplicationSupportLocator.root()
        root = support.appending(path: Self.defaultLibraryName, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(
            at: root.appending(path: "Projects", directoryHint: .isDirectory),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        database = try SQLiteDatabase(url: root.appending(path: "library.sqlite"))
        libraryID = "library-local"
    }

    public func bootstrap() async throws {
        try await database.execute("""
            CREATE TABLE IF NOT EXISTS library_meta (
              key TEXT PRIMARY KEY,
              value TEXT NOT NULL
            );
            """)
        try await database.execute("""
            CREATE TABLE IF NOT EXISTS projects (
              id TEXT PRIMARY KEY,
              relative_path TEXT NOT NULL UNIQUE,
              name TEXT NOT NULL,
              description TEXT NOT NULL DEFAULT '',
              archived_at TEXT,
              created_at TEXT NOT NULL,
              updated_at TEXT NOT NULL
            );
            """)
        try await database.execute(
            "CREATE INDEX IF NOT EXISTS projects_updated_at_idx ON projects(updated_at DESC);"
        )
        try await database.execute(
            "INSERT OR IGNORE INTO library_meta (key, value) VALUES ('formatVersion', '1');"
        )
    }

    public func libraryInfo() async throws -> LibraryInfo {
        try await bootstrap()
        return LibraryInfo(id: libraryID, name: Self.defaultLibraryName, path: root.path)
    }

    public func listProjects() async throws -> [ProjectSummary] {
        try await bootstrap()
        let rows = try await database.rows("""
            SELECT id, relative_path, name, description, archived_at, created_at, updated_at
            FROM projects ORDER BY updated_at DESC;
            """)
        return rows.compactMap(Self.projectSummary)
    }

    public func createProject(name: String, description: String) async throws -> ProjectData {
        try await bootstrap()
        let normalized = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else {
            throw SlateSyncError(code: "PROJECT_NAME_REQUIRED", message: "请输入项目名称")
        }
        let id = "project-\(UUID().uuidString.lowercased())"
        let relativePath = "Projects/\(id)"
        let timestamp = ISO8601DateFormatter().string(from: Date())
        try FileManager.default.createDirectory(
            at: root.appending(path: relativePath, directoryHint: .isDirectory),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try await database.execute(
            """
            INSERT INTO projects
              (id, relative_path, name, description, archived_at, created_at, updated_at)
            VALUES (?, ?, ?, ?, NULL, ?, ?);
            """,
            bindings: [id, relativePath, normalized, description, timestamp, timestamp]
        )
        let summary = ProjectSummary(
            id: id,
            name: normalized,
            description: description,
            relativePath: relativePath,
            createdAt: timestamp,
            updatedAt: timestamp
        )
        return ProjectData(summary: summary)
    }

    private static func projectSummary(_ row: [String: String?]) -> ProjectSummary? {
        guard
            let id = row["id"] ?? nil,
            let name = row["name"] ?? nil,
            let relativePath = row["relative_path"] ?? nil,
            let createdAt = row["created_at"] ?? nil,
            let updatedAt = row["updated_at"] ?? nil
        else { return nil }
        return ProjectSummary(
            id: id,
            name: name,
            description: (row["description"] ?? nil) ?? "",
            relativePath: relativePath,
            archivedAt: row["archived_at"] ?? nil,
            createdAt: createdAt,
            updatedAt: updatedAt,
            canArchive: id != defaultProjectID
        )
    }
}

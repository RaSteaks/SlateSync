import Foundation

/// Frozen filenames and schema used by Electron v1 and the native migration.
public enum SQLiteV1 {
    public static let legacyDatabaseFilename = "slatesync.sqlite"
    public static let libraryDatabaseFilename = "library.sqlite"
    public static let projectDatabaseFilename = "project.sqlite"

    static let librarySchema = """
        CREATE TABLE IF NOT EXISTS library_meta (
          key TEXT PRIMARY KEY,
          value TEXT NOT NULL
        );

        CREATE TABLE IF NOT EXISTS projects (
          id TEXT PRIMARY KEY,
          relative_path TEXT NOT NULL UNIQUE,
          name TEXT NOT NULL,
          description TEXT NOT NULL DEFAULT '',
          archived_at TEXT,
          created_at TEXT NOT NULL,
          updated_at TEXT NOT NULL
        );
        CREATE INDEX IF NOT EXISTS projects_updated_at_idx
          ON projects(updated_at DESC);
        """

    static let projectSchema = """
        CREATE TABLE IF NOT EXISTS app_meta (
          key TEXT PRIMARY KEY,
          value TEXT NOT NULL
        );

        CREATE TABLE IF NOT EXISTS project_meta (
          key TEXT PRIMARY KEY,
          value TEXT NOT NULL
        );

        CREATE TABLE IF NOT EXISTS tasks (
          id TEXT PRIMARY KEY,
          data_json TEXT NOT NULL,
          created_at TEXT NOT NULL,
          updated_at TEXT NOT NULL
        );
        CREATE INDEX IF NOT EXISTS tasks_updated_at_idx ON tasks(updated_at);
        CREATE INDEX IF NOT EXISTS tasks_created_at_idx ON tasks(created_at DESC);

        CREATE TABLE IF NOT EXISTS diagnostic_sessions (
          id TEXT PRIMARY KEY,
          data_json TEXT NOT NULL,
          saved_at TEXT NOT NULL
        );
        CREATE INDEX IF NOT EXISTS diagnostics_saved_at_idx
          ON diagnostic_sessions(saved_at);

        CREATE TABLE IF NOT EXISTS scenario_profiles (
          id TEXT PRIMARY KEY,
          schema_version INTEGER NOT NULL,
          fingerprint_version INTEGER NOT NULL,
          fingerprint TEXT NOT NULL,
          profile_json TEXT NOT NULL,
          sample_count INTEGER NOT NULL DEFAULT 1,
          created_at TEXT NOT NULL,
          updated_at TEXT NOT NULL,
          last_used_at TEXT NOT NULL,
          UNIQUE(fingerprint_version, fingerprint)
        );
        CREATE INDEX IF NOT EXISTS scenario_profiles_last_used_idx
          ON scenario_profiles(last_used_at);

        CREATE TABLE IF NOT EXISTS scenario_observations (
          id TEXT PRIMARY KEY,
          profile_id TEXT,
          fingerprint_version INTEGER NOT NULL,
          fingerprint TEXT NOT NULL,
          observation_json TEXT NOT NULL,
          created_at TEXT NOT NULL,
          FOREIGN KEY(profile_id) REFERENCES scenario_profiles(id)
            ON DELETE SET NULL
        );
        CREATE INDEX IF NOT EXISTS scenario_observations_created_idx
          ON scenario_observations(created_at);
        """

    static func bootstrapLibrary(_ database: SQLiteDatabase) async throws {
        try await database.executeScript(librarySchema)
    }

    static func bootstrapProject(_ database: SQLiteDatabase) async throws {
        // Derive required objects from the same DDL that creates them, so adding
        // a table/index cannot silently leave an independent name list stale.
        // Unknown statement forms fall back to running DDL rather than skipping
        // a future migration whose effects this existence check cannot verify.
        let statements = projectSchema.split(separator: ";").filter {
            !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        let required = statements.compactMap { statement -> String? in
            let words = statement.split(whereSeparator: { $0.isWhitespace })
            guard words.count >= 6, words[0] == "CREATE",
                  words[1] == "TABLE" || words[1] == "INDEX",
                  words[2] == "IF", words[3] == "NOT", words[4] == "EXISTS" else { return nil }
            return "\(words[1].lowercased()):\(words[5])"
        }
        let installed = Set(try await database.rows(
            "SELECT type || ':' || name AS object FROM sqlite_master WHERE type IN ('table', 'index');"
        ).compactMap { $0["object"] ?? nil })
        if required.count == statements.count, !required.isEmpty,
           Set(required).isSubset(of: installed) { return }
        try await database.executeScript(projectSchema)
    }
}

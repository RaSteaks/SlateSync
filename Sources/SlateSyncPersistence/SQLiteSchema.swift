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
        try await database.executeScript(projectSchema)
    }
}

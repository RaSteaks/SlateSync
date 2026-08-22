// Shared SQLite bootstrap and compatibility helpers.
//
// SQLite is the source of truth for structured SlateSync data. The small JSON
// snapshot helpers intentionally remain available so existing installations
// can be migrated safely and older tools can still inspect recent records.
import Database from "better-sqlite3";
import { mkdirSync, chmodSync } from "node:fs";
import {
  mkdir,
  readFile,
  readdir,
  rename,
  unlink,
  writeFile,
} from "node:fs/promises";
import { join, basename, extname } from "node:path";
import { randomUUID } from "node:crypto";

const DATABASE_FILENAME = "slatesync.sqlite";
const LIBRARY_DATABASE_FILENAME = "library.sqlite";
const PROJECT_DATABASE_FILENAME = "project.sqlite";

export function openSlateDatabase(baseDir, options = {}) {
  mkdirSync(baseDir, { recursive: true, mode: 0o700 });
  const kind = options.kind || "project";
  const filename = options.filename || (
    kind === "library" ? LIBRARY_DATABASE_FILENAME : DATABASE_FILENAME
  );
  const dbPath = join(baseDir, filename);
  const db = new Database(dbPath);
  db.pragma("journal_mode = WAL");
  db.pragma("foreign_keys = ON");
  db.pragma("busy_timeout = 5000");
  db.exec(kind === "library" ? LIBRARY_SCHEMA : PROJECT_SCHEMA);
  // SQLite creates the database file before the first table write. Keep the
  // file private because task results and OCR evidence may contain production data.
  try {
    chmodSync(dbPath, 0o600);
  } catch {
    // Some filesystems do not expose POSIX modes; SQLite remains usable there.
  }
  return { db, dbPath };
}

// The library database is deliberately small: it is only a registry of
// project folders. All production data lives in a project's own database.
const LIBRARY_SCHEMA = `
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
`;

// Project databases retain the existing table shapes so legacy data can be
// migrated without rewriting task, diagnostic, or scenario payloads.
const PROJECT_SCHEMA = `
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
`;

export const SQLITE_FILENAMES = Object.freeze({
  legacy: DATABASE_FILENAME,
  library: LIBRARY_DATABASE_FILENAME,
  project: PROJECT_DATABASE_FILENAME,
});

export async function migrateJsonDirectory({
  db,
  directoryPath,
  table,
  idColumn = "id",
  timestampColumn,
  extraColumns = [],
  parseRecord,
}) {
  let files;
  try {
    files = await readdir(directoryPath);
  } catch (error) {
    if (error?.code === "ENOENT") return 0;
    throw error;
  }

  const jsonFiles = files.filter((file) => extname(file).toLowerCase() === ".json");
  if (!jsonFiles.length) return 0;
  const columns = [idColumn, "data_json", timestampColumn, ...extraColumns];
  const placeholders = columns.map(() => "?").join(", ");
  const insert = db.prepare(
    `INSERT OR IGNORE INTO ${table} (${columns.join(", ")})
     VALUES (${placeholders})`,
  );
  const transaction = db.transaction((records) => {
    let imported = 0;
    for (const record of records) {
      const result = insert.run(
        record.id,
        record.dataJson,
        record.timestamp,
        ...(record.extraValues || []),
      );
      imported += result.changes;
    }
    return imported;
  });
  const records = [];
  for (const file of jsonFiles) {
    try {
      const raw = await readFile(join(directoryPath, file), "utf8");
      const value = JSON.parse(raw);
      const record = parseRecord(value, basename(file, extname(file)));
      if (record) records.push(record);
    } catch {
      // A corrupt legacy snapshot must not prevent the application from booting.
    }
  }
  return transaction(records);
}

export async function writeJsonSnapshot(directoryPath, id, value) {
  await mkdir(directoryPath, { recursive: true, mode: 0o700 });
  const filePath = join(directoryPath, `${id}.json`);
  const tempPath = `${filePath}.${randomUUID()}.tmp`;
  await writeFile(tempPath, JSON.stringify(value), {
    encoding: "utf8",
    mode: 0o600,
  });
  await rename(tempPath, filePath);
}

export async function removeJsonSnapshot(directoryPath, id) {
  await unlink(join(directoryPath, `${id}.json`)).catch(() => {});
}

export function closeSlateDatabase(db) {
  if (db?.open) db.close();
}

// Shared SQLite bootstrap and compatibility helpers.
//
// SQLite is the source of truth for structured SlateSync data. The small JSON
// snapshot helpers intentionally remain available so existing installations
// can be migrated safely and older tools can still inspect recent records.
import { openCompatibleDatabase } from "./encrypted-database.mjs";
import { readProjectFile as readFile, writeProjectFile as writeFile } from "./local-encryption.mjs";
import { mkdirSync, chmodSync } from "node:fs";
import {
  mkdir,
  readdir,
  rename,
  unlink,
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
  const db = openCompatibleDatabase(dbPath);
  try {
    db.pragma("journal_mode = WAL");
    // WAL 配合 synchronous = NORMAL：提交不再逐笔强制 fsync，掉电最多丢失最近
    // 几笔已提交事务而不会损坏数据库；这是打开项目热路径上的写入侧优化。
    db.pragma("synchronous = NORMAL");
    db.pragma("foreign_keys = ON");
    db.pragma("busy_timeout = 5000");
    db.exec(kind === "library" ? LIBRARY_SCHEMA : PROJECT_SCHEMA);
    // 存量项目库在这里幂等补列；新库由 PROJECT_SCHEMA 直接带列，此处为空操作。
    if (kind === "project") ensureProjectColumns(db);
    // SQLite creates the database file before the first table write. Keep the
    // file private because task results and OCR evidence may contain production data.
    try {
      chmodSync(dbPath, 0o600);
    } catch {
      // Some filesystems do not expose POSIX modes; SQLite remains usable there.
    }
    return { db, dbPath };
  } catch (error) {
    // Failed PRAGMAs/schema migrations must not leave a database handle open.
    db.close();
    throw error;
  }
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
    updated_at TEXT NOT NULL,
    -- summary_json 缓存 list-tasks 的摘要投影（保存时预计算），避免列表读取
    -- 反复解析含图片组/CSV base64 的完整 blob。放在最后一列，与存量库
    -- ALTER TABLE ADD COLUMN 的追加位置一致，保证两类库 table_info 相同。
    summary_json TEXT
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

// 存量项目库补列：只前进、幂等、nullable，绝不重写已有数据。
function ensureProjectColumns(db) {
  const columns = db.prepare("PRAGMA table_info(tasks)").all();
  if (!columns.some((column) => column.name === "summary_json")) {
    db.exec("ALTER TABLE tasks ADD COLUMN summary_json TEXT");
  }
}

// app_meta 完成标记：一次性 JSON 快照迁移只在键缺失时执行，之后重复打开
// 项目不再 readdir + JSON.parse 全部历史快照。写入即表示迁移阶段结束。
export function readAppMetaMarker(db, key) {
  const row = db.prepare("SELECT value FROM app_meta WHERE key = ?").get(key);
  if (!row) return null;
  try {
    return JSON.parse(row.value);
  } catch {
    return row.value;
  }
}

export function writeAppMetaMarker(db, key, value) {
  db.prepare(`
    INSERT INTO app_meta (key, value) VALUES (?, ?)
    ON CONFLICT(key) DO UPDATE SET value = excluded.value
  `).run(key, JSON.stringify(value ?? true));
}

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

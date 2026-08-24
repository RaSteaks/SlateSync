// Electron Project Library persistence.
//
// The library database indexes project folders, while each project owns an
// independent SQLite database for tasks, diagnostics, and scenario profiles.
// Keeping the boundary on disk makes accidental cross-project reads harder
// than relying on a renderer-side filter or a nullable project_id column.
import Database from "better-sqlite3";
import {
  access,
  mkdir,
  readFile,
  readdir,
  rename,
  rm,
  writeFile,
  copyFile,
} from "node:fs/promises";
import { createHash, randomUUID } from "node:crypto";
import { join, relative, resolve } from "node:path";
import {
  closeSlateDatabase,
  openSlateDatabase,
  SQLITE_FILENAMES,
} from "./sqlite-store.mjs";
import {
  normalizeProjectSettings,
  projectSettingsFromWorkflow,
  validateProjectSettings,
} from "./project-settings.mjs";

export const LIBRARY_FORMAT_VERSION = 1;
export const PROJECT_FORMAT_VERSION = 1;
export const DEFAULT_LIBRARY_NAME = "Local SlateSync Library";
export const DEFAULT_LIBRARY_FOLDER =
  "Local SlateSync Library.slatesync-library";
export const DEFAULT_PROJECT_ID = "project-default";

export function defaultLibraryPath(applicationSupportPath) {
  // Keep the portable package directly under the OS application-data root so
  // the default matches macOS ~/Library/Application Support while libraryPath
  // can still point at any user-selected volume or directory.
  return join(applicationSupportPath, DEFAULT_LIBRARY_FOLDER);
}

export function createProjectLibrary(libraryRoot, options = {}) {
  const rootPath = resolve(String(libraryRoot || ""));
  const projectsPath = join(rootPath, "Projects");
  const { db, dbPath } = openSlateDatabase(rootPath, { kind: "library" });
  const removeDirectory = options.removeDirectory || rm;
  let manifest = null;

  const ready = initializeLibrary();

  const store = {
    libraryRoot: rootPath,
    projectsPath,
    dbPath,

    async getLibraryInfo() {
      await ready;
      return {
        id: manifest.id,
        name: manifest.name,
        path: rootPath,
        formatVersion: manifest.formatVersion,
      };
    },

    async listProjects({ includeArchived = false } = {}) {
      await ready;
      const rows = db.prepare(`
        SELECT id, relative_path, name, description, archived_at,
               created_at, updated_at
        FROM projects
        ${includeArchived ? "" : "WHERE archived_at IS NULL"}
        ORDER BY archived_at IS NOT NULL, updated_at DESC
      `).all();
      return Promise.all(rows.map((row) => projectSummary(row)));
    },

    async getProject(id, { allowArchived = true } = {}) {
      await ready;
      const row = findProjectRow(id);
      if (!row) throw missingProject();
      if (!allowArchived && row.archived_at) throw archivedProject();
      return projectSummary(row, { includeSettings: true });
    },

    async createProject({ name, description = "", settings } = {}) {
      await ready;
      const cleanName = validateProjectName(name);
      const id = idForProject(`${cleanName}:${Date.now()}:${Math.random()}`);
      const projectDir = projectDirectory(id);
      const relativePath = relative(rootPath, projectDir);
      const now = new Date().toISOString();
      const projectSettings = validateProjectSettings(
        settings || options.defaultSettings || normalizeProjectSettings(),
      );

      await mkdir(join(projectDir, "tasks"), { recursive: true, mode: 0o700 });
      await mkdir(join(projectDir, "diagnostics"), {
        recursive: true,
        mode: 0o700,
      });
      const projectDb = openSlateDatabase(projectDir, {
        kind: "project",
        filename: SQLITE_FILENAMES.project,
      });
      try {
        writeProjectMeta(projectDb.db, {
          id,
          libraryId: manifest.id,
          name: cleanName,
          description: cleanDescription(description),
          settings: projectSettings,
          createdAt: now,
          updatedAt: now,
          archivedAt: null,
        });
      } finally {
        closeSlateDatabase(projectDb.db);
      }
      await writeProjectManifest(projectDir, {
        id,
        libraryId: manifest.id,
        name: cleanName,
        description: cleanDescription(description),
        formatVersion: PROJECT_FORMAT_VERSION,
        createdAt: now,
        updatedAt: now,
      });
      db.prepare(`
        INSERT INTO projects
          (id, relative_path, name, description, archived_at, created_at, updated_at)
        VALUES (?, ?, ?, ?, NULL, ?, ?)
      `).run(
        id,
        relativePath,
        cleanName,
        cleanDescription(description),
        now,
        now,
      );
      return store.getProject(id);
    },

    async updateProject(id, patch = {}) {
      await ready;
      const row = findProjectRow(id);
      if (!row) throw missingProject();
      if (row.archived_at) throw archivedProject();
      const projectDir = checkedProjectDirectory(row);
      const current = await store.getProject(id);
      const name = patch.name === undefined
        ? current.name
        : validateProjectName(patch.name);
      const description = patch.description === undefined
        ? current.description
        : cleanDescription(patch.description);
      const settings = patch.settings === undefined
        ? current.settings
        : validateProjectSettings(patch.settings);
      const now = new Date().toISOString();
      const projectDb = openSlateDatabase(projectDir, {
        kind: "project",
        filename: SQLITE_FILENAMES.project,
      });
      try {
        writeProjectMeta(projectDb.db, {
          id: current.id,
          libraryId: manifest.id,
          name,
          description,
          settings,
          createdAt: current.createdAt,
          updatedAt: now,
          archivedAt: current.archivedAt,
        });
      } finally {
        closeSlateDatabase(projectDb.db);
      }
      await writeProjectManifest(projectDir, {
        id: current.id,
        libraryId: manifest.id,
        name,
        description,
        formatVersion: PROJECT_FORMAT_VERSION,
        createdAt: current.createdAt,
        updatedAt: now,
      });
      db.prepare(`
        UPDATE projects
        SET name = ?, description = ?, updated_at = ?
        WHERE id = ?
      `).run(name, description, now, current.id);
      return store.getProject(current.id);
    },

    async touchProjectActivity(id, at = new Date().toISOString()) {
      await ready;
      const row = findProjectRow(id);
      if (!row) throw missingProject();
      // Activity belongs to the lightweight library index. Project content
      // timestamps remain owned by the corresponding project database.
      db.prepare("UPDATE projects SET updated_at = ? WHERE id = ?").run(
        String(at),
        row.id,
      );
      return String(at);
    },

    async archiveProject(id) {
      return setArchived(id, true);
    },

    async restoreProject(id) {
      return setArchived(id, false);
    },

    async deleteProject(id) {
      await ready;
      const row = findProjectRow(id);
      if (!row) throw missingProject();
      if (row.id === DEFAULT_PROJECT_ID) {
        throw new Error("默认项目不能删除");
      }
      const projectDir = checkedProjectDirectory(row);
      const stagedPath = `${projectDir}.deleting-${randomUUID()}`;
      // Stage the exact validated project directory first. If the library
      // index update fails, rename restores a fully usable project instead of
      // leaving a half-deleted row/folder pair.
      await rename(projectDir, stagedPath);
      try {
        db.prepare("DELETE FROM projects WHERE id = ?").run(row.id);
      } catch (error) {
        await rename(stagedPath, projectDir);
        throw error;
      }
      try {
        await removeStagedProjectDirectory(stagedPath);
      } catch {
        // Deletion is already committed in the Library index. A recursive
        // removal can fail after deleting only part of a directory, so keep
        // the uniquely named tombstone rather than resurrecting corrupt data.
        // Initialization retries every tombstone left by an interrupted run.
      }
      return { deleted: row.id };
    },

    async migrateLegacyData(legacyDataDir) {
      await ready;
      const marker = db.prepare(
        "SELECT value FROM library_meta WHERE key = ?",
      ).get("legacy_migration_v1");
      if (marker) return JSON.parse(marker.value);

      const defaultProject = await ensureDefaultProject();
      const projectDir = checkedProjectDirectory(findProjectRow(defaultProject.id));
      const target = openSlateDatabase(projectDir, {
        kind: "project",
        filename: SQLITE_FILENAMES.project,
      });
      const counts = {
        tasks: 0,
        scenarios: 0,
        observations: 0,
        diagnostics: 0,
        snapshots: 0,
      };
      let source = null;
      try {
        const legacyDbPath = join(
          resolve(String(legacyDataDir || "")),
          SQLITE_FILENAMES.legacy,
        );
        if (await exists(legacyDbPath)) {
          source = new Database(legacyDbPath, {
            readonly: true,
            fileMustExist: true,
          });
          source.pragma("foreign_keys = ON");
          const transaction = target.db.transaction(() => {
            counts.scenarios = copyRows(source, target.db, "scenario_profiles", [
              "id",
              "schema_version",
              "fingerprint_version",
              "fingerprint",
              "profile_json",
              "sample_count",
              "created_at",
              "updated_at",
              "last_used_at",
            ]);
            counts.observations = copyRows(source, target.db, "scenario_observations", [
              "id",
              "profile_id",
              "fingerprint_version",
              "fingerprint",
              "observation_json",
              "created_at",
            ]);
            counts.tasks = copyRows(source, target.db, "tasks", [
              "id",
              "data_json",
              "created_at",
              "updated_at",
            ], (row) => ({
              ...row,
              data_json: addProjectIdJson(row.data_json, defaultProject.id),
            }));
            counts.diagnostics = copyRows(source, target.db, "diagnostic_sessions", [
              "id",
              "data_json",
              "saved_at",
            ], (row) => ({
              ...row,
              data_json: addProjectIdJson(row.data_json, defaultProject.id),
            }));
          });
          transaction();
        }
      } finally {
        source?.close();
        closeSlateDatabase(target.db);
      }

      counts.snapshots += await copySnapshotDirectory(
        join(resolve(String(legacyDataDir || "")), "tasks"),
        join(projectDir, "tasks"),
        defaultProject.id,
      );
      counts.snapshots += await copySnapshotDirectory(
        join(resolve(String(legacyDataDir || "")), "diagnostics"),
        join(projectDir, "diagnostics"),
        defaultProject.id,
      );
      const result = {
        version: 1,
        projectId: defaultProject.id,
        migratedAt: new Date().toISOString(),
        counts,
      };
      db.prepare(`
        INSERT INTO library_meta (key, value) VALUES (?, ?)
        ON CONFLICT(key) DO UPDATE SET value = excluded.value
      `).run("legacy_migration_v1", JSON.stringify(result));
      return result;
    },

    async close() {
      await ready;
      closeSlateDatabase(db);
    },
  };

  return store;

  async function initializeLibrary() {
    await mkdir(projectsPath, { recursive: true, mode: 0o700 });
    await cleanupStagedProjectDirectories();
    manifest = await readOrCreateManifest(rootPath, {
      id: libraryIdForPath(rootPath),
      name: options.name || DEFAULT_LIBRARY_NAME,
      formatVersion: LIBRARY_FORMAT_VERSION,
      createdAt: new Date().toISOString(),
    });
    await ensureDefaultProject();
  }

  async function cleanupStagedProjectDirectories() {
    const entries = await readdir(projectsPath, { withFileTypes: true });
    // Tombstones are created only by deleteProject after the Library row has
    // been removed. Retrying them on startup makes a transient file lock
    // recoverable without ever re-exposing a partially removed project.
    await Promise.all(entries
      .filter((entry) => entry.isDirectory() && isStagedProjectDirectory(entry.name))
      .map(async (entry) => {
        try {
          await removeStagedProjectDirectory(join(projectsPath, entry.name));
        } catch {
          // Keep the tombstone for the next startup; it is not addressable by
          // a project row and therefore cannot be opened by the application.
        }
      }));
  }

  async function removeStagedProjectDirectory(stagedPath) {
    // Node retries transient EPERM/EBUSY failures on supported platforms;
    // persistent failures remain a safe tombstone for a later startup retry.
    await removeDirectory(stagedPath, {
      recursive: true,
      force: false,
      maxRetries: 3,
      retryDelay: 100,
    });
  }

  async function ensureDefaultProject() {
    const existing = findProjectRow(DEFAULT_PROJECT_ID);
    if (existing) return projectSummary(existing, { includeSettings: true });
    const created = await createProjectWithId({
      id: DEFAULT_PROJECT_ID,
      name: "默认项目",
      description: "从旧版 SlateSync 数据迁移的默认项目",
      settings: options.defaultSettings || projectSettingsFromWorkflow(),
    });
    return created;
  }

  async function createProjectWithId({ id, name, description, settings }) {
    const projectDir = projectDirectory(id);
    const relativePath = relative(rootPath, projectDir);
    const now = new Date().toISOString();
    const cleanName = validateProjectName(name);
    const cleanDescriptionValue = cleanDescription(description);
    const projectSettings = validateProjectSettings(settings);
    await mkdir(join(projectDir, "tasks"), { recursive: true, mode: 0o700 });
    await mkdir(join(projectDir, "diagnostics"), {
      recursive: true,
      mode: 0o700,
    });
    const projectDb = openSlateDatabase(projectDir, {
      kind: "project",
      filename: SQLITE_FILENAMES.project,
    });
    try {
      writeProjectMeta(projectDb.db, {
        id,
        libraryId: manifest.id,
        name: cleanName,
        description: cleanDescriptionValue,
        settings: projectSettings,
        createdAt: now,
        updatedAt: now,
        archivedAt: null,
      });
    } finally {
      closeSlateDatabase(projectDb.db);
    }
    await writeProjectManifest(projectDir, {
      id,
      libraryId: manifest.id,
      name: cleanName,
      description: cleanDescriptionValue,
      formatVersion: PROJECT_FORMAT_VERSION,
      createdAt: now,
      updatedAt: now,
    });
    db.prepare(`
      INSERT INTO projects
        (id, relative_path, name, description, archived_at, created_at, updated_at)
      VALUES (?, ?, ?, ?, NULL, ?, ?)
    `).run(id, relativePath, cleanName, cleanDescriptionValue, now, now);
    return projectSummary(findProjectRow(id), { includeSettings: true });
  }

  async function projectSummary(row, { includeSettings = false } = {}) {
    const projectDir = checkedProjectDirectory(row);
    let taskCount = 0;
    let latestTaskAt = null;
    let settings = normalizeProjectSettings(options.defaultSettings);
    let lastRecognitionDefaults = null;
    if (await exists(join(projectDir, SQLITE_FILENAMES.project))) {
      const projectDb = openSlateDatabase(projectDir, {
        kind: "project",
        filename: SQLITE_FILENAMES.project,
      });
      try {
        const summary = projectDb.db.prepare(
          "SELECT COUNT(*) AS count, MAX(updated_at) AS latest FROM tasks",
        ).get();
        taskCount = Number(summary?.count) || 0;
        latestTaskAt = summary?.latest || null;
        if (includeSettings) {
          settings = readProjectSettings(projectDb.db, options.defaultSettings);
          lastRecognitionDefaults = readLastRecognitionDefaults(projectDb.db);
        }
      } finally {
        closeSlateDatabase(projectDb.db);
      }
    }
    const summary = {
      id: row.id,
      name: row.name,
      description: row.description || "",
      relativePath: row.relative_path,
      directoryPath: projectDir,
      archivedAt: row.archived_at || null,
      createdAt: row.created_at,
      updatedAt: row.updated_at,
      taskCount,
      latestTaskAt,
      // The default project is the permanent migration target and therefore
      // advertises the same non-archivable invariant enforced by setArchived.
      canArchive: row.id !== DEFAULT_PROJECT_ID,
    };
    // Keep list-projects lightweight; settings are loaded only when a project
    // is opened so the library index never becomes a second settings store.
    if (includeSettings) {
      summary.settings = settings;
      summary.lastRecognitionDefaults = lastRecognitionDefaults;
    }
    return summary;
  }

  async function setArchived(id, archived) {
    await ready;
    const row = findProjectRow(id);
    if (!row) throw missingProject();
    if (id === DEFAULT_PROJECT_ID && archived) {
      throw new Error("默认项目不能归档");
    }
    const archivedAt = archived ? new Date().toISOString() : null;
    const now = new Date().toISOString();
    db.prepare(`
      UPDATE projects
      SET archived_at = ?, updated_at = ?
      WHERE id = ?
    `).run(archivedAt, now, id);
    const projectDir = checkedProjectDirectory(row);
    if (await exists(join(projectDir, SQLITE_FILENAMES.project))) {
      const projectDb = openSlateDatabase(projectDir, {
        kind: "project",
        filename: SQLITE_FILENAMES.project,
      });
      try {
        projectDb.db.prepare(`
          INSERT INTO project_meta (key, value) VALUES (?, ?)
          ON CONFLICT(key) DO UPDATE SET value = excluded.value
        `).run("archived_at", JSON.stringify(archivedAt));
      } finally {
        closeSlateDatabase(projectDb.db);
      }
    }
    return store.getProject(id);
  }

  function findProjectRow(id) {
    return db.prepare(
      "SELECT * FROM projects WHERE id = ?",
    ).get(validateProjectId(id));
  }

  function projectDirectory(id) {
    return join(projectsPath, validateProjectId(id));
  }

  function checkedProjectDirectory(row) {
    if (!row) throw missingProject();
    const candidate = resolve(rootPath, row.relative_path);
    const boundary = `${resolve(projectsPath)}${requirePathSeparator()}`;
    if (candidate !== resolve(projectsPath) && !candidate.startsWith(boundary)) {
      throw new Error("项目路径不在当前 Project Library 中");
    }
    return candidate;
  }
}

function writeProjectMeta(db, project) {
  const entries = {
    project_id: project.id,
    library_id: project.libraryId,
    name: project.name,
    description: project.description,
    settings: JSON.stringify(project.settings),
    created_at: project.createdAt,
    updated_at: project.updatedAt,
    archived_at: JSON.stringify(project.archivedAt || null),
    schema_version: String(PROJECT_FORMAT_VERSION),
  };
  const statement = db.prepare(`
    INSERT INTO project_meta (key, value) VALUES (?, ?)
    ON CONFLICT(key) DO UPDATE SET value = excluded.value
  `);
  const transaction = db.transaction(() => {
    for (const [key, value] of Object.entries(entries)) statement.run(key, value);
  });
  transaction();
}

function readProjectSettings(db, fallback) {
  const row = db.prepare(
    "SELECT value FROM project_meta WHERE key = ?",
  ).get("settings");
  try {
    return normalizeProjectSettings(row ? JSON.parse(row.value) : {}, fallback);
  } catch {
    return normalizeProjectSettings({}, fallback);
  }
}

function readLastRecognitionDefaults(db) {
  // created_at is stable when users edit an old task, so merely viewing or
  // correcting history cannot change the defaults used by the next task.
  const rows = db.prepare(
    "SELECT data_json FROM tasks ORDER BY created_at DESC, rowid DESC",
  ).iterate();
  for (const row of rows) {
    try {
      const task = JSON.parse(row.data_json);
      if (!task?.result || !task.provider || !task.model) continue;
      return {
        providerId: String(task.provider),
        modelId: String(task.model),
        customPrompt: String(task.customPrompt || ""),
      };
    } catch {
      // Skip malformed legacy rows and continue to the next successful task.
    }
  }
  return null;
}

async function readOrCreateManifest(directory, defaults) {
  const filePath = join(directory, "library.json");
  try {
    return {
      ...defaults,
      ...(JSON.parse(await readFile(filePath, "utf8")) || {}),
    };
  } catch (error) {
    if (error?.code !== "ENOENT") throw error;
    const manifest = { ...defaults };
    await writeJsonAtomic(filePath, manifest);
    return manifest;
  }
}

async function writeProjectManifest(projectDir, value) {
  await writeJsonAtomic(join(projectDir, "project.json"), value);
}

async function writeJsonAtomic(filePath, value) {
  const tempPath = `${filePath}.${randomUUID()}.tmp`;
  await writeFile(tempPath, JSON.stringify(value, null, 2), {
    encoding: "utf8",
    mode: 0o600,
  });
  await rename(tempPath, filePath);
}

function copyRows(source, target, table, columns, transform = (row) => row) {
  if (!tableExists(source, table)) return 0;
  const rows = source.prepare(`SELECT ${columns.join(", ")} FROM ${table}`).all();
  const placeholders = columns.map(() => "?").join(", ");
  const insert = target.prepare(`
    INSERT OR IGNORE INTO ${table} (${columns.join(", ")})
    VALUES (${placeholders})
  `);
  let copied = 0;
  for (const sourceRow of rows) {
    const row = transform(sourceRow);
    copied += insert.run(...columns.map((column) => row[column])).changes;
  }
  return copied;
}

function tableExists(db, table) {
  return Boolean(db.prepare(
    "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ?",
  ).get(table));
}

async function copySnapshotDirectory(sourceDir, targetDir, projectId) {
  if (!(await exists(sourceDir))) return 0;
  await mkdir(targetDir, { recursive: true, mode: 0o700 });
  const entries = await readdir(sourceDir, { withFileTypes: true });
  let copied = 0;
  for (const entry of entries) {
    if (!entry.isFile() || !entry.name.endsWith(".json")) continue;
    const targetPath = join(targetDir, entry.name);
    if (await exists(targetPath)) continue;
    const raw = await readFile(join(sourceDir, entry.name), "utf8");
    let contents = raw;
    try {
      contents = JSON.stringify(addProjectId(JSON.parse(raw), projectId));
    } catch {
      // Keep malformed compatibility snapshots byte-for-byte for later repair.
    }
    await writeFile(targetPath, contents, { encoding: "utf8", mode: 0o600 });
    copied += 1;
  }
  return copied;
}

function addProjectId(value, projectId) {
  if (!value || typeof value !== "object" || Array.isArray(value)) return value;
  return value.projectId ? value : { ...value, projectId };
}

function addProjectIdJson(value, projectId) {
  try {
    // Legacy SQLite rows store JSON as text; rewrite that text so migrated
    // tasks and diagnostics carry the same ownership marker as snapshots.
    return JSON.stringify(addProjectId(JSON.parse(value), projectId));
  } catch {
    return value;
  }
}

function validateProjectName(value) {
  const name = String(value || "").trim();
  if (!name) throw new Error("项目名称不能为空");
  if (name.length > 80) throw new Error("项目名称不能超过 80 个字符");
  return name;
}

function cleanDescription(value) {
  return String(value || "").trim().slice(0, 500);
}

function validateProjectId(value) {
  const id = String(value || "");
  if (!/^project-[a-zA-Z0-9_-]+$/.test(id)) throw new Error("无效项目 ID");
  return id;
}

function idForProject(seed) {
  return `project-${createHash("sha256").update(seed).digest("hex").slice(0, 16)}`;
}

function libraryIdForPath(path) {
  return `library-${createHash("sha256").update(path).digest("hex").slice(0, 16)}`;
}

function missingProject() {
  const error = new Error("项目不存在");
  error.code = "ENOENT";
  return error;
}

function archivedProject() {
  const error = new Error("项目已归档");
  error.code = "PROJECT_ARCHIVED";
  return error;
}

function requirePathSeparator() {
  return process.platform === "win32" ? "\\" : "/";
}

function isStagedProjectDirectory(name) {
  return /^project-[a-zA-Z0-9_-]+\.deleting-[a-f0-9-]{36}$/i.test(name);
}

async function exists(path) {
  try {
    await access(path);
    return true;
  } catch {
    return false;
  }
}

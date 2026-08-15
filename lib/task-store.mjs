// Recognition task persistence.
//
// SQLite is the authoritative store for tasks. JSON snapshots are kept as a
// compatibility export so existing installations can migrate without losing
// data and older tooling can still inspect a task file if needed.
import { join } from "node:path";
import { createHash } from "node:crypto";
import {
  closeSlateDatabase,
  migrateJsonDirectory,
  openSlateDatabase,
  removeJsonSnapshot,
  writeJsonSnapshot,
} from "./sqlite-store.mjs";

const MAX_TASKS = 50;

export function createTaskStore(baseDir) {
  const tasksDir = join(baseDir, "tasks");
  const { db, dbPath } = openSlateDatabase(baseDir);
  const ready = migrateJsonDirectory({
    db,
    directoryPath: tasksDir,
    table: "tasks",
    timestampColumn: "updated_at",
    extraColumns: ["created_at"],
    parseRecord(value, fallbackId) {
      const id = validateId(value?.id || fallbackId);
      const data = { ...value, id };
      const createdAt = data.createdAt || new Date(0).toISOString();
      const updatedAt = data.updatedAt || createdAt;
      return {
        id,
        dataJson: JSON.stringify(data),
        timestamp: updatedAt,
        createdAt,
        extraValues: [createdAt],
      };
    },
  }).then((imported) => {
    if (imported) return imported;
    return 0;
  });

  const store = {
    tasksDir,
    dbPath,

    async saveTask(task) {
      await ready;
      const id = task.id ? validateId(task.id) : generateTaskId();
      const now = new Date().toISOString();
      const data = {
        ...task,
        id,
        updatedAt: now,
        createdAt: task.createdAt || now,
      };
      db.prepare(`
        INSERT INTO tasks (id, data_json, created_at, updated_at)
        VALUES (@id, @dataJson, @createdAt, @updatedAt)
        ON CONFLICT(id) DO UPDATE SET
          data_json = excluded.data_json,
          created_at = excluded.created_at,
          updated_at = excluded.updated_at
      `).run({
        id,
        dataJson: JSON.stringify(data),
        createdAt: data.createdAt,
        updatedAt: data.updatedAt,
      });
      await writeJsonSnapshot(tasksDir, id, data);
      await pruneTasks();
      return id;
    },

    async loadTask(id) {
      await ready;
      const taskId = validateId(id);
      const row = db.prepare("SELECT data_json FROM tasks WHERE id = ?").get(taskId);
      if (!row) {
        const error = new Error("任务不存在");
        error.code = "ENOENT";
        throw error;
      }
      return JSON.parse(row.data_json);
    },

    async updateTask(id, patch) {
      const taskId = validateId(id);
      const existing = await store.loadTask(taskId);
      return store.saveTask({
        ...existing,
        ...patch,
        id: taskId,
        createdAt: existing.createdAt,
      });
    },

    async listTasks() {
      await ready;
      const rows = db.prepare(`
        SELECT data_json FROM tasks ORDER BY updated_at DESC
      `).all();
      const tasks = [];
      for (const row of rows) {
        try {
          const data = JSON.parse(row.data_json);
          tasks.push({
            id: data.id,
            filename: data.filename,
            provider: data.provider,
            model: data.model,
            pageCount: data.pageCount,
            scenarioId: data.scenarioId || null,
            recordCount:
              data.editedRecords?.length ?? data.result?.records?.length ?? 0,
            status: data.status || "unknown",
            createdAt: data.createdAt,
            updatedAt: data.updatedAt,
          });
        } catch {
          // Keep listing healthy tasks when a legacy row is malformed.
        }
      }
      return tasks;
    },

    async deleteTask(id) {
      await ready;
      const taskId = validateId(id);
      const result = db.prepare("DELETE FROM tasks WHERE id = ?").run(taskId);
      if (!result.changes) {
        const error = new Error("任务不存在");
        error.code = "ENOENT";
        throw error;
      }
      await removeJsonSnapshot(tasksDir, taskId);
    },

    async close() {
      await ready;
      closeSlateDatabase(db);
    },
  };

  async function pruneTasks() {
    const rows = db.prepare(`
      SELECT id FROM tasks
      ORDER BY updated_at DESC
      LIMIT -1 OFFSET ?
    `).all(MAX_TASKS);
    if (!rows.length) return;
    const remove = db.transaction((ids) => {
      const statement = db.prepare("DELETE FROM tasks WHERE id = ?");
      for (const id of ids) statement.run(id);
    });
    remove(rows.map((row) => row.id));
    await Promise.all(rows.map((row) => removeJsonSnapshot(tasksDir, row.id)));
  }

  return store;
}

export function createTask() {
  return {
    id: null,
    status: "created",
    filename: null,
    fileType: null,
    fileSize: 0,
    pageCount: 0,
    imageDataGroups: null,
    resolveCsvBase64: null,
    resolveCsvFilename: null,
    resolveCsvTable: null,
    resolveCsvEdits: null,
    slateMetadata: null,
    slateWarnings: null,
    slateDirectoryName: null,
    scenarioId: null,
    scenarioFingerprint: null,
    provider: null,
    model: null,
    customPrompt: null,
    accuracyMode: null,
    result: null,
    usage: null,
    durationMs: 0,
    ocrSummary: null,
    diagnosticSessionId: null,
    editedRecords: null,
    createdAt: null,
    updatedAt: null,
  };
}

function generateTaskId() {
  const hash = createHash("sha256")
    .update(`${Date.now()}-${Math.random()}`)
    .digest("hex");
  return hash.slice(0, 12);
}

function validateId(id) {
  const value = String(id || "");
  if (!/^[a-zA-Z0-9_-]+$/.test(value)) {
    throw new Error("无效任务 ID");
  }
  return value;
}

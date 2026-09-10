// Recognition task persistence.
//
// SQLite is the authoritative store for tasks. Electron binds this store to a
// project's project.sqlite, so opening a task store is itself a project
// boundary; JSON snapshots remain a compatibility export for migration.
//
// 打开项目热路径的两项优化落在本文件：
// 1. options.db 注入共享句柄（项目运行时每项目只开一个连接），store 自身不再
//    每次自开连接、重复执行 DDL；注入时 close() 不关闭不属于自己的句柄。
// 2. JSON 快照迁移带 app_meta 完成标记 + list-tasks 读取 summary_json 摘要列，
//    不再每次全量重读快照或解析完整任务 blob。
import { join } from "node:path";
import { createHash } from "node:crypto";
import {
  closeSlateDatabase,
  migrateJsonDirectory,
  openSlateDatabase,
  readAppMetaMarker,
  removeJsonSnapshot,
  SQLITE_FILENAMES,
  writeAppMetaMarker,
  writeJsonSnapshot,
} from "./sqlite-store.mjs";
import {
  clearRecognitionDefaults,
  recordRecognitionDefaults,
} from "./recognition-defaults.mjs";

// 一次性迁移的完成标记键；写入后目录里新出现的 JSON 不再自动导入，
// SQLite 是唯一权威存储，双写保持快照与行内容同步。
const MIGRATION_MARKER_KEY = "json_migration_tasks_v1";

export function createTaskStore(baseDir, options = {}) {
  const tasksDir = join(baseDir, "tasks");
  // 注入共享句柄时本 store 不拥有连接（owned=false），close() 只等待迁移完成；
  // dbPath 仍按打开规则推导，保持 store.dbPath 对调用方可读。
  const owned = !options.db;
  const { db, dbPath } = owned
    ? openSlateDatabase(baseDir, { kind: "project", filename: options.filename })
    : {
        db: options.db,
        dbPath: join(baseDir, options.filename || SQLITE_FILENAMES.legacy),
      };
  const ready = (async () => {
    // 完成标记命中直接返回，省去 readdir + 全量 JSON.parse 的重复成本。
    if (readAppMetaMarker(db, MIGRATION_MARKER_KEY)) return 0;
    const imported = await migrateJsonDirectory({
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
    });
    writeAppMetaMarker(db, MIGRATION_MARKER_KEY, {
      imported,
      markedAt: new Date().toISOString(),
    });
    return imported;
  })();

  // list-tasks 的摘要投影；summary_json 的内容与该函数逐字段一致，
  // 读取端据此避免解析完整 blob（不额外加版本字段，保持既有列表契约）。
  function taskSummaryOf(data) {
    return {
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
    };
  }

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
      const upsert = db.prepare(`
        INSERT INTO tasks (id, data_json, summary_json, created_at, updated_at)
        VALUES (@id, @dataJson, @summaryJson, @createdAt, @updatedAt)
        ON CONFLICT(id) DO UPDATE SET
          data_json = excluded.data_json,
          summary_json = excluded.summary_json,
          created_at = excluded.created_at,
          updated_at = excluded.updated_at
      `);
      // 行写入与识别默认值键的增量维护必须在同一事务：读取端 O(1) 命中
      // 依赖键与行内容一致，两个写入之间不能有可观察的中间态。
      const rowidStatement = db.prepare(
        "SELECT rowid AS rid FROM tasks WHERE id = ?",
      );
      const transaction = db.transaction((record) => {
        // 注意：ON CONFLICT DO UPDATE 更新已有行时 lastInsertRowid 仍停留
        // 在上一次全新插入的 rowid，并不指向被更新行；因此按主键回查真实
        // rowid，保证默认值平局比较与全量扫描排序一致。
        upsert.run(record.params);
        const row = rowidStatement.get(record.params.id);
        recordRecognitionDefaults(db, record.data, Number(row?.rid ?? 0));
      });
      transaction({
        data,
        params: {
          id,
          dataJson: JSON.stringify(data),
          // 摘要与数据同事务落库；存量/迁移产生的 NULL 行由 listTasks 回填。
          summaryJson: JSON.stringify(taskSummaryOf(data)),
          createdAt: data.createdAt,
          updatedAt: data.updatedAt,
        },
      });
      await writeJsonSnapshot(tasksDir, id, data);
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
        SELECT id, summary_json, data_json FROM tasks ORDER BY updated_at DESC
      `).all();
      const tasks = [];
      const backfill = [];
      for (const row of rows) {
        // 优先读保存时预计算的摘要；NULL（存量行/迁移行）或损坏时解析完整
        // blob 重建摘要，循环结束后单事务回填，保证解析成本只发生一次。
        // 展开到空摘要基对象上：JSON 序列化会丢掉 undefined 键，补齐基键后
        // 输出与旧实现（恒为 10 个键）逐键一致。
        if (row.summary_json) {
          try {
            tasks.push({ ...taskSummaryOf({}), ...JSON.parse(row.summary_json) });
            continue;
          } catch {
            // 摘要损坏时回退完整解析并重建。
          }
        }
        try {
          const data = JSON.parse(row.data_json);
          const summary = taskSummaryOf(data);
          tasks.push(summary);
          backfill.push({ id: row.id, summaryJson: JSON.stringify(summary) });
        } catch {
          // Keep listing healthy tasks when a legacy row is malformed.
        }
      }
      if (backfill.length) {
        const update = db.prepare(
          "UPDATE tasks SET summary_json = ? WHERE id = ?",
        );
        db.transaction((items) => {
          for (const item of items) update.run(item.summaryJson, item.id);
        })(backfill);
      }
      return tasks;
    },

    async deleteTask(id) {
      await ready;
      const taskId = validateId(id);
      const transaction = db.transaction((target) => {
        const result = db.prepare("DELETE FROM tasks WHERE id = ?").run(target);
        if (!result.changes) {
          const error = new Error("任务不存在");
          error.code = "ENOENT";
          throw error;
        }
        // 被删任务是默认值键的源任务时同步删键；下一次读取回退扫描。
        clearRecognitionDefaults(db, target);
      });
      transaction(taskId);
      await removeJsonSnapshot(tasksDir, taskId);
    },

    async close() {
      await ready;
      // 注入句柄的 store 不拥有连接；关闭动作由共享句柄的持有者执行一次。
      if (owned) closeSlateDatabase(db);
    },
  };

  return store;
}

export function createTask() {
  return {
    id: null,
    // Electron fills these fields at recognition time so a restored task keeps
    // its owning project and the exact output contract used for that result.
    projectId: null,
    projectSettingsSnapshot: null,
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

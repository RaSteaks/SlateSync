// Recognition task persistence.
//
// Stores each recognition job (source metadata, prepared images, result, user
// edits) as JSON under <data>/tasks with atomic writes, and prunes to the most
// recent MAX_TASKS jobs.
import { readFile, writeFile, mkdir, readdir, unlink, rename } from "node:fs/promises";
import { join } from "node:path";
import { createHash } from "node:crypto";

const MAX_TASKS = 50;

// A "task" represents one slate recognition job, including:
// - Source file metadata (filename, type, size)
// - Prepared image data groups (Base64)
// - Resolve CSV content (raw bytes as Base64)
// - OCR evidence and AI exchanges (from diagnostics capture)
// - Recognition result (records, warnings)
// - User edits (field corrections, row additions/deletions)
// - Workflow state (current step, selected provider/model)

export function createTaskStore(baseDir) {
  const tasksDir = join(baseDir, "tasks");

  const store = {
    tasksDir,

    async saveTask(task) {
      await mkdir(tasksDir, { recursive: true, mode: 0o700 });
      const id = task.id ? validateId(task.id) : generateTaskId();
      const now = new Date().toISOString();
      const data = {
        ...task,
        id,
        updatedAt: now,
        createdAt: task.createdAt || now,
      };
      const filePath = join(tasksDir, `${id}.json`);
      const tempPath = `${filePath}.${generateTaskId()}.tmp`;
      await writeFile(tempPath, JSON.stringify(data), {
        encoding: "utf8",
        mode: 0o600,
      });
      await rename(tempPath, filePath);
      await pruneTasks(tasksDir);
      return id;
    },

    async loadTask(id) {
      const filePath = join(tasksDir, `${validateId(id)}.json`);
      const raw = await readFile(filePath, "utf8");
      return JSON.parse(raw);
    },

    async updateTask(id, patch) {
      const taskId = validateId(id);
      const existing = await store.loadTask(taskId);
      await store.saveTask({
        ...existing,
        ...patch,
        id: taskId,
        createdAt: existing.createdAt,
      });
      return taskId;
    },

    async listTasks() {
      try {
        const files = await readdir(tasksDir);
        const tasks = [];
        for (const file of files.filter((f) => f.endsWith(".json"))) {
          try {
            const raw = await readFile(join(tasksDir, file), "utf8");
            const data = JSON.parse(raw);
            tasks.push({
              id: data.id,
              filename: data.filename,
              provider: data.provider,
              model: data.model,
              pageCount: data.pageCount,
              recordCount:
                data.editedRecords?.length ?? data.result?.records?.length ?? 0,
              status: data.status || "unknown",
              createdAt: data.createdAt,
              updatedAt: data.updatedAt,
            });
          } catch {
            // skip corrupted files
          }
        }
        return tasks.sort(
          (a, b) => (b.updatedAt || "").localeCompare(a.updatedAt || ""),
        );
      } catch {
        return [];
      }
    },

    async deleteTask(id) {
      const filePath = join(tasksDir, `${validateId(id)}.json`);
      await unlink(filePath);
    },
  };

  return store;
}

export function createTask() {
  return {
    id: null,
    status: "created",
    // Source file
    filename: null,
    fileType: null,
    fileSize: 0,
    pageCount: 0,
    // Prepared images (Base64 data URLs, one group per page)
    imageDataGroups: null,
    // Resolve CSV (raw bytes as base64)
    resolveCsvBase64: null,
    resolveCsvFilename: null,
    // Parsed Resolve CSV preview plus renderer-side manual cell overrides.
    resolveCsvTable: null,
    resolveCsvEdits: null,
    // Slate directory scan results
    slateMetadata: null,
    slateWarnings: null,
    slateDirectoryName: null,
    // Recognition config
    provider: null,
    model: null,
    customPrompt: null,
    accuracyMode: null,
    // Recognition result
    result: null,
    usage: null,
    durationMs: 0,
    ocrSummary: null,
    // Diagnostic session reference
    diagnosticSessionId: null,
    // User edits (applied on top of result.records)
    editedRecords: null,
    // Timestamps
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

async function pruneTasks(dir) {
  try {
    const files = await readdir(dir);
    const jsonFiles = files.filter((f) => f.endsWith(".json"));
    if (jsonFiles.length <= MAX_TASKS) return;

    const withStats = await Promise.all(
      jsonFiles.map(async (file) => {
        const filePath = join(dir, file);
        const raw = await readFile(filePath, "utf8").catch(() => null);
        const updatedAt = raw ? JSON.parse(raw)?.updatedAt || "" : "";
        return { file, filePath, updatedAt };
      }),
    );
    withStats.sort((a, b) =>
      (a.updatedAt || "").localeCompare(b.updatedAt || ""),
    );

    const toDelete = withStats.slice(0, withStats.length - MAX_TASKS);
    for (const { filePath } of toDelete) {
      await unlink(filePath).catch(() => {});
    }
  } catch {
    // pruning is best-effort
  }
}

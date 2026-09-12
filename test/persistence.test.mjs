import assert from "node:assert/strict";
import { mkdir, mkdtemp, rm, stat, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";
import { createDiagnosticsStore } from "../lib/diagnostics.mjs";
import {
  closeSlateDatabase,
  openSlateDatabase,
  SQLITE_FILENAMES,
} from "../lib/sqlite-store.mjs";
import { createTaskStore } from "../lib/task-store.mjs";

test("task updates preserve recognition data and use owner-only files", async () => {
  const dataDir = await mkdtemp(join(tmpdir(), "slatesync-tasks-"));
  try {
    const store = createTaskStore(dataDir);
    const id = await store.saveTask({
      filename: "day-01.pdf",
      provider: "openai",
      model: "openai/gpt-5.6-terra",
      status: "completed",
      result: { records: [{ id: "one" }, { id: "two" }] },
    });

    await store.updateTask(id, {
      status: "edited",
      editedRecords: [{ id: "one", scene: "001" }],
    });

    const task = await store.loadTask(id);
    assert.equal(task.filename, "day-01.pdf");
    assert.equal(task.provider, "openai");
    assert.equal(task.result.records.length, 2);
    assert.deepEqual(task.editedRecords, [{ id: "one", scene: "001" }]);
    assert.equal((await store.listTasks())[0].recordCount, 1);

    const fileMode = (await stat(join(store.tasksDir, `${id}.json`))).mode & 0o777;
    assert.equal(fileMode, 0o600);
    await assert.rejects(() => store.loadTask("../outside"), /无效任务 ID/);
  } finally {
    await rm(dataDir, { recursive: true, force: true });
  }
});

test("task snapshots round-trip recognition quality and review provenance", async () => {
  const dataDir = await mkdtemp(join(tmpdir(), "slatesync-quality-task-"));
  try {
    const store = createTaskStore(dataDir);
    const record = {
      id: "record-quality",
      targetId: "target-quality",
      sourcePage: 1,
      cardNumber: "A001",
      videoCode: "C001",
      scene: "203",
      shot: "01",
      take: "01",
      takeStatus: "过",
      description: "近景",
      comments: null,
      shotSize: "CU",
      cameraPosition: "A",
      confidence: "high",
      reviewRequiredFields: ["scene"],
      quality: {
        fields: {
          scene: {
            field: "scene",
            originalValue: "二〇三",
            normalizedValue: "203",
            changed: true,
            confidence: "high",
            reviewRequired: true,
            warnings: [{
              code: "chinese-numeral-converted",
              field: "scene",
              message: "已将中文数字归一化为阿拉伯数字，请人工确认",
              originalValue: "二〇三",
              normalizedValue: "203",
            }],
          },
        },
      },
    };
    const id = await store.saveTask({
      id: "quality-task",
      filename: "quality.png",
      status: "completed",
      result: { sheetTitle: "Quality", records: [record], warnings: [] },
      editedRecords: [record],
    });
    const loaded = await store.loadTask(id);
    assert.deepEqual(loaded.result.records, [record]);
    assert.deepEqual(loaded.editedRecords, [record]);
    await store.close();
  } finally {
    await rm(dataDir, { recursive: true, force: true });
  }
});

test("diagnostic sessions use owner-only files and validated IDs", async () => {
  const dataDir = await mkdtemp(join(tmpdir(), "slatesync-diagnostics-"));
  try {
    const store = createDiagnosticsStore(dataDir);
    const id = await store.saveSession({
      id: "session-123",
      filename: "day-01.pdf",
      result: { records: [] },
    });
    const sessionsDir = await store.getSessionDir();
    const fileMode = (await stat(join(sessionsDir, `${id}.json`))).mode & 0o777;
    assert.equal(fileMode, 0o600);
    assert.equal((await store.loadSession(id)).filename, "day-01.pdf");
    await assert.rejects(
      () => store.loadSession("../outside"),
      /无效诊断会话 ID/,
    );
  } finally {
    await rm(dataDir, { recursive: true, force: true });
  }
});

test("listTasks rebuilds and backfills summary_json cleared by another connection", async () => {
  const dataDir = await mkdtemp(join(tmpdir(), "slatesync-summary-backfill-"));
  const store = createTaskStore(dataDir, { filename: SQLITE_FILENAMES.project });
  let inspector;
  try {
    await store.saveTask({
      id: "task-1",
      filename: "day-01.png",
      provider: "openai",
      model: "gpt",
      status: "completed",
      pageCount: 2,
      result: { records: [{ id: "one" }] },
    });
    await store.saveTask({
      id: "task-2",
      filename: "day-02.png",
      status: "created",
    });

    // 模拟存量库/迁移行：第二条连接清空 summary_json。
    inspector = openSlateDatabase(dataDir, {
      kind: "project",
      filename: SQLITE_FILENAMES.project,
    });
    inspector.db.prepare("UPDATE tasks SET summary_json = NULL").run();
    closeSlateDatabase(inspector.db);
    inspector = null;

    // 读取端解析完整 blob 重建摘要，并在单事务内回填列。
    // 两条任务在同一毫秒内保存时 updated_at 平序，排序比较不依赖行序。
    const tasks = await store.listTasks();
    assert.deepEqual(tasks.map((task) => task.id).sort(), ["task-1", "task-2"]);
    assert.equal(tasks.find((task) => task.id === "task-1").recordCount, 1);
    assert.equal(tasks.find((task) => task.id === "task-2").status, "created");
    inspector = openSlateDatabase(dataDir, {
      kind: "project",
      filename: SQLITE_FILENAMES.project,
    });
    const backfilled = inspector.db.prepare(
      "SELECT id, summary_json FROM tasks ORDER BY updated_at DESC",
    ).all();
    assert.equal(backfilled.every((row) => row.summary_json), true);
    // 每行回填内容与重建出的摘要一致（JSON 序列化两侧丢弃 undefined 键后
    // 按 id 对齐比较，不依赖行序）。
    for (const row of backfilled) {
      const expected = tasks.find((task) => task.id === row.id);
      assert.deepEqual(
        JSON.parse(row.summary_json),
        JSON.parse(JSON.stringify(expected)),
      );
    }
  } finally {
    closeSlateDatabase(inspector?.db);
    await store.close();
    await rm(dataDir, { recursive: true, force: true });
  }
});

test("completed JSON snapshot migration no longer re-imports later manual snapshots", async () => {
  const dataDir = await mkdtemp(join(tmpdir(), "slatesync-migration-marker-"));
  try {
    // 首次打开前目录里已有历史快照：迁移导入并写完成标记。
    await mkdir(join(dataDir, "tasks"), { recursive: true });
    await writeFile(
      join(dataDir, "tasks", "task-legacy.json"),
      JSON.stringify({
        id: "task-legacy",
        filename: "legacy.png",
        status: "completed",
        createdAt: "2026-01-01T00:00:00.000Z",
        updatedAt: "2026-01-01T00:00:00.000Z",
      }),
    );
    let store = createTaskStore(dataDir, { filename: SQLITE_FILENAMES.project });
    assert.deepEqual(
      (await store.listTasks()).map((task) => task.id),
      ["task-legacy"],
    );
    await store.close();

    // 标记写入后手动放入的新快照不再自动导入（SQLite 是唯一权威存储）。
    await writeFile(
      join(dataDir, "tasks", "task-manual.json"),
      JSON.stringify({
        id: "task-manual",
        filename: "manual.png",
        status: "completed",
        createdAt: "2026-01-02T00:00:00.000Z",
        updatedAt: "2026-01-02T00:00:00.000Z",
      }),
    );
    store = createTaskStore(dataDir, { filename: SQLITE_FILENAMES.project });
    assert.deepEqual(
      (await store.listTasks()).map((task) => task.id),
      ["task-legacy"],
    );
    await assert.rejects(() => store.loadTask("task-manual"), /任务不存在/);
  } finally {
    await rm(dataDir, { recursive: true, force: true });
  }
});

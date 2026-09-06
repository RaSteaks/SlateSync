// 识别默认值 O(1) 读取层的验收测试。
//
// 覆盖方案阶段 2 的关键语义：键回写、不合格任务不写键、created_at/rowid
// 平局规则、源任务编辑成不合格后清键、损坏值回退扫描、按需失效。
// 事务路径（saveTask/updateTask/deleteTask 的增量维护）走真实 task-store，
// project_meta 的原始状态用第二条只读检查连接观察。
import assert from "node:assert/strict";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";

import {
  clearRecognitionDefaults,
  invalidateRecognitionDefaults,
  readLastRecognitionDefaults,
  recordRecognitionDefaults,
} from "../lib/recognition-defaults.mjs";
import {
  closeSlateDatabase,
  openSlateDatabase,
  SQLITE_FILENAMES,
} from "../lib/sqlite-store.mjs";
import { createTaskStore } from "../lib/task-store.mjs";

// openSlateDatabase 返回 { db, dbPath } 包装；这里统一取内层连接。
function openProjectDb(dataDir) {
  return openSlateDatabase(dataDir, {
    kind: "project",
    filename: SQLITE_FILENAMES.project,
  }).db;
}

function readRawDefaults(db) {
  const row = db.prepare(
    "SELECT value FROM project_meta WHERE key = 'last_recognition_defaults'",
  ).get();
  return row ? JSON.parse(row.value) : null;
}

// 通过独立的检查连接读取键对应的公开摘要，模拟"另一个读取方"。
function readDefaultsViaStore(dataDir) {
  const db = openProjectDb(dataDir);
  try {
    return readLastRecognitionDefaults(db);
  } finally {
    closeSlateDatabase(db);
  }
}

test("first read scans, answers, and writes the defaults key back", () => {
  const dataDir = mkdtempSync(join(tmpdir(), "slatesync-defaults-backfill-"));
  const db = openProjectDb(dataDir);
  let inspector;
  try {
    db.prepare(`
      INSERT INTO tasks (id, data_json, created_at, updated_at) VALUES (?, ?, ?, ?)
    `).run(
      "task-1",
      JSON.stringify({
        id: "task-1",
        createdAt: "2026-01-02T00:00:00.000Z",
        provider: "openai",
        model: "gpt",
        customPrompt: "keep",
        result: { records: [] },
      }),
      "2026-01-02T00:00:00.000Z",
      "2026-01-02T00:00:00.000Z",
    );
    assert.equal(readRawDefaults(db), null);
    assert.deepEqual(readLastRecognitionDefaults(db), {
      providerId: "openai",
      modelId: "gpt",
      customPrompt: "keep",
    });
    // 回写包含平局比较所需的 source 信息，下一次读取不再扫描。
    const stored = readRawDefaults(db);
    assert.equal(stored.sourceTaskId, "task-1");
    assert.equal(stored.sourceCreatedAt, "2026-01-02T00:00:00.000Z");
    assert.equal(typeof stored.sourceRowid, "number");
    // 第二个连接（模拟后续读取方）直接命中同一键。
    inspector = openProjectDb(dataDir);
    assert.deepEqual(readLastRecognitionDefaults(inspector), {
      providerId: "openai",
      modelId: "gpt",
      customPrompt: "keep",
    });
  } finally {
    closeSlateDatabase(inspector);
    closeSlateDatabase(db);
    rmSync(dataDir, { recursive: true, force: true });
  }
});

test("tasks without a successful result never become defaults", () => {
  const dataDir = mkdtempSync(join(tmpdir(), "slatesync-defaults-unqualified-"));
  const db = openProjectDb(dataDir);
  try {
    db.prepare(`
      INSERT INTO tasks (id, data_json, created_at, updated_at) VALUES (?, ?, ?, ?)
    `).run(
      "task-failed",
      JSON.stringify({
        id: "task-failed",
        createdAt: "2026-01-03T00:00:00.000Z",
        provider: "openai",
        model: "gpt",
        result: null,
      }),
      "2026-01-03T00:00:00.000Z",
      "2026-01-03T00:00:00.000Z",
    );
    assert.equal(readLastRecognitionDefaults(db), null);
    assert.equal(readRawDefaults(db), null);
  } finally {
    closeSlateDatabase(db);
    rmSync(dataDir, { recursive: true, force: true });
  }
});

test("equal created_at resolves by rowid: newer rows win and older edits do not take over", async () => {
  const dataDir = mkdtempSync(join(tmpdir(), "slatesync-defaults-tiebreak-"));
  const store = createTaskStore(dataDir, { filename: SQLITE_FILENAMES.project });
  try {
    const sameTime = "2026-01-02T00:00:00.000Z";
    await store.saveTask({
      id: "task-older-rowid",
      createdAt: sameTime,
      provider: "openai",
      model: "model-a",
      customPrompt: "a",
      result: { records: [] },
    });
    await store.saveTask({
      id: "task-newer-rowid",
      createdAt: sameTime,
      provider: "openai",
      model: "model-b",
      customPrompt: "b",
      result: { records: [] },
    });
    // 后写入的行 rowid 更大：镜像扫描排序，平局时它成为默认值。
    assert.deepEqual(readDefaultsViaStore(dataDir), {
      providerId: "openai",
      modelId: "model-b",
      customPrompt: "b",
    });

    // 编辑 rowid 更小的同 created_at 任务：不得接管键（upsert 更新已有行
    // 时的真实 rowid 回查必须生效）。
    await store.updateTask("task-older-rowid", { customPrompt: "a-edited" });
    assert.deepEqual(readDefaultsViaStore(dataDir), {
      providerId: "openai",
      modelId: "model-b",
      customPrompt: "b",
    });

    // 重新保存键的源任务（同 createdAt、同 rowid）必须刷新键内容。
    await store.updateTask("task-newer-rowid", { customPrompt: "b-edited" });
    assert.deepEqual(readDefaultsViaStore(dataDir), {
      providerId: "openai",
      modelId: "model-b",
      customPrompt: "b-edited",
    });
  } finally {
    await store.close();
    rmSync(dataDir, { recursive: true, force: true });
  }
});

test("editing the source task until it no longer qualifies clears the key and rescans", async () => {
  const dataDir = mkdtempSync(join(tmpdir(), "slatesync-defaults-unqualified-source-"));
  const store = createTaskStore(dataDir, { filename: SQLITE_FILENAMES.project });
  try {
    await store.saveTask({
      id: "task-old-success",
      createdAt: "2026-01-01T00:00:00.000Z",
      provider: "openai",
      model: "model-old",
      customPrompt: "old",
      result: { records: [] },
    });
    await store.saveTask({
      id: "task-new-success",
      createdAt: "2026-01-02T00:00:00.000Z",
      provider: "dashscope",
      model: "model-new",
      customPrompt: "new",
      result: { records: [] },
    });
    assert.deepEqual(readDefaultsViaStore(dataDir).modelId, "model-new");

    // 源任务被编辑成无 result：删除键，回退扫描选中下一个成功任务。
    await store.updateTask("task-new-success", { result: null });
    assert.deepEqual(readDefaultsViaStore(dataDir), {
      providerId: "openai",
      modelId: "model-old",
      customPrompt: "old",
    });
  } finally {
    await store.close();
    rmSync(dataDir, { recursive: true, force: true });
  }
});

test("deleting a non-source task keeps the key; deleting the source falls back by rescan", async () => {
  const dataDir = mkdtempSync(join(tmpdir(), "slatesync-defaults-delete-"));
  const store = createTaskStore(dataDir, { filename: SQLITE_FILENAMES.project });
  let db;
  try {
    await store.saveTask({
      id: "task-old-success",
      createdAt: "2026-01-01T00:00:00.000Z",
      provider: "openai",
      model: "model-old",
      customPrompt: "old",
      result: { records: [] },
    });
    await store.saveTask({
      id: "task-middle-success",
      createdAt: "2026-01-01T12:00:00.000Z",
      provider: "openai",
      model: "model-middle",
      customPrompt: "middle",
      result: { records: [] },
    });
    await store.saveTask({
      id: "task-current-source",
      createdAt: "2026-01-02T00:00:00.000Z",
      provider: "openai",
      model: "model-current",
      customPrompt: "current",
      result: { records: [] },
    });
    // 删除非源任务：键保持，读取端 O(1) 命中不受影响。
    await store.deleteTask("task-middle-success");
    db = openProjectDb(dataDir);
    assert.equal(readRawDefaults(db).sourceTaskId, "task-current-source");
    closeSlateDatabase(db);
    db = null;

    // 删除源任务：键被清掉，重扫后按 created_at 选中剩下的成功任务
    // （middle 已在上面被删除，剩下的只有 old）。
    await store.deleteTask("task-current-source");
    assert.deepEqual(readDefaultsViaStore(dataDir), {
      providerId: "openai",
      modelId: "model-old",
      customPrompt: "old",
    });
  } finally {
    closeSlateDatabase(db);
    await store.close();
    rmSync(dataDir, { recursive: true, force: true });
  }
});

test("a corrupt meta value falls back to a scan and is rewritten", () => {
  const dataDir = mkdtempSync(join(tmpdir(), "slatesync-defaults-corrupt-"));
  const db = openProjectDb(dataDir);
  try {
    db.prepare(`
      INSERT INTO tasks (id, data_json, created_at, updated_at) VALUES (?, ?, ?, ?)
    `).run(
      "task-1",
      JSON.stringify({
        id: "task-1",
        createdAt: "2026-01-02T00:00:00.000Z",
        provider: "openai",
        model: "gpt",
        result: { records: [] },
      }),
      "2026-01-02T00:00:00.000Z",
      "2026-01-02T00:00:00.000Z",
    );
    db.prepare(
      "INSERT INTO project_meta (key, value) VALUES ('last_recognition_defaults', '{not json')",
    ).run();
    assert.deepEqual(readLastRecognitionDefaults(db), {
      providerId: "openai",
      modelId: "gpt",
      customPrompt: "",
    });
    // 回退扫描后键被合法 JSON 覆盖。
    assert.equal(readRawDefaults(db).sourceTaskId, "task-1");
  } finally {
    closeSlateDatabase(db);
    rmSync(dataDir, { recursive: true, force: true });
  }
});

test("record and clear helpers guard against unrelated tasks", () => {
  const dataDir = mkdtempSync(join(tmpdir(), "slatesync-defaults-helpers-"));
  const db = openProjectDb(dataDir);
  try {
    // 无键时 clear 是空操作。
    clearRecognitionDefaults(db, "task-1");
    assert.equal(readRawDefaults(db), null);
    recordRecognitionDefaults(db, {
      id: "task-1",
      createdAt: "2026-01-01T00:00:00.000Z",
      provider: "openai",
      model: "gpt",
      result: { records: [] },
    }, 1);
    assert.equal(readRawDefaults(db).sourceTaskId, "task-1");
    // 非 source 的 clear 不删键。
    clearRecognitionDefaults(db, "task-other");
    assert.equal(readRawDefaults(db).sourceTaskId, "task-1");
    // 失效删除无条件清键，供批量导入路径调用。
    invalidateRecognitionDefaults(db);
    assert.equal(readRawDefaults(db), null);
  } finally {
    closeSlateDatabase(db);
    rmSync(dataDir, { recursive: true, force: true });
  }
});

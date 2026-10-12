import assert from "node:assert/strict";
import { mkdtemp, rm, stat } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";
import { createDiagnosticsStore } from "../lib/diagnostics.mjs";
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

test("listTasks projects summaries in SQL and honours limit and offset", async () => {
  const dataDir = await mkdtemp(join(tmpdir(), "slatesync-tasks-"));
  try {
    const store = createTaskStore(dataDir);
    const first = await store.saveTask({
      filename: "day-01.pdf",
      provider: "openai",
      model: "openai/gpt-5.6-terra",
      status: "completed",
      result: { records: [{ id: "one" }, { id: "two" }, { id: "three" }] },
    });
    await delay(10);
    const second = await store.saveTask({
      filename: "day-02.pdf",
      provider: "openrouter",
      model: "openai/gpt-5.6-luna",
      status: "edited",
      editedRecords: [{ id: "one" }],
    });

    const all = await store.listTasks();
    assert.deepEqual(all.map((task) => task.id), [second, first]);
    assert.equal(all[0].recordCount, 1);
    assert.equal(all[0].status, "edited");
    assert.equal(all[0].filename, "day-02.pdf");
    assert.equal(all[1].recordCount, 3);
    assert.equal(all[1].model, "openai/gpt-5.6-terra");
    assert.ok(all[1].createdAt);

    const limited = await store.listTasks({ limit: 1 });
    assert.deepEqual(limited.map((task) => task.id), [second]);

    const offset = await store.listTasks({ limit: 1, offset: 1 });
    assert.deepEqual(offset.map((task) => task.id), [first]);
  } finally {
    await rm(dataDir, { recursive: true, force: true });
  }
});

test("SLATESYNC_JSON_SNAPSHOT=off skips the JSON compatibility export", async () => {
  const dataDir = await mkdtemp(join(tmpdir(), "slatesync-tasks-"));
  const previous = process.env.SLATESYNC_JSON_SNAPSHOT;
  process.env.SLATESYNC_JSON_SNAPSHOT = "off";
  try {
    const store = createTaskStore(dataDir);
    const id = await store.saveTask({
      filename: "day-01.pdf",
      status: "completed",
    });
    await assert.rejects(
      () => stat(join(store.tasksDir, `${id}.json`)),
      /ENOENT/,
    );
    assert.equal((await store.loadTask(id)).filename, "day-01.pdf");
  } finally {
    if (previous === undefined) delete process.env.SLATESYNC_JSON_SNAPSHOT;
    else process.env.SLATESYNC_JSON_SNAPSHOT = previous;
    await rm(dataDir, { recursive: true, force: true });
  }
});

function delay(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}


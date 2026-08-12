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

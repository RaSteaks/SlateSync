// 项目运行时（每项目单一共享 SQLite 连接）的验收测试。
//
// 覆盖方案阶段 1 的关键行为：两次 get 复用同一上下文与共享句柄、每请求
// 元数据刷新、closeProject 只关一次共享句柄且可重建、归档读写分离、
// defaults 端到端流转。
import assert from "node:assert/strict";
import { mkdir, mkdtemp, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";

import {
  createProjectLibrary,
  DEFAULT_PROJECT_ID,
} from "../lib/project-library.mjs";
import { createProjectRuntime } from "../lib/project-runtime.mjs";

test("first project summary includes migrated tasks even after an empty defaults read", async () => {
  const root = await mkdtemp(join(tmpdir(), "slatesync-runtime-migrated-summary-"));
  const library = createProjectLibrary(join(root, "library"));
  const runtime = createProjectRuntime(library);
  try {
    const project = await library.createProject({ name: "legacy snapshots" });
    assert.equal(project.lastRecognitionDefaults, null);
    const tasksDir = join(project.directoryPath, "tasks");
    await mkdir(tasksDir, { recursive: true });
    await writeFile(join(tasksDir, "legacy.json"), JSON.stringify({
      id: "legacy", provider: "openai", model: "legacy-model", result: { records: [] },
      createdAt: "2026-01-01T00:00:00.000Z", updatedAt: "2026-01-02T00:00:00.000Z",
    }));
    // The very first response must agree with its history, not just a later refresh.
    const context = await runtime.get(project.id);
    assert.equal(context.project.taskCount, 1);
    assert.equal(context.project.latestTaskAt, "2026-01-02T00:00:00.000Z");
    assert.equal(context.project.lastRecognitionDefaults.modelId, "legacy-model");
    assert.equal((await context.taskStore.listTasks()).length, 1);
  } finally {
    await runtime.close(); await library.close(); await rm(root, { recursive: true, force: true });
  }
});

test("repeated gets reuse one shared context and refresh project metadata per request", async () => {
  const tempRoot = await mkdtemp(join(tmpdir(), "slatesync-runtime-shared-"));
  const library = createProjectLibrary(join(tempRoot, "library"));
  const runtime = createProjectRuntime(library);

  try {
    const project = await library.createProject({ name: "共享连接" });
    const first = await runtime.get(project.id);
    const second = await runtime.get(project.id);
    // 同一项目只创建一次上下文；三个 store 注入同一个共享句柄。
    assert.equal(first, second);
    assert.equal(first.taskStore, second.taskStore);
    assert.equal(first.scenarioStore, second.scenarioStore);
    assert.equal(first.diagnostics, second.diagnostics);
    assert.equal(first.project.taskCount, 0);

    // 每请求刷新：写入任务后无需失效协议即可看到新计数。
    await first.taskStore.saveTask({
      id: "shared-task",
      filename: "slate.png",
      status: "completed",
      result: { records: [] },
    });
    const refreshed = await runtime.get(project.id);
    assert.equal(refreshed.project.taskCount, 1);
    assert.ok(refreshed.project.latestTaskAt);
  } finally {
    await runtime.close();
    await library.close();
    await rm(tempRoot, { recursive: true, force: true });
  }
});

test("closeProject closes the shared handle once and the context can be rebuilt", async () => {
  const tempRoot = await mkdtemp(join(tmpdir(), "slatesync-runtime-rebuild-"));
  const library = createProjectLibrary(join(tempRoot, "library"));
  const runtime = createProjectRuntime(library);

  try {
    const project = await library.createProject({ name: "可重建" });
    const first = await runtime.get(project.id);
    await first.taskStore.saveTask({
      id: "persisted-task",
      filename: "slate.png",
      status: "completed",
      result: { records: [] },
    });
    await runtime.closeProject(project.id);
    // 共享句柄已关闭（三个 store 注入句柄，自身都不负责关闭）。
    assert.equal(first.db.open, false);

    const second = await runtime.get(project.id);
    assert.notEqual(second, first);
    assert.equal(second.db.open, true);
    assert.deepEqual(
      (await second.taskStore.listTasks()).map((task) => task.id),
      ["persisted-task"],
    );
    await runtime.closeProject(project.id);
    assert.equal(second.db.open, false);
  } finally {
    await runtime.close();
    await library.close();
    await rm(tempRoot, { recursive: true, force: true });
  }
});

test("archived projects reject writable gets while readOnly keeps working", async () => {
  const tempRoot = await mkdtemp(join(tmpdir(), "slatesync-runtime-archived-"));
  const library = createProjectLibrary(join(tempRoot, "library"));
  const runtime = createProjectRuntime(library);

  try {
    const project = await library.createProject({ name: "归档只读" });
    await library.archiveProject(project.id);

    await assert.rejects(
      () => runtime.get(project.id),
      (error) => error.code === "PROJECT_ARCHIVED",
    );
    const readOnly = await runtime.get(project.id, { allowArchived: true });
    assert.ok(readOnly.project.archivedAt);
    assert.equal(readOnly.project.canArchive, true);
  } finally {
    await runtime.close();
    await library.close();
    await rm(tempRoot, { recursive: true, force: true });
  }
});

test("recognition defaults flow end to end through the shared connection", async () => {
  const tempRoot = await mkdtemp(join(tmpdir(), "slatesync-runtime-defaults-"));
  const library = createProjectLibrary(join(tempRoot, "library"));
  const runtime = createProjectRuntime(library);

  try {
    const project = await library.createProject({ name: "默认值流转" });
    const context = await runtime.get(project.id);
    await context.taskStore.saveTask({
      id: "defaults-source",
      createdAt: "2026-01-02T00:00:00.000Z",
      provider: "dashscope",
      model: "flow-model",
      customPrompt: "flow prompt",
      result: { records: [] },
    });
    // task-store 写事务维护的键由 library 读取端 O(1) 命中，两端共享同一连接。
    assert.deepEqual(
      (await library.getProject(project.id)).lastRecognitionDefaults,
      { providerId: "dashscope", modelId: "flow-model", customPrompt: "flow prompt" },
    );

    await context.taskStore.deleteTask("defaults-source");
    assert.deepEqual(
      (await library.getProject(project.id)).lastRecognitionDefaults,
      null,
    );
  } finally {
    await runtime.close();
    await library.close();
    await rm(tempRoot, { recursive: true, force: true });
  }
});

test("runtime close drains every open project context", async () => {
  const tempRoot = await mkdtemp(join(tmpdir(), "slatesync-runtime-close-"));
  const library = createProjectLibrary(join(tempRoot, "library"));
  const runtime = createProjectRuntime(library);

  try {
    const first = await library.createProject({ name: "项目 A" });
    const second = await library.createProject({ name: "项目 B" });
    const contextA = await runtime.get(first.id);
    const contextB = await runtime.get(second.id);
    await runtime.close();
    assert.equal(contextA.db.open, false);
    assert.equal(contextB.db.open, false);
    // 关闭后 get 仍可重新建立上下文（默认项目始终可寻址）。
    const recreated = await runtime.get(DEFAULT_PROJECT_ID);
    assert.ok(recreated.taskStore);
  } finally {
    await runtime.close();
    await library.close();
    await rm(tempRoot, { recursive: true, force: true });
  }
});

// Ownership regressions: concurrency and retention are tested with real temp
// SQLite handles so a leaked or prematurely closed connection is observable.
test("concurrent first requests share one owner and close every handle", async () => {
  const root = await mkdtemp(join(tmpdir(), "slatesync-runtime-concurrent-"));
  const library = createProjectLibrary(join(root, "library"));
  const runtime = createProjectRuntime(library);
  try {
    const project = await library.createProject({ name: "parallel" });
    const contexts = await Promise.all(Array.from({ length: 8 }, () => runtime.get(project.id)));
    assert.equal(new Set(contexts).size, 1);
    await runtime.close();
    assert.ok(contexts.every((context) => !context.db.open));
  } finally { await runtime.close(); await library.close(); await rm(root, { recursive: true, force: true }); }
});

test("close during initialization drains the lease and forbids new acquisition", async () => {
  const root = await mkdtemp(join(tmpdir(), "slatesync-runtime-drain-"));
  const library = createProjectLibrary(join(root, "library"));
  let entered;
  let resume;
  const started = new Promise((resolve) => { entered = resolve; });
  const blocked = new Promise((resolve) => { resume = resolve; });
  const runtime = createProjectRuntime({
    getProjectRow: (...args) => library.getProjectRow(...args),
    async summarizeProjectRow(...args) { entered(); await blocked; return library.summarizeProjectRow(...args); },
  });
  let lease;
  try {
    const project = await library.createProject({ name: "drain" });
    const opening = runtime.acquire(project.id);
    await started;
    let closed = false;
    const closing = runtime.closeProject(project.id).then(() => { closed = true; });
    await assert.rejects(runtime.acquire(project.id), { code: "PROJECT_BUSY" });
    resume();
    lease = await opening;
    assert.equal(closed, false);
    assert.equal(lease.context.db.open, true);
    await lease.release();
    await closing;
    assert.equal(lease.context.db.open, false);
    assert.equal((await runtime.get(project.id)).db.open, true);
  } finally { resume(); await lease?.release(); await runtime.close(); await library.close(); await rm(root, { recursive: true, force: true }); }
});

test("failed initialization closes its handle and allows retry", async () => {
  const root = await mkdtemp(join(tmpdir(), "slatesync-runtime-failed-"));
  const library = createProjectLibrary(join(root, "library"));
  let failedHandle;
  const runtime = createProjectRuntime({
    getProjectRow: (...args) => library.getProjectRow(...args),
    summarizeProjectRow(row, options) {
      if (!failedHandle) { failedHandle = options.db; throw new Error("synthetic summary failure"); }
      return library.summarizeProjectRow(row, options);
    },
  });
  try {
    const project = await library.createProject({ name: "retry" });
    await assert.rejects(runtime.get(project.id), /synthetic summary failure/);
    assert.equal(failedHandle.open, false);
    assert.equal(runtime.stats().contexts, 0);
    assert.equal((await runtime.get(project.id)).db.open, true);
  } finally { await runtime.close(); await library.close(); await rm(root, { recursive: true, force: true }); }
});

test("idle capacity evicts the oldest context while active leases survive", async () => {
  const root = await mkdtemp(join(tmpdir(), "slatesync-runtime-idle-"));
  const library = createProjectLibrary(join(root, "library"));
  const runtime = createProjectRuntime(library, { idleMs: 25 });
  let active;
  try {
    const a = await library.createProject({ name: "active" });
    const b = await library.createProject({ name: "old idle" });
    const c = await library.createProject({ name: "new idle" });
    active = await runtime.acquire(a.id);
    const old = await runtime.get(b.id);
    const recent = await runtime.get(c.id);
    assert.equal(old.db.open, false);
    assert.equal(recent.db.open, true);
    assert.equal(active.context.db.open, true);
    await new Promise((resolve) => setTimeout(resolve, 60));
    assert.equal(recent.db.open, false);
    assert.equal(active.context.db.open, true);
    assert.deepEqual(runtime.stats(), { contexts: 1, leases: 1, idle: 0 });
    await active.release();
    await active.release(); // Idempotent cleanup cannot underflow lease counts.
    assert.equal(runtime.stats().leases, 0);
  } finally { await active?.release(); await runtime.close(); await library.close(); await rm(root, { recursive: true, force: true }); }
});

test("concurrent archived read and write keep their own access checks", async () => {
  const root = await mkdtemp(join(tmpdir(), "slatesync-runtime-access-"));
  const library = createProjectLibrary(join(root, "library"));
  const runtime = createProjectRuntime(library);
  try {
    const project = await library.createProject({ name: "archived concurrency" });
    await library.archiveProject(project.id);
    const [write, read] = await Promise.allSettled([
      runtime.get(project.id), runtime.get(project.id, { allowArchived: true }),
    ]);
    assert.equal(write.status, "rejected");
    assert.equal(write.reason.code, "PROJECT_ARCHIVED");
    assert.equal(read.status, "fulfilled");
    assert.ok(read.value.project.archivedAt);
  } finally { await runtime.close(); await library.close(); await rm(root, { recursive: true, force: true }); }
});

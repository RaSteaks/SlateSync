// 项目运行时（每项目单一共享 SQLite 连接）的验收测试。
//
// 覆盖方案阶段 1 的关键行为：两次 get 复用同一上下文与共享句柄、每请求
// 元数据刷新、closeProject 只关一次共享句柄且可重建、归档读写分离、
// defaults 端到端流转。
import assert from "node:assert/strict";
import { mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";

import {
  createProjectLibrary,
  DEFAULT_PROJECT_ID,
} from "../lib/project-library.mjs";
import { createProjectRuntime } from "../lib/project-runtime.mjs";

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

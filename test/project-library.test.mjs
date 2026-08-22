import assert from "node:assert/strict";
import { access, mkdtemp, readFile, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";

import { registerIpcHandlers } from "../electron/ipc-handlers.mjs";
import { createDiagnosticsStore } from "../lib/diagnostics.mjs";
import {
  createProjectLibrary,
  DEFAULT_PROJECT_ID,
} from "../lib/project-library.mjs";
import { createProjectRuntime } from "../lib/project-runtime.mjs";
import { createScenarioObservation } from "../lib/scenario/profile.mjs";
import { createScenarioStore } from "../lib/scenario/store.mjs";
import { createTaskStore } from "../lib/task-store.mjs";

function createMockIpcMain() {
  const handlers = new Map();
  return {
    handle(channel, handler) {
      handlers.set(channel, handler);
    },
    async invoke(channel, ...args) {
      const handler = handlers.get(channel);
      if (!handler) throw new Error(`No handler for ${channel}`);
      return handler(
        {
          sender: {
            isDestroyed: () => false,
            send: () => {},
          },
        },
        ...args,
      );
    },
  };
}

function syntheticOcrResult() {
  return {
    id: "paddleocr",
    used: true,
    pages: [
      {
        pageNumber: 1,
        views: [
          {
            width: 1200,
            height: 800,
            blocks: [
              { text: "场次", confidence: 0.99, bboxNormalized: [0.05, 0.08, 0.12, 0.12] },
              { text: "镜", confidence: 0.99, bboxNormalized: [0.2, 0.08, 0.25, 0.12] },
              { text: "次", confidence: 0.99, bboxNormalized: [0.3, 0.08, 0.35, 0.12] },
              { text: "A机", confidence: 0.99, bboxNormalized: [0.7, 0.08, 0.78, 0.12] },
              { text: "87A", confidence: 0.95, bboxNormalized: [0.05, 0.45, 0.12, 0.5] },
              { text: "01", confidence: 0.95, bboxNormalized: [0.2, 0.45, 0.25, 0.5] },
              { text: "02", confidence: 0.95, bboxNormalized: [0.3, 0.45, 0.35, 0.5] },
            ],
          },
        ],
      },
    ],
  };
}

function ipcContext(projectLibrary, projectRuntime) {
  return {
    workflowConfig: {
      resolve: {
        fieldFormats: { scene: "XXX", shot: "XX", take: "XX" },
      },
    },
    runtimeProviderKeys: new Map(),
    runtimeEnv: () => ({ ...process.env }),
    recognitionLimiter: { acquire: () => () => {}, active: 0, limit: 1 },
    settings: { maxBodyBytes: 80 * 1024 * 1024 },
    projectLibrary,
    projectRuntime,
    runtimeSettings: {
      ocrPythonPath: "",
      ocrSetupCompleted: false,
      ocrSetupSkipped: false,
    },
  };
}

test("projects use separate SQLite files and project-scoped IPC", async () => {
  const tempRoot = await mkdtemp(join(tmpdir(), "slatesync-library-"));
  const libraryRoot = join(tempRoot, "Local SlateSync Library.slatesync-library");
  const library = createProjectLibrary(libraryRoot);
  const runtime = createProjectRuntime(library);

  try {
    const defaultProject = await library.getProject(DEFAULT_PROJECT_ID);
    const first = await library.createProject({
      name: "同名项目",
      description: "项目 A",
    });
    const second = await library.createProject({
      name: "同名项目",
      description: "项目 B",
    });

    assert.notEqual(first.id, second.id);
    assert.equal(first.name, second.name);
    assert.equal(defaultProject.canArchive, false);
    assert.equal(first.canArchive, true);
    await access(join(libraryRoot, "library.sqlite"));
    await access(join(libraryRoot, "library.json"));
    await access(join(defaultProject.directoryPath, "project.sqlite"));
    await access(join(first.directoryPath, "project.json"));
    await access(join(second.directoryPath, "project.sqlite"));

    const firstContext = await runtime.get(first.id);
    const secondContext = await runtime.get(second.id);
    await firstContext.taskStore.saveTask({
      id: "same-task-id",
      filename: "project-a.png",
      status: "completed",
      result: { records: [{ scene: "A" }] },
    });
    await secondContext.taskStore.saveTask({
      id: "same-task-id",
      filename: "project-b.png",
      status: "completed",
      result: { records: [{ scene: "B" }] },
    });

    assert.equal((await firstContext.taskStore.listTasks()).length, 1);
    assert.equal((await secondContext.taskStore.listTasks()).length, 1);
    assert.equal(
      (await firstContext.taskStore.loadTask("same-task-id")).filename,
      "project-a.png",
    );
    assert.equal(
      (await secondContext.taskStore.loadTask("same-task-id")).filename,
      "project-b.png",
    );

    const observation = createScenarioObservation(syntheticOcrResult(), {
      filename: "same-layout.png",
    });
    const firstMatch = await firstContext.scenarioStore.matchAndSave(observation);
    assert.deepEqual(await secondContext.scenarioStore.listProfiles(), []);
    await assert.rejects(
      () => secondContext.scenarioStore.getProfile(firstMatch.profile.id),
      /场记结构不存在/,
    );
    const secondMatch = await secondContext.scenarioStore.matchAndSave(observation);
    assert.equal(secondMatch.profile.id, firstMatch.profile.id);
    await firstContext.scenarioStore.matchAndSave(observation);
    assert.equal(
      (await firstContext.scenarioStore.getProfile(firstMatch.profile.id)).sampleCount,
      2,
    );
    assert.equal(
      (await secondContext.scenarioStore.getProfile(secondMatch.profile.id)).sampleCount,
      1,
    );

    const originalDirectory = first.directoryPath;
    const renamed = await library.updateProject(first.id, { name: "重命名项目" });
    assert.equal(renamed.name, "重命名项目");
    assert.equal(renamed.directoryPath, originalDirectory);
    await access(join(originalDirectory, "project.sqlite"));

    const ipcMain = createMockIpcMain();
    registerIpcHandlers(ipcMain, ipcContext(library, runtime));
    assert.deepEqual(
      (await ipcMain.invoke("list-tasks", { projectId: first.id })).map(
        (task) => task.filename,
      ),
      ["project-a.png"],
    );
    assert.equal(
      (await ipcMain.invoke("load-task", {
        projectId: second.id,
        id: "same-task-id",
      })).filename,
      "project-b.png",
    );

    await ipcMain.invoke("archive-project", { id: first.id });
    // Historical reads remain available, but the main-process boundary rejects
    // every write after resolving the archived project on that request.
    assert.equal(
      (await ipcMain.invoke("load-task", {
        projectId: first.id,
        id: "same-task-id",
      })).filename,
      "project-a.png",
    );
    await assert.rejects(
      () => ipcMain.invoke("save-task", {
        projectId: first.id,
        task: { id: "same-task-id", status: "edited" },
      }),
      /项目已归档/,
    );
  } finally {
    await runtime.close();
    await library.close();
    await rm(tempRoot, { recursive: true, force: true });
  }
});

test("legacy data migrates once into the default project and remains intact", async () => {
  const tempRoot = await mkdtemp(join(tmpdir(), "slatesync-migration-"));
  const legacyDir = join(tempRoot, "legacy-data");
  const libraryRoot = join(tempRoot, "library");
  const legacyTasks = createTaskStore(legacyDir);
  const legacyDiagnostics = createDiagnosticsStore(legacyDir);
  const legacyScenarios = createScenarioStore(legacyDir);
  let runtime;
  let library;

  try {
    await legacyTasks.saveTask({
      id: "legacy-task",
      filename: "legacy.png",
      status: "completed",
      result: { records: [{ scene: "001" }] },
    });
    await legacyDiagnostics.saveSession({
      id: "legacy-session",
      filename: "legacy.png",
      result: { records: [] },
    });
    await legacyScenarios.matchAndSave(
      createScenarioObservation(syntheticOcrResult(), {
        filename: "legacy-layout.png",
      }),
    );
    const legacyTaskSnapshot = await readFile(
      join(legacyDir, "tasks", "legacy-task.json"),
      "utf8",
    );

    await Promise.all([
      legacyTasks.close(),
      legacyDiagnostics.close(),
      legacyScenarios.close(),
    ]);
    library = createProjectLibrary(libraryRoot);
    const firstMigration = await library.migrateLegacyData(legacyDir);
    assert.equal(firstMigration.projectId, DEFAULT_PROJECT_ID);
    assert.equal(firstMigration.counts.tasks, 1);
    assert.equal(firstMigration.counts.diagnostics, 1);
    assert.equal(firstMigration.counts.scenarios, 1);
    assert.equal(firstMigration.counts.observations, 1);
    assert.equal(firstMigration.counts.snapshots, 2);

    runtime = createProjectRuntime(library);
    const context = await runtime.get(DEFAULT_PROJECT_ID);
    assert.equal((await context.taskStore.listTasks()).length, 1);
    assert.equal((await context.diagnostics.listSessions()).length, 1);
    assert.equal((await context.scenarioStore.listProfiles()).length, 1);
    assert.equal(
      (await context.taskStore.loadTask("legacy-task")).projectId,
      DEFAULT_PROJECT_ID,
    );
    assert.equal(
      JSON.parse(await readFile(
        join(context.project.directoryPath, "tasks", "legacy-task.json"),
        "utf8",
      )).projectId,
      DEFAULT_PROJECT_ID,
    );
    assert.equal(JSON.parse(legacyTaskSnapshot).projectId, undefined);
    assert.equal(
      await readFile(join(legacyDir, "tasks", "legacy-task.json"), "utf8"),
      legacyTaskSnapshot,
    );

    const secondMigration = await library.migrateLegacyData(legacyDir);
    assert.deepEqual(secondMigration, firstMigration);
  } finally {
    await runtime?.close();
    await library?.close();
    await rm(tempRoot, { recursive: true, force: true });
  }
});

test("task stores retain more than 50 tasks and their JSON snapshots", async () => {
  const tempRoot = await mkdtemp(join(tmpdir(), "slatesync-unlimited-tasks-"));
  const taskStore = createTaskStore(tempRoot);

  try {
    for (let index = 0; index < 55; index += 1) {
      await taskStore.saveTask({
        id: `task-${String(index).padStart(2, "0")}`,
        filename: `slate-${index}.png`,
        status: "completed",
        result: { records: [{ scene: String(index) }] },
      });
    }

    assert.equal((await taskStore.listTasks()).length, 55);
    assert.equal(
      JSON.parse(await readFile(join(tempRoot, "tasks", "task-00.json"), "utf8"))
        .filename,
      "slate-0.png",
    );
  } finally {
    await taskStore.close();
    await rm(tempRoot, { recursive: true, force: true });
  }
});

test("project details derive new-task defaults from the latest successful recognition", async () => {
  const tempRoot = await mkdtemp(join(tmpdir(), "slatesync-project-defaults-"));
  const library = createProjectLibrary(join(tempRoot, "library"));
  const runtime = createProjectRuntime(library);

  try {
    const project = await library.createProject({ name: "继承测试" });
    const context = await runtime.get(project.id);
    await context.taskStore.saveTask({
      id: "older-success",
      createdAt: "2026-01-01T00:00:00.000Z",
      provider: "openai",
      model: "older-model",
      customPrompt: "older prompt",
      result: { records: [] },
    });
    await context.taskStore.saveTask({
      id: "newer-failure",
      createdAt: "2026-01-03T00:00:00.000Z",
      provider: "openrouter",
      model: "failed-model",
      customPrompt: "failed prompt",
      result: null,
    });
    await context.taskStore.saveTask({
      id: "latest-success",
      createdAt: "2026-01-02T00:00:00.000Z",
      provider: "dashscope",
      model: "latest-model",
      customPrompt: "latest prompt",
      result: { records: [{ scene: "002" }] },
    });

    assert.deepEqual((await library.getProject(project.id)).lastRecognitionDefaults, {
      providerId: "dashscope",
      modelId: "latest-model",
      customPrompt: "latest prompt",
    });

    // Editing an older task changes updated_at but must not make it the source
    // of defaults for a newly created task.
    await context.taskStore.updateTask("older-success", {
      customPrompt: "edited historical prompt",
    });
    assert.equal(
      (await library.getProject(project.id)).lastRecognitionDefaults.customPrompt,
      "latest prompt",
    );

    await context.taskStore.deleteTask("latest-success");
    assert.deepEqual((await library.getProject(project.id)).lastRecognitionDefaults, {
      providerId: "openai",
      modelId: "older-model",
      customPrompt: "edited historical prompt",
    });
  } finally {
    await runtime.close();
    await library.close();
    await rm(tempRoot, { recursive: true, force: true });
  }
});

test("archived projects reject metadata changes until restored", async () => {
  const tempRoot = await mkdtemp(join(tmpdir(), "slatesync-archived-project-"));
  const library = createProjectLibrary(join(tempRoot, "library"));

  try {
    const project = await library.createProject({ name: "只读项目" });
    await library.archiveProject(project.id);
    await assert.rejects(
      () => library.updateProject(project.id, { name: "不应成功" }),
      (error) => error.code === "PROJECT_ARCHIVED",
    );
    await library.restoreProject(project.id);
    assert.equal(
      (await library.updateProject(project.id, { name: "恢复后可修改" })).name,
      "恢复后可修改",
    );
  } finally {
    await library.close();
    await rm(tempRoot, { recursive: true, force: true });
  }
});

test("touching project activity updates library ordering without changing task data", async () => {
  const tempRoot = await mkdtemp(join(tmpdir(), "slatesync-project-activity-"));
  const library = createProjectLibrary(join(tempRoot, "library"));

  try {
    const first = await library.createProject({ name: "项目 A" });
    const second = await library.createProject({ name: "项目 B" });
    await library.touchProjectActivity(second.id, "2099-01-01T00:00:00.000Z");
    await library.touchProjectActivity(first.id, "2099-01-02T00:00:00.000Z");

    const projects = await library.listProjects({ includeArchived: true });
    assert.equal(projects[0].id, first.id);
    assert.equal(projects[0].updatedAt, "2099-01-02T00:00:00.000Z");
    assert.equal(projects[0].taskCount, 0);
  } finally {
    await library.close();
    await rm(tempRoot, { recursive: true, force: true });
  }
});

import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import {
  access,
  mkdtemp,
  mkdir,
  readFile,
  rm,
  stat,
  writeFile,
} from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";
import { createSettingsStore } from "../electron/settings-store.mjs";
import {
  createProjectLibrary,
  DEFAULT_PROJECT_ID,
} from "../lib/project-library.mjs";
import {
  exportProjectLibrary,
  validateProjectLibrary,
} from "../lib/project-library-transfer.mjs";
import { createProjectRuntime } from "../lib/project-runtime.mjs";
import { createTask, createTaskStore } from "../lib/task-store.mjs";
import { restoreCsvPreviewState } from "../public/task-persistence.js";

// Every persistence test uses an OS temporary directory, preserving the
// operator's real userData and Project Library while exercising disk formats.
const fixtureRoot = new URL("./fixtures/baseline/persistence/", import.meta.url);

async function fixture(name) {
  return JSON.parse(await readFile(new URL(name, fixtureRoot), "utf8"));
}

async function sha256(path) {
  return createHash("sha256").update(await readFile(path)).digest("hex");
}

function permissionBits(value) {
  return value.mode & 0o777;
}

test("baseline task fixture keeps the complete task and CSV restore contracts", async () => {
  const expected = await fixture("task.json");
  assert.deepEqual(Object.keys(createTask()).sort(), Object.keys(expected).sort());

  const restored = restoreCsvPreviewState(expected);
  assert.equal(restored.metadataFilename, "timeline.csv");
  assert.deepEqual([...restored.csvEdits], [["0:1", "002"]]);
  assert.deepEqual(restored.metadataTable, expected.resolveCsvTable);
  assert.deepEqual(restored.slateMetadata, expected.slateMetadata);
});

test("baseline Project Library create/list/open/export preserves manifests and isolation", async () => {
  const root = await mkdtemp(join(tmpdir(), "slatesync-baseline-library-"));
  const sourcePath = join(root, "Baseline.slatesync-library");
  const targetPath = join(root, "Exported.slatesync-library");
  const expectedLibrary = await fixture("library.json");
  const expectedProject = await fixture("project.json");
  const source = createProjectLibrary(sourcePath, { name: expectedLibrary.name });
  const runtime = createProjectRuntime(source);
  let exported;
  let exportedRuntime;
  try {
    const defaultProject = await source.getProject(DEFAULT_PROJECT_ID);
    const secondProject = await source.createProject({
      name: "Second Project",
      description: expectedProject.description,
    });
    const listed = await source.listProjects();
    assert.deepEqual(new Set(listed.map(({ id }) => id)), new Set([DEFAULT_PROJECT_ID, secondProject.id]));
    assert.equal((await source.getProject(secondProject.id)).directoryPath, secondProject.directoryPath);

    const defaultContext = await runtime.get(DEFAULT_PROJECT_ID);
    const secondContext = await runtime.get(secondProject.id);
    const task = await fixture("task.json");
    await defaultContext.taskStore.saveTask({ ...task, id: "shared-task", projectId: DEFAULT_PROJECT_ID });
    await secondContext.taskStore.saveTask({ ...task, id: "shared-task", projectId: secondProject.id, filename: "second.png" });
    assert.equal((await defaultContext.taskStore.loadTask("shared-task")).filename, task.filename);
    assert.equal((await secondContext.taskStore.loadTask("shared-task")).filename, "second.png");

    const sourceLibraryBytes = await readFile(join(sourcePath, "library.json"));
    const sourceProjectBytes = await readFile(join(secondProject.directoryPath, "project.json"));
    const libraryManifest = JSON.parse(sourceLibraryBytes);
    const projectManifest = JSON.parse(sourceProjectBytes);
    assert.deepEqual(Object.keys(libraryManifest).sort(), Object.keys(expectedLibrary).sort());
    assert.deepEqual(Object.keys(projectManifest).sort(), Object.keys(expectedProject).sort());
    assert.equal(libraryManifest.formatVersion, expectedLibrary.formatVersion);
    assert.equal(projectManifest.formatVersion, expectedProject.formatVersion);

    const exportedInfo = await exportProjectLibrary(sourcePath, targetPath);
    assert.deepEqual(exportedInfo, await validateProjectLibrary(targetPath));
    assert.deepEqual(await readFile(join(targetPath, "library.json")), sourceLibraryBytes);
    assert.deepEqual(
      await readFile(join(targetPath, "Projects", secondProject.id, "project.json")),
      sourceProjectBytes,
    );

    exported = createProjectLibrary(targetPath);
    exportedRuntime = createProjectRuntime(exported);
    const exportedContext = await exportedRuntime.get(secondProject.id);
    assert.equal((await exportedContext.taskStore.loadTask("shared-task")).filename, "second.png");
    assert.equal((await defaultContext.taskStore.loadTask("shared-task")).filename, task.filename);

    if (process.platform !== "win32") {
      assert.equal(permissionBits(await stat(sourcePath)), 0o700);
      assert.equal(permissionBits(await stat(join(sourcePath, "library.sqlite"))), 0o600);
      assert.equal(permissionBits(await stat(join(defaultProject.directoryPath, "tasks"))), 0o700);
      assert.equal(permissionBits(await stat(join(defaultProject.directoryPath, "tasks", "shared-task.json"))), 0o600);
      assert.equal(permissionBits(await stat(join(defaultProject.directoryPath, "project.sqlite"))), 0o600);
    }
  } finally {
    await exportedRuntime?.close();
    await exported?.close();
    await runtime.close();
    await source.close();
    await rm(root, { recursive: true, force: true });
  }
});

test("baseline SQLite is authoritative while snapshots and >50 projections remain compatible", async () => {
  const root = await mkdtemp(join(tmpdir(), "slatesync-baseline-tasks-"));
  const store = createTaskStore(root);
  try {
    const expected = await fixture("task.json");
    for (let index = 0; index < 55; index += 1) {
      await store.saveTask({
        ...expected,
        id: `task-${String(index).padStart(3, "0")}`,
        filename: `synthetic-${index}.png`,
      });
    }
    const listed = await store.listTasks();
    assert.equal(listed.length, 55);
    assert.deepEqual(Object.keys(listed[0]).sort(), [
      "createdAt", "filename", "id", "model", "pageCount", "provider",
      "recordCount", "scenarioId", "status", "updatedAt",
    ].sort());
    assert.equal(listed.every((item, index) => index === 0 || item.updatedAt <= listed[index - 1].updatedAt), true);
    assert.equal(new Set(listed.map(({ id }) => id)).size, 55);

    const snapshotPath = join(store.tasksDir, "task-000.json");
    const snapshot = JSON.parse(await readFile(snapshotPath, "utf8"));
    assert.equal(snapshot.filename, "synthetic-0.png");
    await writeFile(snapshotPath, JSON.stringify({ ...snapshot, filename: "snapshot-only-change.png" }));
    assert.equal((await store.loadTask("task-000")).filename, "synthetic-0.png");
  } finally {
    await store.close();
    await rm(root, { recursive: true, force: true });
  }
});

test("baseline legacy SQLite and JSON migrate once without mutating their source", async () => {
  const root = await mkdtemp(join(tmpdir(), "slatesync-baseline-legacy-"));
  const legacyRoot = join(root, "legacy");
  const targetRoot = join(root, "Migrated.slatesync-library");
  const recipe = await fixture("legacy-migration.json");
  await mkdir(legacyRoot, { recursive: true });
  const legacyStore = createTaskStore(legacyRoot);
  const expected = await fixture("task.json");
  await legacyStore.saveTask({ ...expected, id: recipe.taskId, projectId: null });
  await legacyStore.close();

  const sourceDb = join(legacyRoot, recipe.sourceDatabase);
  const sourceSnapshot = join(legacyRoot, "tasks", `${recipe.taskId}.json`);
  const originalDbHash = await sha256(sourceDb);
  const originalSnapshot = await readFile(sourceSnapshot);
  const library = createProjectLibrary(targetRoot);
  const runtime = createProjectRuntime(library);
  try {
    const first = await library.migrateLegacyData(legacyRoot);
    const second = await library.migrateLegacyData(legacyRoot);
    assert.deepEqual(second, first);
    assert.equal(first.version, recipe.version);
    assert.equal(first.projectId, recipe.projectId);
    assert.equal(first.counts.tasks, recipe.expectedCounts.tasks);
    assert.equal(first.counts.snapshots, recipe.expectedCounts.snapshots);

    const context = await runtime.get(DEFAULT_PROJECT_ID);
    const migrated = await context.taskStore.loadTask(recipe.taskId);
    assert.equal(migrated.projectId, DEFAULT_PROJECT_ID);
    assert.equal(migrated.filename, expected.filename);
    assert.equal(await sha256(sourceDb), originalDbHash);
    assert.deepEqual(await readFile(sourceSnapshot), originalSnapshot);
    await access(sourceDb);
  } finally {
    await runtime.close();
    await library.close();
    await rm(root, { recursive: true, force: true });
  }
});

test("baseline machine settings keep the reviewed four-field shape", async () => {
  const root = await mkdtemp(join(tmpdir(), "slatesync-baseline-settings-"));
  const settingsStore = createSettingsStore(root);
  try {
    const defaults = await settingsStore.load();
    assert.deepEqual(Object.keys(defaults).sort(), [
      "libraryPath", "ocrPythonPath", "ocrSetupCompleted", "ocrSetupSkipped",
    ].sort());
    const expected = await fixture("settings.json");
    assert.deepEqual(await settingsStore.save(expected), expected);
    assert.deepEqual(await settingsStore.load(), expected);
  } finally {
    await rm(root, { recursive: true, force: true });
  }
});

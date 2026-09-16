import test from "node:test";
import assert from "node:assert/strict";
import { Worker } from "node:worker_threads";
import { mkdtemp, rm, writeFile, readFile, stat, mkdir } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { createStorageClient } from "../lib/storage-client.mjs";
import { openSlateDatabase, closeSlateDatabase } from "../lib/sqlite-store.mjs";
import { withEncryptionKeyProvider } from "../lib/local-encryption.mjs";
import { SYNTHETIC_KEY } from "../test-support/storage-worker-fixture.mjs";
import { createProjectLibrary } from "../lib/project-library.mjs";

const cleanups = new WeakMap();
const cleanup = (t, operation) => cleanups.get(t).push(operation);
const encrypted = process.platform === "darwin";
const fixture = new URL("../test-support/storage-worker-fixture.mjs", import.meta.url);
async function temporary(t) {
  const root = await mkdtemp(join(tmpdir(), "slatesync-worker-test-"));
  cleanups.set(t, []);
  t.after(async () => {
    for (const operation of [...cleanups.get(t)].reverse()) await operation();
    await rm(root, { recursive: true, force: true });
  });
  return root;
}
function client(t, options = {}) {
  const storage = createStorageClient(options);
  cleanup(t, () => storage.close().catch(() => {}));
  return storage;
}

test("real Worker correlates requests, preserves errors, drains accepted saves and reopens", async (t) => {
  const root = await temporary(t);
  const storage = client(t);
  await storage.initialize({ root: join(root, "library") });
  const projects = await Promise.all(Array.from({ length: 3 }, (_, i) => storage.projectLibrary.createProject({ name: `project-${i}` })));
  assert.deepEqual(projects.map((project) => project.name), ["project-0", "project-1", "project-2"]);
  const context = await storage.projectRuntime.get(projects[0].id);
  const saves = Array.from({ length: 5 }, (_, i) => context.taskStore.saveTask({ id: `task-${i}`, filename: `file-${i}` }));
  const closing = storage.close();
  assert.deepEqual(await Promise.all(saves), ["task-0", "task-1", "task-2", "task-3", "task-4"]);
  await closing;
  await assert.rejects(storage.projectLibrary.listProjects(), { code: "STORAGE_UNAVAILABLE" });
  const reopened = client(t);
  await reopened.initialize({ root: join(root, "library") });
  const restored = await reopened.projectRuntime.get(projects[0].id);
  assert.equal((await restored.taskStore.listTasks()).length, 5);
  await assert.rejects(restored.taskStore.loadTask("missing"), { code: "ENOENT" });
  assert.ok((await reopened.stats()).threadId > 0);
});

test("Worker retains leased projects across idle eviction and close waits for release", async (t) => {
  const root = await temporary(t);
  const storage = client(t);
  await storage.initialize({ root: join(root, "library"), runtimeOptions: { idleMs: 20 } });
  const a = await storage.projectLibrary.createProject({ name: "active" });
  const b = await storage.projectLibrary.createProject({ name: "idle" });
  const lease = await storage.projectRuntime.acquire(a.id);
  cleanup(t, () => lease.release().catch(() => {}));
  await storage.projectRuntime.get(b.id);
  await new Promise((resolve) => setTimeout(resolve, 50));
  const stats = await storage.stats();
  assert.equal(stats.contexts, 1);
  assert.equal(stats.leases, 1);
  await assert.rejects(storage.projectRuntime.closeProject(a.id), { code: "PROJECT_BUSY" });
  let closed = false;
  const closing = storage.close().then(() => { closed = true; });
  await new Promise((resolve) => setTimeout(resolve, 10));
  assert.equal(closed, false);
  await lease.release();
  await closing;
});

test("Worker crash rejects pending work and never recreates or replays the worker", async (t) => {
  const root = await temporary(t);
  let worker;
  let creations = 0;
  const storage = client(t, { workerFactory: () => {
    creations += 1;
    worker = new Worker(new URL("../lib/storage-worker.mjs", import.meta.url), { workerData: { slatesyncStorage: true } });
    return worker;
  } });
  // Terminate before initialization finishes; assertions do not assume whether
  // an interrupted command committed, only that no success/replay is invented.
  const pending = storage.initialize({ root: join(root, "library") });
  const rejected = assert.rejects(pending, { code: "STORAGE_UNAVAILABLE" });
  await worker.terminate();
  await rejected;
  await assert.rejects(storage.projectLibrary.createProject({ name: "must not replay" }), { code: "STORAGE_UNAVAILABLE" });
  assert.equal(creations, 1);
});

test("encrypted initialized library reads and repeated opens do not replace ciphertext", { skip: !encrypted }, async (t) => {
  const root = await temporary(t);
  const libraryRoot = join(root, "library");
  await mkdir(libraryRoot);
  await writeFile(join(libraryRoot, ".slatesync-encryption"), "EEFA4048-D462-476D-A043-502CDDA4AA2D");
  const storage = client(t, { workerFactory: () => new Worker(fixture) });
  await storage.initialize({ root: libraryRoot });
  const project = await storage.projectLibrary.createProject({ name: "encrypted" });
  const context = await storage.projectRuntime.get(project.id);
  await context.taskStore.saveTask({ id: "saved", filename: "before.png" });
  await storage.projectRuntime.close();
  const files = [join(libraryRoot, "library.sqlite"), join(project.directoryPath, "project.sqlite")];
  const before = await Promise.all(files.map(async (path) => ({ bytes: await readFile(path), stat: await stat(path, { bigint: true }) })));
  for (let i = 0; i < 3; i++) {
    await storage.projectLibrary.listProjects();
    await storage.projectRuntime.get(project.id);
    await storage.projectRuntime.close();
  }
  for (let i = 0; i < files.length; i++) {
    assert.deepEqual(await readFile(files[i]), before[i].bytes);
    const after = await stat(files[i], { bigint: true });
    assert.equal(after.ino, before[i].stat.ino);
    assert.equal(after.mtimeNs, before[i].stat.mtimeNs);
  }
  const packagePath = join(root, "export.slatesync-project");
  await storage.projectLibrary.exportProjectPackage(project.id, packagePath);
  const imported = await storage.projectLibrary.importProjectPackage(packagePath);
  assert.equal((await (await storage.projectRuntime.get(imported.id)).taskStore.loadTask("saved")).filename, "before.png");
  const renamed = await storage.projectLibrary.renameLibrary("renamed");
  assert.equal(renamed.path, join(root, "renamed"));
  assert.equal((await storage.projectRuntime.get(project.id)).project.name, "encrypted");
});

test("schema inspection repairs a missing index/summary column without repeated DDL writes", async (t) => {
  const root = await temporary(t);
  const { db } = openSlateDatabase(root);
  db.exec("DROP INDEX tasks_updated_at_idx; ALTER TABLE tasks DROP COLUMN summary_json");
  closeSlateDatabase(db);
  const reopened = openSlateDatabase(root).db;
  try {
    assert.ok(reopened.prepare("PRAGMA table_info(tasks)").all().some((column) => column.name === "summary_json"));
    assert.ok(reopened.prepare("SELECT name FROM sqlite_master WHERE name = 'tasks_updated_at_idx'").get());
  } finally { closeSlateDatabase(reopened); }
});

test("external encrypted commits remain visible through a warm Worker connection", { skip: !encrypted }, async (t) => {
  const root = await temporary(t);
  const libraryRoot = join(root, "library");
  await mkdir(libraryRoot);
  await writeFile(join(libraryRoot, ".slatesync-encryption"), "EEFA4048-D462-476D-A043-502CDDA4AA2D");
  const storage = client(t, { workerFactory: () => new Worker(fixture) });
  await storage.initialize({ root: libraryRoot });
  const project = await storage.projectLibrary.createProject({ name: "before" });
  await storage.projectRuntime.get(project.id);
  await withEncryptionKeyProvider(() => SYNTHETIC_KEY, async () => {
    const other = createProjectLibrary(libraryRoot);
    try { await other.updateProject(project.id, { name: "external update" }); }
    finally { await other.close(); }
  });
  assert.equal((await storage.projectRuntime.get(project.id)).project.name, "external update");
});

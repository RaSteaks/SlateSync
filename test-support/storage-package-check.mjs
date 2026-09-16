// Build an isolated ASAR with the same storage paths/native unpacking as the
// app, then exercise it using Electron's Node-only mode (no app or window).
import { createPackageWithOptions } from "@electron/asar";
import { mkdtemp, cp, mkdir, writeFile, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import { execFile } from "node:child_process";
import { promisify } from "node:util";
import electron from "electron";
const repo = fileURLToPath(new URL("../", import.meta.url));
const root = await mkdtemp(join(tmpdir(), "slatesync-storage-package-"));
try {
  const stage = join(root, "stage");
  await mkdir(stage);
  for (const dir of ["lib", "public"]) await cp(join(repo, dir), join(stage, dir), { recursive: true });
  await writeFile(join(stage, "package.json"), JSON.stringify({ type: "module" }));
  for (const dependency of ["better-sqlite3", "bindings", "file-uri-to-path"]) {
    await cp(join(repo, "node_modules", dependency), join(stage, "node_modules", dependency), { recursive: true });
  }
  // The synthetic bootstrap exists only in this test archive, never the app's
  // files inventory. Production keys are neither read nor injected.
  await mkdir(join(stage, "test-support"));
  await cp(join(repo, "test-support/storage-worker-fixture.mjs"), join(stage, "test-support/storage-worker-fixture.mjs"));
  await mkdir(join(root, "app/bin"), { recursive: true });
  await cp(join(repo, "bin/local-encryption.dylib"), join(root, "app/bin/local-encryption.dylib"));
  const archive = join(root, "app.asar");
  await createPackageWithOptions(stage, archive, { unpack: "**/*.node" });
  const script = join(root, "verify.mjs");
  await writeFile(script, `
import assert from 'node:assert/strict';
import { Worker } from 'node:worker_threads';
import { mkdir, writeFile } from 'node:fs/promises';
import { join } from 'node:path';
import { pathToFileURL } from 'node:url';
const root = process.argv[2];
const archive = join(root, 'app.asar');
const { createStorageClient } = await import(pathToFileURL(join(archive, 'lib/storage-client.mjs')));
for (const encrypted of [false, true]) {
  const libraryRoot = join(root, encrypted ? 'encrypted' : 'plain');
  await mkdir(libraryRoot);
  if (encrypted) await writeFile(join(libraryRoot, '.slatesync-encryption'), 'EEFA4048-D462-476D-A043-502CDDA4AA2D');
  const storage = createStorageClient(encrypted ? {
    workerFactory: () => new Worker(pathToFileURL(join(archive, 'test-support/storage-worker-fixture.mjs'))),
  } : {});
  try {
    await storage.initialize({ root: libraryRoot, resourcesPath: root });
    const project = await storage.projectLibrary.createProject({ name: 'packaged worker' });
    const context = await storage.projectRuntime.get(project.id);
    await context.taskStore.saveTask({ id: 'durable', filename: 'packaged.png' });
    assert.equal((await context.taskStore.loadTask('durable')).filename, 'packaged.png');
    assert.ok((await storage.stats()).threadId > 0);
    console.log(JSON.stringify({ encrypted, worker: 'ASAR', native: 'loaded', durableRoundTrip: true }));
  } finally { await storage.close(); }
}
`);
  const { stdout } = await promisify(execFile)(electron, [script, root], {
    env: { ...process.env, ELECTRON_RUN_AS_NODE: "1" }, timeout: 60_000,
  });
  console.log(stdout.trim());
} finally { await rm(root, { recursive: true, force: true }); }

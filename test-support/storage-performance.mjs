// Headless synthetic benchmark. Compare the same durable storage operation in
// the calling thread and in the production Worker facade. Never use a real key
// or library; all files are removed after measurement.
import { Worker } from "node:worker_threads";
import { performance } from "node:perf_hooks";
import { mkdtemp, mkdir, writeFile, rm, stat } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { createProjectLibrary } from "../lib/project-library.mjs";
import { createProjectRuntime } from "../lib/project-runtime.mjs";
import { createStorageClient } from "../lib/storage-client.mjs";
import { withEncryptionKeyProvider } from "../lib/local-encryption.mjs";
import { SYNTHETIC_KEY } from "./storage-worker-fixture.mjs";

if (process.platform !== "darwin") throw new Error("Encrypted flock benchmark requires macOS");
const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));
async function measure(operation) {
  const gaps = [];
  let last = performance.now();
  const timer = setInterval(() => { const now = performance.now(); gaps.push(now - last); last = now; }, 5);
  try {
    await sleep(25);
    const beforeCpu = process.cpuUsage();
    const start = performance.now();
    for (let i = 0; i < 3; i++) { await operation(i); await new Promise((resolve) => setImmediate(resolve)); }
    const wallMs = performance.now() - start;
    const cpu = process.cpuUsage(beforeCpu);
    await sleep(25);
    return { threeWritesWallMs: wallMs, callingThreadMaxTimerGapMs: Math.max(...gaps),
      processCpuMs: (cpu.user + cpu.system) / 1000, processRssMiB: process.memoryUsage().rss / 1024 ** 2 };
  } finally { clearInterval(timer); }
}
const results = [];
for (const sizeMiB of [32, 128]) {
  const root = await mkdtemp(join(tmpdir(), "slatesync-storage-perf-"));
  let library;
  let runtime;
  let lease;
  let storage;
  try {
    const libraryRoot = join(root, "library");
    await mkdir(libraryRoot);
    await writeFile(join(libraryRoot, ".slatesync-encryption"), "EEFA4048-D462-476D-A043-502CDDA4AA2D");
    const row = await withEncryptionKeyProvider(() => SYNTHETIC_KEY, async () => {
      library = createProjectLibrary(libraryRoot);
      const project = await library.createProject({ name: `synthetic-${sizeMiB}MiB` });
      runtime = createProjectRuntime(library);
      lease = await runtime.acquire(project.id);
      // Large diagnostic evidence makes the database realistic without sending
      // a large task payload across RPC during the tiny-save measurement.
      lease.context.db.prepare("INSERT INTO diagnostic_sessions(id,data_json,saved_at) VALUES (?,?,?)")
        .run("large-evidence", JSON.stringify({ id: "large-evidence", evidence: "x".repeat(sizeMiB * 1024 ** 2) }), new Date().toISOString());
      await lease.context.taskStore.saveTask({ id: "small-task", filename: "seed", provider: "synthetic", model: "synthetic", result: { records: [] } });
      const databaseMiB = (await stat(join(project.directoryPath, "project.sqlite"))).size / 1024 ** 2;
      const synchronous = await measure((i) => lease.context.taskStore.saveTask({ id: "small-task", filename: `sync-${i}` }));
      await lease.release(); lease = null;
      await runtime.close(); runtime = null;
      await library.close(); library = null;
      return { sizeMiB, databaseMiB, projectId: project.id, synchronous };
    });
    storage = createStorageClient({ workerFactory: () => new Worker(new URL("./storage-worker-fixture.mjs", import.meta.url)) });
    await storage.initialize({ root: libraryRoot });
    const context = await storage.projectRuntime.get(row.projectId);
    row.worker = await measure((i) => context.taskStore.saveTask({ id: "small-task", filename: `worker-${i}` }));
    const warm = await storage.stats();
    row.workerState = { contexts: warm.contexts, idle: warm.idle, threadId: warm.threadId,
      heapUsedMiB: warm.memory.heapUsed / 1024 ** 2, externalMiB: warm.memory.external / 1024 ** 2 };
    await storage.projectRuntime.close();
    const closed = await storage.stats();
    row.afterRuntimeClose = { contexts: closed.contexts, leases: closed.leases };
    delete row.projectId;
    results.push(row);
  } finally {
    await lease?.release(); await runtime?.close(); await library?.close(); await storage?.close();
    await rm(root, { recursive: true, force: true });
  }
}
console.log(JSON.stringify({ measuredAt: new Date().toISOString(), node: process.version, platform: process.platform, arch: process.arch,
  notes: "Three tiny durable saves; same optimized storage implementation, synchronous caller vs Worker. Timer interval 5ms. CPU/RSS cover the whole process, not only Main. Synthetic keys and temporary data only. No GUI.", results }, null, 2));

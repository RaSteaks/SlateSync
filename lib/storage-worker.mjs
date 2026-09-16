// Single persistence owner. Serialize entire commands, including asynchronous
// JSON snapshots, so a later close/transfer cannot overtake an accepted save.
import { parentPort, workerData, threadId } from "node:worker_threads";
import { createProjectLibrary } from "./project-library.mjs";
import { createProjectRuntime } from "./project-runtime.mjs";
import { exportProjectLibrary, validateProjectLibrary } from "./project-library-transfer.mjs";
import { configureLocalEncryptionResources } from "./local-encryption.mjs";
import { LIBRARY_METHODS, STORE_METHODS } from "./storage-protocol.mjs";

export function startStorageWorker(port, { runWithContext = (fn) => fn() } = {}) {
  let library;
  let runtime;
  let matching;
  let nextLease = 0;
  let queue = Promise.resolve();
  let stopped = false;
  const leases = new Map();
  async function dispatch(op, args) {
    if (op === "initialize") {
      if (library) throw new Error("存储 Worker 已初始化");
      const [config] = args;
      if (config.resourcesPath) configureLocalEncryptionResources(config.resourcesPath);
      matching = config.matching;
      library = createProjectLibrary(config.root, { defaultSettings: config.defaultSettings });
      runtime = createProjectRuntime(library, { ...config.runtimeOptions, matching: () => matching });
      if (config.legacyDataDir) await library.migrateLegacyData(config.legacyDataDir);
      return library.getLibraryInfo();
    }
    if (op === "shutdown") {
      assertNoLeases();
      try { await runtime?.close(); } finally {
        try { await library?.close(); } finally { stopped = true; }
      }
      return;
    }
    if (!library || !runtime) throw new Error("存储 Worker 尚未初始化");
    if (op === "acquire") {
      const [id, options] = args;
      const lease = await runtime.acquire(id, options);
      const token = ++nextLease;
      leases.set(token, { ...lease, id });
      return { token, project: lease.context.project };
    }
    if (op === "release") {
      const lease = leases.get(args[0]);
      if (lease) { leases.delete(args[0]); await lease.release(); }
      return;
    }
    if (op === "context") return (await runtime.get(...args)).project;
    if (op === "store") {
      const [projectId, options, store, method, values, config] = args;
      if (!Object.hasOwn(STORE_METHODS, store) || !STORE_METHODS[store].includes(method)) throw new Error("无效存储方法");
      // Store calls pin the connection and recheck archive access; the outer
      // operation already loaded its project projection, so do not rescan drafts.
      const lease = await runtime.acquire(projectId, { ...options, refreshProject: false });
      // Apply the snapshot in this command, not a separate RPC that another
      // recognition could interleave with a different workflow revision.
      if (config && Object.hasOwn(config, "matching")) matching = config.matching;
      try { return await lease.context[store][method](...values); }
      finally { await lease.release(); }
    }
    if (op === "library") {
      const [method, values] = args;
      if (!LIBRARY_METHODS.includes(method)) throw new Error("无效项目库方法");
      if (method === "renameLibrary") {
        assertNoLeases();
        await runtime.close(); // Cached encrypted paths must not survive a rename.
      }
      return library[method](...values);
    }
    if (op === "exportLibrary") return exportProjectLibrary(library.libraryRoot, args[0]);
    if (op === "validateLibrary") return validateProjectLibrary(args[0]);
    if (op === "closeProject") {
      assertNoLeases(args[0]);
      return runtime.closeProject(args[0]);
    }
    if (op === "closeRuntime") { assertNoLeases(); return runtime.close(); }
    if (op === "stats") return { ...runtime.stats(), threadId, memory: process.memoryUsage() };
    throw new Error("无效存储操作");
  }
  function assertNoLeases(id) {
    // Waiting here would deadlock the serial queue behind a release command.
    // Main drains complete IPC/recognition leases before destructive commands.
    if ([...leases.values()].some((lease) => id === undefined || lease.id === id)) {
      throw Object.assign(new Error("项目仍有活动存储租约"), { code: "PROJECT_BUSY" });
    }
  }
  port.on("message", (request) => {
    queue = queue.then(() => runWithContext(async () => {
      const { id, op, args = [] } = request;
      try {
        if (stopped) throw new Error("存储 Worker 已关闭");
        const value = await dispatch(op, args);
        port.postMessage({ id, ok: true, value });
        if (stopped) port.close();
      } catch (error) {
        port.postMessage({ id, ok: false, error: {
          name: error?.name || "Error", message: error?.message || String(error),
          code: error?.code, retryable: error?.retryable,
        } });
        if (stopped) port.close();
      }
    })).catch(() => { port.close(); });
  });
}
if (parentPort && workerData?.slatesyncStorage) startStorageWorker(parentPort);

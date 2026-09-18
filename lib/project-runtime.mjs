// Own one shared SQLite connection per project, including during initialization.
// Leases protect complete asynchronous operations; idle contexts are bounded and
// can be reopened. Main/Worker callers must not retain an unleased get() result.
import { createDiagnosticsStore } from "./diagnostics.mjs";
import { createScenarioStore } from "./scenario/store.mjs";
import { createTaskStore } from "./task-store.mjs";
import { closeSlateDatabase, openSlateDatabase, SQLITE_FILENAMES } from "./sqlite-store.mjs";

export function createProjectRuntime(projectLibrary, options = {}) {
  const entries = new Map();
  const maxIdle = options.maxIdle ?? 1;
  const idleMs = options.idleMs ?? 60_000;
  let closingAll = null;
  let sequence = 0;

  const busy = () => Object.assign(new Error("项目运行时正在关闭，请稍后重试"), { code: "PROJECT_BUSY" });
  async function dispose(context) {
    // Even failed migrations must release the unique owner, not leak its handle.
    try {
      const results = await Promise.allSettled([
        context.taskStore?.close(), context.scenarioStore?.close(), context.diagnostics?.close(),
      ]);
      const failure = results.find((result) => result.status === "rejected");
      if (failure) throw failure.reason;
    } finally { if (context.db.open) closeSlateDatabase(context.db); }
  }

  function makeEntry(id) {
    const entry = { leases: 0, timer: null, idleOrder: 0, drains: [], closing: null, promise: null };
    // Register before any await: concurrent first callers share this promise.
    entries.set(id, entry);
    entry.promise = (async () => {
      const row = await projectLibrary.getProjectRow(id, { allowArchived: true });
      const { db } = openSlateDatabase(row.directoryPath, { kind: "project", filename: SQLITE_FILENAMES.project });
      const context = { db };
      try {
        const shared = { filename: SQLITE_FILENAMES.project, db };
        context.taskStore = createTaskStore(row.directoryPath, shared);
        context.scenarioStore = createScenarioStore(row.directoryPath, { ...shared, matching: options.matching });
        context.diagnostics = createDiagnosticsStore(row.directoryPath, shared);
        // Injected store close only awaits initialization, leaving db owned here.
        await Promise.all([context.taskStore.close(), context.scenarioStore.close(), context.diagnostics.close()]);
        // Migration can add tasks and invalidate recognition defaults. Publish
        // the opening summary only after those stores have finished initializing.
        context.project = await projectLibrary.summarizeProjectRow(row, { db, includeSettings: true });
        return context;
      } catch (error) {
        await dispose(context).catch(() => {});
        throw error;
      }
    })();
    entry.promise.catch(() => { if (entries.get(id) === entry) entries.delete(id); });
    return entry;
  }

  function closeEntry(id, entry) {
    if (entry.closing) return entry.closing;
    clearTimeout(entry.timer);
    entry.closing = (async () => {
      if (entry.leases) await new Promise((resolve) => entry.drains.push(resolve));
      let context;
      try { context = await entry.promise; } catch { return; }
      await dispose(context);
    })().finally(() => { if (entries.get(id) === entry) entries.delete(id); });
    return entry.closing;
  }

  async function releaseEntry(id, entry) {
    entry.leases -= 1;
    if (entry.leases) return;
    entry.drains.splice(0).forEach((resolve) => resolve());
    if (entry.closing || entries.get(id) !== entry) return;
    entry.idleOrder = ++sequence;
    entry.timer = setTimeout(() => {
      void closeEntry(id, entry).catch((error) => options.onError?.(error));
    }, idleMs);
    entry.timer.unref?.();
    const idle = [...entries].filter(([, value]) => !value.leases && !value.closing)
      .sort((a, b) => a[1].idleOrder - b[1].idleOrder);
    await Promise.all(idle.slice(0, Math.max(0, idle.length - maxIdle)).map(([key, value]) => closeEntry(key, value)));
  }

  const runtime = {
    async acquire(id, { allowArchived = false, refreshProject = true } = {}) {
      if (closingAll) throw busy();
      let entry = entries.get(id);
      if (entry?.closing) throw busy();
      const initializedHere = !entry;
      entry ??= makeEntry(id);
      clearTimeout(entry.timer);
      entry.leases += 1;
      let released = false;
      const release = async () => { if (!released) { released = true; await releaseEntry(id, entry); } };
      try {
        const context = await entry.promise;
        // Archive/settings checks remain per request even when initialization was shared.
        const row = await projectLibrary.getProjectRow(id, { allowArchived });
        // Nested store leases still validate access, but need no expensive task summary.
        if (refreshProject && !initializedHere) context.project = await projectLibrary.summarizeProjectRow(row, { db: context.db, includeSettings: true });
        return { context, release };
      } catch (error) { await release(); throw error; }
    },
    async get(id, options) {
      const lease = await runtime.acquire(id, options);
      try { return lease.context; } finally { await lease.release(); }
    },
    async closeProject(id) {
      const entry = entries.get(id);
      if (entry) await closeEntry(id, entry);
    },
    close() {
      if (!closingAll) {
        closingAll = Promise.allSettled([...entries].map(([id, entry]) => closeEntry(id, entry)))
          .then((results) => {
            const failure = results.find((result) => result.status === "rejected");
            if (failure) throw failure.reason;
          }).finally(() => { closingAll = null; });
      }
      return closingAll;
    },
    // Aggregate diagnostics only; never expose SQLite handles or project payloads.
    stats() {
      return { contexts: entries.size, leases: [...entries.values()].reduce((n, entry) => n + entry.leases, 0),
        idle: [...entries.values()].filter((entry) => !entry.leases && !entry.closing).length };
    },
  };
  return runtime;
}

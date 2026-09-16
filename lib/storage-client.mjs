// Main-side async facades. The worker is the only persistence owner; an unknown
// write outcome is surfaced, never replayed after a crash or transport failure.
import { Worker } from "node:worker_threads";
import { LIBRARY_METHODS, STORE_METHODS, storageError } from "./storage-protocol.mjs";

export function createStorageClient({ workerFactory = () => new Worker(new URL("./storage-worker.mjs", import.meta.url), {
  workerData: { slatesyncStorage: true },
}), getMatching } = {}) {
  const worker = workerFactory();
  const pending = new Map();
  let sequence = 0;
  let failure = null;
  let stopping = false;
  let closePromise;
  let activeLeases = 0;
  const leaseDrains = [];
  const finishLease = () => {
    activeLeases -= 1;
    if (!activeLeases) leaseDrains.splice(0).forEach((resolve) => resolve());
  };
  let resolveExit;
  const exited = new Promise((resolve) => { resolveExit = resolve; });
  function fail(error) {
    failure ??= error;
    for (const request of pending.values()) request.reject(failure);
    pending.clear();
    leaseDrains.splice(0).forEach((resolve) => resolve());
  }
  worker.on("error", (error) => fail(storageError(error.message)));
  worker.on("exit", (code) => {
    if (!stopping || code !== 0 || pending.size) fail(storageError(`存储 Worker 已退出 (${code})；未确认的写入不会自动重试`));
    resolveExit();
  });
  worker.on("message", (message) => {
    const request = pending.get(message.id);
    if (!request) return;
    pending.delete(message.id);
    if (message.ok) request.resolve(message.value);
    else request.reject(Object.assign(new Error(message.error.message), message.error));
  });
  function send(op, args = [], shutdown = false) {
    if (failure) return Promise.reject(failure);
    if (stopping && !shutdown) return Promise.reject(storageError("存储正在关闭"));
    const id = ++sequence;
    return new Promise((resolve, reject) => {
      pending.set(id, { resolve, reject });
      try { worker.postMessage({ id, op, args }); }
      catch (error) { pending.delete(id); reject(error); }
    });
  }
  function contextFacade(projectId, options, project) {
    const context = { project };
    for (const [store, methods] of Object.entries(STORE_METHODS)) {
      context[store] = Object.fromEntries(methods.map((method) => [method, async (...args) => {
        // Functions cannot cross structured clone. Preserve per-observation hot
        // workflow settings by sending just the resolved matching snapshot.
        if (store === "scenarioStore" && method === "matchAndSave" && getMatching) {
          return send("store", [projectId, options, store, method, args, { matching: await getMatching() }]);
        }
        return send("store", [projectId, options, store, method, args]);
      }]));
    }
    return context;
  }
  const projectLibrary = Object.fromEntries(LIBRARY_METHODS.map((method) => [method, (...args) => send("library", [method, args])]));
  const projectRuntime = {
    async get(id, options = {}) { return contextFacade(id, options, await send("context", [id, options])); },
    async acquire(id, options = {}) {
      if (stopping || failure) throw failure || storageError("存储正在关闭");
      activeLeases += 1;
      try {
        const { token, project } = await send("acquire", [id, options]);
        let releasePromise;
        return { context: contextFacade(id, options, project), release: () => {
          // Releases remain admissible while close waits for existing leases.
          releasePromise ??= send("release", [token], true).finally(finishLease);
          return releasePromise;
        } };
      } catch (error) { finishLease(); throw error; }
    },
    closeProject: (id) => send("closeProject", [id]),
    close: () => send("closeRuntime"),
  };
  return {
    projectLibrary, projectRuntime,
    initialize: (config) => send("initialize", [config]),
    exportLibrary: (target) => send("exportLibrary", [target]),
    validateLibrary: (path) => send("validateLibrary", [path]),
    stats: () => send("stats"),
    close() {
      if (!closePromise) {
        // Queue the shutdown behind already accepted commands. Only a crash
        // terminates pending writes; normal exit waits for durable completion.
        stopping = true;
        closePromise = (async () => {
          if (activeLeases && !failure) await new Promise((resolve) => leaseDrains.push(resolve));
          await send("shutdown", [], true);
          await exited;
          if (failure) throw failure;
        })();
      }
      return closePromise;
    },
  };
}

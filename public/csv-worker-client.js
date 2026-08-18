// Small request/response client for the long-lived CSV module Worker.
// A single Worker retains the decoded Resolve table between load and export.
export function createCsvWorkerClient({
  WorkerClass = globalThis.Worker,
  workerUrl = new URL("./csv-worker.js", import.meta.url),
} = {}) {
  if (typeof WorkerClass !== "function") return null;

  let worker;
  try {
    worker = new WorkerClass(workerUrl, { type: "module" });
  } catch {
    // Older/restricted runtimes keep full functionality through the renderer
    // fallback instead of failing application startup.
    return null;
  }
  const pending = new Map();
  let nextId = 1;
  let failed = false;

  worker.addEventListener("message", (event) => {
    const { id, result, error } = event.data || {};
    const request = pending.get(id);
    if (!request) return;
    pending.delete(id);
    if (error) {
      const taskError = new Error(error);
      taskError.csvWorkerTask = true;
      request.reject(taskError);
    } else {
      request.resolve(result);
    }
  });

  worker.addEventListener("error", (event) => {
    failed = true;
    const error = new Error(event?.message || "CSV 后台 Worker 不可用");
    for (const request of pending.values()) request.reject(error);
    pending.clear();
  });

  return {
    request(task, transfer = []) {
      if (failed) return Promise.reject(new Error("CSV 后台 Worker 不可用"));
      const id = nextId;
      nextId += 1;
      return new Promise((resolve, reject) => {
        pending.set(id, { resolve, reject });
        try {
          worker.postMessage({ id, task }, transfer);
        } catch (error) {
          pending.delete(id);
          reject(error);
        }
      });
    },
    terminate() {
      failed = true;
      worker.terminate();
      const error = new Error("CSV 后台 Worker 已停止");
      for (const request of pending.values()) request.reject(error);
      pending.clear();
    },
  };
}

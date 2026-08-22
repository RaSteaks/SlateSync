import assert from "node:assert/strict";
import test from "node:test";
import { createCsvWorkerClient } from "../public/csv-worker-client.js";

class FakeWorker {
  listeners = new Map();

  addEventListener(type, listener) {
    this.listeners.set(type, listener);
  }

  postMessage({ id, task }) {
    queueMicrotask(() => {
      this.listeners.get("message")?.({
        data: task.fail
          ? { id, error: "任务数据无效" }
          : { id, result: { ready: true } },
      });
    });
  }

  terminate() {}
}

test("CSV Worker client resolves responses and identifies task errors", async () => {
  const client = createCsvWorkerClient({
    WorkerClass: FakeWorker,
    workerUrl: "worker.js",
  });
  assert.deepEqual(await client.request({ type: "ready" }), { ready: true });

  await assert.rejects(
    client.request({ type: "ready", fail: true }),
    (error) => error.message === "任务数据无效" && error.csvWorkerTask === true,
  );
  client.terminate();
});

test("CSV Worker client allows a renderer fallback when construction fails", () => {
  class BrokenWorker {
    constructor() {
      throw new Error("worker unavailable");
    }
  }
  assert.equal(
    createCsvWorkerClient({ WorkerClass: BrokenWorker, workerUrl: "worker.js" }),
    null,
  );
});

// Module Worker entry point for large Resolve CSV operations.
import { createCsvTaskProcessor } from "./csv-background-tasks.js";

const CSV_WORKER_PROTOCOL_VERSION = 1;
const processCsvTask = createCsvTaskProcessor();

self.addEventListener("message", (event) => {
  const { id, version, task } = event.data || {};
  try {
    // The frozen legacy client predates the envelope marker and omits it;
    // modern callers must send v1, so compatibility stays additive here.
    if (version !== undefined && version !== CSV_WORKER_PROTOCOL_VERSION) {
      throw new Error(`CSV Worker 协议版本不匹配：${String(version || "missing")}`);
    }
    const result = processCsvTask(task);
    const bytes = result?.bytes;
    if (bytes instanceof Uint8Array) {
      // Transfer ownership of the exact byte range so the renderer receives
      // binary data without expanding it into a memory-heavy number array.
      const data = bytes.byteOffset === 0 && bytes.byteLength === bytes.buffer.byteLength
        ? bytes.buffer
        : bytes.buffer.slice(bytes.byteOffset, bytes.byteOffset + bytes.byteLength);
      self.postMessage({ id, result: { ...result, bytes: data } }, [data]);
      return;
    }
    self.postMessage({ id, result });
  } catch (error) {
    self.postMessage({
      id,
      error: error?.message || "CSV 后台任务失败",
    });
  }
});

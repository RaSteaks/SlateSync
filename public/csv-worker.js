// Module Worker entry point for large Resolve CSV operations.
import { createCsvTaskProcessor } from "./csv-background-tasks.js";

const processCsvTask = createCsvTaskProcessor();

self.addEventListener("message", (event) => {
  const { id, task } = event.data || {};
  try {
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

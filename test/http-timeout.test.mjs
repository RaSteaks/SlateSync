import assert from "node:assert/strict";
import test from "node:test";

import {
  createAbortDeadline,
  readResponseTextWithDeadline,
} from "../lib/http-timeout.mjs";

test("response body reads reject when the shared deadline expires", async () => {
  const deadline = createAbortDeadline(10, null, "测试请求超时");

  try {
    await assert.rejects(
      readResponseTextWithDeadline(
        { text: () => new Promise(() => {}) },
        deadline.signal,
      ),
      (error) =>
        error?.name === "TimeoutError" && error.message === "测试请求超时",
    );
    assert.equal(deadline.didTimeout(), true);
  } finally {
    deadline.cleanup();
  }
});

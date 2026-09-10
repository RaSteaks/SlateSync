// Shared deadline helpers for Main-side HTTP clients.
//
// Fetch resolves before a response body is consumed. Keeping the deadline
// controller alive through response.text() prevents a gateway that stalls
// after headers from bypassing the caller's timeout and retry policy.

export function createAbortDeadline(timeoutMs, parentSignal = null, message = "请求超时") {
  const duration = Math.max(0, Number(timeoutMs) || 0);
  const controller = new AbortController();
  let timedOut = false;
  let timer = null;
  let removeParentAbort = () => {};

  const timeout = () => {
    timedOut = true;
    controller.abort(createTimeoutError(message));
  };
  timer = setTimeout(timeout, duration);

  if (parentSignal) {
    const abortFromParent = () => {
      controller.abort(parentSignal.reason || createAbortError("请求已取消"));
    };
    if (parentSignal.aborted) abortFromParent();
    else {
      parentSignal.addEventListener("abort", abortFromParent, { once: true });
      removeParentAbort = () => parentSignal.removeEventListener("abort", abortFromParent);
    }
  }

  return {
    signal: controller.signal,
    didTimeout: () => timedOut,
    cleanup() {
      clearTimeout(timer);
      removeParentAbort();
    },
  };
}

export async function readResponseTextWithDeadline(response, signal) {
  const bodyPromise = Promise.resolve().then(() => response.text());
  if (!signal) return bodyPromise;

  let removeAbort = () => {};
  const abortPromise = new Promise((_, reject) => {
    const rejectAborted = () => {
      reject(signal.reason || createAbortError("请求已取消"));
    };
    if (signal.aborted) rejectAborted();
    else {
      signal.addEventListener("abort", rejectAborted, { once: true });
      removeAbort = () => signal.removeEventListener("abort", rejectAborted);
    }
  });

  try {
    return await Promise.race([bodyPromise, abortPromise]);
  } finally {
    removeAbort();
  }
}

function createTimeoutError(message) {
  if (typeof DOMException === "function") return new DOMException(message, "TimeoutError");
  const error = new Error(message);
  error.name = "TimeoutError";
  return error;
}

function createAbortError(message) {
  if (typeof DOMException === "function") return new DOMException(message, "AbortError");
  const error = new Error(message);
  error.name = "AbortError";
  return error;
}


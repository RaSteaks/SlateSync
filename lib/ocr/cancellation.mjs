// Shared recognition-cancellation contract for the orchestration client and
// local OCR runners. Keeping this separate prevents an aborted OCR subprocess
// from being mistaken for an optional-engine failure and falling through to a
// paid model request.

export function throwIfRecognitionCanceled(signal) {
  if (signal?.aborted) throw recognitionCanceledError();
}

export function isRecognitionCanceled(error, signal) {
  return Boolean(
    signal?.aborted || error?.code === "RECOGNITION_CANCELED",
  );
}

export function recognitionCanceledError() {
  const error = new Error("识别已停止");
  error.name = "AbortError";
  error.code = "RECOGNITION_CANCELED";
  error.status = 499;
  return error;
}

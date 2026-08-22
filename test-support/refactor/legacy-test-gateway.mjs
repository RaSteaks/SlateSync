// Gate-00 froze two Node fixtures before the typed gateway existed. They set a
// fake electronAPI directly; this process-only adapter converts that fake into
// the sole slateSync surface without adding an electronAPI read to production.
// It is not included by electron-builder and is removed with the legacy adapter.
let legacyFake;

function result(operation) {
  return Promise.resolve().then(operation).then(
    (data) => ({ ok: true, data }),
    (error) => ({
      ok: false,
      error: {
        code: typeof error?.code === "string" ? error.code : "UNKNOWN",
        message: typeof error?.message === "string" ? error.message : "未知错误",
        retryable: Boolean(error?.retryable),
      },
    }),
  );
}

Object.defineProperty(globalThis, "electronAPI", {
  configurable: true,
  get: () => legacyFake,
  set(value) {
    legacyFake = value;
    globalThis.slateSync = {
      files: {
        save: ({ defaultFilename, data }) => result(() => value.saveFile(defaultFilename, data)),
      },
      recognition: {
        run: (request) => result(() => value.recognize(request)),
        onProgress(listener) {
          value.onRecognitionProgress(listener);
          let active = true;
          return () => {
            if (!active) return;
            active = false;
            value.removeRecognitionProgressListener();
          };
        },
      },
    };
  },
});

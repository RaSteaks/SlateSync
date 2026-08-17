// Debounced, serialized autosave for editable task results.
// Snapshots are captured only when a save starts, keeping keystrokes cheap while
// ensuring an older request can never overwrite a newer pending edit.
export function createTaskAutosave({
  capture,
  save,
  onStatus = () => {},
  delayMs = 500,
  setTimer = globalThis.setTimeout,
  clearTimer = globalThis.clearTimeout,
}) {
  let timer = null;
  let changeVersion = 0;
  let savedVersion = 0;
  let worker = null;
  let flushRequested = false;
  let failed = false;

  function clearScheduled() {
    if (timer == null) return;
    clearTimer(timer);
    timer = null;
  }

  function scheduleTimer() {
    clearScheduled();
    timer = setTimer(() => {
      timer = null;
      void commit(false);
    }, delayMs);
  }

  function commit(flushAll) {
    clearScheduled();
    if (flushAll) flushRequested = true;
    if (!worker) {
      // Every caller shares one worker. This prevents two simultaneous flushes
      // from both starting a save after the same older request completes.
      worker = runWorker().finally(() => {
        worker = null;
      });
    }
    return worker;
  }

  async function runWorker() {
    while (savedVersion !== changeVersion) {
      const targetVersion = changeVersion;
      const snapshot = capture();
      if (!snapshot) {
        savedVersion = targetVersion;
        break;
      }
      failed = false;
      onStatus({ state: "saving", version: targetVersion });
      try {
        await save(snapshot);
        savedVersion = targetVersion;
      } catch (error) {
        failed = true;
        flushRequested = false;
        onStatus({ state: "error", version: targetVersion, error });
        return false;
      }

      if (savedVersion === changeVersion) {
        flushRequested = false;
        onStatus({ state: "saved", version: savedVersion });
        return true;
      }
      onStatus({ state: "dirty", version: changeVersion });
      if (!flushRequested) {
        scheduleTimer();
        return true;
      }
    }
    flushRequested = false;
    return true;
  }

  return {
    markDirty() {
      changeVersion += 1;
      failed = false;
      onStatus({ state: "dirty", version: changeVersion });
      scheduleTimer();
    },
    flush() {
      return commit(true);
    },
    retry() {
      failed = false;
      onStatus({ state: "dirty", version: changeVersion });
      return commit(true);
    },
    reset() {
      clearScheduled();
      changeVersion = 0;
      savedVersion = 0;
      flushRequested = false;
      failed = false;
      onStatus({ state: "idle", version: 0 });
    },
    hasPending() {
      return savedVersion !== changeVersion || Boolean(worker);
    },
  };
}

import assert from "node:assert/strict";
import test from "node:test";

import { createTaskAutosave } from "../public/task-autosave.js";

function deferred() {
  let resolve;
  let reject;
  const promise = new Promise((resolvePromise, rejectPromise) => {
    resolve = resolvePromise;
    reject = rejectPromise;
  });
  return { promise, resolve, reject };
}

function fakeScheduler() {
  let nextId = 0;
  const callbacks = new Map();
  return {
    setTimer(callback) {
      nextId += 1;
      callbacks.set(nextId, callback);
      return nextId;
    },
    clearTimer(id) {
      callbacks.delete(id);
    },
    runLatest() {
      const latest = [...callbacks.entries()].at(-1);
      if (!latest) return;
      callbacks.delete(latest[0]);
      latest[1]();
    },
  };
}

test("autosave debounces edits and saves the newest immutable snapshot", async () => {
  const scheduler = fakeScheduler();
  const saves = [];
  let value = "first";
  const autosave = createTaskAutosave({
    capture: () => ({ value }),
    save: async (snapshot) => saves.push(snapshot),
    setTimer: scheduler.setTimer,
    clearTimer: scheduler.clearTimer,
  });

  autosave.markDirty();
  value = "latest";
  autosave.markDirty();
  scheduler.runLatest();
  await autosave.flush();

  assert.deepEqual(saves, [{ value: "latest" }]);
  assert.equal(autosave.hasPending(), false);
});

test("autosave serializes an in-flight save and keeps only the latest pending version", async () => {
  const firstSave = deferred();
  const saves = [];
  let value = "one";
  const autosave = createTaskAutosave({
    capture: () => ({ value }),
    save: async (snapshot) => {
      saves.push(snapshot);
      if (saves.length === 1) await firstSave.promise;
    },
  });

  autosave.markDirty();
  const firstFlush = autosave.flush();
  await Promise.resolve();
  value = "two";
  autosave.markDirty();
  value = "three";
  autosave.markDirty();
  const secondFlush = autosave.flush();

  assert.deepEqual(saves, [{ value: "one" }]);
  firstSave.resolve();
  assert.equal(await firstFlush, true);
  assert.equal(await secondFlush, true);
  assert.deepEqual(saves, [{ value: "one" }, { value: "three" }]);
  assert.equal(autosave.hasPending(), false);
});

test("autosave reports failure, remains pending, and retries the same edit", async () => {
  const statuses = [];
  let attempts = 0;
  const autosave = createTaskAutosave({
    capture: () => ({ value: "edited" }),
    save: async () => {
      attempts += 1;
      if (attempts === 1) throw new Error("disk full");
    },
    onStatus: (status) => statuses.push(status.state),
  });

  autosave.markDirty();
  assert.equal(await autosave.flush(), false);
  assert.equal(autosave.hasPending(), true);
  assert.equal(statuses.at(-1), "error");

  assert.equal(await autosave.retry(), true);
  assert.equal(attempts, 2);
  assert.equal(autosave.hasPending(), false);
  assert.equal(statuses.at(-1), "saved");
});

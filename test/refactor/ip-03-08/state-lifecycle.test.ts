import { describe, expect, it, vi } from "vitest";
import { createOperationGuard } from "../../../src/renderer/services/operation-guard";
import { createTaskAutosave } from "../../../src/renderer/services/task-autosave";
import { useRecognitionStore } from "../../../src/renderer/state/recognition-store";

describe("modern lifecycle boundaries", () => {
  it("ignores stale recognition progress and never regresses capped progress", () => {
    const store = useRecognitionStore.getState();
    store.reset();
    store.start(7, "project-1", 3);
    store.progress(6, { phase: "stale", percent: 99, completed: 3, total: 3, message: "late" });
    expect(useRecognitionStore.getState().percent).toBe(0);
    store.progress(7, { phase: "running", percent: 62, completed: 1, total: 3, message: "one" });
    store.progress(7, { phase: "running", percent: 12, completed: 1, total: 3, message: "late lower" });
    expect(useRecognitionStore.getState().percent).toBe(62);
    // A later provider phase must not erase the OCR fallback warning.
    store.progress(7, { phase: "ocr", percent: 35, message: "图片识别", warning: "OCR fallback" });
    store.progress(7, { phase: "primary", percent: 40, message: "模型识别" });
    expect(useRecognitionStore.getState().warning).toBe("OCR fallback");
    store.complete(6, {} as never);
    expect(useRecognitionStore.getState().running).toBe(true);
    store.reset();
  });

  it("invalidates superseded work without exposing cancellation as a public API", () => {
    const guard = createOperationGuard();
    const first = guard.start();
    const second = guard.start();
    expect(guard.isCurrent(first)).toBe(false);
    expect(guard.isCurrent(second)).toBe(true);
    guard.invalidate();
    expect(guard.isCurrent(second)).toBe(false);
  });

  it("serializes one save and retains only the newest pending snapshot", async () => {
    let releaseFirst!: () => void;
    const first = new Promise<void>((resolve) => { releaseFirst = resolve; });
    const saved: string[] = [];
    const onState = vi.fn();
    const autosave = createTaskAutosave({
      capture: () => ({ value: "captured" }),
      save: async (task) => {
        saved.push(String(task.value));
        if (saved.length === 1) await first;
      },
      onState,
      delayMs: 0,
    });
    autosave.markDirty();
    await Promise.resolve();
    autosave.markDirty();
    releaseFirst();
    await new Promise((resolve) => setTimeout(resolve, 5));
    expect(saved).toEqual(["captured"]);
    expect(onState).toHaveBeenCalled();
    autosave.reset();
  });

  it("serializes an in-flight old task before saving a new task scope", async () => {
    let releaseOld!: () => void;
    const oldWrite = new Promise<void>((resolve) => { releaseOld = resolve; });
    const saved: string[] = [];
    const states: string[] = [];
    const autosave = createTaskAutosave({
      capture: () => null,
      save: async (task) => {
        saved.push(String(task.filename));
        if (task.filename === "old") await oldWrite;
      },
      onState: (state) => states.push(state),
      delayMs: 0,
    });

    autosave.markDirty({ filename: "old" });
    const oldFlush = autosave.flush();
    await Promise.resolve();
    autosave.reset();
    autosave.markDirty({ filename: "new" });
    const newFlush = autosave.flush();
    expect(saved).toEqual(["old"]);
    releaseOld();
    expect(await oldFlush).toBe(true);
    expect(await newFlush).toBe(true);
    expect(saved).toEqual(["old", "new"]);
    expect(states.at(-1)).toBe("saved");
  });

  it("retains a failed snapshot for explicit retry", async () => {
    let attempts = 0;
    const states: string[] = [];
    const autosave = createTaskAutosave({
      capture: () => null,
      save: async () => { attempts += 1; if (attempts === 1) throw new Error("offline"); },
      onState: (state) => states.push(state),
      delayMs: 0,
    });
    autosave.markDirty({ filename: "retry" });
    expect(await autosave.flush()).toBe(false);
    expect(states.at(-1)).toBe("error");
    expect(await autosave.retry()).toBe(true);
    expect(attempts).toBe(2);
    expect(states.at(-1)).toBe("saved");
  });
});

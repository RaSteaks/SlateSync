import { describe, expect, it, vi } from "vitest";
import { createOperationGuard } from "../../../src/renderer/services/operation-guard";
import { createTaskAutosave } from "../../../src/renderer/services/task-autosave";
import { useRecognitionStore } from "../../../src/renderer/state/recognition-store";
import { useTaskStore } from "../../../src/renderer/state/task-store";

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

  it("keeps the task-bound recognition snapshot across a log detour", () => {
    const store = useRecognitionStore.getState();
    store.reset();
    // The same marker also carries project/task identity during the brief
    // autosave/preparation window before start() has published running=true.
    store.markWorkspaceHandoff("project-1", "task-1");
    expect(useRecognitionStore.getState().projectId).toBe("project-1");
    expect(useRecognitionStore.getState().taskId).toBe("task-1");
    store.reset();
    store.start(11, "project-1", 4);
    store.setTaskId("task-1");
    store.progress(11, { phase: "primary", percent: 48, completed: 2, total: 4, message: "第 2 页" });
    store.markWorkspaceHandoff();

    const handoff = useRecognitionStore.getState();
    expect(handoff.taskId).toBe("task-1");
    expect(handoff.resumeOnWorkspace).toBe(true);
    expect(handoff.percent).toBe(48);

    // Completion must retain the handoff marker until Workspace rehydrates the
    // authoritative saved task; resetting then closes the one-shot handoff.
    store.complete(11, { taskId: "task-1", pageCount: 4, result: { sheetTitle: null, records: [], warnings: [] } } as never);
    expect(useRecognitionStore.getState().resumeOnWorkspace).toBe(true);
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

  it("exposes the Main-assigned task ID after an autosave", async () => {
    const autosave = createTaskAutosave({
      capture: () => null,
      save: async () => "task-from-main",
      onState: () => undefined,
      delayMs: 0,
    });

    // Recognition can continue after Workspace unmounts, so its request must
    // read the ID from the save result rather than from a UI-owned activeId.
    autosave.markDirty({ filename: "draft" });
    expect(await autosave.flush()).toBe(true);
    expect(autosave.getLastSavedTaskId()).toBe("task-from-main");
    autosave.reset();
    expect(autosave.getLastSavedTaskId()).toBeNull();
  });

  it("records which project the task rail items belong to", () => {
    const store = useTaskStore.getState();
    store.clear();
    store.setItems([], "project-1");
    expect(useTaskStore.getState().loadedProjectId).toBe("project-1");
    store.clear();
    expect(useTaskStore.getState().loadedProjectId).toBeNull();
  });
});

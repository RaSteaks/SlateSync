// @vitest-environment jsdom
import { afterEach, describe, expect, it, vi } from "vitest";
import { acquireWorkspaceOperation, isWorkspaceBusy } from "../../src/renderer/services/workspace-operation";
import { useGlobalSettingsStore, useProjectStore, useRecognitionStore, useSettingsStore, useTaskStore, useUiStore } from "../../src/renderer/state";
import { saveGlobalSettingsChanges } from "../../src/renderer/features/settings/globalSettingsActions";
import type { GlobalSettingsData } from "../../src/shared/contracts/index.js";

const saved = { values: { MAX_BODY_MB: "80", PADDLEOCR_PYTHON: "/old/python" }, overrides: [], keyConfigured: {}, restartRequired: false } as GlobalSettingsData;
afterEach(() => {
  useTaskStore.setState({ operation: null });
  useRecognitionStore.getState().reset();
  useGlobalSettingsStore.getState().clear();
  useSettingsStore.getState().clearProject();
  useProjectStore.setState({ current: null });
  useUiStore.setState({ toast: null });
});

describe("workspace action ownership", () => {
  it("blocks duplicate starts and task changes before running, through cancel cleanup", () => {
    const run = acquireWorkspaceOperation("recognition", "p")!;
    expect(useRecognitionStore.getState().running).toBe(false);
    for (const kind of ["recognition", "new", "switch", "delete", "transfer"] as const) {
      expect(acquireWorkspaceOperation(kind, "p")).toBeNull();
    }
    // run() may settle first; cancel still owns Main cleanup and the lease.
    run.retain();
    run.release();
    expect(isWorkspaceBusy()).toBe(true);
    expect(acquireWorkspaceOperation("new", "p")).toBeNull();
    run.release();
    const next = acquireWorkspaceOperation("new", "p")!;
    expect(next).not.toBeNull();
    useTaskStore.getState().clear();
    expect(isWorkspaceBusy()).toBe(true);
    next.release();
    expect(isWorkspaceBusy()).toBe(false);
  });

  it("serializes loading with recognition and ignores an old lease release", () => {
    const load = acquireWorkspaceOperation("switch", "p")!;
    const oldId = useTaskStore.getState().operation!.id;
    expect(acquireWorkspaceOperation("recognition", "p")).toBeNull();
    load.release();
    const run = acquireWorkspaceOperation("recognition", "p")!;
    useTaskStore.getState().endOperation(oldId);
    expect(isWorkspaceBusy()).toBe(true);
    run.release();
  });
});

describe("settings write ownership", () => {
  it("locks draft edits, preserves failed drafts, and prevents duplicate requests", async () => {
    const store = useGlobalSettingsStore.getState();
    store.adoptServerSnapshot(saved);
    store.setDraftValue("MAX_BODY_MB", "100");
    let reject!: (error: Error) => void;
    const save = vi.fn(() => new Promise((_, no) => { reject = no; }));
    Object.defineProperty(window, "slateSync", { configurable: true, value: { settings: { getGlobalSettings: async () => ({ ok: true, data: saved }), saveGlobalSettings: save } } });
    const pending = saveGlobalSettingsChanges();
    store.setDraftValue("MAX_BODY_MB", "200");
    store.setDraftValues({ MAX_BODY_MB: "300" });
    store.discardDraft();
    expect(useGlobalSettingsStore.getState().draftValues.MAX_BODY_MB).toBe("100");
    expect(await saveGlobalSettingsChanges()).toBe(false);
    reject(new Error("offline"));
    expect(await pending).toBe(false);
    expect(save).toHaveBeenCalledTimes(1);
    expect(useGlobalSettingsStore.getState().dirtyKeys.has("MAX_BODY_MB")).toBe(true);
    expect(useGlobalSettingsStore.getState().mutationOwner).toBeNull();
    store.setDraftValue("MAX_BODY_MB", "200");
    expect(useGlobalSettingsStore.getState().draftValues.MAX_BODY_MB).toBe("200");
  });

  it("serializes OCR path writes while allowing unrelated draft edits", async () => {
    const store = useGlobalSettingsStore.getState();
    store.adoptServerSnapshot(saved);
    expect(store.beginMutation("install")).toBe(true);
    expect(await saveGlobalSettingsChanges()).toBe(false);
    store.setDraftValue("PADDLEOCR_PYTHON", "/later/python");
    store.setDraftValue("MAX_BODY_MB", "90");
    expect(useGlobalSettingsStore.getState().draftValues.PADDLEOCR_PYTHON).toBeUndefined();
    store.mergeSaved({ PADDLEOCR_PYTHON: "/installed/python" });
    store.endMutation("install");
    expect(useGlobalSettingsStore.getState().draftValues.MAX_BODY_MB).toBe("90");
    expect(useGlobalSettingsStore.getState().saved?.values.PADDLEOCR_PYTHON).toBe("/installed/python");
  });

  it("reports a committed save as successful if only configuration refresh fails", async () => {
    const store = useGlobalSettingsStore.getState();
    store.adoptServerSnapshot(saved);
    store.setDraftValue("MAX_BODY_MB", "100");
    Object.defineProperty(window, "slateSync", { configurable: true, value: {
      settings: { getGlobalSettings: async () => ({ ok: true, data: saved }), saveGlobalSettings: vi.fn(async () => ({ ok: true, data: { ...saved, values: { ...saved.values, MAX_BODY_MB: "100" } } })) },
      app: { getConfig: vi.fn(async () => { throw new Error("refresh failed"); }) },
    } });
    expect(await saveGlobalSettingsChanges()).toBe(true);
    expect(useGlobalSettingsStore.getState().saveState).toBe("saved");
    expect(useGlobalSettingsStore.getState().saveError).toBeNull();
    expect(useGlobalSettingsStore.getState().dirtyKeys.size).toBe(0);
    expect(useUiStore.getState().toast?.message).toContain("已保存");
    expect(useUiStore.getState().toast?.tone).toBe("warning");
  });
});

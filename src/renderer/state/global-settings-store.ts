import { create } from "zustand";
import type { GlobalSettingKey, GlobalSettingValues, GlobalSettingsData } from "../../shared/contracts/index.js";
import type { GlobalSettingsSlice } from "./types";

/** UI disabled state and programmatic edits use exactly the same write gate. */
export function isGlobalSettingLocked(state: GlobalSettingsSlice, key?: GlobalSettingKey): boolean {
  return state.saveState === "saving" || state.mutationOwner === "global"
    || (key === "PADDLEOCR_PYTHON" && (state.mutationOwner === "ocr" || state.mutationOwner === "install"));
}

function applyDraftValue(
  state: GlobalSettingsSlice,
  key: GlobalSettingKey,
  value: string,
): Partial<GlobalSettingsSlice> {
  if (isGlobalSettingLocked(state, key)) return state;
  const savedValue = state.saved?.values[key];
  const nextDraftValues = { ...state.draftValues };
  const nextDirtyKeys = new Set(state.dirtyKeys);
  if (savedValue !== undefined && savedValue === value) {
    // Reverting to the saved value must not keep counting as dirty, and an
    // untouched inherited default must never become a stored override.
    delete nextDraftValues[key];
    nextDirtyKeys.delete(key);
  } else {
    nextDraftValues[key] = value;
    nextDirtyKeys.add(key);
  }
  return {
    draftValues: nextDraftValues,
    dirtyKeys: nextDirtyKeys,
    // Editing after a save or failure restarts the visible save lifecycle.
    saveState: state.saveState === "saved" || state.saveState === "error" ? "idle" : state.saveState,
    saveError: null,
  };
}

const initialState = {
  mutationOwner: null as GlobalSettingsSlice["mutationOwner"],
  saved: null,
  draftValues: {} as Partial<GlobalSettingValues>,
  dirtyKeys: new Set<GlobalSettingKey>() as ReadonlySet<GlobalSettingKey>,
  fieldErrors: {} as Partial<Record<GlobalSettingKey, string>>,
  saveState: "idle" as const,
  saveError: null,
};

// Module-level singleton on purpose: the page header and the App-level route
// guard read this store without a mounted GlobalSettingsPage, and the draft
// survives route detours by design. Tests must reset it via clear().
export const useGlobalSettingsStore = create<GlobalSettingsSlice>((set, get) => ({
  ...initialState,
  beginMutation: (mutationOwner) => {
    if (get().mutationOwner || get().saveState === "saving") return false;
    set({ mutationOwner });
    return true;
  },
  endMutation: (owner) => set((state) => state.mutationOwner === owner ? { mutationOwner: null } : state),
  setDraftValue: (key, value) => set((state) => applyDraftValue(state, key, value)),
  setDraftValues: (patch) => set((state) => {
    let next: Partial<GlobalSettingsSlice> = {};
    for (const [key, value] of Object.entries(patch) as Array<[GlobalSettingKey, string]>) {
      // Reuse the single-key semantics per entry so batch patches (preset
      // copies, routing choices) honor the same revert-to-saved rules.
      next = applyDraftValue({ ...state, ...next }, key, value);
    }
    return next;
  }),
  clearDirtyKey: (key) => set((state) => {
    if (!state.dirtyKeys.has(key) && !(key in state.draftValues)) return state;
    const nextDraftValues = { ...state.draftValues };
    delete nextDraftValues[key];
    const nextDirtyKeys = new Set(state.dirtyKeys);
    nextDirtyKeys.delete(key);
    return { draftValues: nextDraftValues, dirtyKeys: nextDirtyKeys };
  }),
  adoptServerSnapshot: (saved) => set({
    saved,
    draftValues: {},
    dirtyKeys: new Set(),
    fieldErrors: {},
  }),
  mergeSaved: (values, overridesAdd) => set((state) => {
    if (!state.saved) return state;
    const nextSaved: GlobalSettingsData = {
      ...state.saved,
      values: { ...state.saved.values, ...values },
      overrides: overridesAdd?.length
        ? [...state.saved.overrides, ...overridesAdd.filter((key) => !state.saved?.overrides.includes(key))]
        : state.saved.overrides,
    };
    // Merged keys were persisted by an independent endpoint (OCR check or
    // one-click install); drop their drafts so the dirty count stays honest.
    const nextDraftValues = { ...state.draftValues };
    const nextDirtyKeys = new Set(state.dirtyKeys);
    for (const key of Object.keys(values) as GlobalSettingKey[]) {
      delete nextDraftValues[key];
      nextDirtyKeys.delete(key);
    }
    return { saved: nextSaved, draftValues: nextDraftValues, dirtyKeys: nextDirtyKeys };
  }),
  setKeyConfigured: (providerId, configured) => set((state) => {
    if (!state.saved) return state;
    return {
      saved: {
        ...state.saved,
        keyConfigured: { ...state.saved.keyConfigured, [providerId]: configured },
      },
    };
  }),
  discardDraft: () => set((state) => state.mutationOwner || state.saveState === "saving" ? state : {
    draftValues: {},
    dirtyKeys: new Set(),
    fieldErrors: {},
    saveState: "idle",
    saveError: null,
  }),
  setFieldError: (key, message) => set((state) => {
    const nextFieldErrors = { ...state.fieldErrors };
    if (message === null) delete nextFieldErrors[key];
    else nextFieldErrors[key] = message;
    return { fieldErrors: nextFieldErrors };
  }),
  setSaveState: (saveState) => set({ saveState }),
  setSaveError: (saveError) => set({ saveError }),
  clear: () => set({ ...initialState }),
}));

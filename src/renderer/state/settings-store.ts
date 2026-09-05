import { create } from "zustand";
import type { ProjectSettingsDraft, SettingsSlice } from "./types";

const projectInitialState = { projectId: null, baseline: null, draft: null, dirty: false, saving: false, saveError: null };
const normalized = (draft: ProjectSettingsDraft) => ({ ...draft, name: draft.name.trim(), description: draft.description.trim() });

export const useSettingsStore = create<SettingsSlice>((set) => ({
  ocr: null,
  setOcr: (ocr) => set({ ocr }),
  ...projectInitialState,
  // Background config refreshes may replace project objects. A dirty draft is
  // owned by project identity, not by the lifetime of a particular page render.
  hydrateProject: (projectId, draft) => set((state) => {
    if (state.projectId === projectId && (state.dirty || state.saving)) return state;
    return { ...projectInitialState, projectId, baseline: structuredClone(draft), draft: structuredClone(draft) };
  }),
  patchProject: (patch) => set((state) => {
    if (!state.draft || !state.baseline || state.saving) return state;
    const draft = { ...state.draft, ...patch };
    return { draft, dirty: JSON.stringify(normalized(draft)) !== JSON.stringify(normalized(state.baseline)), saveError: null };
  }),
  discardProject: () => set((state) => state.saving ? state : { draft: state.baseline && structuredClone(state.baseline), dirty: false, saveError: null }),
  clearProject: () => set(projectInitialState),
}));

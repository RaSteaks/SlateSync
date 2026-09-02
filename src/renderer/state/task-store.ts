import { create } from "zustand";
import type { TaskSlice } from "./types";

export const useTaskStore = create<TaskSlice>((set) => ({
  items: [],
  loadedProjectId: null,
  activeId: null,
  active: null,
  loading: false,
  saveState: "idle",
  error: null,
  setItems: (items, loadedProjectId = null) => set({ items: [...items], loadedProjectId }),
  setActive: (activeId, active) => set({ activeId, active }),
  setLoading: (loading) => set({ loading }),
  setSaveState: (saveState) => set({ saveState }),
  setError: (error) => set({ error }),
  clear: () => set({ items: [], loadedProjectId: null, activeId: null, active: null, loading: false, saveState: "idle", error: null }),
}));

import { create } from "zustand";
import type { TaskSlice } from "./types";
import { useRecognitionStore } from "./recognition-store";

let operationSequence = 0;

export const useTaskStore = create<TaskSlice>((set, get) => ({
  operation: null,
  beginOperation: (kind, projectId) => {
    if (get().operation || useRecognitionStore.getState().running) return null;
    const id = ++operationSequence;
    set({ operation: { id, kind, projectId } });
    return id;
  },
  // Clearing task contents does not release a request's lease. Only its owner
  // may release it, after every asynchronous continuation has settled.
  endOperation: (id) => set((state) => state.operation?.id === id ? { operation: null } : state),
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

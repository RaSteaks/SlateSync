import { create } from "zustand";
import type { TaskSlice } from "./types";

export const useTaskStore = create<TaskSlice>((set) => ({
  items: [],
  activeId: null,
  active: null,
  loading: false,
  saveState: "idle",
  error: null,
  setItems: (items) => set({ items: [...items] }),
  setActive: (activeId, active) => set({ activeId, active }),
  setLoading: (loading) => set({ loading }),
  setSaveState: (saveState) => set({ saveState }),
  setError: (error) => set({ error }),
  clear: () => set({ items: [], activeId: null, active: null, loading: false, saveState: "idle", error: null }),
}));

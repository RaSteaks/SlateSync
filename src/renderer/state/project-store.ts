import { create } from "zustand";
import type { ProjectSlice } from "./types";

export const useProjectStore = create<ProjectSlice>((set) => ({
  config: null,
  library: null,
  projects: [],
  current: null,
  scenarios: [],
  modelDiscovery: {},
  loading: false,
  error: null,
  setConfig: (config) => set({ config }),
  setLibrary: (library) => set({ library }),
  setProjects: (projects) => set({ projects: [...projects] }),
  setCurrent: (current) => set({ current }),
  setScenarios: (scenarios) => set({ scenarios: [...scenarios] }),
  setModelDiscovery: (providerId, result) => set((state) => ({ modelDiscovery: { ...state.modelDiscovery, [providerId]: result } })),
  // No-op guards avoid rerendering the 500-card Library for repeated lifecycle
  // writes while refresh/open operation tokens remain the concurrency owner.
  setLoading: (loading) => set((state) => state.loading === loading ? state : { loading }),
  setError: (error) => set((state) => state.error === error ? state : { error }),
}));

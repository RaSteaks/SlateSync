import { create } from "zustand";
import type { MetadataSlice } from "./types";

export const useMetadataStore = create<MetadataSlice>((set) => ({
  directory: null,
  result: null,
  scanning: false,
  error: null,
  setDirectory: (directory) => set({ directory }),
  setScanning: (scanning) => set({ scanning }),
  setResult: (result) => set({ result, error: null }),
  setError: (error) => set({ error, scanning: false }),
  clear: () => set({ directory: null, result: null, scanning: false, error: null }),
}));

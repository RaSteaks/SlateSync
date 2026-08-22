import { create } from "zustand";
import type { SettingsSlice } from "./types";

export const useSettingsStore = create<SettingsSlice>((set) => ({
  ocr: null,
  setOcr: (ocr) => set({ ocr }),
}));

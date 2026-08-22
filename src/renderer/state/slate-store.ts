import { create } from "zustand";
import type { SlateSlice } from "./types";

export const useSlateStore = create<SlateSlice>((set) => ({
  filename: null,
  fileType: null,
  fileSize: 0,
  pageCount: 0,
  imageDataGroups: [],
  pdfDataUrl: null,
  preparing: false,
  preparationProgress: 0,
  preparationMessage: "等待输入",
  error: null,
  setInput: (input) => set({ ...input, pdfDataUrl: input.pdfDataUrl || null, imageDataGroups: input.imageDataGroups.map((group) => [...group]), preparing: false, preparationProgress: 100, preparationMessage: "已准备" }),
  clearInput: () => set({ filename: null, fileType: null, fileSize: 0, pageCount: 0, imageDataGroups: [], pdfDataUrl: null, preparing: false, preparationProgress: 0, preparationMessage: "等待输入", error: null }),
  setPreparing: (preparing, progress = 0, message = preparing ? "正在准备素材" : "已准备") => set({ preparing, preparationProgress: progress, preparationMessage: message }),
  setError: (error) => set({ error, preparing: false }),
}));

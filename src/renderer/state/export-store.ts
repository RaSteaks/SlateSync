import { create } from "zustand";
import type { ExportSlice } from "./types";

export const useExportStore = create<ExportSlice>((set) => ({
  table: null,
  previewTable: null,
  filename: null,
  edits: {},
  slateCsvRecords: null,
  slateCsvFilename: null,
  processing: false,
  error: null,
  setTable: (table, filename = null) => set({ table, previewTable: null, filename, edits: {}, error: null }),
  setPreviewTable: (previewTable) => set({ previewTable }),
  setEdit: (key, value) => set((state) => ({ edits: { ...state.edits, [key]: value } })),
  setEdits: (edits) => set({ edits: { ...edits } }),
  setSlateCsvRecords: (slateCsvRecords, slateCsvFilename = null) => set({ slateCsvRecords: slateCsvRecords ? [...slateCsvRecords] : null, slateCsvFilename }),
  setProcessing: (processing) => set({ processing }),
  setError: (error) => set({ error, processing: false }),
  clear: () => set({ table: null, previewTable: null, filename: null, edits: {}, slateCsvRecords: null, slateCsvFilename: null, processing: false, error: null }),
}));

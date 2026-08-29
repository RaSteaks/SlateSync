import { create } from "zustand";
import type { RecognitionSlice } from "./types";

export const useRecognitionStore = create<RecognitionSlice>((set) => ({
  operationId: 0,
  projectId: null,
  taskId: null,
  resumeOnWorkspace: false,
  running: false,
  phase: "idle",
  percent: 0,
  completedPages: 0,
  totalPages: 0,
  message: "等待识别",
  warning: null,
  data: null,
  records: [],
  error: null,
  start: (operationId, projectId, totalPages, taskId = null) => set({ operationId, projectId, taskId, resumeOnWorkspace: false, running: true, phase: "preparing", percent: 0, completedPages: 0, totalPages, message: "准备识别素材", warning: null, data: null, records: [], error: null }),
  // The task ID is bound after autosave so a recognition request can keep its
  // durable owner even when the Workspace route is temporarily unmounted.
  setTaskId: (taskId) => set({ taskId }),
  // Logs are a read-only observer. Marking the handoff keeps the global
  // recognition snapshot and route-owned task inputs alive for the return trip.
  markWorkspaceHandoff: (projectId = null, taskId = null) => set((state) => ({
    resumeOnWorkspace: true,
    projectId: projectId ?? state.projectId,
    taskId: taskId ?? state.taskId,
  })),
  clearWorkspaceHandoff: () => set({ resumeOnWorkspace: false }),
  // Progress warnings survive later page-status messages so optional OCR
  // fallback remains visible until the final result warning is available.
  progress: (operationId, event) => set((state) => {
    if (state.operationId !== operationId || !state.running || state.phase === "stopping") return state;
    const nextPercent = Math.min(99, Math.max(state.percent, Number(event.percent) || 0));
    return { phase: event.phase || state.phase, percent: nextPercent, completedPages: event.completed ?? state.completedPages, totalPages: event.total ?? state.totalPages, message: event.message || state.message, warning: event.warning === undefined ? state.warning : event.warning || null };
  }),
  complete: (operationId, data) => set((state) => state.operationId !== operationId ? state : { running: false, phase: "complete", percent: 100, completedPages: data.pageCount, totalPages: data.pageCount, message: "识别完成", warning: null, data, taskId: data.taskId || state.taskId, error: null, records: data.result.records }),
  requestCancel: (operationId) => set((state) => state.operationId !== operationId || !state.running ? state : { phase: "stopping", message: "正在停止识别" }),
  cancel: (operationId) => set((state) => state.operationId !== operationId ? state : { running: false, phase: "canceled", message: "识别已停止", warning: null, error: null }),
  cancelRequestFailed: (operationId) => set((state) => state.operationId !== operationId || !state.running ? state : { phase: "running", message: "停止失败，识别仍在进行" }),
  updateRecord: (index, patch) => set((state) => {
    const records = state.records.map((record, recordIndex) => recordIndex === index ? { ...record, ...patch } : record);
    return { records, data: state.data ? { ...state.data, result: { ...state.data.result, records } } : state.data };
  }),
  addRecord: (record) => set((state) => {
    const records = [...state.records, record];
    return { records, data: state.data ? { ...state.data, result: { ...state.data.result, records } } : state.data };
  }),
  removeRecord: (index) => set((state) => {
    const records = state.records.filter((_, recordIndex) => recordIndex !== index);
    return { records, data: state.data ? { ...state.data, result: { ...state.data.result, records } } : state.data };
  }),
  fail: (operationId, error) => set((state) => state.operationId !== operationId ? state : { running: false, phase: "error", message: "识别失败", warning: null, error }),
  reset: () => set({ operationId: 0, projectId: null, taskId: null, resumeOnWorkspace: false, running: false, phase: "idle", percent: 0, completedPages: 0, totalPages: 0, message: "等待识别", warning: null, data: null, records: [], error: null }),
}));

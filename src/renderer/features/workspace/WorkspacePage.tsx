import { ChevronLeft, ChevronRight, Download, FileSpreadsheet, FolderSearch, Play, RefreshCw, Square, Upload } from "lucide-react";
import { useCallback, useEffect, useMemo, useRef, useState, type KeyboardEvent as ReactKeyboardEvent, type WheelEvent as ReactWheelEvent } from "react";
import { useShallow } from "zustand/react/shallow";
import type {
  OcrSummary,
  PersistedRecognitionRecord,
  ProjectSettings,
  RecognitionData,
  RecognitionRecord,
  RecognitionRequest,
  ScannedSlateMetadata,
  TaskData,
} from "../../../shared/contracts/index.js";
import { Badge, Button, Dialog, Field, InlineError, Progress, Select, Stack, Surface, Text, Textarea } from "../../design-system";
import { appErrorFromUnknown, getSlateSync, unwrap } from "../../services/api";
import { createOperationGuard } from "../../services/operation-guard";
import { getCsvWorkerService } from "../../services/csv-worker-service";
import { getPreparationService } from "../../services/preparation-service";
import { createTaskAutosave } from "../../services/task-autosave";
import { RECOGNITION_SHORTCUT_EVENT } from "../../services/keyboard-shortcuts";
import { useExportStore, useMetadataStore, useProjectStore, useRecognitionStore, useSlateStore, useTaskStore, useUiStore } from "../../state";
import { useFileDrop } from "../../hooks/use-file-drop";
import { validateCsvFile } from "../../validation/input-validation";
import { CsvVirtualTable } from "../csv/CsvVirtualTable";
import { RecognitionResultPanel } from "../recognition/RecognitionResultPanel";
import { ModelSelect } from "../recognition/ModelSelect";
import { groupModelOptions } from "../recognition/model-options";
import { useRecognitionDraft } from "../recognition/use-recognition-draft";
import { SlateInputPanel, type SlateInputPanelHandle } from "../slate/SlateInputPanel";
import { TaskRail } from "../tasks/TaskRail";
import styles from "../../app/app.module.css";

// @ts-expect-error The frozen browser compatibility module intentionally has no TS declarations.
import { REQUEST_COMPRESSION_PROFILES, requestBodyBytes, requestBodyFits, selectRecognitionImageGroups } from "../../../../public/recognition-request.js";

const EMPTY_OCR: OcrSummary = {
  enabled: false,
  available: false,
  used: false,
  cacheHit: false,
  engine: "none",
  model: null,
  profile: null,
  profileLabel: null,
  detectionModel: null,
  recognitionModel: null,
  recognitionBatchSize: null,
  device: null,
  pageCount: 0,
  viewCount: 0,
  blockCount: 0,
  lowConfidenceBlockCount: 0,
  durationMs: 0,
  warning: null,
};

function defaultSettings(config: ReturnType<typeof useProjectStore.getState>["config"]): ProjectSettings {
  return {
    version: 1,
    providerId: null,
    modelId: null,
    accuracyMode: "high",
    scenarioId: null,
    customPrompt: "",
    resolve: {
      fieldFormats: config?.workflow.resolve.fieldFormats || { scene: "XXX", shot: "XX", take: "XX" },
      comments: config?.workflow.resolve.comments || { goodTake: "_OK", holdTake: "_KP" },
    },
  };
}

function normalizeRecord(record: PersistedRecognitionRecord, index: number): RecognitionRecord {
  return {
    id: record.id || `restored-${index}`,
    sourcePage: record.sourcePage ?? null,
    cardNumber: record.cardNumber || null,
    videoCode: record.videoCode || null,
    scene: record.scene || null,
    shot: record.shot || null,
    take: record.take || null,
    takeStatus: record.takeStatus || null,
    description: record.description || null,
    comments: record.comments || null,
    shotSize: record.shotSize || null,
    cameraPosition: record.cameraPosition || null,
    confidence: record.confidence || "medium",
    ...(record.reviewRequiredFields ? { reviewRequiredFields: record.reviewRequiredFields } : {}),
  };
}

export interface WorkspaceToolbarExportState {
  readonly canExport: boolean;
  readonly processing: boolean;
}

export type RegisterWorkspaceToolbarExport = (
  handler: (() => void) | null,
  state?: WorkspaceToolbarExportState,
) => void;

/** 项目库传输前由 Workspace 先把当前草稿推进 SQLite。 */
export type RegisterWorkspaceTransferPreparation = (
  handler: (() => Promise<boolean>) | null,
) => void;

export function WorkspacePage({ registerToolbarExport, registerTransferPreparation, hidden = false }: { registerToolbarExport?: RegisterWorkspaceToolbarExport; registerTransferPreparation?: RegisterWorkspaceTransferPreparation; hidden?: boolean } = {}) {
  const project = useProjectStore((state) => state.current);
  const config = useProjectStore((state) => state.config);
  const scenarios = useProjectStore((state) => state.scenarios);
  const route = useUiStore((state) => state.route);
  const loadedTaskProjectId = useTaskStore((state) => state.loadedProjectId);
  const setToast = useUiStore((state) => state.setToast);
  // High-frequency progress and sparse table edits subscribe only to rendered
  // fields. Worker-retained tables and task snapshots are read by actions.
  const slate = useSlateStore(useShallow((state) => ({
    filename: state.filename,
    fileType: state.fileType,
    fileSize: state.fileSize,
    pageCount: state.pageCount,
    imageDataGroups: state.imageDataGroups,
    preparing: state.preparing,
  })));
  const recognition = useRecognitionStore(useShallow((state) => ({
    projectId: state.projectId,
    taskId: state.taskId,
    resumeOnWorkspace: state.resumeOnWorkspace,
    running: state.running,
    phase: state.phase,
    percent: state.percent,
    completedPages: state.completedPages,
    totalPages: state.totalPages,
    message: state.message,
    warning: state.warning,
    records: state.records,
  })));
  const exportState = useExportStore(useShallow((state) => ({
    table: state.table,
    previewTable: state.previewTable,
    filename: state.filename,
    edits: state.edits,
    slateCsvRecords: state.slateCsvRecords,
    slateCsvFilename: state.slateCsvFilename,
    processing: state.processing,
    error: state.error,
  })));
  const metadata = useMetadataStore(useShallow((state) => ({ result: state.result, scanning: state.scanning })));
  const { draft, dirty: draftDirty, replace: replaceDraft, patch: patchDraft, setModelFallback, markClean: markDraftClean } = useRecognitionDraft();
  const { providerId, modelId, accuracyMode, scenarioId, customPrompt } = draft;
  const [models, setModels] = useState<readonly import("../../../shared/contracts/index.js").ModelData[]>([]);
  const [error, setError] = useState<string | null>(null);
  const [switchingTask, setSwitchingTask] = useState(false);
  const [previewSelection, setPreviewSelection] = useState<{ page: number; source: string } | null>(null);
  const previewWheelDeltaRef = useRef(0);
  const previewWheelLockedRef = useRef(false);
  const previewWheelUnlockTimerRef = useRef<number | null>(null);
  const taskSwitchInFlightRef = useRef(false);
  const slatePanelRef = useRef<SlateInputPanelHandle>(null);
  const slatePreviewRef = useRef<HTMLDivElement>(null);
  const lastPreviewGroupsRef = useRef<readonly (readonly string[])[] | null>(null);
  const slateCsvInputRef = useRef<HTMLInputElement>(null);
  const resolveCsvInputRef = useRef<HTMLInputElement>(null);
  const [deleteTaskId, setDeleteTaskId] = useState<string | null>(null);
  const operationGuard = useMemo(() => createOperationGuard(), []);
  const taskListGuard = useMemo(() => createOperationGuard(), []);
  const taskLoadGuard = useMemo(() => createOperationGuard(), []);
  const previewGuard = useMemo(() => createOperationGuard(), []);
  const projectIdRef = useRef<string | null>(null);
  const workspaceMountedRef = useRef(true);
  const latestCapture = useRef<() => TaskData | null>(() => null);
  const runRecognitionRef = useRef<() => void>(() => undefined);
  const exportCsvRef = useRef<() => void>(() => undefined);
  const cancelRequestedRef = useRef(false);
  const recognitionInFlightRef = useRef(false);
  const previousRouteRef = useRef<ReturnType<typeof useUiStore.getState>["route"] | null>(null);
  projectIdRef.current = project?.id || null;

  useEffect(() => {
    const preparation = getPreparationService();
    if (hidden) {
      // Route detours must not cancel an active prepare/recompress request, but
      // an idle Worker should not stay alive merely because Workspace is hidden.
      preparation.terminateWhenIdle();
      return;
    }
    // Returning to Workspace cancels a deferred idle release before the user
    // can start another upload or recognition compression pass.
    preparation.keepAlive();
  }, [hidden]);

  useEffect(() => {
    if (!slate.imageDataGroups.length) {
      lastPreviewGroupsRef.current = null;
      return undefined;
    }
    if (lastPreviewGroupsRef.current === slate.imageDataGroups) return undefined;
    lastPreviewGroupsRef.current = slate.imageDataGroups;
    const frame = requestAnimationFrame(() => slatePreviewRef.current?.focus({ preventScroll: false }));
    return () => cancelAnimationFrame(frame);
  }, [slate.imageDataGroups]);

  const previewPages = useMemo(() => slate.imageDataGroups.flatMap((group, page) => {
    const source = group[0];
    return source ? [{ page, source }] : [];
  }), [slate.imageDataGroups]);

  useEffect(() => {
    // A task switch or replacement must never leave the lightbox pointing at
    // an image that no longer belongs to the visible slate preview.
    setPreviewSelection((current) => current && previewPages.some((item) => item.page === current.page && item.source === current.source) ? current : null);
  }, [previewPages]);

  const selectedPreview = useMemo(() => {
    if (!previewSelection) return null;
    return previewPages.find((item) => item.page === previewSelection.page && item.source === previewSelection.source) || null;
  }, [previewPages, previewSelection]);
  const selectedPreviewPosition = selectedPreview ? previewPages.indexOf(selectedPreview) : -1;

  const selectPreviewPage = useCallback((page: number) => {
    const next = previewPages.find((item) => item.page === page);
    if (next) setPreviewSelection({ page: next.page, source: next.source });
  }, [previewPages]);

  const movePreviewPage = useCallback((offset: number) => {
    setPreviewSelection((current) => {
      if (!current) return current;
      const currentPosition = previewPages.findIndex((item) => item.page === current.page && item.source === current.source);
      const next = currentPosition >= 0 ? previewPages[currentPosition + offset] : undefined;
      return next ? { page: next.page, source: next.source } : current;
    });
  }, [previewPages]);

  const handlePreviewKeyDown = useCallback((event: ReactKeyboardEvent<HTMLDivElement>) => {
    if (!selectedPreview || (event.key !== "ArrowLeft" && event.key !== "ArrowRight")) return;
    event.preventDefault();
    movePreviewPage(event.key === "ArrowRight" ? 1 : -1);
  }, [movePreviewPage, selectedPreview]);

  const schedulePreviewWheelUnlock = useCallback(() => {
    if (previewWheelUnlockTimerRef.current !== null) window.clearTimeout(previewWheelUnlockTimerRef.current);
    previewWheelUnlockTimerRef.current = window.setTimeout(() => {
      // Trackpad momentum can outlive a short throttle window. Unlock only
      // after the full horizontal wheel burst has gone quiet.
      previewWheelDeltaRef.current = 0;
      previewWheelLockedRef.current = false;
      previewWheelUnlockTimerRef.current = null;
    }, 320);
  }, []);

  const handlePreviewWheel = useCallback((event: ReactWheelEvent<HTMLDivElement>) => {
    // Ctrl + wheel is commonly emitted by trackpad pinch-to-zoom; leave that
    // browser gesture untouched and only consume an intentional horizontal move.
    if (!selectedPreview || event.ctrlKey) return;
    const delta = Math.abs(event.deltaX) >= Math.abs(event.deltaY) ? event.deltaX : event.shiftKey ? event.deltaY : 0;
    if (!delta) return;
    event.preventDefault();

    // A single trackpad swipe arrives as many wheel events, including momentum
    // tail events; the lock limits the whole burst to one page transition.
    schedulePreviewWheelUnlock();
    if (previewWheelLockedRef.current) return;
    previewWheelDeltaRef.current += delta;
    if (Math.abs(previewWheelDeltaRef.current) < 48) return;

    const direction = previewWheelDeltaRef.current > 0 ? 1 : -1;
    previewWheelDeltaRef.current = 0;
    previewWheelLockedRef.current = true;
    movePreviewPage(direction);
  }, [movePreviewPage, schedulePreviewWheelUnlock, selectedPreview]);

  useEffect(() => {
    if (selectedPreview) return;
    previewWheelDeltaRef.current = 0;
    previewWheelLockedRef.current = false;
    if (previewWheelUnlockTimerRef.current !== null) {
      window.clearTimeout(previewWheelUnlockTimerRef.current);
      previewWheelUnlockTimerRef.current = null;
    }
  }, [selectedPreview]);

  useEffect(() => () => {
    if (previewWheelUnlockTimerRef.current !== null) window.clearTimeout(previewWheelUnlockTimerRef.current);
  }, []);

  useEffect(() => {
    if (route === "workspace") return;
    // Route detours preserve the task projection, but transient workspace
    // dialogs must close so a portal cannot cover the destination settings or
    // log page while the workspace root is hidden.
    setDeleteTaskId(null);
    setPreviewSelection(null);
  }, [route]);

  const settingsSnapshot = useCallback((): ProjectSettings => {
    const base = project?.settings || defaultSettings(config);
    return {
      ...base,
      providerId: providerId || null,
      modelId: modelId || null,
      accuracyMode,
      scenarioId: scenarioId || null,
      customPrompt,
    };
  }, [accuracyMode, config, customPrompt, modelId, project?.settings, providerId, scenarioId]);

  const invalidateResolvePreview = useCallback(() => {
    // Each recognition run owns a new preview scope; clear the old projection
    // before async work can fail or be canceled without producing a result.
    previewGuard.invalidate();
    useExportStore.getState().setPreviewTable(null);
  }, [previewGuard]);

  const refreshResolvePreview = useCallback(async () => {
    const currentExport = useExportStore.getState();
    const currentRecognition = useRecognitionStore.getState();
    if (!currentExport.table || !currentRecognition.records.length) {
      invalidateResolvePreview();
      return;
    }

    const operationId = previewGuard.start();
    const settings = settingsSnapshot();
    try {
      const previewTable = await getCsvWorkerService().mergePreview({
        type: "merge-preview",
        records: currentRecognition.records,
        slateMetadata: useMetadataStore.getState().result?.metadata || [],
        fieldFormats: settings.resolve.fieldFormats,
        comments: settings.resolve.comments,
      });
      const latestExport = useExportStore.getState();
      const latestRecognition = useRecognitionStore.getState();
      if (!workspaceMountedRef.current || !previewGuard.isCurrent(operationId) || latestExport.table !== currentExport.table || latestRecognition.records !== currentRecognition.records) return;
      useExportStore.getState().setPreviewTable(previewTable);
    } catch (nextError) {
      if (!workspaceMountedRef.current || !previewGuard.isCurrent(operationId)) return;
      const appError = appErrorFromUnknown(nextError);
      useExportStore.getState().setError(appError);
      setError(appError.message);
    }
  }, [invalidateResolvePreview, previewGuard, settingsSnapshot]);

  const captureTask = useCallback((): TaskData | null => {
    const currentProject = useProjectStore.getState().current;
    const currentSlate = useSlateStore.getState();
    const currentRecognition = useRecognitionStore.getState();
    const currentExport = useExportStore.getState();
    const currentMetadata = useMetadataStore.getState();
    const currentTask = useTaskStore.getState();
    if (!currentProject) return null;
    return {
      ...(currentTask.active || {}),
      id: currentTask.activeId,
      projectId: currentProject.id,
      projectSettingsSnapshot: settingsSnapshot(),
      status: currentRecognition.data ? "completed" : "draft",
      filename: currentSlate.filename,
      fileType: currentSlate.fileType,
      fileSize: currentSlate.fileSize,
      pageCount: currentSlate.pageCount,
      imageDataGroups: currentSlate.imageDataGroups,
      resolveCsvTable: currentExport.table,
      resolveCsvEdits: currentExport.edits,
      resolveCsvFilename: currentExport.filename,
      slateMetadata: currentMetadata.result?.metadata || [],
      slateWarnings: currentMetadata.result?.warnings || [],
      missingMetadataKeys: currentMetadata.result?.missingKeys || [],
      slateDirectoryName: currentMetadata.directory?.dirName || null,
      provider: currentRecognition.data?.provider || providerId || null,
      model: currentRecognition.data?.model || modelId || null,
      scenarioId: scenarioId || null,
      customPrompt,
      accuracyMode,
      result: currentRecognition.data?.result || currentTask.active?.result || null,
      usage: currentRecognition.data?.usage || currentTask.active?.usage || null,
      durationMs: currentRecognition.data?.durationMs || currentTask.active?.durationMs || 0,
      ocrSummary: currentRecognition.data?.ocr || currentTask.active?.ocrSummary || null,
      diagnosticSessionId: currentRecognition.data?.diagnosticSessionId || currentTask.active?.diagnosticSessionId || null,
      editedRecords: currentRecognition.records,
      updatedAt: new Date().toISOString(),
    };
  }, [accuracyMode, customPrompt, modelId, providerId, scenarioId, settingsSnapshot]);

  useEffect(() => { latestCapture.current = captureTask; }, [captureTask]);

  const autosave = useMemo(() => createTaskAutosave({
    capture: () => latestCapture.current(),
    save: async (task) => {
      const projectId = task.projectId || projectIdRef.current;
      if (!projectId) return null;
      const expectedTaskId = task.id || null;
      const id = await unwrap(await getSlateSync().tasks.save({ projectId, task }));
      const taskState = useTaskStore.getState();
      // A completed write may only claim the task that originally owned it.
      if (workspaceMountedRef.current && useProjectStore.getState().current?.id === projectId && taskState.activeId === expectedTaskId) {
        taskState.setActive(id, { ...task, id });
      }
      // The returned ID remains authoritative even if the route was changed
      // while this save was awaiting Main; autosave exposes it to recognition.
      return id;
    },
    onState: (state) => {
      useTaskStore.getState().setSaveState(state);
      if (state === "saved") markDraftClean();
    },
  }), []);

  const markDirtyAfterRender = useCallback(() => {
    setTimeout(() => autosave.markDirty(latestCapture.current()), 0);
  }, [autosave]);

  const prepareForProjectTransfer = useCallback(async () => {
    // 项目库按钮可能赶在延迟 markDirty 回调之前触发，先发布最新草稿再 flush。
    if (draftDirty) autosave.markDirty(latestCapture.current());
    return autosave.flush();
  }, [autosave, draftDirty]);

  useEffect(() => {
    if (!registerTransferPreparation) return undefined;
    registerTransferPreparation(prepareForProjectTransfer);
    return () => registerTransferPreparation(null);
  }, [prepareForProjectTransfer, registerTransferPreparation]);

  useEffect(() => {
    const onBeforeUnload = (event: BeforeUnloadEvent) => {
      if (!draftDirty && !autosave.hasPending() && !useRecognitionStore.getState().running) return;
      event.preventDefault();
      event.returnValue = "";
      void autosave.flush();
    };
    window.addEventListener("beforeunload", onBeforeUnload);
    return () => window.removeEventListener("beforeunload", onBeforeUnload);
  }, [autosave, draftDirty]);

  const refreshTasks = useCallback(async (projectId = projectIdRef.current) => {
    if (!projectId) return;
    const operationId = taskListGuard.start();
    useTaskStore.getState().setError(null);
    useTaskStore.getState().setLoading(true);
    try {
      const items = await unwrap(await getSlateSync().tasks.list({ projectId }));
      if (taskListGuard.isCurrent(operationId) && projectIdRef.current === projectId) useTaskStore.getState().setItems(items, projectId);
    } catch (nextError) {
      if (taskListGuard.isCurrent(operationId)) useTaskStore.getState().setError(appErrorFromUnknown(nextError));
    } finally {
      if (taskListGuard.isCurrent(operationId)) useTaskStore.getState().setLoading(false);
    }
  }, [taskListGuard]);

  useEffect(() => {
    const projectId = project?.id;
    if (!projectId) return undefined;
    const returningFromLogViewer = recognition.resumeOnWorkspace && recognition.projectId === projectId;
    // App's opening read already owns the first projection. A missing marker
    // means this is a route return (or a direct Workspace mount), while a log
    // handoff always forces a fresh authoritative summary after completion.
    if (loadedTaskProjectId === projectId && !returningFromLogViewer) return undefined;
    void refreshTasks(projectId);
    return undefined;
  }, [loadedTaskProjectId, project?.id, recognition.projectId, recognition.resumeOnWorkspace, refreshTasks]);

  const clearWorkspaceData = useCallback(async () => {
    operationGuard.invalidate();
    previewGuard.invalidate();
    useRecognitionStore.getState().reset();
    useSlateStore.getState().clearInput();
    useExportStore.getState().clear();
    useMetadataStore.getState().clear();
    await getCsvWorkerService().clear();
  }, [operationGuard, previewGuard]);

  useEffect(() => () => {
    workspaceMountedRef.current = false;
    operationGuard.invalidate();
    previewGuard.invalidate();
    taskListGuard.invalidate();
    taskLoadGuard.invalidate();
    void autosave.flush();
    const preserveRecognitionForLogViewer = useUiStore.getState().route === "logs"
      && (useRecognitionStore.getState().running || recognitionInFlightRef.current);
    if (preserveRecognitionForLogViewer) {
      // Logs is a read-only detour. Keep every route-owned input and the
      // worker alive so returning to Workspace can render the same task while
      // the App-level progress listener continues receiving events.
      useRecognitionStore.getState().markWorkspaceHandoff(projectIdRef.current, useTaskStore.getState().activeId);
      return;
    }
    getCsvWorkerService().terminate();
    // Non-log routes still release the potentially large image/CSV graphs;
    // their next visit reloads the authoritative task from Main.
    useRecognitionStore.getState().reset();
    useSlateStore.getState().clearInput();
    useExportStore.getState().clear();
    useMetadataStore.getState().clear();
    useTaskStore.getState().clear();
  }, [autosave, operationGuard, previewGuard, taskListGuard, taskLoadGuard]);

  useEffect(() => {
    if (!project) return;
    // Initialize once per project identity. Settings-page saves and global
    // config refreshes may replace these objects while this instance is hidden;
    // they must not clear the user's retained workspace projection.
    const settings = project.settings || defaultSettings(config);
    const retainedRecognition = useRecognitionStore.getState();
    const resumeFromLogViewer = retainedRecognition.resumeOnWorkspace
      && retainedRecognition.projectId === project.id;
    const retainedTask = resumeFromLogViewer ? useTaskStore.getState().active : null;
    autosave.reset();
    replaceDraft({
      providerId: retainedTask?.provider || project.lastRecognitionDefaults?.providerId || settings.providerId || config?.providers.find((item) => item.configured)?.id || config?.providers[0]?.id || "",
      modelId: retainedTask?.model || project.lastRecognitionDefaults?.modelId || settings.modelId || "",
      accuracyMode: retainedTask?.accuracyMode || settings.accuracyMode || "high",
      scenarioId: retainedTask?.scenarioId || settings.scenarioId || "",
      customPrompt: retainedTask?.customPrompt ?? project.lastRecognitionDefaults?.customPrompt ?? settings.customPrompt ?? "",
    });
    if (!resumeFromLogViewer) {
      useRecognitionStore.getState().reset();
      previewGuard.invalidate();
      useSlateStore.getState().clearInput();
      useExportStore.getState().clear();
      useMetadataStore.getState().clear();
      void getCsvWorkerService().clear();
    }
    return () => {
      taskListGuard.invalidate();
      taskLoadGuard.invalidate();
      void autosave.flush();
    };
  }, [autosave, previewGuard, project?.id, replaceDraft, taskListGuard, taskLoadGuard]);

  useEffect(() => {
    if (!providerId) return;
    let active = true;
    void (async () => {
      try {
        const result = await unwrap(await getSlateSync().recognition.getModels({ providerId, forceRefresh: false }));
        if (!active) return;
        setModels(result.models);
        // Only seed a genuinely new task. A saved/removed model must remain
        // visible as a stale reference until the user explicitly remaps it.
        if (!modelId) setModelFallback(result.models[0]?.id || "");
      } catch {
        if (active) setModels(config?.models.filter((model) => model.providers.includes(providerId)) || []);
      }
    })();
    return () => { active = false; };
  }, [config?.models, modelId, providerId, setModelFallback]);

  const applyTask = useCallback(async (taskId: string, task: TaskData) => {
    const csvWorker = getCsvWorkerService();
    // Prime retained Worker state before publishing the restored table to
    // React, so an immediately clicked Export cannot observe half-restored UI.
    if (task.resolveCsvTable) await csvWorker.prime(task.resolveCsvTable);
    else await csvWorker.clear();

    useRecognitionStore.getState().reset();
    useSlateStore.getState().clearInput();
    useExportStore.getState().clear();
    useMetadataStore.getState().clear();
    if (task.imageDataGroups?.length) {
      useSlateStore.getState().setInput({
        filename: task.filename || "恢复的场记单",
        fileType: task.fileType || "image/jpeg",
        fileSize: task.fileSize || 0,
        pageCount: task.pageCount || task.imageDataGroups.length,
        imageDataGroups: task.imageDataGroups,
      });
    }
    if (task.resolveCsvTable) useExportStore.getState().setTable(task.resolveCsvTable, task.resolveCsvFilename);
    if (task.resolveCsvEdits) useExportStore.getState().setEdits(task.resolveCsvEdits);
    if (task.slateMetadata?.length || task.slateWarnings?.length || task.missingMetadataKeys?.length) {
      useMetadataStore.getState().setResult({
        metadata: (task.slateMetadata || []).map((item) => ({
          sourceName: item.sourceName || task.slateDirectoryName || "已恢复元数据",
          clipName: item.clipName || "",
          materialKey: item.materialKey,
          sensorFps: item.sensorFps || "",
          shootDay: item.shootDay || "",
        })),
        warnings: task.slateWarnings || [],
        missingKeys: task.missingMetadataKeys || [],
        stats: { visitedDirectories: 0, prunedDirectories: 0, skippedDeepDirectories: 0, discoveredSlateFiles: 0, readSlateFiles: 0, learnedStructures: 0 },
      });
    }

    const snapshot = task.projectSettingsSnapshot || project?.settings || defaultSettings(config);
    replaceDraft({
      providerId: task.provider || snapshot.providerId || "",
      modelId: task.model || snapshot.modelId || "",
      accuracyMode: task.accuracyMode || snapshot.accuracyMode || "standard",
      scenarioId: task.scenarioId || snapshot.scenarioId || "",
      customPrompt: task.customPrompt ?? snapshot.customPrompt ?? "",
    });

    const persisted = task.editedRecords?.length ? task.editedRecords : task.result?.records;
    if (persisted?.length || task.result) {
      const restoredRecords = (persisted || []).map(normalizeRecord);
      const restored: RecognitionData = {
        provider: task.provider || "",
        model: task.model || "",
        inputMode: "images",
        durationMs: task.durationMs || 0,
        pageCount: task.pageCount || 0,
        accuracyMode: task.accuracyMode || "standard",
        usage: task.usage || null,
        ocr: task.ocrSummary || EMPTY_OCR,
        scenario: null,
        result: { sheetTitle: task.result?.sheetTitle || null, records: restoredRecords, warnings: task.result?.warnings || [] },
        projectId: project?.id || null,
        projectSettingsSnapshot: snapshot,
        lastRecognitionDefaults: project?.lastRecognitionDefaults || null,
        diagnosticSessionId: task.diagnosticSessionId || null,
        taskId,
      };
      const token = useRecognitionStore.getState().operationId + 1;
      useRecognitionStore.getState().start(token, project?.id || null, restored.pageCount);
      useRecognitionStore.getState().complete(token, restored);
    }
    await refreshResolvePreview();
    autosave.reset();
    useTaskStore.getState().setActive(taskId, task);
    useTaskStore.getState().setSaveState("saved");
  }, [autosave, config, project, refreshResolvePreview, refreshTasks, replaceDraft]);

  useEffect(() => {
    if (!project || !recognition.resumeOnWorkspace || recognition.projectId !== project.id) return undefined;
    const taskId = recognition.taskId;
    // A running request already has its complete in-memory projection. Only
    // reload after it stops, otherwise a draft snapshot from Main could erase
    // the live progress/result while the user is back on the Workspace route.
    if (recognition.running) return undefined;
    if (!taskId) {
      useRecognitionStore.getState().clearWorkspaceHandoff();
      return undefined;
    }

    let active = true;
    void (async () => {
      try {
        const task = await unwrap(await getSlateSync().tasks.load({ projectId: project.id, id: taskId }));
        const currentRecognition = useRecognitionStore.getState();
        if (!active || currentRecognition.running || !currentRecognition.resumeOnWorkspace || currentRecognition.taskId !== taskId) return;
        if (task.result || task.editedRecords?.length) {
          await applyTask(taskId, task);
        } else {
          // Preserve a failed/canceled in-memory result when Main only has the
          // original draft, but still make the handoff one-shot.
          useTaskStore.getState().setActive(taskId, task);
          useTaskStore.getState().setSaveState("saved");
          useRecognitionStore.getState().clearWorkspaceHandoff();
        }
        // The restored detail is authoritative; refresh the rail so its
        // summary/status cannot remain the pre-handoff draft projection.
        await refreshTasks(project.id);
      } catch (nextError) {
        if (!active) return;
        useRecognitionStore.getState().clearWorkspaceHandoff();
        setError(appErrorFromUnknown(nextError).message);
      }
    })();
    return () => { active = false; };
  }, [project, recognition.projectId, recognition.resumeOnWorkspace, recognition.running, recognition.taskId, refreshTasks]);

  const refreshWorkspaceAfterRouteReturn = useCallback(async (projectId: string) => {
    // Finish the same autosave queue before re-reading Main; otherwise a fast
    // settings/logs round-trip could replace the user's newest local edits with
    // an older persisted task snapshot.
    if (!(await autosave.flush())) {
      if (useTaskStore.getState().saveState === "error") setError("工作台快照保存失败，暂不刷新当前任务。");
      return;
    }
    const currentRecognition = useRecognitionStore.getState();
    if (currentRecognition.running) {
      // A live request already owns the freshest detail in the global store;
      // only the task rail needs the authoritative Main-side summary.
      await refreshTasks(projectId);
      return;
    }

    const activeTaskId = useTaskStore.getState().activeId || autosave.getLastSavedTaskId();
    if (activeTaskId) {
      const task = await unwrap(await getSlateSync().tasks.load({ projectId, id: activeTaskId }));
      if (useUiStore.getState().route !== "workspace" || projectIdRef.current !== projectId || useRecognitionStore.getState().running) return;
      // Rehydrate the detail projection after the detour so completed edits and
      // any task data written by Main during the detour are immediately visible.
      await applyTask(activeTaskId, task);
    }
    await refreshTasks(projectId);
  }, [applyTask, autosave, refreshTasks, setError]);

  useEffect(() => {
    const previousRoute = previousRouteRef.current;
    previousRouteRef.current = route;
    if (!project?.id || route !== "workspace" || !previousRoute || previousRoute === "workspace") return undefined;
    void refreshWorkspaceAfterRouteReturn(project.id).catch((nextError) => {
      if (useUiStore.getState().route === "workspace" && projectIdRef.current === project.id) setError(appErrorFromUnknown(nextError).message);
    });
    return undefined;
  }, [project?.id, refreshWorkspaceAfterRouteReturn, route, setError]);

  const loadTask = async (taskId: string) => {
    if (!project || switchingTask || taskSwitchInFlightRef.current || taskId === useTaskStore.getState().activeId) return;
    // Operation guards and this ref serialize the normal millisecond-scale
    // switch without forcing a redundant full-workspace busy render. Longer
    // destructive new/delete flows still expose the visible switching state.
    taskSwitchInFlightRef.current = true;
    setError(null);
    try {
      if (!(await autosave.flush())) throw new Error("当前任务保存失败；请重试保存后再切换任务。");
      const operationId = taskLoadGuard.start();
      const task = await unwrap(await getSlateSync().tasks.load({ projectId: project.id, id: taskId }));
      if (!taskLoadGuard.isCurrent(operationId) || projectIdRef.current !== project.id) return;
      await applyTask(taskId, task);
    } catch (nextError) {
      setError(appErrorFromUnknown(nextError).message);
    } finally {
      taskSwitchInFlightRef.current = false;
    }
  };

  const newTask = async () => {
    if (switchingTask) return;
    setSwitchingTask(true);
    setError(null);
    try {
      if (!(await autosave.flush())) throw new Error("当前任务保存失败；请重试保存后再新建任务。");
      taskLoadGuard.invalidate();
      await clearWorkspaceData();
      autosave.reset();
      useTaskStore.getState().setActive(null, null);
    } catch (nextError) {
      setError(appErrorFromUnknown(nextError).message);
    } finally {
      setSwitchingTask(false);
    }
  };

  const deleteTask = async () => {
    const taskId = deleteTaskId;
    if (!project || !taskId) return;
    setSwitchingTask(true);
    setError(null);
    try {
      const deletingActive = useTaskStore.getState().activeId === taskId;
      if (deletingActive && !(await autosave.flush())) throw new Error("当前任务保存失败；请先重试保存再删除。");
      await unwrap(await getSlateSync().tasks.delete({ projectId: project.id, id: taskId }));
      if (deletingActive) {
        await clearWorkspaceData();
        autosave.reset();
        useTaskStore.getState().setActive(null, null);
      }
      setDeleteTaskId(null);
      await refreshTasks(project.id);
      setToast({ tone: "success", message: "任务已删除" });
    } catch (nextError) {
      setError(appErrorFromUnknown(nextError).message);
    } finally {
      setSwitchingTask(false);
    }
  };

  const onEdit = useCallback((key: `${number}:${number}`, value: string) => {
    useExportStore.getState().setEdit(key, value);
    autosave.markDirty(captureTask());
  }, [autosave, captureTask]);

  const loadResolveCsv = async (file: File) => {
    // A directory scan in flight is keyed to the current CSV; loading another
    // one now would let the stale scan land on the wrong table.
    if (metadata.scanning) {
      setError("请等待目录扫描完成后再载入 Resolve CSV。");
      return;
    }
    const validation = validateCsvFile(file, "resolve");
    if (!validation.ok) { setError(validation.message); return; }
    setError(null);
    useExportStore.getState().setProcessing(true);
    try {
      const table = await getCsvWorkerService().decode(await file.arrayBuffer());
      useExportStore.getState().setTable(table, file.name);
      // Scan-derived metadata (slate sidecars) is keyed to the previously loaded
      // CSV's material set; clear it so a stale scan is never re-applied against
      // a different CSV. Recognition records are kept — a genuine mismatch is
      // caught by the export gate instead.
      useMetadataStore.getState().clear();
      await refreshResolvePreview();
      setToast({ tone: "success", message: `已载入 ${table.rows.length.toLocaleString("zh-CN")} 行 Resolve CSV` });
      autosave.markDirty(captureTask());
    } catch (nextError) {
      const appError = appErrorFromUnknown(nextError);
      useExportStore.getState().setError(appError);
      setError(appError.message);
    } finally {
      useExportStore.getState().setProcessing(false);
    }
  };

  const loadSlateCsv = async (file: File) => {
    const validation = validateCsvFile(file, "slate");
    if (!validation.ok) { setError(validation.message); return; }
    setError(null);
    useExportStore.getState().setProcessing(true);
    try {
      const records = await getCsvWorkerService().decodeSlateCsv(await file.arrayBuffer());
      useExportStore.getState().setSlateCsvRecords(records, file.name);
      setToast({ tone: "success", message: `已载入 ${records.length.toLocaleString("zh-CN")} 条场记 CSV 记录` });
    } catch (nextError) {
      const appError = appErrorFromUnknown(nextError);
      useExportStore.getState().setError(appError);
      setError(appError.message);
    } finally {
      useExportStore.getState().setProcessing(false);
    }
  };

  const slateCsvDrop = useFileDrop({ disabled: exportState.processing || recognition.running, onFile: loadSlateCsv });
  // Loading a Resolve CSV must be blocked while a directory scan is in flight:
  // the scan is keyed to the current CSV and would otherwise land as stale
  // results after the store is cleared for the newly loaded file.
  const resolveCsvDrop = useFileDrop({ disabled: exportState.processing || recognition.running || metadata.scanning, onFile: loadResolveCsv });

  const selectMetadataDirectory = async () => {
    if (!exportState.table || !project) return;
    try {
      const directory = await unwrap(await getSlateSync().files.selectDirectory());
      if (!directory) return;
      useMetadataStore.getState().setDirectory(directory);
      useMetadataStore.getState().setScanning(true);
      const expectedKeys = await getCsvWorkerService().collectMaterialKeys();
      const result = await unwrap(await getSlateSync().files.scanSlateDirectory({
        dirPath: directory.dirPath,
        expectedKeys,
        ...(config?.workflow.slate.maxDirectoryDepth !== undefined ? { maxDepth: config.workflow.slate.maxDirectoryDepth } : {}),
      }));
      useMetadataStore.getState().setResult(result);
      // A re-scan rebuilds the preview tail, so grid edits recorded against the
      // old row layout would drift onto different cells; drop them (legacy
      // clears csvEdits on scan too).
      useExportStore.getState().setEdits({});
      await refreshResolvePreview();
      autosave.markDirty(captureTask());
    } catch (nextError) {
      useMetadataStore.getState().setError(appErrorFromUnknown(nextError));
    } finally {
      useMetadataStore.getState().setScanning(false);
    }
  };

  const mergeSlateCsv = async () => {
    if (!project || !exportState.slateCsvRecords?.length) return;
    setError(null);
    try {
      if (!(await autosave.flush())) throw new Error("当前任务保存失败；请重试保存后再生成结果。");
      const records = await getCsvWorkerService().recordsFromSlateCsv(exportState.slateCsvRecords);
      const operationId = operationGuard.start();
      const data: RecognitionData = {
        provider: "local",
        model: "slate-csv",
        inputMode: "images",
        durationMs: 0,
        pageCount: 0,
        accuracyMode: "standard",
        usage: null,
        ocr: EMPTY_OCR,
        scenario: null,
        result: { sheetTitle: exportState.slateCsvFilename || "场记 CSV", records, warnings: [] },
        projectId: project.id,
        projectSettingsSnapshot: settingsSnapshot(),
        lastRecognitionDefaults: project.lastRecognitionDefaults,
        diagnosticSessionId: null,
        taskId: null,
      };
      invalidateResolvePreview();
      useRecognitionStore.getState().start(operationId, project.id, 0);
      useRecognitionStore.getState().complete(operationId, data);
      await refreshResolvePreview();
      autosave.markDirty(captureTask());
      setToast({ tone: "success", message: `已生成 ${records.length} 条本地记录` });
    } catch (nextError) {
      setError(appErrorFromUnknown(nextError).message);
    }
  };

  const buildRecognitionRequest = async (taskIdOverride?: string | null): Promise<RecognitionRequest> => {
    if (!project) throw new Error("项目上下文已失效。");
    const currentSlate = useSlateStore.getState();
    const activeTaskId = taskIdOverride ?? useTaskStore.getState().activeId;
    const slateCsvRecords = useExportStore.getState().slateCsvRecords;
    const maxRequestBytes = config?.upload.maxRequestBytes || 80 * 1024 * 1024;
    const base = {
      provider: providerId,
      model: modelId,
      pageCount: currentSlate.pageCount,
      accuracyMode,
      scenarioId: scenarioId || null,
      projectId: project.id,
      // autosave.flush() runs before this builder, so a newly persisted draft
      // already has the stable ID that Main must complete instead of cloning.
      ...(activeTaskId ? { taskId: activeTaskId } : {}),
      ...(currentSlate.filename ? { filename: currentSlate.filename } : {}),
      ...(customPrompt.trim() ? { customPrompt: customPrompt.trim() } : {}),
      ...(slateCsvRecords?.length ? { slateCsvRecords } : {}),
    } as const;
    // PDFs are rasterized by PreparationService before this builder runs. The
    // model request deliberately contains only page images so local OCR always
    // precedes every provider call, including optional-OCR fallback runs.
    let imageDataGroups = selectRecognitionImageGroups(currentSlate.imageDataGroups, accuracyMode) as readonly (readonly string[])[];
    let request: RecognitionRequest = { ...base, imageDataGroups };
    if (requestBodyFits(JSON.stringify(request), maxRequestBytes)) return request;
    for (const profile of REQUEST_COMPRESSION_PROFILES as readonly { maxDimension: number; quality: number }[]) {
      imageDataGroups = await getPreparationService().recompress(imageDataGroups, profile, (progress, message) => {
        useSlateStore.getState().setPreparing(true, progress, message);
      });
      request = { ...base, imageDataGroups };
      if (requestBodyFits(JSON.stringify(request), maxRequestBytes)) {
        useSlateStore.getState().setInput({
          filename: currentSlate.filename || "已准备的场记单",
          fileType: currentSlate.fileType || "image/jpeg",
          fileSize: currentSlate.fileSize,
          pageCount: currentSlate.pageCount,
          imageDataGroups,
        });
        return request;
      }
    }
    useSlateStore.getState().setPreparing(false);
    throw new Error(`处理后的场记单仍有 ${(requestBodyBytes(JSON.stringify(request)) / 1024 / 1024).toFixed(1)} MB，超过上传限制，请拆分 PDF 后重试。`);
  };

  const runRecognition = async () => {
    if (!project) return;
    // Local Slate CSV merge deliberately precedes provider validation: this
    // path must remain usable on an offline machine with no API credentials.
    if (!slate.imageDataGroups.length && exportState.slateCsvRecords?.length) { await mergeSlateCsv(); return; }
    if (!providerId || !modelId) return;
    if (!slate.imageDataGroups.length) return;
    setError(null);
    cancelRequestedRef.current = false;
    // Cover the short preparation/autosave window before the global store is
    // marked running; a log detour during that window must not release inputs.
    recognitionInFlightRef.current = true;
    let activeOperationId: number | null = null;
    try {
      if (!(await autosave.flush())) throw new Error("当前任务保存失败；请重试保存后再开始识别。");
      // Prefer the ID returned by the completed save; activeId belongs to the
      // mounted Workspace and can still be null after a log detour.
      const persistedTaskId = autosave.getLastSavedTaskId() || useTaskStore.getState().activeId;
      const request = await buildRecognitionRequest(persistedTaskId);
      const operationId = operationGuard.start();
      activeOperationId = operationId;
      invalidateResolvePreview();
      // Bind the durable owner atomically with running state so Main updates
      // the draft even when this Workspace instance is no longer mounted.
      useRecognitionStore.getState().start(operationId, project.id, slate.pageCount, persistedTaskId);
      const api = getSlateSync();
      {
        const result = await unwrap(await api.recognition.run(request));
        if (result.projectId !== project.id) return;
        useRecognitionStore.getState().complete(operationId, result);
        await refreshResolvePreview();
        // A route change invalidates workspace-owned mutations, but the
        // completed global recognition state remains useful to LogViewerPage.
        if (!workspaceMountedRef.current || !operationGuard.isCurrent(operationId)) return;
        if (result.taskId) {
          autosave.reset();
          useTaskStore.getState().setActive(result.taskId, { ...captureTask(), id: result.taskId, projectId: project.id });
          useTaskStore.getState().setSaveState("saved");
        } else {
          autosave.markDirty(captureTask());
        }
        await refreshTasks(project.id);
        setToast({ tone: "success", message: `识别完成 · ${result.result.records.length} 条记录` });
      }
    } catch (nextError) {
      const appError = appErrorFromUnknown(nextError);
      const operationId = activeOperationId ?? useRecognitionStore.getState().operationId;
      if (cancelRequestedRef.current || appError.code === "RECOGNITION_CANCELED" || appError.message.includes("识别已停止")) {
        useRecognitionStore.getState().cancel(operationId);
        if (workspaceMountedRef.current) setError(null);
        return;
      }
      if (useRecognitionStore.getState().operationId === operationId) useRecognitionStore.getState().fail(operationId, appError);
      if (workspaceMountedRef.current && operationGuard.isCurrent(operationId)) setError(appError.message);
    } finally {
      recognitionInFlightRef.current = false;
      useSlateStore.getState().setPreparing(false);
    }
  };

  const stopRecognition = async () => {
    if (!project || !recognition.running || recognition.phase === "stopping") return;
    const operationId = useRecognitionStore.getState().operationId;
    cancelRequestedRef.current = true;
    useRecognitionStore.getState().requestCancel(operationId);
    try {
      const result = await unwrap(await getSlateSync().recognition.cancel({ projectId: project.id }));
      if (!result.canceled) {
        cancelRequestedRef.current = false;
        useRecognitionStore.getState().cancelRequestFailed(operationId);
        setError("没有可停止的识别任务。");
        return;
      }
      operationGuard.invalidate();
      useRecognitionStore.getState().cancel(operationId);
      setToast({ tone: "neutral", message: "识别已停止" });
    } catch (nextError) {
      cancelRequestedRef.current = false;
      useRecognitionStore.getState().cancelRequestFailed(operationId);
      setError(appErrorFromUnknown(nextError).message);
    }
  };

  // Keep the global listener stable while always invoking the latest draft and
  // project state captured by the recognition action.
  runRecognitionRef.current = () => { void runRecognition(); };

  useEffect(() => {
    const onShortcut = () => runRecognitionRef.current();
    window.addEventListener(RECOGNITION_SHORTCUT_EVENT, onShortcut);
    return () => window.removeEventListener(RECOGNITION_SHORTCUT_EVENT, onShortcut);
  }, []);

  const exportCsv = async () => {
    const records = useRecognitionStore.getState().records;
    if (!project || !records.length) return;
    useExportStore.getState().setProcessing(true);
    setError(null);
    try {
      const settings = settingsSnapshot();
      const filename = `${(slate.filename || project.name).replace(/\.[^.]+$/, "")}.resolve.csv`;
      const slateMetadata: ScannedSlateMetadata[] = metadata.result?.metadata ? [...metadata.result.metadata] : [];
      const bytes = exportState.table
        ? await getCsvWorkerService().exportResolve({ type: "export-resolve", records, csvEdits: Object.entries(exportState.edits), slateMetadata, fieldFormats: settings.resolve.fieldFormats, comments: settings.resolve.comments })
        : await getCsvWorkerService().exportStandalone({ type: "export-standalone", records, fieldFormats: settings.resolve.fieldFormats, comments: settings.resolve.comments });
      const saved = await unwrap(await getSlateSync().files.save({ defaultFilename: filename, data: bytes }));
      if (saved.saved) setToast({ tone: "success", message: saved.filePath ? `已保存：${saved.filePath}` : "Resolve CSV 已保存" });
    } catch (nextError) {
      const appError = appErrorFromUnknown(nextError);
      useExportStore.getState().setError(appError);
      setError(appError.message);
    } finally {
      useExportStore.getState().setProcessing(false);
    }
  };

  const canExport = Boolean(
    project &&
      recognition.records.length &&
      !exportState.processing &&
      !recognition.running &&
      !switchingTask,
  );
  // Keep the parent toolbar callback stable while this ref follows the latest
  // draft, project, metadata, table edits, and export error handling closure.
  exportCsvRef.current = () => { void exportCsv(); };
  const invokeToolbarExport = useCallback(() => exportCsvRef.current(), []);
  useEffect(() => {
    if (!registerToolbarExport) return undefined;
    registerToolbarExport(invokeToolbarExport, { canExport, processing: exportState.processing });
    return () => registerToolbarExport(null);
  }, [canExport, exportState.processing, invokeToolbarExport, registerToolbarExport]);

  if (!project) return <div className={styles.page}><InlineError message="请先从项目库打开一个项目。" /></div>;
  const settings = project.settings || defaultSettings(config);
  const provider = config?.providers.find((item) => item.id === providerId);
  const availableModels = models.length
    ? models
    : config?.models.filter((item) => item.providers.includes(providerId)) || [];
  const selectableModels = availableModels.filter((model) => !model.capabilityStatus || ["declared", "inferred", "verified"].includes(model.capabilityStatus));
  const modelGroups = groupModelOptions(providerId, selectableModels);
  const staleProvider = Boolean(providerId && !config?.providers.some((item) => item.id === providerId));
  // An empty selectable list is also stale when a project remembers a model:
  // pending/failed probes must never fall through to an unverified request.
  const staleModel = Boolean(modelId && !selectableModels.some((model) => model.id === modelId));
  const canMergeLocal = Boolean(!slate.imageDataGroups.length && exportState.slateCsvRecords?.length);
  const canRecognize = Boolean((canMergeLocal || (slate.imageDataGroups.length && provider?.configured && modelId && !staleProvider && !staleModel)) && !recognition.running && !slate.preparing && !switchingTask);

  return (
    <div className={styles.page} hidden={hidden}>
      <div className={styles.pageHeader}>
        <div><p className={styles.eyebrow}>工作台</p><h1 className={styles.heading}>{project.name}</h1></div>
        <div className={styles.pageActions}><Badge tone={provider?.configured ? "success" : "warning"}>{provider?.configured ? `${provider.label} 已就绪` : "Provider 未配置"}</Badge></div>
      </div>
      {error && <div style={{ marginBottom: 16 }}>{useTaskStore.getState().saveState === "error" ? <InlineError message={error} onRetry={() => void autosave.retry()} /> : <InlineError message={error} />}</div>}
      {staleProvider && <div style={{ marginBottom: 16 }}><InlineError message="已保存的 Provider 已被删除，请前往项目设置重新选择。" /></div>}
      {staleModel && <div style={{ marginBottom: 16 }}><InlineError message="已保存的模型不可用或探针已失效，请重新选择。" /></div>}
      <div className={styles.workspaceGrid}>
        <div className={styles.workspaceLeft}>
          <Surface className={styles.panel}><TaskRail onSelect={(id) => void loadTask(id)} onRefresh={() => void refreshTasks()} onNew={() => void newTask()} onDelete={setDeleteTaskId} onRetrySave={() => void autosave.retry()} switching={switchingTask} /></Surface>
          <SlateInputPanel ref={slatePanelRef} onInputChanged={() => autosave.markDirty(captureTask())} />
          {/* Keep optional sources together before recognition so the user can
              finish all supporting-data choices before starting the job. */}
          <Surface className={styles.panel}>
            <div className={styles.sectionHeader}><div><p className={styles.kicker}>可选</p><h2 className={styles.sectionTitle}>可选输入</h2></div><FolderSearch size={18} aria-hidden="true" /></div>
            <Text tone="muted" size="sm">载入 CSV 可辅助识别或回填；素材目录可补充帧率和拍摄日。</Text>
            <Stack direction="row" gap={2} align="center" wrap style={{ marginTop: 14 }}>
              {/* Both CSV sources use the same outlined affordance so neither
                  input is visually mistaken for an unbounded text action. */}
              <span className={styles.fileDropTarget} data-dragging={slateCsvDrop.dragging || undefined} {...slateCsvDrop.dropProps}><input ref={slateCsvInputRef} type="file" accept=".csv,text/csv" hidden onChange={(event) => { const file = event.target.files?.[0]; if (file) void loadSlateCsv(file); event.currentTarget.value = ""; }} /><Button type="button" variant="secondary" size="sm" onClick={() => slateCsvInputRef.current?.click()} startIcon={<FileSpreadsheet size={14} />}>场记 CSV</Button></span>
              <span className={styles.fileDropTarget} data-dragging={resolveCsvDrop.dragging || undefined} {...resolveCsvDrop.dropProps}><input ref={resolveCsvInputRef} type="file" accept=".csv,text/csv" hidden disabled={exportState.processing || recognition.running || metadata.scanning} onChange={(event) => { const file = event.target.files?.[0]; if (file) void loadResolveCsv(file); event.currentTarget.value = ""; }} /><Button type="button" variant="secondary" size="sm" disabled={exportState.processing || recognition.running || metadata.scanning} onClick={() => resolveCsvInputRef.current?.click()} startIcon={<FileSpreadsheet size={14} />}>Resolve CSV</Button></span>
              {exportState.slateCsvRecords && <Badge tone="accent">场记 CSV · {exportState.slateCsvRecords.length} 条</Badge>}
              {exportState.table && <Badge tone="success">Resolve CSV · {exportState.table.rows.length} 行</Badge>}
            </Stack>
            {exportState.slateCsvRecords && <Button variant="ghost" size="sm" style={{ marginTop: 8 }} onClick={() => useExportStore.getState().setSlateCsvRecords(null, null)}>移除场记 CSV</Button>}
            <div style={{ marginTop: 16, paddingTop: 16, borderTop: "1px solid var(--ss-color-line)" }}>
              <Text as="h3" size="sm" weight="medium">素材元数据回填</Text>
              <Text tone="muted" size="sm" style={{ marginTop: 5 }}>从素材目录回填帧率和拍摄日。</Text>
              <Stack direction="row" gap={2} align="center" style={{ marginTop: 14 }}><Button variant="secondary" size="sm" disabled={!exportState.table || metadata.scanning} loading={metadata.scanning} onClick={() => void selectMetadataDirectory()} startIcon={<FolderSearch size={14} />}>选择素材目录</Button>{metadata.result && <Badge tone="success">{metadata.result.metadata.length} 个元数据</Badge>}</Stack>
              {metadata.result?.warnings.length ? <Text tone="warning" size="xs" style={{ marginTop: 10 }}>{metadata.result.warnings[0]}</Text> : null}
            </div>
          </Surface>
          <Surface className={styles.panel}>
            <div className={styles.sectionHeader}><div><p className={styles.kicker}>02 / 识别</p><h2 className={styles.sectionTitle}>识别设置</h2></div><Play size={18} aria-hidden="true" /></div>
            <div className={styles.grid}>
              <Field label="Provider"><Select value={providerId} onChange={(event) => { patchDraft({ providerId: event.target.value, modelId: "" }); markDirtyAfterRender(); }} disabled={recognition.running}><option value="">选择 Provider</option>{staleProvider && <option value={providerId}>{providerId} · 接口已移除</option>}{config?.providers.map((item) => <option key={item.id} value={item.id}>{item.label}{item.configured ? "" : " · 未配置"}</option>)}</Select></Field>
              <Field label="模型"><ModelSelect value={modelId} groups={modelGroups} onChange={(nextModelId) => { patchDraft({ modelId: nextModelId }); markDirtyAfterRender(); }} disabled={recognition.running} placeholder="选择视觉模型" /></Field>
              <Field label="识别模式"><Select value={accuracyMode} onChange={(event) => { patchDraft({ accuracyMode: event.target.value as "high" | "standard" }); markDirtyAfterRender(); }} disabled={recognition.running}><option value="high">精确 · 主识别 + 查漏</option><option value="standard">快速 · 单次识别</option></Select></Field>
              <Field label="场记结构"><Select value={scenarioId} onChange={(event) => { patchDraft({ scenarioId: event.target.value }); markDirtyAfterRender(); }} disabled={recognition.running}><option value="">自动识别</option>{scenarios.map((scenario) => <option key={scenario.id} value={scenario.id}>{scenario.label} · {scenario.sampleCount} 次</option>)}</Select></Field>
              <Field label="识别提示" hint="可选"><Textarea className="resize-none" value={customPrompt} onChange={(event) => { patchDraft({ customPrompt: event.target.value }); markDirtyAfterRender(); }} maxLength={2000} showCount disabled={recognition.running} placeholder={settings.customPrompt || "补充文字或机位约定"} /></Field>
              <Stack direction="row" gap={2} align="center">
                <Button size="lg" onClick={() => void runRecognition()} disabled={!canRecognize} loading={(recognition.running && recognition.phase !== "stopping") || slate.preparing} startIcon={<Play size={16} />}>{canMergeLocal ? "从场记 CSV 生成结果" : "开始识别"}</Button>
                <Button variant="danger" size="lg" onClick={() => void stopRecognition()} disabled={!recognition.running || recognition.phase === "stopping"} loading={recognition.phase === "stopping"} startIcon={<Square size={14} />}>停止</Button>
              </Stack>
              {!provider?.configured && !canMergeLocal && <Text tone="warning" size="xs">未配置 Provider 密钥。可前往全局设置，或载入场记 CSV。</Text>}
            </div>
          </Surface>
        </div>

        <div className={styles.workspaceMain}>
          <Surface className={styles.panel}>
            <Stack direction="row" justify="between" align="center"><div><p className={styles.kicker}>预览</p><h2 className={styles.sectionTitle}>场记单</h2>{slate.imageDataGroups.length > 0 && <Text tone="subtle" size="xs" style={{ marginTop: 4 }}>点击页面可放大查看</Text>}</div><Stack direction="row" gap={2} align="center"><Text tone="subtle" size="xs" mono>{slate.pageCount ? `${slate.pageCount} 页` : "未载入"}</Text>{slate.filename && <Button variant="ghost" size="sm" onClick={() => slatePanelRef.current?.openPicker()} startIcon={<Upload size={14} />}>替换</Button>}</Stack></Stack>
            {slate.imageDataGroups.length ? <div ref={slatePreviewRef} tabIndex={-1} aria-label="场记单预览" className={styles.preview} style={{ marginTop: 14 }}><div className={styles.previewPages}>{previewPages.map(({ page, source }) => {
              const pageLabel = `${slate.filename || "场记单"} 第 ${page + 1} 页`;
              return <button type="button" className={styles.previewPageButton} key={`${slate.filename}-${page}`} aria-label={`放大查看${pageLabel}`} onClick={() => selectPreviewPage(page)}>
                <span className={styles.previewPage}><img src={source} alt={pageLabel} /><span>{String(page + 1).padStart(2, "0")}</span></span>
              </button>;
            })}</div></div> : <div className={styles.routeHint} style={{ marginTop: 14 }}>载入场记单后显示预览。</div>}
            {recognition.running && <div className={styles.recognitionBanner} style={{ marginTop: 14 }}>
              <div className={styles.recognitionBannerHeader}><Stack direction="row" gap={2} align="center"><Badge tone="accent">{recognition.phase}</Badge><Text size="sm" weight="medium">{recognition.message}</Text></Stack><Text tone="accent" size="sm" mono>{Math.round(recognition.percent)}%</Text></div>
              <Progress value={recognition.percent} label="识别进度" />
              <Text tone="subtle" size="xs">{recognition.completedPages} / {recognition.totalPages} 页</Text>
              {recognition.resumeOnWorkspace && <Text tone="accent" size="xs">已从日志页返回，识别任务仍在后台继续。</Text>}
              {/* Announce only the durable warning; rapidly changing progress keeps its own progressbar semantics. */}
              {recognition.warning && <div className={styles.warningItem} role="status" aria-live="polite" aria-atomic="true">{recognition.warning}</div>}
            </div>}
          </Surface>

          <Surface className={styles.panel}>
            <div className={styles.sectionHeader}>
              {/* CSV selection lives in the optional-input surface; this panel
                  stays focused on previewing and editing the merged result. */}
              <div><p className={styles.kicker}>03 / CSV</p><h2 className={styles.sectionTitle}>回填预览</h2></div>
              {exportState.table && <Stack direction="row" gap={2} align="center" wrap><Button variant="ghost" size="sm" onClick={() => { previewGuard.invalidate(); void getCsvWorkerService().clear(); useExportStore.getState().setTable(null, null); autosave.markDirty(captureTask()); }} startIcon={<RefreshCw size={14} />}>清除表格</Button></Stack>}
            </div>
            {exportState.error && <InlineError message={exportState.error.message} />}
            {(exportState.previewTable || exportState.table) && <div style={{ marginTop: 14 }}><CsvVirtualTable table={exportState.previewTable || exportState.table} edits={exportState.edits} onEdit={onEdit} /></div>}
            {!exportState.table && <div className={styles.routeHint} style={{ marginTop: 14 }}>请在左侧可选输入中载入 Resolve CSV 后预览并编辑回填结果。</div>}
          </Surface>
          <RecognitionResultPanel onRecordEdited={() => { void refreshResolvePreview(); autosave.markDirty(captureTask()); }} />
        </div>
      </div>

      <Dialog
        open={Boolean(deleteTaskId)}
        title="删除任务？"
        description="此操作不可撤销。"
        onClose={() => !switchingTask && setDeleteTaskId(null)}
        footer={<Stack direction="row" gap={2} justify="end"><Button variant="ghost" onClick={() => setDeleteTaskId(null)} disabled={switchingTask}>取消</Button><Button variant="danger" onClick={() => void deleteTask()} loading={switchingTask}>确认删除</Button></Stack>}
      >
        <Text tone="muted" size="sm">只删除当前选中的任务。</Text>
      </Dialog>

      <Dialog
        open={Boolean(selectedPreview)}
        title={selectedPreview ? `${slate.filename || "场记单"} · 第 ${selectedPreview.page + 1} 页` : "场记单预览"}
        description="左右滑动触控板或使用 ← → 切换页面；按 Escape 或关闭按钮返回预览。"
        onClose={() => setPreviewSelection(null)}
        onKeyDown={handlePreviewKeyDown}
        size="wide"
        footer={<Stack className={styles.previewLightboxFooter} direction="row" justify="between" align="center"><Button type="button" variant="ghost" onClick={() => movePreviewPage(-1)} disabled={selectedPreviewPosition <= 0} startIcon={<ChevronLeft size={15} aria-hidden="true" />}>上一页</Button><Text tone="subtle" size="xs" mono>{selectedPreviewPosition >= 0 ? `${selectedPreviewPosition + 1} / ${previewPages.length}` : ""}</Text><Button type="button" variant="ghost" onClick={() => movePreviewPage(1)} disabled={selectedPreviewPosition < 0 || selectedPreviewPosition >= previewPages.length - 1} endIcon={<ChevronRight size={15} aria-hidden="true" />}>下一页</Button></Stack>}
      >
        {selectedPreview && <div className={styles.previewLightbox} onWheel={handlePreviewWheel}>
          <img src={selectedPreview.source} alt={`${slate.filename || "场记单"} 第 ${selectedPreview.page + 1} 页，大图`} draggable={false} />
        </div>}
      </Dialog>
    </div>
  );
}

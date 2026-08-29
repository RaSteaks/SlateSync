import { readFile } from "node:fs/promises";
import { describe, expect, it } from "vitest";

const workspaceSource = new URL("../../../src/renderer/features/workspace/WorkspacePage.tsx", import.meta.url);
const appSource = new URL("../../../src/renderer/App.tsx", import.meta.url);
const preparationWorkerSource = new URL("../../../src/renderer/workers/preparation.worker.ts", import.meta.url);

describe("workspace task lifecycle", () => {
  it("forwards the autosaved draft ID into recognition", async () => {
    const source = await readFile(workspaceSource, "utf8");

    // The save result remains available when the Workspace route is gone, so
    // Main receives the durable owner instead of creating a second task.
    expect(source).toContain("const persistedTaskId = autosave.getLastSavedTaskId() || useTaskStore.getState().activeId");
    expect(source).toContain("buildRecognitionRequest(persistedTaskId)");
    expect(source).toContain("start(operationId, project.id, slate.pageCount, persistedTaskId)");
  });

  it("announces only the persistent OCR warning as live status", async () => {
    const source = await readFile(workspaceSource, "utf8");
    const bannerTag = source.match(/recognition\.running && <div className=\{styles\.recognitionBanner\}[^>]*>/)?.[0];

    // Page and percentage updates can be frequent, so the banner itself must
    // not queue every progress mutation for assistive technology.
    expect(bannerTag).toBeDefined();
    expect(bannerTag).not.toContain('role="status"');
    expect(bannerTag).not.toContain('aria-live=');
    expect(source).toContain('recognition.warning && <div className={styles.warningItem} role="status" aria-live="polite" aria-atomic="true">');
  });

  it("registers Resolve CSV export in the sticky workspace toolbar", async () => {
    const [workspace, app] = await Promise.all([
      readFile(workspaceSource, "utf8"),
      readFile(appSource, "utf8"),
    ]);

    // Export keeps the workspace-owned settings and Worker state while the
    // shell owns the fixed top-row trigger and its visible async state.
    expect(workspace).toContain("registerToolbarExport(invokeToolbarExport");
    expect(workspace).toContain("return () => registerToolbarExport(null)");
    expect(workspace).not.toContain(">导出 Resolve CSV</Button>");
    expect(app).toContain("registerToolbarExport={registerWorkspaceToolbarExport}");
    expect(app).toContain("workspaceExportRef.current?.()");
    expect(app).toContain(">导出 Resolve CSV</Button>");
  });

  it("refreshes the visible Resolve preview from completed recognition", async () => {
    const source = await readFile(workspaceSource, "utf8");

    // The raw table remains the durable source while previewTable is rebuilt
    // through the CSV Worker after recognition or record edits.
    expect(source).toContain('mergePreview({');
    expect(source).toContain('useExportStore.getState().setPreviewTable(previewTable)');
    expect(source).toContain('exportState.previewTable || exportState.table');
    expect(source).toContain('useRecognitionStore.getState().complete(operationId, result);\n        await refreshResolvePreview();');
  });

  it("clears the previous Resolve preview before starting a new run", async () => {
    const source = await readFile(workspaceSource, "utf8");

    // Cancellation or failure must not leave the prior run's merged projection
    // visible while the raw CSV remains available for the next attempt.
    expect(source).toContain("const invalidateResolvePreview = useCallback(() => {");
    expect(source).toContain("invalidateResolvePreview();\n      useRecognitionStore.getState().start(operationId, project.id, 0);");
    expect(source).toContain("invalidateResolvePreview();");
    expect(source).toContain("useRecognitionStore.getState().start(operationId, project.id, slate.pageCount, persistedTaskId);");
  });

  it("keeps recognition progress global and prepares detail views for image uploads", async () => {
    const [workspace, app, worker] = await Promise.all([
      readFile(workspaceSource, "utf8"),
      readFile(appSource, "utf8"),
      readFile(preparationWorkerSource, "utf8"),
    ]);

    expect(app).toContain("getSlateSync().recognition.onProgress");
    expect(workspace).toContain("markWorkspaceHandoff");
    expect(workspace).toContain("resumeFromLogViewer");
    expect(worker).toContain("return preparePageViews(canvas, 0.92, 0.93);");
    expect(worker).toContain("const imageDataGroups = isPdf ? await rasterizePdf(data, id) : [await rasterizeImage(data, fileType)];");
  });

  it("keeps the workspace mounted across logs and settings, then refreshes on return", async () => {
    const [workspace, app] = await Promise.all([
      readFile(workspaceSource, "utf8"),
      readFile(appSource, "utf8"),
    ]);

    expect(app).toContain('route !== "projects" && <WorkspacePage');
    expect(app).toContain('hidden={route !== "workspace"}');
    expect(workspace).toContain("const refreshWorkspaceAfterRouteReturn = useCallback");
    expect(workspace).toContain("preparation.terminateWhenIdle()");
    expect(workspace).toContain("preparation.keepAlive()");
    expect(workspace).toContain("await autosave.flush()");
    expect(workspace).toContain("getSlateSync().tasks.load({ projectId, id: activeTaskId })");
    expect(workspace).toContain("await refreshTasks(projectId)");
  });

  it("opens slate preview pages in an accessible enlarged dialog", async () => {
    const source = await readFile(workspaceSource, "utf8");

    // Preview pages remain native buttons, so mouse and keyboard activation
    // share the same lightbox path and the shared Dialog restores focus.
    expect(source).toContain("const previewPages = useMemo");
    expect(source).toContain("onClick={() => selectPreviewPage(page)}");
    expect(source).toContain("aria-label={`放大查看${pageLabel}`}");
    expect(source).toContain('description="左右滑动触控板或使用 ← → 切换页面；按 Escape 或关闭按钮返回预览。"');
    expect(source).toContain('size="wide"');
    expect(source).toContain("handlePreviewWheel");
    expect(source).toContain("event.deltaX");
    expect(source).toContain("previewWheelLockedRef");
    expect(source).toContain("schedulePreviewWheelUnlock");
    expect(source).toContain("window.setTimeout");
    expect(source).toContain("movePreviewPage(event.key === \"ArrowRight\" ? 1 : -1)");
    expect(source).toContain(">上一页</Button>");
    expect(source).toContain(">下一页</Button>");
    expect(source).toContain("previewLightbox");
  });

  it("reloads task history when the workspace enters a project", async () => {
    const [source, app] = await Promise.all([
      readFile(workspaceSource, "utf8"),
      readFile(appSource, "utf8"),
    ]);

    // App marks the opening projection, while Workspace only refreshes when
    // that marker is absent or a log handoff explicitly requires reloading.
    expect(app).toContain("setItems(tasks, id)");
    expect(source).toContain("loadedTaskProjectId");
    expect(source).toContain("if (loadedTaskProjectId === projectId && !returningFromLogViewer) return undefined;");
    expect(source).toContain("void refreshTasks(projectId);");
    expect(source).toContain("useTaskStore.getState().setError(null);");
  });

  it("refreshes the task rail after restoring a log handoff", async () => {
    const source = await readFile(workspaceSource, "utf8");

    expect(source).toContain("await applyTask(taskId, task);\n        } else {");
    expect(source).toContain("await refreshTasks(project.id);");
  });

  it("provides searchable historical task feedback", async () => {
    const source = await readFile(new URL("../../../src/renderer/features/tasks/TaskRail.tsx", import.meta.url), "utf8");

    expect(source).toContain('aria-label="搜索历史任务"');
    expect(source).toContain("taskSearchText");
    expect(source).toContain("count: visibleTasks.length");
    expect(source).toContain('title="没有匹配任务"');
    expect(source).toContain("清除搜索");
  });
});

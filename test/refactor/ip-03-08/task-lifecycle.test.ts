import { readFile } from "node:fs/promises";
import { describe, expect, it } from "vitest";

const workspaceSource = new URL("../../../src/renderer/features/workspace/WorkspacePage.tsx", import.meta.url);
const appSource = new URL("../../../src/renderer/App.tsx", import.meta.url);

describe("workspace task lifecycle", () => {
  it("forwards the autosaved draft ID into recognition", async () => {
    const source = await readFile(workspaceSource, "utf8");

    // Recognition starts only after autosave.flush(), so activeId is the
    // persisted draft identity that Main must update to completed.
    expect(source).toContain("const activeTaskId = useTaskStore.getState().activeId");
    expect(source).toContain("...(activeTaskId ? { taskId: activeTaskId } : {})");
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
    expect(source).toContain("invalidateResolvePreview();\n      useRecognitionStore.getState().start(operationId, project.id, slate.pageCount);");
  });
});

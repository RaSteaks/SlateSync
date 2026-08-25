import { readFile } from "node:fs/promises";
import { describe, expect, it } from "vitest";

const workspaceSource = new URL("../../../src/renderer/features/workspace/WorkspacePage.tsx", import.meta.url);

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
});

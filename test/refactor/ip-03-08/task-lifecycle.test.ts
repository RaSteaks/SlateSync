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
});

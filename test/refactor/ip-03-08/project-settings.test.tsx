// @vitest-environment jsdom
import { act } from "react";
import { createRoot } from "react-dom/client";
import { afterEach, describe, expect, it, vi } from "vitest";
import type { ProjectData, SlateSyncApi } from "../../../src/shared/contracts/index.js";
import { ProjectSettingsPage } from "../../../src/renderer/features/settings/ProjectSettingsPage";
import { useProjectStore, useRecognitionStore, useUiStore } from "../../../src/renderer/state";

// Keep React's concurrent scheduler assertions deterministic in jsdom.
(globalThis as { IS_REACT_ACT_ENVIRONMENT?: boolean }).IS_REACT_ACT_ENVIRONMENT = true;

const mounted: Array<{ host: HTMLDivElement; root: ReturnType<typeof createRoot> }> = [];

afterEach(() => {
  for (const { host, root } of mounted.splice(0)) {
    act(() => root.unmount());
    host.remove();
  }
  useProjectStore.setState({ config: null, projects: [], current: null, scenarios: [], error: null });
  useRecognitionStore.getState().reset();
  useUiStore.setState({ toast: null });
  Object.defineProperty(window, "slateSync", { configurable: true, value: undefined });
});

function buttonNamed(name: string): HTMLButtonElement {
  const button = [...document.body.querySelectorAll("button")].find((candidate) => candidate.textContent?.trim() === name);
  if (!(button instanceof HTMLButtonElement)) throw new Error(`missing button: ${name}`);
  return button;
}

describe("project deletion confirmation", () => {
  it("requires both dialogs and an exact project-name confirmation before deleting", async () => {
    const project = {
      id: "project-delete",
      name: "待删除项目",
      description: "",
      relativePath: "projects/project-delete",
      archivedAt: null,
      createdAt: "2026-01-01T00:00:00.000Z",
      updatedAt: "2026-01-01T00:00:00.000Z",
      taskCount: 0,
      latestTaskAt: null,
      canArchive: true,
      settings: { version: 1, providerId: null, modelId: null, accuracyMode: "high", scenarioId: null, customPrompt: "", resolve: { fieldFormats: { scene: "XXX", shot: "XX", take: "XX" }, comments: { goodTake: "_OK", holdTake: "_KP" } } },
      lastRecognitionDefaults: null,
    } satisfies ProjectData;
    const deleteProject = vi.fn(async () => ({ ok: true as const, data: { deleted: project.id } }));
    const api = {
      projects: {
        listScenarios: vi.fn(async () => ({ ok: true as const, data: [] })),
        delete: deleteProject,
      },
    } as unknown as SlateSyncApi;
    Object.defineProperty(window, "slateSync", { configurable: true, value: api });
    useProjectStore.setState({ current: project, projects: [project] });
    const onDeleted = vi.fn();
    const host = document.createElement("div");
    document.body.append(host);
    const root = createRoot(host);
    mounted.push({ host, root });

    await act(async () => {
      root.render(<ProjectSettingsPage onBack={() => undefined} onDeleted={onDeleted} />);
      await Promise.resolve();
    });
    expect(deleteProject).not.toHaveBeenCalled();

    act(() => buttonNamed("删除项目").click());
    expect(document.body.querySelector('[role="dialog"]')?.textContent).toContain("此操作不可撤销");
    expect(deleteProject).not.toHaveBeenCalled();

    act(() => buttonNamed("继续确认").click());
    const dialog = document.body.querySelector<HTMLElement>('[role="dialog"]');
    const confirmation = dialog?.querySelector("input");
    const permanentDelete = buttonNamed("永久删除");
    expect(dialog?.textContent).toContain("输入“待删除项目”以确认");
    expect(permanentDelete.disabled).toBe(true);

    act(() => {
      const valueSetter = Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, "value")?.set;
      valueSetter?.call(confirmation, project.name);
      confirmation?.dispatchEvent(new Event("input", { bubbles: true }));
    });
    expect(buttonNamed("永久删除").disabled).toBe(false);

    await act(async () => {
      buttonNamed("永久删除").click();
      await Promise.resolve();
    });
    expect(deleteProject).toHaveBeenCalledWith({ id: project.id });
    expect(onDeleted).toHaveBeenCalledWith(project.id);
  });
});

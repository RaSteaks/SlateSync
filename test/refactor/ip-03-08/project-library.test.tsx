// @vitest-environment jsdom
import { act } from "react";
import { createRoot } from "react-dom/client";
import { afterEach, describe, expect, it, vi } from "vitest";
import type { ProjectSummary, SlateSyncApi } from "../../../src/shared/contracts/index.js";
import { ProjectLibraryPage } from "../../../src/renderer/features/projects/ProjectLibraryPage";
import { useProjectStore, useUiStore } from "../../../src/renderer/state";

// Keep React's concurrent renderer deterministic for card hit-area assertions.
(globalThis as { IS_REACT_ACT_ENVIRONMENT?: boolean }).IS_REACT_ACT_ENVIRONMENT = true;

const mounted: Array<{ host: HTMLDivElement; root: ReturnType<typeof createRoot> }> = [];

const project: ProjectSummary = {
  id: "project-card",
  name: "整卡交互测试",
  description: "点击名称外的区域也能进入",
  relativePath: "projects/project-card",
  archivedAt: null,
  createdAt: "2026-08-24T00:00:00.000Z",
  updatedAt: "2026-08-24T00:00:00.000Z",
  taskCount: 3,
  latestTaskAt: "2026-08-24T01:00:00.000Z",
  canArchive: true,
};

afterEach(() => {
  for (const { host, root } of mounted.splice(0)) {
    act(() => root.unmount());
    host.remove();
  }
  useProjectStore.setState({ library: null, projects: [], current: null, loading: false, error: null });
  useUiStore.setState({ dialog: null, toast: null });
  Object.defineProperty(window, "slateSync", { configurable: true, value: undefined });
});

describe("project library cards", () => {
  it("uses one full-card button while keeping settings and archive independent", async () => {
    const archive = vi.fn(async () => ({ ok: true as const, data: { ...project, archivedAt: "2026-08-24T02:00:00.000Z" } }));
    Object.defineProperty(window, "slateSync", {
      configurable: true,
      value: {
        projects: {
          getLibraryInfo: async () => ({ ok: true, data: { id: "library", name: "测试项目库", formatVersion: 1, path: "/tmp/library" } }),
          list: async () => ({ ok: true, data: [project] }),
          archive,
        },
      } as unknown as SlateSyncApi,
    });

    const onOpenProject = vi.fn();
    const onOpenLibrarySettings = vi.fn();
    const host = document.createElement("div");
    document.body.append(host);
    const root = createRoot(host);
    mounted.push({ host, root });
    await act(async () => {
      root.render(<ProjectLibraryPage onOpenProject={onOpenProject} onOpenLibrarySettings={onOpenLibrarySettings} />);
      await Promise.resolve();
    });

    const openButton = host.querySelector<HTMLButtonElement>('button[aria-label="打开项目 整卡交互测试"]');
    const settingsButton = host.querySelector<HTMLButtonElement>('button[aria-label="项目设置"]');
    const archiveButton = [...host.querySelectorAll<HTMLButtonElement>("button")].find((button) => button.textContent?.includes("归档"));
    expect(openButton).not.toBeNull();
    expect(openButton?.contains(host.querySelector("h3"))).toBe(false);
    expect(host.textContent).toContain("在线项目");
    expect(host.textContent).toContain("项目列表");
    expect(host.textContent).not.toContain("当前项目");

    const librarySettingsButton = [...host.querySelectorAll<HTMLButtonElement>("button")].find((button) => button.textContent?.includes("项目库设置"));
    act(() => librarySettingsButton?.click());
    expect(onOpenLibrarySettings).toHaveBeenCalledOnce();

    act(() => openButton?.click());
    expect(onOpenProject).toHaveBeenLastCalledWith(project.id, "workspace");

    onOpenProject.mockClear();
    act(() => settingsButton?.click());
    expect(onOpenProject).toHaveBeenCalledWith(project.id, "project-settings");

    onOpenProject.mockClear();
    await act(async () => archiveButton?.click());
    expect(archive).toHaveBeenCalledWith({ id: project.id });
    expect(onOpenProject).not.toHaveBeenCalled();
  });
});

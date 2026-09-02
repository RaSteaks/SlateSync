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

const project = {
  id: "project-package",
  name: "项目包设置测试",
  description: "项目设置里的传输入口",
  relativePath: "projects/project-package",
  archivedAt: null,
  createdAt: "2026-01-01T00:00:00.000Z",
  updatedAt: "2026-01-01T00:00:00.000Z",
  taskCount: 2,
  latestTaskAt: "2026-01-01T01:00:00.000Z",
  canArchive: true,
  settings: { version: 1, providerId: null, modelId: null, accuracyMode: "high" as const, scenarioId: null, customPrompt: "", resolve: { fieldFormats: { scene: "XXX", shot: "XX", take: "XX" }, comments: { goodTake: "_OK", holdTake: "_KP" } } },
  lastRecognitionDefaults: null,
} satisfies ProjectData;

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

describe("project package settings actions", () => {
  async function renderPage(api: Partial<SlateSyncApi["projects"]>, props: { onPrepareTransfer?: () => Promise<boolean>; onProjectImported?: (projectId: string) => void | boolean | Promise<void | boolean> } = {}) {
    Object.defineProperty(window, "slateSync", {
      configurable: true,
      value: { projects: { listScenarios: vi.fn(async () => ({ ok: true as const, data: [] })), ...api } },
    });
    useProjectStore.setState({ current: project, projects: [project] });
    const host = document.createElement("div");
    document.body.append(host);
    const root = createRoot(host);
    mounted.push({ host, root });
    await act(async () => {
      root.render(<ProjectSettingsPage onBack={() => undefined} onDeleted={() => undefined} {...props} />);
      await Promise.resolve();
    });
    return host;
  }

  it("keeps import/export in project settings, refreshes after import, and preserves cancellation", async () => {
    const imported = { ...project, id: "project-package-copy", name: project.name };
    const list = vi.fn(async () => ({ ok: true as const, data: [project, imported] }));
    const importProject = vi.fn()
      .mockResolvedValueOnce({ ok: true as const, data: { canceled: false as const, project: imported } })
      .mockResolvedValueOnce({ ok: true as const, data: { canceled: true as const } });
    const exportProject = vi.fn(async () => ({ ok: true as const, data: { canceled: false as const, project, path: "/tmp/项目包设置测试.slatesync-project" } }));
    const prepareTransfer = vi.fn(async () => true);
    const onProjectImported = vi.fn();
    const host = await renderPage({ list, importProject, exportProject }, { onPrepareTransfer: prepareTransfer, onProjectImported });

    expect(host.textContent).toContain("项目包");
    const importButton = buttonNamed("导入项目");
    const exportButton = buttonNamed("导出项目");
    await act(async () => {
      exportButton.click();
      await Promise.resolve();
    });
    expect(exportProject).toHaveBeenCalledWith({ id: project.id });
    expect(useUiStore.getState().toast?.message).toContain("项目已导出");

    await act(async () => {
      importButton.click();
      await Promise.resolve();
      await Promise.resolve();
    });
    expect(prepareTransfer).toHaveBeenCalledTimes(2);
    expect(importProject).toHaveBeenCalledOnce();
    expect(list).toHaveBeenCalledOnce();
    expect(useProjectStore.getState().projects.map((item) => item.id)).toEqual([project.id, imported.id]);
    expect(onProjectImported).toHaveBeenCalledOnce();
    expect(onProjectImported).toHaveBeenCalledWith(project.id);
    expect(useUiStore.getState().toast?.message).toContain("项目已导入");

    await act(async () => {
      useUiStore.getState().setToast(null);
      importButton.click();
      await Promise.resolve();
    });
    expect(importProject).toHaveBeenCalledTimes(2);
    expect(list).toHaveBeenCalledOnce();
    expect(onProjectImported).toHaveBeenCalledOnce();
    expect(useUiStore.getState().toast).toBeNull();
  });

  it("keeps a committed import visible when the follow-up project refresh fails", async () => {
    const imported = { ...project, id: "project-package-refresh-fallback" };
    const list = vi.fn(async () => { throw new Error("temporary list outage"); });
    const importProject = vi.fn(async () => ({
      ok: true as const,
      data: { canceled: false as const, project: imported },
    }));
    const onProjectImported = vi.fn();
    await renderPage({ list, importProject }, { onProjectImported });

    await act(async () => {
      buttonNamed("导入项目").click();
      await Promise.resolve();
      await Promise.resolve();
      await Promise.resolve();
    });

    expect(importProject).toHaveBeenCalledOnce();
    expect(useProjectStore.getState().projects.map((item) => item.id)).toContain(imported.id);
    expect(useUiStore.getState().toast).toMatchObject({ tone: "warning" });
    expect(useUiStore.getState().toast?.message).toContain("列表刷新失败");
    expect(onProjectImported).toHaveBeenCalledWith(project.id);
  });

  it("blocks package transfer while project settings edits are unsaved", async () => {
    const importProject = vi.fn(async () => ({
      ok: true as const,
      data: { canceled: true as const },
    }));
    const host = await renderPage({ importProject });
    const nameInput = [...host.querySelectorAll<HTMLInputElement>("input")]
      .find((input) => input.value === project.name);
    expect(nameInput).toBeDefined();

    act(() => {
      const valueSetter = Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, "value")?.set;
      valueSetter?.call(nameInput, `${project.name}（已修改）`);
      nameInput?.dispatchEvent(new Event("input", { bubbles: true }));
    });

    expect(host.textContent).toContain("未保存的修改不会随项目包传输");
    expect(buttonNamed("导入项目").disabled).toBe(true);
    expect(buttonNamed("导出项目").disabled).toBe(true);
    expect(importProject).not.toHaveBeenCalled();
  });

  it("does not open the picker when workspace preparation fails", async () => {
    const prepareTransfer = vi.fn(async () => false);
    const importProject = vi.fn(async () => ({ ok: true as const, data: { canceled: true as const } }));
    const host = await renderPage({ importProject }, { onPrepareTransfer: prepareTransfer });

    await act(async () => {
      buttonNamed("导入项目").click();
      await Promise.resolve();
    });
    expect(prepareTransfer).toHaveBeenCalledOnce();
    expect(importProject).not.toHaveBeenCalled();
    expect(host.textContent).toContain("项目包");
  });

  it("disables duplicate project package actions while an export is pending", async () => {
    let resolveExport!: (value: { ok: true; data: { canceled: true } }) => void;
    const exportProject = vi.fn(() => new Promise<{ ok: true; data: { canceled: true } }>((resolve) => {
      resolveExport = resolve;
    }));
    await renderPage({ exportProject });

    const exportButton = buttonNamed("导出项目");
    await act(async () => {
      exportButton.click();
      await Promise.resolve();
    });
    expect(exportProject).toHaveBeenCalledOnce();
    expect(exportButton.disabled).toBe(true);
    exportButton.click();
    expect(exportProject).toHaveBeenCalledOnce();

    await act(async () => {
      resolveExport({ ok: true, data: { canceled: true } });
      await Promise.resolve();
    });
  });
});

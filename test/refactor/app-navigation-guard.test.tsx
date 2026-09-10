// @vitest-environment jsdom
/// <reference types="node" />
// First shell-mount test: the unsaved global-settings draft must gate every
// shell route change through the guard dialog.
import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { afterEach, describe, expect, it, vi } from "vitest";
import type { ConfigData, GlobalSettingsData, SlateSyncApi } from "../../src/shared/contracts/index.js";
import { App } from "../../src/renderer/App";
import { useGlobalSettingsStore, useProjectStore, useSettingsStore, useTaskStore, useUiStore } from "../../src/renderer/state";

(globalThis as { IS_REACT_ACT_ENVIRONMENT?: boolean }).IS_REACT_ACT_ENVIRONMENT = true;

const mounted: Array<{ host: HTMLDivElement; root: Root }> = [];

const shellConfig = {
  providers: [],
  models: [],
  ocrEngines: [],
} as unknown as ConfigData;

const savedSettings = {
  values: { MAX_BODY_MB: "80" } as GlobalSettingsData["values"],
  overrides: [],
  keyConfigured: {},
  restartRequired: false,
} satisfies GlobalSettingsData;

function seedDirtyDraft() {
  const store = useGlobalSettingsStore.getState();
  store.clear();
  store.adoptServerSnapshot(savedSettings);
  store.setDraftValue("MAX_BODY_MB", "100");
}

function installApi(saveGlobalSettings = vi.fn(async () => ({ ok: true as const, data: savedSettings }))) {
  const api = {
    app: { getConfig: vi.fn(async () => ({ ok: true as const, data: shellConfig })) },
    projects: { getLibraryInfo: vi.fn(async () => ({ ok: true as const, data: { name: "项目库", path: "/tmp/library" } })) },
    recognition: { onProgress: vi.fn(() => () => {}) },
    settings: {
      getGlobalSettings: vi.fn(async () => ({ ok: true as const, data: savedSettings })),
      getOcrSettings: vi.fn(async () => ({ ok: true as const, data: { pythonPath: "", setupCompleted: false, setupSkipped: false } })),
      saveGlobalSettings,
    },
    logs: { read: vi.fn(async () => ({ ok: true as const, data: { entries: [], hasMore: false } })) },
  } as unknown as SlateSyncApi;
  Object.defineProperty(window, "slateSync", { configurable: true, value: api });
  return api;
}

async function renderApp() {
  const host = document.createElement("div");
  document.body.append(host);
  const root = createRoot(host);
  mounted.push({ host, root });
  await act(async () => {
    root.render(<App />);
    await Promise.resolve();
    await Promise.resolve();
    await Promise.resolve();
  });
  return host;
}

function findNavItem(host: HTMLDivElement, label: string) {
  const button = [...host.querySelectorAll("button")].find((candidate) => candidate.textContent?.trim() === label);
  if (!(button instanceof HTMLButtonElement)) throw new Error(`missing nav item: ${label}`);
  return button;
}

function findDialogButton(label: string) {
  const dialog = document.querySelector('[role="dialog"]');
  const button = [...(dialog?.querySelectorAll("button") || [])].find((candidate) => candidate.textContent?.trim() === label);
  if (!(button instanceof HTMLButtonElement)) throw new Error(`missing dialog button: ${label}`);
  return button;
}

async function settle() {
  await act(async () => {
    await Promise.resolve();
    await Promise.resolve();
  });
}

afterEach(() => {
  for (const { host, root } of mounted.splice(0)) {
    act(() => root.unmount());
    host.remove();
  }
  useGlobalSettingsStore.getState().clear();
  useProjectStore.setState({ config: null, projects: [], current: null, scenarios: [], error: null });
  useSettingsStore.setState({ ocr: null });
  useUiStore.setState({ route: "projects", theme: "system", density: "comfortable", toast: null, dialog: null });
  Object.defineProperty(window, "slateSync", { configurable: true, value: undefined });
  vi.restoreAllMocks();
});

describe("app shell navigation guard for global settings drafts", () => {
  it("opens the leave dialog and keeps the route when drafts are dirty", async () => {
    const api = installApi();
    seedDirtyDraft();
    useUiStore.setState({ route: "global-settings" });
    const host = await renderApp();

    expect(useGlobalSettingsStore.getState().dirtyKeys.size).toBe(1);
    await act(async () => {
      findNavItem(host, "日志").click();
      await Promise.resolve();
    });

    const dialog = document.querySelector('[role="dialog"]');
    expect(dialog?.textContent).toContain("有未保存的修改");
    expect(dialog?.textContent).toContain("草稿会保留");
    // The route stays on global settings until the user decides.
    expect(useUiStore.getState().route).toBe("global-settings");
    expect(findNavItem(host, "全局设置").dataset.active).toBe("true");

    await act(async () => {
      findDialogButton("取消").click();
      await Promise.resolve();
    });
    expect(document.querySelector('[role="dialog"]')).toBeNull();
    expect(useUiStore.getState().route).toBe("global-settings");
    expect(useGlobalSettingsStore.getState().dirtyKeys.size).toBe(1);
    expect(api.settings.saveGlobalSettings).not.toHaveBeenCalled();
  });

  it("discards the draft and navigates after confirmation", async () => {
    installApi();
    seedDirtyDraft();
    useUiStore.setState({ route: "global-settings" });
    const host = await renderApp();

    await act(async () => {
      findNavItem(host, "日志").click();
      await Promise.resolve();
    });
    await act(async () => {
      findDialogButton("放弃修改并离开").click();
      await settle();
    });

    expect(document.querySelector('[role="dialog"]')).toBeNull();
    expect(useUiStore.getState().route).toBe("logs");
    expect(findNavItem(host, "日志").dataset.active).toBe("true");
    // 放弃后草稿清空：回到全局设置不会看到旧的未保存修改。
    expect(useGlobalSettingsStore.getState().dirtyKeys.size).toBe(0);
  });

  it("saves and leaves through the dialog primary action", async () => {
    const api = installApi();
    seedDirtyDraft();
    useUiStore.setState({ route: "global-settings" });
    const host = await renderApp();

    await act(async () => {
      findNavItem(host, "日志").click();
      await Promise.resolve();
    });
    await act(async () => {
      findDialogButton("保存并离开").click();
      await settle();
    });

    expect(api.settings.saveGlobalSettings).toHaveBeenCalledWith({ values: { MAX_BODY_MB: "100" } });
    expect(document.querySelector('[role="dialog"]')).toBeNull();
    expect(useUiStore.getState().route).toBe("logs");
    expect(useGlobalSettingsStore.getState().dirtyKeys.size).toBe(0);
  });

  it("resumes the Project Library cleanup after discarding guarded drafts", async () => {
    installApi();
    seedDirtyDraft();
    useUiStore.setState({ route: "global-settings" });
    const clearTasks = vi.spyOn(useTaskStore.getState(), "clear");
    const host = await renderApp();

    await act(async () => {
      findNavItem(host, "项目库").click();
      await Promise.resolve();
    });
    await act(async () => {
      findDialogButton("放弃修改并离开").click();
      await settle();
    });

    // Project Library is a lifecycle transition, not a plain route assignment:
    // accepting the guard must still release workspace-owned stores.
    expect(clearTasks).toHaveBeenCalledTimes(1);
    expect(useUiStore.getState().route).toBe("projects");
  });

  it("locks every dismissal path while save-and-leave is pending", async () => {
    let resolveSave: (value: { ok: true; data: GlobalSettingsData }) => void = () => {};
    const save = vi.fn(() => new Promise<{ ok: true; data: GlobalSettingsData }>((resolve) => { resolveSave = resolve; }));
    installApi(save);
    seedDirtyDraft();
    useUiStore.setState({ route: "global-settings" });
    const host = await renderApp();

    await act(async () => {
      findNavItem(host, "日志").click();
      await Promise.resolve();
      findDialogButton("保存并离开").click();
      await Promise.resolve();
    });

    expect(findDialogButton("取消").disabled).toBe(true);
    expect(findDialogButton("放弃修改并离开").disabled).toBe(true);
    const close = document.querySelector<HTMLButtonElement>('[aria-label="关闭对话框"]');
    expect(close?.disabled).toBe(true);

    await act(async () => {
      document.dispatchEvent(new KeyboardEvent("keydown", { key: "Escape", bubbles: true, cancelable: true }));
      await Promise.resolve();
    });
    expect(document.querySelector('[role="dialog"]')).not.toBeNull();
    expect(useUiStore.getState().route).toBe("global-settings");

    await act(async () => {
      resolveSave({ ok: true, data: savedSettings });
      await settle();
    });
    expect(document.querySelector('[role="dialog"]')).toBeNull();
    expect(useUiStore.getState().route).toBe("logs");
  });

  it("navigates without a dialog when the draft is clean", async () => {
    installApi();
    useGlobalSettingsStore.getState().clear();
    useGlobalSettingsStore.getState().adoptServerSnapshot(savedSettings);
    useUiStore.setState({ route: "global-settings" });
    const host = await renderApp();

    await act(async () => {
      findNavItem(host, "日志").click();
      await settle();
    });

    expect(document.querySelector('[role="dialog"]')).toBeNull();
    expect(useUiStore.getState().route).toBe("logs");
  });

  it("routes Cmd+S to the global settings save event", async () => {
    const api = installApi();
    seedDirtyDraft();
    useUiStore.setState({ route: "global-settings" });
    await renderApp();

    await act(async () => {
      document.dispatchEvent(new KeyboardEvent("keydown", { key: "s", metaKey: true, bubbles: true, cancelable: true }));
      await settle();
    });

    expect(api.settings.saveGlobalSettings).toHaveBeenCalledTimes(1);
    expect(useGlobalSettingsStore.getState().dirtyKeys.size).toBe(0);
  });

  it("exposes settings sections as a sidebar dropdown with dirty dots", async () => {
    installApi();
    seedDirtyDraft(); // MAX_BODY_MB is a runtime-section key.
    useUiStore.setState({ route: "global-settings" });
    const host = await renderApp();

    // The dropdown mounts only while the global-settings route is active.
    const group = host.querySelector('[aria-label="全局设置分区导航"]');
    expect(group).not.toBeNull();
    const findSubItem = (label: string) =>
      [...(group?.querySelectorAll("button") || [])].find((candidate) => candidate.textContent?.trim() === label);
    expect(findSubItem("运行参数")?.getAttribute("data-dirty")).toBe("true");
    expect(findSubItem("密钥与外观")?.getAttribute("data-dirty")).toBeNull();

    await act(async () => {
      findSubItem("本地 OCR")?.click();
      await Promise.resolve();
    });
    expect(useUiStore.getState().settingsSection).toBe("settings-ocr");

    // Repeating a section click is an action even when its selected ID matches.
    const target = host.querySelector<HTMLElement>("#settings-ocr")!;
    target.scrollIntoView = vi.fn();
    await act(async () => { findSubItem("本地 OCR")?.click(); });
    expect(target.scrollIntoView).toHaveBeenCalledTimes(1);
    expect(document.activeElement).toBe(target.querySelector("h2"));

    // The parent item is also a destination: repeating it returns focus and
    // scroll to the page heading instead of only clearing the active subitem.
    const pageHeading = host.querySelector<HTMLElement>("#global-settings-heading")!;
    pageHeading.scrollIntoView = vi.fn();
    await act(async () => { findNavItem(host, "全局设置").click(); });
    expect(useUiStore.getState().settingsSection).toBeNull();
    expect(pageHeading.scrollIntoView).toHaveBeenCalledTimes(1);
    expect(document.activeElement).toBe(pageHeading);

    // Leaving the route unmounts the dropdown; a dirty draft must go through
    // the guard dialog, so discard before navigating away here.
    act(() => { useGlobalSettingsStore.getState().discardDraft(); });
    await act(async () => {
      findNavItem(host, "说明").click();
      await settle();
    });
    expect(useUiStore.getState().route).toBe("help");
    expect(host.querySelector('[aria-label="全局设置分区导航"]')).toBeNull();

    // Cmd/Ctrl+, shares the same parent destination and must not restore the
    // previously selected subsection when reopening Global Settings.
    await act(async () => {
      document.dispatchEvent(new KeyboardEvent("keydown", { key: ",", metaKey: true, bubbles: true, cancelable: true }));
      await settle();
    });
    expect(useUiStore.getState().route).toBe("global-settings");
    expect(useUiStore.getState().settingsSection).toBeNull();
    expect(document.activeElement).toBe(host.querySelector("#global-settings-heading"));
  });
});

// @vitest-environment jsdom
import { act } from "react";
import { createRoot } from "react-dom/client";
import { afterEach, expect, it, vi } from "vitest";
import { App } from "../../src/renderer/App";
import { useGlobalSettingsStore, useProjectStore, useRecognitionStore, useSettingsStore, useTaskStore, useUiStore } from "../../src/renderer/state";
import type { ConfigData, ProjectData } from "../../src/shared/contracts/index.js";

// Keep these shell/form tests independent of image/CSV workers. Their mounted
// workspace transfer and recognition paths are exercised in real Chromium.
vi.mock("../../src/renderer/features/workspace/WorkspacePage", () => ({ WorkspacePage: () => null }));
(globalThis as { IS_REACT_ACT_ENVIRONMENT?: boolean }).IS_REACT_ACT_ENVIRONMENT = true;
const mounted: Array<{ root: ReturnType<typeof createRoot>; host: HTMLDivElement }> = [];
const project = {
  id: "guard-project", name: "原项目", description: "", archivedAt: null, canArchive: true,
  settings: { version: 1, providerId: null, modelId: null, accuracyMode: "high", scenarioId: null, customPrompt: "", resolve: { fieldFormats: { scene: "XXX", shot: "XX", take: "XX" }, comments: { goodTake: "_OK", holdTake: "_KP" } } },
} as ProjectData;
const config = { providers: [], models: [], ocrEngines: [], workflow: { resolve: project.settings!.resolve } } as unknown as ConfigData;
const settle = () => act(async () => { await Promise.resolve(); await Promise.resolve(); });
const button = (name: string, container: ParentNode = document) => {
  const result = [...container.querySelectorAll("button")].find(node => node.textContent?.trim() === name);
  if (!result) throw new Error(`Missing ${name}`);
  return result;
};
function editName(value: string) {
  const input = document.querySelector<HTMLInputElement>("#project-settings-name")!;
  Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, "value")!.set!.call(input, value);
  input.dispatchEvent(new Event("input", { bubbles: true }));
}
async function render(update = vi.fn(async (data) => ({ ok: true, data: { ...project, ...data } }))) {
  Object.defineProperty(window, "slateSync", { configurable: true, value: {
    app: { getConfig: async () => ({ ok: true, data: config }) },
    projects: { getLibraryInfo: async () => ({ ok: true, data: { name: "隔离库", path: "/tmp/mock" } }), list: async () => ({ ok: true, data: [project] }), listScenarios: async () => ({ ok: true, data: [] }), update },
    recognition: { onProgress: () => () => {} }, logs: { read: async () => ({ ok: true, data: { entries: [] } }) },
  } });
  useProjectStore.setState({ current: structuredClone(project), projects: [project], config });
  useUiStore.setState({ route: "project-settings" });
  const host = document.createElement("div"); document.body.append(host);
  const root = createRoot(host); mounted.push({ root, host });
  await act(async () => { root.render(<App />); });
  return { host, update };
}
afterEach(() => {
  for (const { root, host } of mounted.splice(0)) { act(() => root.unmount()); host.remove(); }
  useSettingsStore.getState().clearProject(); useGlobalSettingsStore.getState().clear();
  useRecognitionStore.getState().reset(); useTaskStore.setState({ operation: null });
  useProjectStore.setState({ current: null, config: null, projects: [] });
  useUiStore.setState({ route: "projects", dialog: null, toast: null });
  vi.restoreAllMocks();
});

it("guards all shell exits, retains drafts across refresh and cancels, then discards to the library", async () => {
  const { host } = await render();
  act(() => editName("未保存名称"));
  act(() => { useProjectStore.getState().setConfig(structuredClone(config)); useProjectStore.getState().setCurrent(structuredClone(project)); });
  expect(useSettingsStore.getState().draft?.name).toBe("未保存名称");
  for (const destination of ["工作台", "日志", "全局设置", "项目库"]) {
    act(() => button(destination, host).click());
    expect(useUiStore.getState().route).toBe("project-settings");
    expect(document.querySelector('[role="dialog"]')).not.toBeNull();
    act(() => button("取消", document.querySelector('[role="dialog"]')!).click());
    expect(useSettingsStore.getState().draft?.name).toBe("未保存名称");
  }
  const close = new Event("beforeunload", { cancelable: true });
  window.dispatchEvent(close); expect(close.defaultPrevented).toBe(true);
  act(() => editName(project.name)); expect(useSettingsStore.getState().dirty).toBe(false);
  act(() => editName("放弃此值")); act(() => button("项目库", host).click());
  await act(async () => { button("放弃修改并离开").click(); });
  expect(useUiStore.getState().route).toBe("projects");
  expect(useSettingsStore.getState().draft).toBeNull();
});

it("shares Cmd+S with save-and-leave, blocks edits while pending, and recovers after a failure", async () => {
  let finish!: (value: unknown) => void;
  const update = vi.fn(() => new Promise(resolve => { finish = resolve; }));
  const { host } = await render(update);
  act(() => editName("保存名称"));
  act(() => document.dispatchEvent(new KeyboardEvent("keydown", { key: "s", metaKey: true, bubbles: true, cancelable: true })));
  expect(update).toHaveBeenCalledTimes(1);
  expect(document.querySelector<HTMLInputElement>("#project-settings-name")?.disabled).toBe(true);
  act(() => button("日志", host).click());
  expect(button("取消").disabled).toBe(true);
  act(() => document.dispatchEvent(new KeyboardEvent("keydown", { key: "Escape", cancelable: true })));
  expect(useUiStore.getState().route).toBe("project-settings");
  await act(async () => { finish({ ok: false, error: { code: "TEST", message: "模拟失败" } }); });
  expect(document.querySelector('[role="dialog"] [role="alert"]')?.textContent).toContain("模拟失败");
  expect(useSettingsStore.getState().draft?.name).toBe("保存名称");
  act(() => button("保存并离开").click());
  await act(async () => { finish({ ok: true, data: { ...project, name: "保存名称" } }); });
  await settle();
  expect(useUiStore.getState().route).toBe("logs");
  expect(useProjectStore.getState().current?.name).toBe("保存名称");
  expect(useSettingsStore.getState().dirty).toBe(false);
});

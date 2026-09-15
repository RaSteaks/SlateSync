// @vitest-environment jsdom
import { act } from "react";
import { createRoot } from "react-dom/client";
import { afterEach, expect, it, vi } from "vitest";
import { App } from "../../src/renderer/App";
import { useGlobalSettingsStore, useProjectStore, useRecognitionStore, useSettingsStore, useTaskStore, useUiStore } from "../../src/renderer/state";
import { DEFAULT_EXPORT_OPTIONS, type ConfigData, type ProjectData } from "../../src/shared/contracts/index.js";
// @ts-expect-error Shared browser module is intentionally JavaScript.
import { normalizeExportOptions } from "../../public/export-options.js";

// CSV 样表导入走 Worker 服务；这里替换为同步假实现，只验证工作台交互。
const { importRequest } = vi.hoisted(() => ({
  importRequest: vi.fn(async () => ({
    options: normalizeExportOptions({
      templateId: "imported-csv-v1",
      templateName: "样表",
      columns: [
        { key: "imported:0", header: "自定义列", enabled: true },
        { key: "scene", header: "场次", enabled: true },
      ],
      filenameTemplate: "{source}_后期.csv",
    }),
    sourceEncoding: "gb18030",
  })),
}));

vi.mock("../../src/renderer/features/workspace/WorkspacePage", () => ({ WorkspacePage: () => null }));
vi.mock("../../src/renderer/services/csv-worker-service", () => ({
  getCsvWorkerService: () => ({ request: importRequest }),
}));

(globalThis as { IS_REACT_ACT_ENVIRONMENT?: boolean }).IS_REACT_ACT_ENVIRONMENT = true;
const mounted: Array<{ root: ReturnType<typeof createRoot>; host: HTMLDivElement }> = [];
const project = {
  id: "template-project", name: "模板项目", description: "", archivedAt: null, canArchive: true,
  settings: { version: 2, providerId: null, modelId: null, accuracyMode: "high", scenarioId: null, customPrompt: "", resolve: { fieldFormats: { scene: "XXX", shot: "XX", take: "XX" }, comments: { goodTake: "_OK", holdTake: "_KP" } }, export: DEFAULT_EXPORT_OPTIONS },
} as unknown as ProjectData;
const config = { providers: [], models: [], ocrEngines: [], workflow: { resolve: project.settings!.resolve } } as unknown as ConfigData;
const settle = () => act(async () => { await Promise.resolve(); await Promise.resolve(); });
const button = (name: string, container: ParentNode = document) => {
  const result = [...container.querySelectorAll("button")].find((node) => node.textContent?.trim() === name);
  if (!result) throw new Error(`Missing button ${name}`);
  return result;
};
// 列表条目按钮内含徽标文本，用包含匹配。
const buttonContaining = (text: string, container: ParentNode = document) => {
  const result = [...container.querySelectorAll("button")].find((node) => node.textContent?.includes(text));
  if (!result) throw new Error(`Missing button containing ${text}`);
  return result;
};
const setInput = (input: HTMLInputElement, value: string) => {
  Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, "value")!.set!.call(input, value);
  input.dispatchEvent(new Event("input", { bubbles: true }));
};
const dialog = () => {
  const node = document.querySelector('[role="dialog"]');
  if (!node) throw new Error("Missing dialog");
  return node;
};
const editorNameInput = (host: ParentNode) => {
  const field = [...host.querySelectorAll("label")].find((label) => label.textContent?.includes("模板名称"));
  const input = field?.querySelector("input");
  if (!input) throw new Error("Missing template name input");
  return input as HTMLInputElement;
};
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
  importRequest.mockClear();
  vi.restoreAllMocks();
});

it("switches an unsaved configuration to the built-in without a false dirty dialog", async () => {
  const { host } = await render();
  const draft = structuredClone(useSettingsStore.getState().draft!);
  draft.settings.export = normalizeExportOptions({ templateId: "custom" });
  act(() => useSettingsStore.getState().hydrateProject(project.id, draft));
  expect(host.textContent).toContain("当前配置（未保存）");
  act(() => buttonContaining("DaVinci Resolve 21.1", host).click());
  expect(button("复制为自定义", host).disabled).toBe(false);
  expect(document.querySelector('[role="dialog"]')).toBeNull();
});

it("starts on the read-only built-in, creates a linked custom template and saves the library", async () => {
  const { host, update } = await render();
  // 内置模板只读：无名称输入，仅提供复制入口。
  expect(() => editorNameInput(host)).toThrow();
  expect(button("复制为自定义", host).textContent).toContain("复制为自定义");
  expect(host.textContent).toContain("只读");
  // Built-in fields are locked; the copy action remains available.
  const editor = button("复制为自定义", host).closest("div")!.parentElement!;
  expect(editor.querySelectorAll("input, select").length).toBeGreaterThan(0);
  expect([...editor.querySelectorAll("input, select")].every((node) => (node as HTMLInputElement).disabled)).toBe(true);

  act(() => button("新建自定义模板", host).click());
  expect(host.textContent).toContain("自定义 CSV");
  expect(editorNameInput(host).value).toBe("自定义 CSV");
  expect(useSettingsStore.getState().dirty).toBe(true);
  // 新模板复制当前配置并立即链接；保存项目设置时整库随设置写入。
  await act(async () => { document.querySelector<HTMLButtonElement>('button[form="project-settings-form"]')!.click(); });
  const payload = update.mock.calls.at(-1)?.[0];
  expect(payload.settings.exportTemplates.map((template: { name: string }) => template.name)).toEqual(["自定义 CSV"]);
  expect(payload.settings.export.savedTemplateId).toEqual(payload.settings.exportTemplates[0].id);
  // New presets copied from the built-in carry the full custom column set.
  expect(payload.settings.exportTemplates[0].columns.length).toBeGreaterThan(5);
});

it("blocks duplicate names on save-as, then commits a distinct copy", async () => {
  const { host } = await render();
  act(() => button("新建自定义模板", host).click());
  act(() => button("另存为", host).click());
  const nameInput = dialog().querySelector("input") as HTMLInputElement;
  expect(nameInput.value).toBe("自定义 CSV · 副本");
  setInput(nameInput, "自定义 CSV");
  act(() => button("保存模板", dialog()).click());
  expect(dialog().textContent).toContain("模板名称与现有模板重复");
  setInput(nameInput, "自定义 CSV · 副本");
  act(() => button("保存模板", dialog()).click());
  expect(host.textContent).toContain("自定义 CSV · 副本");
  expect(useSettingsStore.getState().draft?.settings.exportTemplates).toHaveLength(2);
});

it("prompts before switching away from unsaved editor changes and honors every choice", async () => {
  const { host } = await render();
  act(() => button("新建自定义模板", host).click());
  act(() => setInput(editorNameInput(host), "改名模板"));
  act(() => buttonContaining("DaVinci Resolve 21.1", host).click());
  expect(dialog().textContent).toContain("未保存的修改");
  // 取消：编辑器保持原状。
  act(() => button("取消", dialog()).click());
  expect(editorNameInput(host).value).toBe("改名模板");
  // 保存并切换：先提交名称再切换。
  act(() => buttonContaining("DaVinci Resolve 21.1", host).click());
  act(() => button("保存并切换", dialog()).click());
  expect(host.textContent).toContain("复制为自定义");
  const templates = useSettingsStore.getState().draft?.settings.exportTemplates ?? [];
  expect(templates[0].name).toBe("改名模板");
  // 放弃并切换：未保存内容被丢弃。
  act(() => button("新建自定义模板", host).click());
  act(() => setInput(editorNameInput(host), "即将放弃"));
  act(() => buttonContaining("DaVinci Resolve 21.1", host).click());
  act(() => button("放弃并切换", dialog()).click());
  expect(host.textContent).toContain("复制为自定义");
  const retained = useSettingsStore.getState().draft?.settings.exportTemplates ?? [];
  // 已显式创建的模板条目保留；仅未保存的改名被丢弃。
  expect(retained.map((template: { name: string }) => template.name)).toEqual(["改名模板", "自定义 CSV"]);
  expect(retained.some((template: { name: string }) => template.name === "即将放弃")).toBe(false);
});

it("auto-switches after deleting the current template and falls back to the built-in", async () => {
  const { host } = await render();
  act(() => button("新建自定义模板", host).click());
  act(() => button("另存为", host).click());
  act(() => button("保存模板", dialog()).click());
  // 删除当前模板（第二个条目）→ 自动切换到前一个。
  act(() => button("删除模板", host).click());
  expect(dialog().textContent).toContain("删除「自定义 CSV · 副本」？");
  act(() => button("删除模板", dialog()).click());
  expect(editorNameInput(host).value).toBe("自定义 CSV");
  // 删除最后一个模板 → 回到只读内置。
  act(() => button("删除模板", host).click());
  act(() => button("删除模板", dialog()).click());
  expect(button("复制为自定义", host).textContent).toContain("复制为自定义");
  expect(useSettingsStore.getState().draft?.settings.exportTemplates).toHaveLength(0);
});

it("imports a CSV sample through the worker service and names it in a dialog", async () => {
  const { host } = await render();
  const input = host.querySelector('input[type="file"]') as HTMLInputElement;
  const file = new File(["Scene,Take\nSC01,TK01"], "后期样表.csv", { type: "text/csv" });
  Object.defineProperty(input, "files", { configurable: true, value: [file] });
  await act(async () => { input.dispatchEvent(new Event("change", { bubbles: true })); });
  await settle();
  expect(importRequest).toHaveBeenCalledTimes(1);
  const nameInput = dialog().querySelector("input") as HTMLInputElement;
  // 建议名称取自样表文件名（去扩展名）。
  expect(nameInput.value).toBe("后期样表");
  setInput(nameInput, "导入样表");
  await act(async () => { button("保存模板", dialog()).click(); });
  expect(host.textContent).toContain("导入样表");
  // GBK/GB18030 源样表提示输出仍为 UTF-8。
  expect(host.textContent).toContain("GBK");
  const templates = useSettingsStore.getState().draft?.settings.exportTemplates ?? [];
  expect(templates[0].templateId).toBe("imported-csv-v1");
  // Imported columns keep sample order with positional keys.
  expect(templates[0].columns.map((column: { key: string }) => column.key)).toEqual(["imported:0", "imported:1"]);
});

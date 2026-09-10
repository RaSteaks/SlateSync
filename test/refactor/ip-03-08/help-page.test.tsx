// @vitest-environment jsdom
import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { afterEach, describe, expect, it } from "vitest";
import { HelpPage } from "../../../src/renderer/features/help/HelpPage";

// Keep the local help interaction test deterministic with React 19's scheduler.
(globalThis as { IS_REACT_ACT_ENVIRONMENT?: boolean }).IS_REACT_ACT_ENVIRONMENT = true;

const mounted: Array<{ host: HTMLDivElement; root: Root }> = [];

afterEach(() => {
  for (const { host, root } of mounted.splice(0)) {
    act(() => root.unmount());
    host.remove();
  }
});

function mount() {
  const host = document.createElement("div");
  document.body.append(host);
  const root = createRoot(host);
  mounted.push({ host, root });
  return { host, root };
}

function setInputValue(input: HTMLInputElement, value: string) {
  const valueSetter = Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, "value")?.set;
  valueSetter?.call(input, value);
  input.dispatchEvent(new Event("input", { bubbles: true }));
}

describe("HelpPage", () => {
  it("renders the workflow, model, OCR, and tuning sections with a local directory", () => {
    const { host, root } = mount();
    act(() => root.render(<HelpPage />));

    expect(host.querySelector("h1")?.textContent).toBe("说明");
    expect(host.querySelector('[aria-label="说明目录"]')).not.toBeNull();
    expect(host.querySelectorAll('[aria-label="说明目录"] a')).toHaveLength(7);
    expect(host.textContent).toContain("软件使用方法");
    expect(host.textContent).toContain("场记术语对照表");
    expect(host.textContent).toContain("项目独立导入与导出");
    expect(host.textContent).toContain("slatesync-project");
    expect(host.textContent).toContain("大模型如何配置");
    expect(host.textContent).toContain("OCR 如何配置");
    expect(host.textContent).toContain("PaddleOCR 参数具体含义");
    expect(host.textContent).toContain("速度、运行参数与排查");
    expect(host.textContent).toContain("v6_tiny_det");
    expect(host.textContent).toContain("JSON Schema");
    expect(host.textContent).not.toContain("安全提醒");
  });

  it("filters sections by keyword and can restore the complete guide", () => {
    const { host, root } = mount();
    act(() => root.render(<HelpPage />));
    const input = host.querySelector<HTMLInputElement>("input");
    if (!input) throw new Error("missing help search input");

    act(() => setInputValue(input, "模型版本"));
    expect(host.querySelectorAll('section[id^="help-"]')).toHaveLength(1);
    expect(host.querySelectorAll('[aria-label="说明目录"] a')).toHaveLength(1);
    expect(host.querySelector('[aria-label="说明目录"] a')?.getAttribute("href")).toBe("#help-paddle-parameters");
    expect(host.textContent).toContain("PaddleOCR 参数具体含义");
    expect(host.querySelector("#help-quick-start")).toBeNull();

    act(() => setInputValue(input, "完全不存在的关键词"));
    expect(host.textContent).toContain("没有匹配的说明");
    expect(host.querySelectorAll('section[id^="help-"]')).toHaveLength(0);
    expect(host.querySelectorAll('[aria-label="说明目录"] a')).toHaveLength(0);

    const clear = host.querySelector<HTMLButtonElement>('[aria-label="清空搜索"]');
    expect(clear).not.toBeNull();
    act(() => clear?.click());
    expect(host.querySelectorAll('section[id^="help-"]')).toHaveLength(7);
  });

  it("renders the glossary section and filters it by terminology keywords", () => {
    const { host, root } = mount();
    act(() => root.render(<HelpPage />));

    expect(host.querySelector("#help-glossary")).not.toBeNull();
    expect(host.textContent).toContain("素材键对账");
    expect(host.textContent).toContain("C011-18");

    const input = host.querySelector<HTMLInputElement>("input");
    if (!input) throw new Error("missing help search input");
    act(() => setInputValue(input, "视频码"));
    expect(host.querySelectorAll('section[id^="help-"]')).toHaveLength(1);
    expect(host.querySelector("#help-glossary")).not.toBeNull();
    expect(host.querySelector('[aria-label="说明目录"] a')?.getAttribute("href")).toBe("#help-glossary");
  });
});

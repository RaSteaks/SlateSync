// @vitest-environment jsdom
import { act, useState } from "react";
import { createRoot } from "react-dom/client";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import type { ModelData } from "../../../src/shared/contracts/index.js";
import { ModelSelect } from "../../../src/renderer/features/recognition/ModelSelect";

(globalThis as { IS_REACT_ACT_ENVIRONMENT?: boolean }).IS_REACT_ACT_ENVIRONMENT = true;

const mounted: Array<{ host: HTMLDivElement; root: ReturnType<typeof createRoot> }> = [];

// jsdom lacks CSS.escape and layout observers; browser tests cover positioning.
beforeEach(() => {
  vi.stubGlobal("CSS", { escape: (value: string) => value.replace(/[^a-zA-Z0-9_-]/g, "\\$&") });
  vi.stubGlobal("ResizeObserver", class { observe() {} unobserve() {} disconnect() {} });
  HTMLElement.prototype.scrollIntoView = vi.fn();
});

afterEach(() => {
  for (const { host, root } of mounted.splice(0)) {
    act(() => root.unmount());
    host.remove();
  }
});

function model(id: string, label: string): ModelData {
  return { id, label, description: "", providers: ["openrouter"] };
}

describe("ModelSelect", () => {
  it("closes on disabled/catalog changes and refuses detached stale options", async () => {
    const onChange = vi.fn();
    const host = document.createElement("div"); document.body.append(host);
    const root = createRoot(host); mounted.push({ host, root });
    const render = (id: string, disabled = false) => root.render(<ModelSelect value="" groups={[{ key: "models", label: "模型", models: [model(id, id)] }]} placeholder="选择模型" onChange={onChange} disabled={disabled} />);
    act(() => render("old"));
    const trigger = host.querySelector<HTMLButtonElement>("button")!;
    await act(async () => trigger.click());
    const stale = document.querySelector<HTMLElement>('[role="row"][data-key="models:old"]')!;
    expect(stale).not.toBeNull();
    act(() => render("old", true));
    expect(document.querySelector('[role="treegrid"]')).toBeNull();
    act(() => stale.click());
    expect(onChange).not.toHaveBeenCalled();
    act(() => render("old"));
    await act(async () => trigger.click());
    act(() => render("new"));
    expect(trigger.getAttribute("aria-expanded")).toBe("false");
    await act(async () => trigger.click());
    expect(document.querySelector('[role="treegrid"]')?.textContent).toContain("new");
    expect(document.querySelector('[role="treegrid"]')?.textContent).not.toContain("old");
  });

  it("keeps fixed models visible and collapses vendor groups until expanded", async () => {
    function Harness() {
      const [value, setValue] = useState("");
      return (
        <ModelSelect
          value={value}
          placeholder="选择视觉模型"
          groups={[
            { key: "featured", label: "推荐模型", models: [model("openai/gpt-4o", "GPT-4o")], collapsible: false },
            { key: "vendor-deepseek", label: "DeepSeek · 其余 2 个", models: [model("deepseek/a", "DeepSeek A"), model("deepseek/b", "DeepSeek B")], collapsible: true },
          ]}
          onChange={setValue}
        />
      );
    }

    const host = document.createElement("div");
    document.body.append(host);
    const root = createRoot(host);
    mounted.push({ host, root });
    act(() => root.render(<Harness />));

    const trigger = host.querySelector<HTMLButtonElement>('button[aria-haspopup="dialog"]');
    if (!trigger) throw new Error("model picker trigger missing");
    await act(async () => { trigger.click(); });

    expect(document.body.textContent).toContain("GPT-4o");
    expect(document.body.textContent).not.toContain("DeepSeek A");

    const vendorHeader = document.querySelector<HTMLButtonElement>('button[slot="chevron"]');
    if (!vendorHeader) throw new Error("collapsed vendor group missing");
    await act(async () => { vendorHeader.click(); });
    expect(vendorHeader.closest('[role="row"]')?.getAttribute("aria-expanded")).toBe("true");
    expect(document.body.textContent).toContain("DeepSeek A");

    const vendorOption = [...document.querySelectorAll<HTMLButtonElement>('[role="row"][data-key]')].find((option) => option.textContent?.includes("DeepSeek A"));
    if (!vendorOption) throw new Error("vendor model option missing");
    await act(async () => { vendorOption.click(); });
    expect(trigger.getAttribute("aria-expanded")).toBe("false");
    expect(trigger.textContent).toContain("DeepSeek A");

    await act(async () => { trigger.click(); });
    expect(document.querySelector<HTMLButtonElement>('[role="row"][aria-expanded="true"]')?.textContent).toContain("DeepSeek");
  });
});

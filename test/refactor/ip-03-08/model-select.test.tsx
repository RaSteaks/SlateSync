// @vitest-environment jsdom
import { act, useState } from "react";
import { createRoot } from "react-dom/client";
import { afterEach, describe, expect, it } from "vitest";
import type { ModelData } from "../../../src/shared/contracts/index.js";
import { ModelSelect } from "../../../src/renderer/features/recognition/ModelSelect";

(globalThis as { IS_REACT_ACT_ENVIRONMENT?: boolean }).IS_REACT_ACT_ENVIRONMENT = true;

const mounted: Array<{ host: HTMLDivElement; root: ReturnType<typeof createRoot> }> = [];

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
  it("keeps fixed models visible and collapses vendor groups until expanded", () => {
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

    const trigger = host.querySelector<HTMLButtonElement>('button[aria-haspopup="listbox"]');
    if (!trigger) throw new Error("model picker trigger missing");
    act(() => trigger.click());

    expect(host.textContent).toContain("GPT-4o");
    expect(host.textContent).not.toContain("DeepSeek A");

    const vendorHeader = host.querySelector<HTMLButtonElement>('[aria-expanded="false"]');
    if (!vendorHeader) throw new Error("collapsed vendor group missing");
    act(() => vendorHeader.click());
    expect(vendorHeader.getAttribute("aria-expanded")).toBe("true");
    expect(host.textContent).toContain("DeepSeek A");

    const vendorOption = [...host.querySelectorAll<HTMLButtonElement>('[role="option"]')].find((option) => option.textContent?.includes("DeepSeek A"));
    if (!vendorOption) throw new Error("vendor model option missing");
    act(() => vendorOption.click());
    expect(trigger.getAttribute("aria-expanded")).toBe("false");
    expect(trigger.textContent).toContain("DeepSeek A");

    act(() => trigger.click());
    expect(host.querySelector<HTMLButtonElement>('[aria-expanded="true"]')?.textContent).toContain("DeepSeek");
  });
});

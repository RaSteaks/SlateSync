// @vitest-environment jsdom
import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { afterEach, describe, expect, it, vi } from "vitest";
import { Button, Dialog, Text } from "../../../src/renderer/design-system/index";

// React 19 uses this marker to make focus/portal assertions flush through the
// same scheduler that the Electron renderer uses during interaction tests.
(globalThis as { IS_REACT_ACT_ENVIRONMENT?: boolean }).IS_REACT_ACT_ENVIRONMENT = true;

const roots: Array<{ host: HTMLDivElement; root: Root }> = [];

afterEach(() => {
  for (const { host, root } of roots.splice(0)) {
    act(() => root.unmount());
    host.remove();
  }
  document.body.innerHTML = "";
});

function render(node: React.ReactNode) {
  const host = document.createElement("div");
  document.body.append(host);
  const root = createRoot(host);
  roots.push({ host, root });
  act(() => root.render(node));
  return { host, root };
}

describe("modern design system", () => {
  it("keeps loading buttons disabled and exposes semantic content", () => {
    const { host } = render(<Button loading>保存</Button>);
    const button = host.querySelector("button");
    expect(button?.disabled).toBe(true);
    expect(button?.textContent).toContain("保存");
    expect(button?.querySelector("svg")).not.toBeNull();

    render(<Text as="h1" tone="warning">需要复核</Text>);
    expect(document.querySelector("h1")?.getAttribute("data-tone")).toBe("warning");
  });

  it("traps dialog focus, dismisses on Escape, and restores the opener", async () => {
    const opener = document.createElement("button");
    opener.textContent = "打开";
    document.body.append(opener);
    opener.focus();
    const onClose = vi.fn();
    const view = render(<Dialog open title="测试对话框" onClose={onClose}><input aria-label="名称" /></Dialog>);

    const dialog = document.querySelector('[role="dialog"]');
    expect(dialog).not.toBeNull();
    expect(document.activeElement?.getAttribute("aria-label")).toBe("关闭对话框");

    act(() => document.dispatchEvent(new KeyboardEvent("keydown", { key: "Escape" })));
    expect(onClose).toHaveBeenCalledTimes(1);

    await act(async () => {
      view.root.render(<Dialog open={false} title="测试对话框" onClose={onClose}><input aria-label="名称" /></Dialog>);
      // Dialog restores focus after its portal commit/frame, matching the
      // browser lifecycle used by the Electron accessibility E2E.
      await new Promise<void>((resolve) => {
        if (typeof window.requestAnimationFrame === "function") window.requestAnimationFrame(() => resolve());
        else queueMicrotask(resolve);
      });
    });
    expect(document.activeElement).toBe(opener);
  });
});

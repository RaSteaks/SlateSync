// @vitest-environment jsdom
import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { afterEach, describe, expect, it, vi } from "vitest";
import { Button, Dialog, Field, Input, Text, Textarea } from "../../../src/renderer/design-system/index";
import { isEditableShortcutTarget } from "../../../src/renderer/services/keyboard-shortcuts";

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

  it("exposes a wide dialog size for document inspection surfaces", () => {
    render(<Dialog open title="大图预览" onClose={() => undefined} size="wide"><img alt="场记单" src="data:image/gif;base64,R0lGODlhAQABAIAAAAAAAP///ywAAAAAAQABAAACAUwAOw==" /></Dialog>);

    // The presentation size is a data attribute so the shared Dialog keeps
    // one focus and dismissal implementation across normal and wide content.
    expect(document.querySelector('[role="dialog"]')?.getAttribute("data-size")).toBe("wide");
  });

  it("forwards dialog-local keyboard handlers to the dialog surface", () => {
    const onKeyDown = vi.fn();
    render(<Dialog open title="大图预览" onClose={() => undefined} onKeyDown={onKeyDown}><img alt="场记单" src="data:image/gif;base64,R0lGODlhAQABAIAAAAAAAP///ywAAAAAAQABAAACAUwAOw==" /></Dialog>);

    // Feature-level arrow navigation can bubble from the close button and
    // footer controls without changing Dialog's global Escape/Tab behavior.
    const dialog = document.querySelector<HTMLElement>('[role="dialog"]');
    act(() => dialog?.dispatchEvent(new KeyboardEvent("keydown", { key: "ArrowRight", bubbles: true })));
    expect(onKeyDown).toHaveBeenCalledTimes(1);
  });

  it("connects inline errors and leaves readable space for textarea counts", () => {
    const { host } = render(<Field label="项目名称" error="请输入项目名称。"><Input /></Field>);
    const input = host.querySelector("input");
    expect(input?.getAttribute("aria-invalid")).toBe("true");
    expect(input?.getAttribute("data-state")).toBe("error");
    expect(host.querySelector('[role="alert"]')?.textContent).toBe("请输入项目名称。");

    const counted = render(<Textarea value="场记" onChange={() => undefined} maxLength={2000} showCount />);
    expect(counted.host.textContent).toContain("2 / 2000");
  });

  it("does not let global shortcuts override editable controls", () => {
    const { host } = render(<><Input /><button type="button">运行</button><div contentEditable /></>);
    expect(isEditableShortcutTarget(host.querySelector("input"))).toBe(true);
    expect(isEditableShortcutTarget(host.querySelector("button"))).toBe(true);
    expect(isEditableShortcutTarget(host.querySelector("div[contenteditable]"))).toBe(true);
    expect(isEditableShortcutTarget(host)).toBe(false);
  });
});

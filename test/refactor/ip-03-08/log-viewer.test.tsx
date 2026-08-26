// @vitest-environment jsdom
import { act } from "react";
import { createRoot } from "react-dom/client";
import { afterEach, describe, expect, it, vi } from "vitest";
import type { LogEntry, SlateSyncApi } from "../../../src/shared/contracts/index.js";
import { LogViewerPage } from "../../../src/renderer/features/logs/LogViewerPage";
import { useRecognitionStore } from "../../../src/renderer/state";

// Keep React's concurrent renderer deterministic for polling and store updates.
(globalThis as { IS_REACT_ACT_ENVIRONMENT?: boolean }).IS_REACT_ACT_ENVIRONMENT = true;

const mounted: Array<{ host: HTMLDivElement; root: ReturnType<typeof createRoot> }> = [];

const entry: LogEntry = {
  timestamp: "2026-08-26 14:32:05.456",
  level: "warn",
  category: "recognition",
  message: "正在查漏 · 本地 OCR 不可用",
  phase: "audit",
  percent: 45,
  completed: 3,
  total: 8,
  pageNumber: 3,
};

afterEach(() => {
  for (const { host, root } of mounted.splice(0)) {
    act(() => root.unmount());
    host.remove();
  }
  useRecognitionStore.getState().reset();
  Object.defineProperty(window, "slateSync", { configurable: true, value: undefined });
});

function mount() {
  const host = document.createElement("div");
  document.body.append(host);
  const root = createRoot(host);
  mounted.push({ host, root });
  return { host, root };
}

describe("LogViewerPage", () => {
  it("renders filtered log entries, inline progress, and the live recognition card", async () => {
    const read = vi.fn(async () => ({ ok: true as const, data: { entries: [entry], hasMore: true } }));
    Object.defineProperty(window, "slateSync", {
      configurable: true,
      value: { logs: { read } } as unknown as SlateSyncApi,
    });
    act(() => {
      useRecognitionStore.getState().start(7, "project-logging", 8);
      useRecognitionStore.getState().progress(7, {
        phase: "primary",
        percent: 45,
        completed: 3,
        total: 8,
        message: "正在主识别第 3/8 页",
      });
    });
    const { host, root } = mount();

    await act(async () => {
      root.render(<LogViewerPage />);
      await Promise.resolve();
      await Promise.resolve();
    });

    expect(host.querySelector("h1")?.textContent).toBe("日志查看器");
    expect(host.textContent).toContain("正在查漏 · 本地 OCR 不可用");
    expect(host.textContent).toContain("警告");
    expect(host.querySelector('[role="progressbar"][aria-label="当前识别进度"]')).not.toBeNull();
    expect(host.querySelector('[data-testid="log-inline-progress"] span')?.getAttribute("style")).toContain("45%");
    expect(read).toHaveBeenCalledWith({ limit: 500 });

    const level = host.querySelector<HTMLSelectElement>('select[aria-label="日志级别"]');
    expect(level).not.toBeNull();
    await act(async () => {
      if (!level) throw new Error("level filter missing");
      level.value = "warn";
      level.dispatchEvent(new Event("change", { bubbles: true }));
      await Promise.resolve();
      await Promise.resolve();
    });
    expect(read).toHaveBeenLastCalledWith({ limit: 500, level: "warn" });
  });

  it("shows an empty state when the local log directory has no entries", async () => {
    const read = vi.fn(async () => ({ ok: true as const, data: { entries: [], hasMore: false } }));
    Object.defineProperty(window, "slateSync", {
      configurable: true,
      value: { logs: { read } } as unknown as SlateSyncApi,
    });
    const { host, root } = mount();

    await act(async () => {
      root.render(<LogViewerPage />);
      await Promise.resolve();
      await Promise.resolve();
    });

    expect(host.textContent).toContain("暂无日志");
    expect(host.textContent).toContain("当前没有进行中的识别");
  });
});

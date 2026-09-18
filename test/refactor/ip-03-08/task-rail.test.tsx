// @vitest-environment jsdom
import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { afterEach, describe, expect, it, vi } from "vitest";
import type { TaskListItem } from "../../../src/shared/contracts/index.js";
import { TaskRail } from "../../../src/renderer/features/tasks/TaskRail";
import { useTaskStore } from "../../../src/renderer/state";

// Keep React's concurrent renderer deterministic for the task history filter.
(globalThis as { IS_REACT_ACT_ENVIRONMENT?: boolean }).IS_REACT_ACT_ENVIRONMENT = true;

const mounted: Array<{ host: HTMLDivElement; root: Root }> = [];

const tasks: TaskListItem[] = [
  {
    id: "task-a001",
    filename: "A001C001.png",
    provider: "openai",
    model: "vision",
    pageCount: 1,
    scenarioId: null,
    recordCount: 4,
    status: "completed",
    createdAt: "2026-08-29T00:00:00.000Z",
    updatedAt: "2026-08-29T00:00:01.000Z",
  },
  {
    id: "task-b002",
    filename: "B002C003.png",
    provider: "openai",
    model: "vision",
    pageCount: 2,
    scenarioId: null,
    recordCount: 7,
    status: "failed",
    createdAt: "2026-08-28T00:00:00.000Z",
    updatedAt: "2026-08-28T00:00:01.000Z",
  },
];

function mountRail(items = tasks) {
  useTaskStore.setState({ items, loadedProjectId: "project-1", activeId: null, active: null, loading: false, saveState: "saved", error: null });
  const host = document.createElement("div");
  document.body.append(host);
  const root = createRoot(host);
  mounted.push({ host, root });
  act(() => {
    root.render(
      <TaskRail
        onSelect={() => undefined}
        onRefresh={() => undefined}
        onNew={() => undefined}
        onDelete={() => undefined}
        onRetrySave={() => undefined}
      />,
    );
  });
  return host;
}

function fillSearch(input: HTMLInputElement, value: string) {
  const valueSetter = Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, "value")?.set;
  act(() => {
    valueSetter?.call(input, value);
    input.dispatchEvent(new Event("input", { bubbles: true }));
  });
}

afterEach(() => {
  for (const { host, root } of mounted.splice(0)) {
    act(() => root.unmount());
    host.remove();
  }
  vi.restoreAllMocks();
  useTaskStore.getState().clear();
  document.body.innerHTML = "";
});

describe("task history rail", () => {
  it("bounds large-history DOM and reuses search normalization across keystrokes", () => {
    vi.spyOn(HTMLElement.prototype, "offsetHeight", "get").mockReturnValue(260);
    const largeHistory = Array.from({ length: 5000 }, (_, index) => ({
      ...tasks[0]!, id: `task-${index}`, filename: `slate-${index}.png`,
    }));
    const normalized = vi.spyOn(String.prototype, "toLocaleLowerCase");
    const host = mountRail(largeHistory);
    // Opening should neither normalize 5,000 search records nor render them all.
    expect(normalized.mock.calls.length).toBeLessThan(100);
    expect(host.querySelectorAll('button[aria-label^="删除"]').length).toBeLessThan(30);
    const search = host.querySelector<HTMLInputElement>('input[aria-label="搜索历史任务"]')!;
    fillSearch(search, "slate-499");
    expect(host.textContent).toContain("匹配 11 / 5000 个任务");
    normalized.mockClear();
    fillSearch(search, "slate-4999");
    expect(host.textContent).toContain("slate-4999.png");
    expect(host.textContent).toContain("匹配 1 / 5000 个任务");
    expect(normalized.mock.calls.length).toBeLessThan(100);
    act(() => search.dispatchEvent(new KeyboardEvent("keydown", { key: "Escape", bubbles: true })));
    expect(host.textContent).toContain("共 5000 个历史任务");
    expect(host.querySelectorAll('button[aria-label^="删除"]').length).toBeLessThan(30);
  });

  it("filters historical tasks and exposes a helpful no-result state", () => {
    vi.spyOn(HTMLElement.prototype, "offsetHeight", "get").mockReturnValue(260);
    const host = mountRail();
    const search = host.querySelector<HTMLInputElement>('input[aria-label="搜索历史任务"]');

    expect(search).not.toBeNull();
    expect(host.textContent).toContain("A001C001.png");
    expect(host.textContent).toContain("B002C003.png");

    fillSearch(search!, "B002");
    expect(host.textContent).toContain("B002C003.png");
    expect(host.textContent).not.toContain("A001C001.png");
    expect(host.textContent).toContain("匹配 1 / 2 个任务");

    fillSearch(search!, "不存在");
    expect(host.textContent).toContain("没有匹配任务");
    expect(host.textContent).toContain("试试文件名、任务 ID 或状态的其他关键词。");
  });
});

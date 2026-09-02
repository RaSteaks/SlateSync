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

function mountRail() {
  useTaskStore.setState({ items: tasks, loadedProjectId: "project-1", activeId: null, active: null, loading: false, saveState: "saved", error: null });
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

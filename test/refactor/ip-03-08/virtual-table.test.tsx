// @vitest-environment jsdom
import { act } from "react";
import { createRoot } from "react-dom/client";
import { afterEach, describe, expect, it, vi } from "vitest";
import type { RecognitionData, ResolveCsvTable } from "../../../src/shared/contracts/index.js";
import { CsvVirtualTable, EditableCell } from "../../../src/renderer/features/csv/CsvVirtualTable";
import { RecognitionResultPanel, ResultEditableCell } from "../../../src/renderer/features/recognition/RecognitionResultPanel";
import { useRecognitionStore } from "../../../src/renderer/state";

// Keep React's concurrent scheduler assertions deterministic in jsdom.
(globalThis as { IS_REACT_ACT_ENVIRONMENT?: boolean }).IS_REACT_ACT_ENVIRONMENT = true;

const mounted: Array<{ host: HTMLDivElement; root: ReturnType<typeof createRoot> }> = [];

// jsdom has no layout engine, whereas TanStack Virtual needs a non-zero
// viewport to mount an initial row range.
function mockVirtualViewport() {
  vi.spyOn(HTMLElement.prototype, "offsetHeight", "get").mockReturnValue(420);
  vi.spyOn(HTMLElement.prototype, "offsetWidth", "get").mockReturnValue(900);
}

afterEach(() => {
  for (const { host, root } of mounted.splice(0)) {
    act(() => root.unmount());
    host.remove();
  }
  vi.useRealTimers();
  vi.restoreAllMocks();
  useRecognitionStore.getState().reset();
});

describe("virtual Resolve table", () => {
  it("keeps the 10,000-row view below the DOM-row budget", () => {
    const table: ResolveCsvTable = {
      headers: ["File Name", "Scene", "Shot", "Take"],
      rows: Array.from({ length: 10_000 }, (_, index) => [`A${index}.mov`, String(index), "01", "01"]),
      format: { encoding: "utf-8", bom: false, delimiter: ",", lineEnding: "\r\n", finalNewline: true },
    };
    const host = document.createElement("div");
    document.body.append(host);
    const root = createRoot(host);
    mounted.push({ host, root });
    act(() => root.render(<CsvVirtualTable table={table} edits={{}} onEdit={() => undefined} />));
    expect(host.querySelector('[data-testid="csv-virtual-table"]')).not.toBeNull();
    expect(host.querySelectorAll("tbody tr").length).toBeLessThan(100);
  });

  it("keeps typing local and commits a cell once on blur", () => {
    const onEdit = vi.fn();
    const host = document.createElement("div");
    document.body.append(host);
    const root = createRoot(host);
    mounted.push({ host, root });
    act(() => root.render(<EditableCell label="Scene 第 2 行" value="1" edited={false} onCommit={onEdit} />));
    const input = host.querySelector("input");
    expect(input).not.toBeNull();
    act(() => {
      const valueSetter = Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, "value")?.set;
      valueSetter?.call(input, "12");
      input?.dispatchEvent(new Event("input", { bubbles: true }));
    });
    expect(onEdit).not.toHaveBeenCalled();
    act(() => input?.dispatchEvent(new FocusEvent("focusout", { bubbles: true })));
    expect(onEdit).toHaveBeenCalledWith("12");
  });

  it("leaves Enter and Escape to an active IME composition", () => {
    const onCsvCommit = vi.fn();
    const onResultCommit = vi.fn();
    const host = document.createElement("div");
    document.body.append(host);
    const root = createRoot(host);
    mounted.push({ host, root });
    act(() => root.render(<><EditableCell label="CSV 场次" value="1" edited={false} onCommit={onCsvCommit} /><ResultEditableCell label="识别场次" value="001" onCommit={onResultCommit} /></>));
    const [csvInput, resultInput] = [...host.querySelectorAll<HTMLInputElement>("input")];
    const valueSetter = Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, "value")?.set;

    act(() => {
      csvInput?.focus();
      valueSetter?.call(csvInput, "场 2");
      csvInput?.dispatchEvent(new Event("input", { bubbles: true }));
      csvInput?.dispatchEvent(new Event("compositionstart", { bubbles: true }));
      csvInput?.dispatchEvent(new KeyboardEvent("keydown", { key: "Enter", bubbles: true }));
      csvInput?.dispatchEvent(new KeyboardEvent("keydown", { key: "Escape", bubbles: true }));
    });
    expect(csvInput?.value).toBe("场 2");
    expect(onCsvCommit).not.toHaveBeenCalled();
    act(() => {
      csvInput?.dispatchEvent(new Event("compositionend", { bubbles: true }));
      csvInput?.dispatchEvent(new KeyboardEvent("keydown", { key: "Enter", bubbles: true }));
    });
    expect(onCsvCommit).toHaveBeenCalledWith("场 2");

    act(() => {
      resultInput?.focus();
      valueSetter?.call(resultInput, "场 002");
      resultInput?.dispatchEvent(new Event("input", { bubbles: true }));
      resultInput?.dispatchEvent(new Event("compositionstart", { bubbles: true }));
      resultInput?.dispatchEvent(new KeyboardEvent("keydown", { key: "Enter", bubbles: true }));
      resultInput?.dispatchEvent(new KeyboardEvent("keydown", { key: "Escape", bubbles: true }));
    });
    expect(resultInput?.value).toBe("场 002");
    expect(onResultCommit).not.toHaveBeenCalled();
    act(() => {
      resultInput?.dispatchEvent(new Event("compositionend", { bubbles: true }));
      resultInput?.dispatchEvent(new KeyboardEvent("keydown", { key: "Enter", bubbles: true }));
    });
    expect(onResultCommit).toHaveBeenCalledWith("场 002");
  });

  it("retains a queued edit after its virtual row unmounts", () => {
    mockVirtualViewport();
    const onEdit = vi.fn();
    const table: ResolveCsvTable = {
      headers: ["Scene"],
      rows: Array.from({ length: 1_000 }, (_, index) => [String(index)]),
      format: { encoding: "utf-8", bom: false, delimiter: ",", lineEnding: "\r\n", finalNewline: true },
    };
    const host = document.createElement("div");
    document.body.append(host);
    const root = createRoot(host);
    mounted.push({ host, root });
    act(() => root.render(<CsvVirtualTable table={table} edits={{}} onEdit={onEdit} />));
    vi.useFakeTimers();

    const input = host.querySelector<HTMLInputElement>('input[aria-label="Scene 第 2 行"]');
    const scroll = host.querySelector<HTMLDivElement>("[class*='tableScroll']");
    const valueSetter = Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, "value")?.set;
    expect(input).not.toBeNull();
    expect(scroll).not.toBeNull();
    act(() => {
      valueSetter?.call(input, "scene-after-scroll");
      input?.dispatchEvent(new Event("input", { bubbles: true }));
      if (scroll) {
        scroll.scrollTop = 1_500;
        scroll.dispatchEvent(new Event("scroll"));
      }
    });

    // The row is no longer rendered, but its draft belongs to the table queue
    // instead of the virtual cell instance that just left the DOM.
    expect(host.querySelector('tr[data-index="0"]')).toBeNull();
    act(() => vi.advanceTimersByTime(250));
    expect(onEdit).toHaveBeenCalledWith("0:0", "scene-after-scroll");
  });

  it("flushes a queued CSV edit before the window can close", () => {
    mockVirtualViewport();
    const onEdit = vi.fn();
    const table: ResolveCsvTable = {
      headers: ["Scene"],
      rows: [["1"]],
      format: { encoding: "utf-8", bom: false, delimiter: ",", lineEnding: "\r\n", finalNewline: true },
    };
    const host = document.createElement("div");
    document.body.append(host);
    const root = createRoot(host);
    mounted.push({ host, root });
    act(() => root.render(<CsvVirtualTable table={table} edits={{}} onEdit={onEdit} />));
    const input = host.querySelector<HTMLInputElement>('input[aria-label="Scene 第 2 行"]');
    const valueSetter = Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, "value")?.set;
    act(() => {
      valueSetter?.call(input, "final-scene");
      input?.dispatchEvent(new Event("input", { bubbles: true }));
      window.dispatchEvent(new Event("beforeunload"));
    });
    expect(onEdit).toHaveBeenCalledWith("0:0", "final-scene");
  });

  it("commits recognition table edits on Enter and restores them on Escape", () => {
    const onCommit = vi.fn();
    const host = document.createElement("div");
    document.body.append(host);
    const root = createRoot(host);
    mounted.push({ host, root });
    act(() => root.render(<ResultEditableCell label="场次" value="001" onCommit={onCommit} />));
    const input = host.querySelector("input");
    const valueSetter = Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, "value")?.set;
    act(() => input?.focus());
    act(() => {
      valueSetter?.call(input, "002");
      input?.dispatchEvent(new Event("input", { bubbles: true }));
    });
    act(() => {
      input?.dispatchEvent(new KeyboardEvent("keydown", { key: "Enter", bubbles: true }));
    });
    expect(onCommit).toHaveBeenCalledWith("002");

    onCommit.mockClear();
    act(() => input?.focus());
    act(() => {
      valueSetter?.call(input, "003");
      input?.dispatchEvent(new Event("input", { bubbles: true }));
    });
    act(() => {
      input?.dispatchEvent(new KeyboardEvent("keydown", { key: "Escape", bubbles: true }));
    });
    expect(onCommit).not.toHaveBeenCalled();
    expect(input?.value).toBe("001");
  });

  it("renders completed recognition output as an accessible editable table", () => {
    const result = {
      pageCount: 1,
      result: {
        sheetTitle: "A 组场记单",
        warnings: [],
        records: [{ id: "record-1", sourcePage: 1, cardNumber: "A001", videoCode: "C001", scene: "12", shot: "3", take: "2", takeStatus: "过", description: "近景", comments: null, shotSize: "CU", cameraPosition: "A", confidence: "high" }],
      },
    } as unknown as RecognitionData;
    useRecognitionStore.getState().start(1, "project-1", 1);
    useRecognitionStore.getState().complete(1, result);

    const host = document.createElement("div");
    document.body.append(host);
    const root = createRoot(host);
    mounted.push({ host, root });
    act(() => root.render(<RecognitionResultPanel />));

    const table = host.querySelector("table");
    expect(table).not.toBeNull();
    expect(table?.querySelector("caption")?.textContent).toContain("场记单识别结果");
    expect([...table?.querySelectorAll("th") || []].map((cell) => cell.textContent)).toContain("场次");
    expect(table?.querySelector<HTMLInputElement>('input[aria-label^="场次"]')?.value).toBe("12");
  });

  it("flushes a queued recognition edit before the window closes", () => {
    const result = {
      pageCount: 1,
      result: {
        sheetTitle: "A 组场记单",
        warnings: [],
        records: [{ id: "record-1", sourcePage: 1, cardNumber: "A001", videoCode: "C001", scene: "12", shot: "3", take: "2", takeStatus: "过", description: "近景", comments: null, shotSize: "CU", cameraPosition: "A", confidence: "high" }],
      },
    } as unknown as RecognitionData;
    useRecognitionStore.getState().start(1, "project-1", 1);
    useRecognitionStore.getState().complete(1, result);

    const onRecordEdited = vi.fn();
    const host = document.createElement("div");
    document.body.append(host);
    const root = createRoot(host);
    mounted.push({ host, root });
    act(() => root.render(<RecognitionResultPanel onRecordEdited={onRecordEdited} />));
    const input = host.querySelector<HTMLInputElement>('input[aria-label^="场次"]');
    const valueSetter = Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, "value")?.set;
    act(() => {
      valueSetter?.call(input, "13");
      input?.dispatchEvent(new Event("input", { bubbles: true }));
    });
    expect(useRecognitionStore.getState().records[0]?.scene).toBe("12");
    act(() => window.dispatchEvent(new Event("beforeunload")));
    expect(useRecognitionStore.getState().records[0]?.scene).toBe("13");
    expect(onRecordEdited).toHaveBeenCalledTimes(1);
  });
});

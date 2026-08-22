// @vitest-environment jsdom
import { act } from "react";
import { createRoot } from "react-dom/client";
import { afterEach, describe, expect, it } from "vitest";
import type { ResolveCsvTable } from "../../../src/shared/contracts/index.js";
import { CsvVirtualTable } from "../../../src/renderer/features/csv/CsvVirtualTable";

// Keep React's concurrent scheduler assertions deterministic in jsdom.
(globalThis as { IS_REACT_ACT_ENVIRONMENT?: boolean }).IS_REACT_ACT_ENVIRONMENT = true;

const mounted: Array<{ host: HTMLDivElement; root: ReturnType<typeof createRoot> }> = [];

afterEach(() => {
  for (const { host, root } of mounted.splice(0)) {
    act(() => root.unmount());
    host.remove();
  }
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
});

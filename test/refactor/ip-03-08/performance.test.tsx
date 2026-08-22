import { afterAll, describe, expect, it } from "vitest";
import { encodeResolveCsv } from "../../../public/resolve-csv.js";
import type { ResolveCsvTable } from "../../../src/shared/contracts/index.js";

const ROW_COUNT = 10_000;
const metrics: Record<string, unknown> = { rowCount: ROW_COUNT };

afterAll(() => {
  // The harness prints raw measurements; the reviewed evidence file is
  // written by the implementer so test execution never mutates refactor docs.
  console.log("IP03_08_PERFORMANCE_METRICS", JSON.stringify(metrics));
});

function makeTable(): ResolveCsvTable {
  return {
    headers: ["File Name", "Scene", "Shot", "Take"],
    rows: Array.from({ length: ROW_COUNT }, (_, index) => [`A${String(index + 1).padStart(5, "0")}C001.mov`, String((index % 120) + 1), "01", String((index % 8) + 1)]),
    format: { encoding: "utf-8", bom: false, delimiter: ",", lineEnding: "\r\n", finalNewline: true },
  };
}

describe("10,000-row Worker export performance", () => {
  it("measures the retained Worker encoder on synthetic rows", () => {
    const table = makeTable();
    const started = performance.now();
    const bytes = encodeResolveCsv(table);
    const exportMs = performance.now() - started;
    expect(typeof bytes.byteLength).toBe("number");
    expect(bytes.byteLength).toBeGreaterThan(ROW_COUNT * 10);
    expect(exportMs).toBeLessThan(1000);
    metrics.exportMs = exportMs;
    metrics.exportBytes = bytes.byteLength;
  });
});

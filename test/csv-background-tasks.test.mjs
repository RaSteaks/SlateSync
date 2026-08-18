import assert from "node:assert/strict";
import test from "node:test";
import { createCsvTaskProcessor } from "../public/csv-background-tasks.js";
import { decodeResolveCsv } from "../public/resolve-csv.js";

const source = new TextEncoder().encode(
  "File Name,Scene,Shot,Take,Comments\nA001C001.mov,,,,\n",
);

test("CSV background processor retains metadata and exports sparse edits", () => {
  const processTask = createCsvTaskProcessor();
  const decoded = processTask({ type: "decode-metadata", data: source });
  assert.equal(decoded.table.rows.length, 1);

  const { bytes } = processTask({
    type: "export-resolve",
    records: [{
      cardNumber: "A001",
      videoCode: "C001",
      scene: "1",
      shot: "2",
      take: "3",
      takeStatus: "过",
    }],
    csvEdits: [["0:1", "009"]],
    fieldFormats: { scene: "XXX", shot: "XX", take: "XX" },
    comments: { goodTake: "_OK", holdTake: "_KP" },
  });

  const exported = decodeResolveCsv(bytes);
  assert.deepEqual(exported.rows[0].slice(1, 5), ["009", "02", "03", "_OK"]);
});

test("CSV background processor clears retained metadata", () => {
  const processTask = createCsvTaskProcessor();
  processTask({ type: "decode-metadata", data: source });
  processTask({ type: "clear-metadata" });
  assert.throws(
    () => processTask({ type: "export-resolve", records: [] }),
    /尚未载入有效的 Resolve CSV/,
  );
});

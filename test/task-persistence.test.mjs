import assert from "node:assert/strict";
import test from "node:test";
import {
  restoreCsvPreviewState,
  serializeCsvPreviewState,
} from "../public/task-persistence.js";

test("CSV preview task state round-trips table, edits, and metadata", () => {
  const snapshot = serializeCsvPreviewState({
    metadataTable: {
      headers: ["File Name", "Scene", "Comments"],
      rows: [["A001C001.mov", "001", ""]],
      format: { encoding: "utf-8", delimiter: "," },
    },
    metadataFilename: "timeline.csv",
    csvEdits: new Map([
      ["0:1", "002"],
      ["0:2", "_OK"],
    ]),
    slateMetadata: [{ materialKey: "A:1:1", sensorFps: "24" }],
    slateWarnings: ["warning"],
    missingMetadataKeys: ["A:1:2"],
    slateDirectoryName: "Day 01",
  });

  const restored = restoreCsvPreviewState(snapshot);
  assert.equal(restored.metadataFilename, "timeline.csv");
  assert.deepEqual(restored.metadataTable, snapshot.resolveCsvTable);
  assert.deepEqual([...restored.csvEdits], [
    ["0:1", "002"],
    ["0:2", "_OK"],
  ]);
  assert.deepEqual(restored.slateMetadata, snapshot.slateMetadata);
  assert.deepEqual(restored.missingMetadataKeys, ["A:1:2"]);
  assert.equal(restored.slateDirectoryName, "Day 01");
});

test("CSV preview restore ignores malformed edit keys and missing tables", () => {
  assert.equal(restoreCsvPreviewState({ resolveCsvEdits: { bad: "value" } }), null);

  const restored = restoreCsvPreviewState({
    resolveCsvTable: { headers: ["Scene"], rows: [["001"]] },
    resolveCsvEdits: { "0:0": "002", bad: "ignored" },
  });
  assert.deepEqual([...restored.csvEdits], [["0:0", "002"]]);
  assert.equal(restored.metadataFilename, "Resolve.csv");
});

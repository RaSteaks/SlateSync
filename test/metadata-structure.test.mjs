import test from "node:test";
import assert from "node:assert/strict";
import {
  defaultMetadataStructure,
  learnStructure,
  probeNames,
} from "../public/metadata-structure.js";

test("learnStructure derives a dirname-suffix template", () => {
  assert.deepEqual(
    learnStructure("A004C004_DEMO001", ["A004C004_DEMO001-slate.txt"]),
    [{ dirnameSuffix: "-slate.txt" }],
  );
});

test("learnStructure derives a fixed-name template", () => {
  assert.deepEqual(learnStructure("A004C004_DEMO002", ["camera-slate.txt"]), [
    { fixedName: "camera-slate.txt" },
  ]);
});

test("learnStructure returns empty for no metadata files", () => {
  assert.deepEqual(learnStructure("A004C004_DEMO003", []), []);
});

test("learnStructure handles mixed dirname-suffix and fixed names", () => {
  assert.deepEqual(
    learnStructure("A004C004_DEMO004", [
      "A004C004_DEMO004-slate.txt",
      "metadata.xml",
    ]),
    [{ dirnameSuffix: "-slate.txt" }, { fixedName: "metadata.xml" }],
  );
});

test("probeNames expands templates for a given dir name", () => {
  assert.deepEqual(
    probeNames(
      [{ dirnameSuffix: "-slate.txt" }, { fixedName: "camera-slate.txt" }],
      "B002C007",
    ),
    ["B002C007-slate.txt", "camera-slate.txt"],
  );
});

test("defaultMetadataStructure seeds the Kinefinity convention", () => {
  assert.deepEqual(defaultMetadataStructure(), [{ dirnameSuffix: "-slate.txt" }]);
});

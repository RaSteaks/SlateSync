import assert from "node:assert/strict";
import { mkdtemp, mkdir, rm, writeFile } from "node:fs/promises";
import test from "node:test";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { createSlateScanner } from "../electron/slate-scanner.mjs";

test("Electron scanner reports expected materials whose directories are absent", async () => {
  const root = await mkdtemp(join(tmpdir(), "slatesync-scanner-"));
  try {
    await mkdir(join(root, "A001C001"));
    await writeFile(
      join(root, "A001C001", "A001C001-slate.txt"),
      "Clip Name: A001C001\nSensor FPS: 48",
    );
    await mkdir(join(root, "A001C002"));

    const result = await createSlateScanner().scan(root, {
      expectedKeys: ["A:1:1", "A:1:2", "A:1:3"],
      maxDepth: 4,
    });

    assert.equal(result.metadata.length, 1);
    assert.deepEqual(result.missingKeys, ["A:1:2", "A:1:3"]);
  } finally {
    await rm(root, { recursive: true, force: true });
  }
});

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
    assert.equal(result.metadata[0].materialKey, "A:1:1");
    assert.deepEqual(result.missingKeys, ["A:1:2", "A:1:3"]);
  } finally {
    await rm(root, { recursive: true, force: true });
  }
});

test("Electron scanner ignores loose sidecars whose clip is absent from the CSV", async () => {
  const root = await mkdtemp(join(tmpdir(), "slatesync-scanner-"));
  try {
    await mkdir(join(root, "A001C001"));
    await writeFile(
      join(root, "A001C001", "A001C001-slate.txt"),
      "Clip Name: A001C001\nSensor FPS: 48",
    );
    // A loose root sidecar for a clip Resolve never imported is ignored: the
    // exported CSV only ever backfills materials that are actually in it.
    await writeFile(
      join(root, "A007C002-slate.txt"),
      "Clip Name: A007C002\nSensor FPS: 50",
    );

    const result = await createSlateScanner().scan(root, {
      expectedKeys: ["A:1:1"],
      maxDepth: 4,
    });

    assert.equal(result.metadata.length, 1);
    assert.equal(result.metadata[0].materialKey, "A:1:1");
    assert.equal(result.missingKeys.length, 0);
  } finally {
    await rm(root, { recursive: true, force: true });
  }
});

test("Electron scanner prunes unrelated clip directories without collecting sidecars", async () => {
  const root = await mkdtemp(join(tmpdir(), "slatesync-scanner-"));
  try {
    await mkdir(join(root, "A001C001"));
    await writeFile(
      join(root, "A001C001", "A001C001-slate.txt"),
      "Clip Name: A001C001\nSensor FPS: 48",
    );
    await mkdir(join(root, "A009C003"));
    await writeFile(
      join(root, "A009C003", "A009C003-slate.txt"),
      "Clip Name: A009C003\nSensor FPS: 25",
    );

    const result = await createSlateScanner().scan(root, {
      expectedKeys: ["A:1:1"],
      maxDepth: 4,
    });

    assert.equal(result.metadata.length, 1);
    assert.equal(result.stats.prunedDirectories, 1);
    assert.equal(result.missingKeys.length, 0);
  } finally {
    await rm(root, { recursive: true, force: true });
  }
});

test("Electron scanner learns a fixed-name convention from a matched clip directory", async () => {
  const root = await mkdtemp(join(tmpdir(), "slatesync-scanner-"));
  try {
    await mkdir(join(root, "A001C001"));
    await writeFile(
      join(root, "A001C001", "camera-slate.txt"),
      "Clip Name: A001C001\nSensor FPS: 48",
    );

    const result = await createSlateScanner().scan(root, {
      expectedKeys: ["A:1:1"],
      maxDepth: 4,
    });

    assert.equal(result.metadata.length, 1);
    assert.equal(result.metadata[0].sensorFps, "48");
    assert.equal(result.stats.learnedStructures, 1);
    assert.equal(result.missingKeys.length, 0);
  } finally {
    await rm(root, { recursive: true, force: true });
  }
});

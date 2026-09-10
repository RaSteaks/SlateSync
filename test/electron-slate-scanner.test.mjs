import assert from "node:assert/strict";
import { mkdtemp, mkdir, rm, writeFile } from "node:fs/promises";
import test from "node:test";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { createSlateScanner } from "../electron/slate-scanner.mjs";

// ---- 最小合成 MOV（仅 moov{mvhd}，素材键与拍摄日期来自文件名/创建时间）----

function u32(value) {
  const buffer = Buffer.alloc(4);
  buffer.writeUInt32BE(value >>> 0);
  return buffer;
}

function atom(type, ...payloads) {
  const payload = Buffer.concat(payloads);
  const header = Buffer.alloc(8);
  header.writeUInt32BE(payload.length + 8, 0);
  header.write(type, 4, "latin1");
  return Buffer.concat([header, payload]);
}

// Mac 纪元：2026-08-05T22:54:06Z 对应的秒数
const MAC_SECONDS = 1785915246 + 2082844800;

function buildMinimalMovFile() {
  const ftyp = atom("ftyp", Buffer.from("qt  ", "latin1"), u32(512), Buffer.from("qt  ", "latin1"));
  const moov = atom(
    "moov",
    atom("mvhd", u32(0), u32(MAC_SECONDS), u32(MAC_SECONDS), u32(24000), u32(665000), Buffer.alloc(80)),
  );
  return Buffer.concat([ftyp, atom("mdat", Buffer.alloc(64)), moov]);
}

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

test("Electron scanner falls back to a directory's video when its sidecar is unusable", async () => {
  const root = await mkdtemp(join(tmpdir(), "slatesync-scanner-"));
  try {
    await mkdir(join(root, "A001C001"));
    // 同目录下探测命中的侧车解析失败（无任何可用帧率/日期），不应"一票否决"：
    // 该目录的视频候选（内嵌元数据）仍要被回退读取
    await writeFile(join(root, "A001C001", "A001C001-slate.txt"), "导演手记: 随手一记");
    await writeFile(join(root, "A001C001", "A001C001_260905_R2EC.MOV"), buildMinimalMovFile());

    const result = await createSlateScanner().scan(root, {
      expectedKeys: ["A:1:1"],
      maxDepth: 4,
    });

    assert.equal(result.metadata.length, 1);
    assert.equal(result.metadata[0].materialKey, "A:1:1");
    assert.deepEqual(result.missingKeys, []);
    // 无效侧车保留解析警告，视频回退成功
    assert.equal(result.warnings.length, 1);
    assert.match(result.warnings[0], /缺少有效的 Sensor FPS 或 Shot Date/);
  } finally {
    await rm(root, { recursive: true, force: true });
  }
});

test("Electron scanner picks up a sidecar the fixed probe missed before falling back to videos", async () => {
  const root = await mkdtemp(join(tmpdir(), "slatesync-scanner-"));
  try {
    await mkdir(join(root, "A001C001"));
    // 探测按已知命名约定命中 slate.txt，但同目录还有探测覆盖不到的 ARRI XML。
    // slate.txt 解析失败后，必须先把新枚举出的 XML 补解析掉，才允许回退视频。
    await writeFile(join(root, "A001C001", "A001C001-slate.txt"), "导演手记: 随手一记");
    await writeFile(
      join(root, "A001C001", "A001C001.xml"),
      [
        '<?xml version="1.0" encoding="UTF-8"?>',
        "<xmeml>",
        ' <clipitem id="A001C001-1">',
        "  <name>A001C001</name>",
        '  <field column="Sensor_fps" value="24000"/>',
        '  <field column="Shoot_Date" value="2026-09-05"/>',
        " </clipitem>",
        "</xmeml>",
      ].join("\n"),
    );

    const result = await createSlateScanner().scan(root, {
      expectedKeys: ["A:1:1"],
      maxDepth: 4,
    });

    assert.equal(result.metadata.length, 1);
    assert.equal(result.metadata[0].materialKey, "A:1:1");
    assert.equal(result.metadata[0].sensorFps, "24");
    assert.equal(result.metadata[0].shootDay, "26-09-05");
    assert.deepEqual(result.missingKeys, []);
    // 无效 slate.txt 的解析警告保留；XML 侧车成功产出条目
    assert.equal(result.warnings.length, 1);
    assert.match(result.warnings[0], /缺少有效的 Sensor FPS 或 Shot Date/);
  } finally {
    await rm(root, { recursive: true, force: true });
  }
});

test("Electron scanner does not let an unrelated XML block a valid ARRI MOV", async () => {
  const root = await mkdtemp(join(tmpdir(), "slatesync-scanner-"));
  try {
    await mkdir(join(root, "A001C001"));
    // 无关 XML（非 ARRI 指纹）解析必然失败，但按目录裁决只产生一条警告，
    // 不得阻塞同目录内嵌元数据的视频候选
    await writeFile(join(root, "A001C001", "timeline-export.xml"), "<xmeml></xmeml>");
    await writeFile(
      join(root, "A001C001", "A001C001_260905_R2EC.mov"),
      buildMinimalMovFile(),
    );

    const result = await createSlateScanner().scan(root, {
      expectedKeys: ["A:1:1"],
      maxDepth: 4,
    });

    assert.equal(result.metadata.length, 1);
    assert.equal(result.metadata[0].materialKey, "A:1:1");
    assert.deepEqual(result.missingKeys, []);
    assert.equal(result.warnings.length, 1);
    assert.match(result.warnings[0], /无法识别的元数据文件来源/);
  } finally {
    await rm(root, { recursive: true, force: true });
  }
});

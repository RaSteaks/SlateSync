// ARRI/Avid ALE（多片段日志）适配器测试：
//   - 经典布局（Heading 头段 + 空行 + 列头行）与紧凑布局（无空行、冒号头）
//   - parseEntries 返回 entry[]，单条 parse 明确抛错指向批量接口
//   - 列名变体、缺 fps 列、有理数帧率、美式歧义日期被拒绝
//   - 无法识别素材键的行跳过、全部无键抛错
//   - 扫描器集成：一个 ALE 覆盖 Resolve CSV 的多个素材
import assert from "node:assert/strict";
import { mkdtemp, rm, writeFile } from "node:fs/promises";
import test from "node:test";
import { tmpdir } from "node:os";
import { join } from "node:path";
import {
  METADATA_FILE_PATTERN,
  parseMetadataEntries,
  parseMetadataFile,
} from "../public/metadata-sources/index.js";
import { parseArriAleText } from "../public/metadata-sources/arri-ale.js";
import { createSlateScanner } from "../electron/slate-scanner.mjs";

const CLASSIC_ALE = [
  "Heading",
  "FIELD_DELIM\tTABS",
  "VIDEO_FORMAT\t1080p",
  "FCM\tNONE",
  "",
  "Name\tFPS\tShoot Date\tScene\tTake\tStart\tComments",
  "A004C004_260905_R2EC\t23.976\t2026-09-05\t12\t3\t16:24:05:08\tgood take",
  "A004C005_260905_R2EC\t25\t2026-09-05\t12\t4\t16:31:10:00\t",
  "A004C006_260905_R2EC\t24000/1001\t2026-09-05\t13\t1\t17:02:00:00\tbad audio",
].join("\n");

const COMPACT_ALE = [
  "Title: Demo",
  "FCM: None",
  "Name\tFPS\tScene",
  "A001C001_260905_R2EC\t24\t8",
  "A001C002_260905_R2EC\t24\t9",
].join("\n");

test("registry union pattern matches ALE files", () => {
  assert.equal(METADATA_FILE_PATTERN.test("Day1.ale"), true);
  assert.equal(METADATA_FILE_PATTERN.test("Day1.ALE"), true);
});

test("parseEntries expands one ALE into an entry per recognized clip", () => {
  const entries = parseMetadataEntries(CLASSIC_ALE, "Day1.ale");
  assert.equal(entries.length, 3);
  assert.deepEqual(entries[0], {
    sourceName: "Day1.ale",
    clipName: "A004C004_260905_R2EC",
    materialKey: "A:4:4",
    sensorFps: "23.976",
    shootDay: "26-09-05",
    extra: { scene: "12", take: "3", tcStart: "16:24:05:08", notes: "good take" },
  });
  assert.equal(entries[1].materialKey, "A:4:5");
  assert.equal(entries[1].sensorFps, "25");
  assert.deepEqual(entries[1].extra, { scene: "12", take: "4", tcStart: "16:31:10:00" });
  // 有理数帧率列走 ARRI 专属规范化
  assert.equal(entries[2].sensorFps, "23.976");
  assert.equal(entries[2].extra.notes, "bad audio");
});

test("single-clip parse rejects a multi-clip ALE with a pointer to the batch API", () => {
  assert.throws(
    () => parseMetadataFile(CLASSIC_ALE, "Day1.ale"),
    /多片段 ALE 文件/,
  );
});

test("a compact ALE without a blank line still locates its column header", () => {
  const entries = parseMetadataEntries(COMPACT_ALE, "Day1.ale");
  assert.equal(entries.length, 2);
  assert.equal(entries[0].materialKey, "A:1:1");
  assert.equal(entries[1].materialKey, "A:1:2");
  assert.deepEqual(entries[0].extra, { scene: "8" });
});

test("column name variants are matched loosely and a missing fps column yields empty fps", () => {
  const ale = [
    "Heading",
    "FCM\tNONE",
    "",
    "Clip Name\tCapture FPS\tShoot Date",
    "A004C004_260905_R2EC\t24\t2026-09-05",
    "A004C005_260905_R2EC\t\t2026-09-05",
  ].join("\n");
  const entries = parseMetadataEntries(ale, "Day1.ale");
  assert.equal(entries[0].sensorFps, "24");
  assert.equal(entries[0].shootDay, "26-09-05");
  // 无 fps 列或空单元格 → 空串条目仍然输出，让该素材计为"已找到"
  assert.deepEqual(
    [entries[0].sensorFps, entries[1].sensorFps],
    ["24", ""],
  );
});

test("CRLF line endings and trailing blank lines are tolerated", () => {
  const ale = CLASSIC_ALE.split("\n").join("\r\n") + "\r\n";
  const entries = parseMetadataEntries(ale, "Day1.ale");
  assert.equal(entries.length, 3);
});

test("rows without a recognizable material key are skipped; an all-unrecognized ALE throws", () => {
  const mixed = [
    "Heading",
    "FCM\tNONE",
    "",
    "Name\tFPS",
    "手机花絮.mov\t30",
    "A004C004_260905_R2EC\t24",
  ].join("\n");
  const entries = parseMetadataEntries(mixed, "Day1.ale");
  assert.equal(entries.length, 1);
  assert.equal(entries[0].materialKey, "A:4:4");

  assert.throws(
    () => parseArriAleText("Heading\nFCM\tNONE\n\nName\tFPS\n手机花絮.mov\t30\n", "Day1.ale"),
    /没有可识别的素材编号/,
  );
});

test("an ambiguous US-style date is rejected instead of misread", () => {
  const ale = [
    "Heading",
    "FCM\tNONE",
    "",
    "Name\tFPS\tShoot Date",
    "A004C004_260905_R2EC\t24\t05/09/2026",
  ].join("\n");
  const entries = parseMetadataEntries(ale, "Day1.ale");
  assert.equal(entries[0].sensorFps, "24");
  assert.equal(entries[0].shootDay, "");
});

test("a non-ALE .ale file falls through to the unrecognized-source dispatch error", () => {
  assert.throws(
    () => parseMetadataEntries("随便一段文本，既没有列头也没有素材", "Day1.ale"),
    /无法识别的元数据文件来源/,
  );
});

test("scanner expands one root ALE into entries for every covered material", async () => {
  const root = await mkdtemp(join(tmpdir(), "slatesync-arri-ale-"));
  try {
    await writeFile(join(root, "Day1.ale"), CLASSIC_ALE);

    const result = await createSlateScanner().scan(root, {
      expectedKeys: ["A:4:4", "A:4:5", "A:4:6"],
      maxDepth: 4,
    });

    assert.deepEqual(result.missingKeys, []);
    assert.equal(result.metadata.length, 3);
    assert.equal(result.stats.discoveredSlateFiles, 1);
    assert.equal(result.stats.readSlateFiles, 1);
    assert.equal(result.warnings.length, 0);
  } finally {
    await rm(root, { recursive: true, force: true });
  }
});

import assert from "node:assert/strict";
import test from "node:test";
import { parseSlateMetadataText } from "../public/resolve-csv.js";
import {
  METADATA_FILE_PATTERN,
  METADATA_SOURCES,
  parseMetadataFile,
} from "../public/metadata-sources/index.js";

const SAMPLE = [
  "# SLATE.TXT Revision 2.0",
  "Clip Name...........: A004C004_DEMO001",
  "Sensor FPS..........: 48",
  "Shot Date...........: 2026-08-04",
  "Project FPS.........: 24",
].join("\r\n");

test("registry exposes the Kinefinity source and a case-insensitive union pattern", () => {
  // QuickTime 内嵌元数据（DJI 等）注册后共两类来源
  assert.deepEqual(METADATA_SOURCES.map((source) => source.id).sort(), [
    "kinefinity",
    "quicktime",
  ]);
  assert.equal(METADATA_FILE_PATTERN.test("A004C004-slate.txt"), true);
  assert.equal(METADATA_FILE_PATTERN.test("A004C004-SLATE.TXT"), true);
  // 并集 pattern 现在也覆盖内嵌元数据的视频扩展名
  assert.equal(METADATA_FILE_PATTERN.test("A004C004.mov"), true);
});

test("parseMetadataFile dispatches a Kinefinity slate.txt to the canonical shape", () => {
  const metadata = parseMetadataFile(
    new TextEncoder().encode(SAMPLE),
    "A004C004_DEMO001-slate.txt",
  );
  assert.deepEqual(metadata, {
    sourceName: "A004C004_DEMO001-slate.txt",
    clipName: "A004C004_DEMO001",
    materialKey: "A:4:4",
    sensorFps: "48",
    shootDay: "26-08-04",
  });
});

test("parseMetadataFile matches the legacy parseSlateMetadataText export", () => {
  const bytes = new TextEncoder().encode(SAMPLE);
  assert.deepEqual(
    parseMetadataFile(bytes, "A004C004_DEMO001-slate.txt"),
    parseSlateMetadataText(bytes, "A004C004_DEMO001-slate.txt"),
  );
});

test("parseMetadataFile rejects an unsupported file source", () => {
  assert.throws(
    () => parseMetadataFile(new TextEncoder().encode("<xml/>"), "clip.xml"),
    /无法识别的元数据文件来源/,
  );
});

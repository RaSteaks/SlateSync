// ARRI FCP 7 XML 侧车适配器测试：
//   - detect 指纹：FCP 标记 + ARRI 标记同时命中；ACES AMF 显式排除；
//     无 ARRI 标记的普通 FCP XML 不命中
//   - 官方两种取值形态：<field column= value=/> 属性对（优先）与
//     SensorFps:24.000 嵌入文本
//   - ×1000 帧率编码（24000→24、23976→23.976）；mastercomment/filmslate 进 extra
//   - 归属校验：文件名键与 Clip Name 冲突抛错、两者皆无抛错
//   - BOM/UTF-16 解码；扫描器集成
import assert from "node:assert/strict";
import { mkdir, mkdtemp, rm, writeFile } from "node:fs/promises";
import test from "node:test";
import { tmpdir } from "node:os";
import { join } from "node:path";
import {
  METADATA_FILE_PATTERN,
  parseMetadataEntries,
  parseMetadataFile,
} from "../public/metadata-sources/index.js";
import { createSlateScanner } from "../electron/slate-scanner.mjs";

const CLIP = "A001C001_260905_R2EC";

function buildArriXml({
  clipName = CLIP,
  fpsValue = "24000",
  fpsForm = "column",
  dateValue = "2026-09-05",
  extra = true,
} = {}) {
  const lines = [
    '<?xml version="1.0" encoding="UTF-8"?>',
    '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">',
    '<xmeml version="4">',
    ' <sequence id="Reel 1">',
    `  <clipitem id="${CLIP}-1">`,
    `   <name>${clipName}</name>`,
    `   <masterclipid>${clipName}</masterclipid>`,
  ];
  if (fpsForm === "column") {
    lines.push(`   <field column="Sensor_fps" value="${fpsValue}"/>`);
    lines.push(`   <field column="Shoot_Date" value="${dateValue}"/>`);
  } else if (fpsForm === "name") {
    lines.push(`   <field name="Sensor_fps" value="${fpsValue}"/>`);
    lines.push(`   <shootdate>${dateValue}</shootdate>`);
  } else {
    lines.push("   <notes>");
    lines.push(`SensorFps:${fpsValue}`);
    lines.push("   </notes>");
    lines.push(`   <shootdate>${dateValue}</shootdate>`);
  }
  if (extra) {
    lines.push('   <field column="Scene" value="12"/>');
    lines.push('   <field column="Take" value="3"/>');
    lines.push('   <field name="Master Comment 1" value="good take"/>');
  }
  lines.push("  </clipitem>", " </sequence>", "</xmeml>", "");
  return lines.join("\n");
}

function encodeUtf16Le(text) {
  const bytes = [0xff, 0xfe]; // BOM
  for (const char of text) {
    const code = char.charCodeAt(0);
    bytes.push(code & 0xff, code >> 8);
  }
  return Uint8Array.from(bytes);
}

test("union pattern matches .xml sidecars", () => {
  assert.equal(METADATA_FILE_PATTERN.test(`${CLIP}.xml`), true);
});

test("value-attribute form parses ×1000 fps encoding and extra fields", () => {
  const entry = parseMetadataFile(
    new TextEncoder().encode(buildArriXml()),
    `${CLIP}.xml`,
  );
  assert.equal(entry.materialKey, "A:1:1");
  assert.equal(entry.sensorFps, "24");
  assert.equal(entry.shootDay, "26-09-05");
  assert.equal(entry.sourceName, `${CLIP}.xml`);
  assert.deepEqual(entry.extra, {
    scene: "12",
    take: "3",
    notes: "good take",
  });
});

test("23976 decodes to 23.976", () => {
  const entry = parseMetadataFile(
    new TextEncoder().encode(buildArriXml({ fpsValue: "23976" })),
    `${CLIP}.xml`,
  );
  assert.equal(entry.sensorFps, "23.976");
});

test("name-attribute form and leaf-text date are read", () => {
  const entry = parseMetadataFile(
    new TextEncoder().encode(buildArriXml({ fpsForm: "name" })),
    `${CLIP}.xml`,
  );
  assert.equal(entry.sensorFps, "24");
  assert.equal(entry.shootDay, "26-09-05");
});

test("embedded SensorFps: text form is read", () => {
  const entry = parseMetadataFile(
    new TextEncoder().encode(buildArriXml({ fpsForm: "embedded", fpsValue: "24.000" })),
    `${CLIP}.xml`,
  );
  assert.equal(entry.sensorFps, "24");
  assert.equal(entry.shootDay, "26-09-05");
});

test("ACES AMF files are never treated as camera clip metadata", () => {
  const amf = [
    '<?xml version="1.0" encoding="UTF-8"?>',
    '<amf xmlns="urn:ASC:AMF" xmlns:cdl="urn:ASC:CDL">',
    " <clip id=\"c1\"><cdl:ColorDecisionList/></clip>",
    "</amf>",
  ].join("\n");
  assert.throws(
    () => parseMetadataFile(new TextEncoder().encode(amf), "lookup.amf.xml"),
    /无法识别的元数据文件来源/,
  );
});

test("a plain FCP XML without ARRI field markers is not matched", () => {
  const plain = [
    '<?xml version="1.0" encoding="UTF-8"?>',
    '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">',
    '<xmeml version="4">',
    ' <clipitem id="c1"><name>B-Roll</name></clipitem>',
    "</xmeml>",
  ].join("\n");
  assert.throws(
    () => parseMetadataFile(new TextEncoder().encode(plain), "timeline-export.xml"),
    /无法识别的元数据文件来源/,
  );
});

test("an ARRI field pushed past the 2KB head by a long sequence is still matched", () => {
  // FCP XML 可以在首个 clipitem 之前放很长的 sequence/format 段：2KB 头部
  // 看不到 ARRI 标记时，detect 必须用全文指纹复查（文件体积已在上游封顶）
  const padding = Array.from(
    { length: 40 },
    (_, index) =>
      `  <output>${index} 长序列备注，把首个 clipitem 与 ARRI 字段推出 2KB 头部。</output>`,
  ).join("\n");
  const padded = [
    '<?xml version="1.0" encoding="UTF-8"?>',
    "<xmeml>",
    ' <sequence id="Reel 1">',
    padding,
    " </sequence>",
    ` <clipitem id="${CLIP}-1">`,
    `  <name>${CLIP}</name>`,
    '  <field column="Sensor_fps" value="24000"/>',
    '  <field column="Shoot_Date" value="2026-09-05"/>',
    " </clipitem>",
    "</xmeml>",
  ].join("\n");
  const bytes = new TextEncoder().encode(padded);
  assert.ok(
    bytes.byteLength > 2048,
    `测试前提失效：全文必须超过 2KB（当前 ${bytes.byteLength} 字节）`,
  );
  assert.equal(
    new TextDecoder().decode(bytes.subarray(0, 2048)).includes("Sensor_fps"),
    false,
    "测试前提失效：ARRI 标记必须落在 2KB 头部之外",
  );

  const entry = parseMetadataFile(bytes, `${CLIP}.xml`);
  assert.equal(entry.materialKey, "A:1:1");
  assert.equal(entry.sensorFps, "24");
  assert.equal(entry.shootDay, "26-09-05");
});

test("a Clip Name conflicting with the filename material key is rejected", () => {
  assert.throws(
    () =>
      parseMetadataFile(
        new TextEncoder().encode(buildArriXml({ clipName: "A002C003_260905_R2EC" })),
        `${CLIP}.xml`,
      ),
    /与文件名指向不同素材/,
  );
});

test("a recognizable sidecar name cannot replace an unrecognizable Clip Name", () => {
  // 文件名带素材键、XML 只有无法识别的名字 → 单片段载体不静默回退
  const xml = buildArriXml({ clipName: "公司宣传片_最终版" });
  assert.throws(
    () => parseMetadataFile(new TextEncoder().encode(xml), `${CLIP}.xml`),
    /的 Clip Name“公司宣传片_最终版”无法识别/,
  );
});

test("filename fallback applies only when the XML has no name-like field", () => {
  const xml = [
    '<?xml version="1.0" encoding="UTF-8"?>',
    "<xmeml>",
    ' <field column="Sensor_fps" value="24000"/>',
    "</xmeml>",
  ].join("\n");
  const entry = parseMetadataFile(new TextEncoder().encode(xml), `${CLIP}.xml`);
  assert.equal(entry.materialKey, "A:1:1");
  assert.equal(entry.clipName, "A001C001");
});

test("missing both clip identity and filename key is rejected", () => {
  const xml = [
    '<?xml version="1.0" encoding="UTF-8"?>',
    "<xmeml>",
    ' <field column="Sensor_fps" value="24000"/>',
    "</xmeml>",
  ].join("\n");
  assert.throws(
    () => parseMetadataFile(new TextEncoder().encode(xml), "metadata.xml"),
    /缺少可识别的素材标识/,
  );
});

test("missing both fps and shoot date is rejected", () => {
  const xml = [
    '<?xml version="1.0" encoding="UTF-8"?>',
    '<xmeml version="4">',
    ` <clipitem id="${CLIP}-1">`,
    `  <name>${CLIP}</name>`,
    '  <field column="Scene" value="12"/>',
    " </clipitem>",
    "</xmeml>",
  ].join("\n");
  assert.throws(
    () => parseMetadataFile(new TextEncoder().encode(xml), `${CLIP}.xml`),
    /缺少有效的帧率或拍摄日期/,
  );
});

test("BOM and UTF-16 encoded XML are decoded", () => {
  const entry = parseMetadataFile(
    encodeUtf16Le(buildArriXml()),
    `${CLIP}.xml`,
  );
  assert.equal(entry.sensorFps, "24");
  assert.equal(entry.materialKey, "A:1:1");
});

test("scanner reads an ARRI XML sidecar for its clip", async () => {
  const root = await mkdtemp(join(tmpdir(), "slatesync-arri-xml-"));
  try {
    await mkdir(join(root, CLIP));
    await writeFile(join(root, CLIP, `${CLIP}.xml`), buildArriXml());

    const result = await createSlateScanner().scan(root, {
      expectedKeys: ["A:1:1"],
      maxDepth: 4,
    });

    assert.equal(result.metadata.length, 1);
    assert.equal(result.metadata[0].sensorFps, "24");
    assert.equal(result.metadata[0].shootDay, "26-09-05");
    assert.deepEqual(result.missingKeys, []);
    assert.equal(result.warnings.length, 0);
  } finally {
    await rm(root, { recursive: true, force: true });
  }
});

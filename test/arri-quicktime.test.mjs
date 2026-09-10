// ARRI QuickTime 内嵌元数据（com.arri.* 键）的解析器与扫描器集成测试。
// 合成 MOV（合法 atom 结构 + 少量字节）覆盖：
//   - 与 DJI 适配器的内容互斥（无标记 / 仅 ARRI / 仅 DJI / 双标记四态）
//   - SensorFps 的 ×1000 编码（24000→24、23976→23.976）与有理数（24000/1001）
//   - typed 整数载荷（typeFlags=21）解码
//   - 无视频轨时帧率键回退、无 clipFileName 键时文件名兜底
//   - 扫描器对 ARRI MOV 与 slate.txt 侧车的混合发现
import assert from "node:assert/strict";
import { mkdtemp, mkdir, rm, writeFile } from "node:fs/promises";
import test from "node:test";
import { tmpdir } from "node:os";
import { join } from "node:path";
import {
  METADATA_FILE_PATTERN,
  METADATA_SOURCES,
  parseMetadataFile,
} from "../public/metadata-sources/index.js";
import { arriQuicktimeMetadataSource } from "../public/metadata-sources/arri-quicktime.js";
import { quicktimeMetadataSource } from "../public/metadata-sources/quicktime.js";
import { createSlateScanner } from "../electron/slate-scanner.mjs";

// Mac 纪元 → Unix 纪元秒差（mvhd.creationTime 换算用）
const MAC_EPOCH_OFFSET_SECONDS = 2082844800;
// 固定测试时刻：2026-09-05T22:54:06Z；拍摄日期按本地时区取日
const UNIX_SECONDS = 1785915246;
const MAC_SECONDS = UNIX_SECONDS + MAC_EPOCH_OFFSET_SECONDS;

const ARRI_CLIP = "A001C001_260905_R2EC";

// ---- 合成 atom 构建工具（与 quicktime-embedded.test.mjs 同一套约定）----

function u32(value) {
  const buffer = Buffer.alloc(4);
  buffer.writeUInt32BE(value >>> 0);
  return buffer;
}

function u16(value) {
  const buffer = Buffer.alloc(2);
  buffer.writeUInt16BE(value);
  return buffer;
}

function atom(type, ...payloads) {
  const payload = Buffer.concat(payloads);
  const header = Buffer.alloc(8);
  header.writeUInt32BE(payload.length + 8, 0);
  header.write(type, 4, "latin1");
  return Buffer.concat([header, payload]);
}

// hdlr：version/flags(4)+pre_defined(4)+handler_type(4)+reserved(12)+name
function handlerAtom(handlerType) {
  return atom(
    "hdlr",
    u32(0),
    u32(0),
    Buffer.from(handlerType, "latin1"),
    Buffer.alloc(12),
    Buffer.from("\0"),
  );
}

// mvhd v0：version/flags+creation+modification+timescale+duration+固定尾段
function mvhdAtom({ creationSeconds, timescale = 24000, duration = 665000 }) {
  return atom(
    "mvhd",
    u32(0),
    u32(creationSeconds),
    u32(creationSeconds),
    u32(timescale),
    u32(duration),
    Buffer.alloc(80),
  );
}

// mdhd v0：version/flags+creation+modification+timescale+duration+language 等
function mdhdAtom(timescale) {
  return atom(
    "mdhd",
    u32(0),
    u32(MAC_SECONDS),
    u32(MAC_SECONDS),
    u32(timescale),
    u32(665000),
    u32(0x55c40000),
  );
}

// stts：version/flags+entry_count+N×(sample_count+sample_delta)
function sttsAtom(entries) {
  return atom(
    "stts",
    u32(0),
    u32(entries.length),
    ...entries.flatMap(([count, delta]) => [u32(count), u32(delta)]),
  );
}

// ilst 的 data 子 atom：typeFlags=1 为 UTF-8 文本，21 为有符号整数
function dataAtom(value) {
  if (typeof value === "string") {
    return atom("data", u32(1), u32(0), Buffer.from(value, "utf8"));
  }
  return atom("data", u32(value.typeFlags), u32(0), value.bytes);
}

// mdta 键值区：meta{ hdlr(mdta), keys, ilst }
function mdtaMetaAtom(keyValues) {
  const keyNames = keyValues.map(([key]) => key);
  const keysPayload = [u32(0), u32(keyNames.length)];
  keyNames.forEach((name) => {
    const text = Buffer.from(name, "utf8");
    keysPayload.push(u32(8 + text.length), Buffer.from("mdta", "latin1"), text);
  });
  const ilstItems = keyValues.map(([, value], index) => {
    const data = dataAtom(value);
    // ilst 项的类型字段是 1 起始的键序号（4 字节大端）
    return atom(
      String.fromCharCode(0, 0, 0, index + 1),
      data,
    );
  });
  return atom("meta", handlerAtom("mdta"), atom("keys", ...keysPayload), atom("ilst", ...ilstItems));
}

// 组装一条合成 ARRI 风 moov：mvhd + 可选视频轨 + udta(meta)
function buildMoov({
  creationSeconds = MAC_SECONDS,
  timescale = 24000,
  sampleDelta = 1000,
  withVideoTrack = true,
  keyValues = [
    ["com.arri.camera.ClipFileName", ARRI_CLIP],
    ["com.arri.camera.Model", "ALEXA 35"],
  ],
} = {}) {
  const children = [mvhdAtom({ creationSeconds })];
  if (withVideoTrack) {
    children.push(
      atom(
        "trak",
        atom(
          "mdia",
          handlerAtom("vide"),
          mdhdAtom(timescale),
          atom("minf", atom("stbl", sttsAtom([[665, sampleDelta]]))),
        ),
      ),
    );
  }
  children.push(atom("udta", mdtaMetaAtom(keyValues)));
  return atom("moov", ...children);
}

// 组装一个可落盘的最小 MOV：ftyp + mdat + moov（moov 在尾部）
function buildMovFile(options) {
  const ftyp = atom(
    "ftyp",
    Buffer.from("qt  ", "latin1"),
    u32(512),
    Buffer.from("qt  ", "latin1"),
  );
  const mdat = atom("mdat", Buffer.alloc(64));
  return Buffer.concat([ftyp, mdat, buildMoov(options)]);
}

function expectedLocalShootDay() {
  const date = new Date(UNIX_SECONDS * 1000);
  return `${String(date.getFullYear()).slice(-2)}-${String(date.getMonth() + 1).padStart(2, "0")}-${String(date.getDate()).padStart(2, "0")}`;
}

// ---- 注册表与互斥检测（四态）----

test("registry exposes the ARRI QuickTime source and the union pattern matches video files", () => {
  assert.equal(
    METADATA_SOURCES.some((source) => source.id === "arri-quicktime"),
    true,
  );
  assert.equal(METADATA_FILE_PATTERN.test(ARRI_CLIP + ".mov"), true);
  assert.equal(METADATA_FILE_PATTERN.test(ARRI_CLIP + ".MOV"), true);
});

test("mutual exclusion: a plain moov without vendor markers stays with the DJI source", () => {
  const input = Buffer.alloc(64);
  assert.equal(arriQuicktimeMetadataSource.detect("clip.MOV", input), false);
  assert.equal(quicktimeMetadataSource.detect("clip.MOV", input), true);
  // 缺省命中保住既有错误路径（而非"无法识别的元数据文件来源"）
  assert.throws(() => parseMetadataFile(input, "clip.MOV"), /缺少 moov atom/);
});

test("mutual exclusion: an ARRI-keyed moov routes only to the ARRI source", () => {
  const moov = buildMoov();
  assert.equal(arriQuicktimeMetadataSource.detect("A001C001.MOV", moov), true);
  assert.equal(quicktimeMetadataSource.detect("A001C001.MOV", moov), false);
});

test("mutual exclusion: a DJI proapps moov routes only to the DJI source", () => {
  const moov = buildMoov({
    keyValues: [["com.apple.proapps.clipFileName", "D020C0016_260906_T0GY61"]],
  });
  assert.equal(arriQuicktimeMetadataSource.detect("D020C0016.MOV", moov), false);
  assert.equal(quicktimeMetadataSource.detect("D020C0016.MOV", moov), true);
});

test("mutual exclusion: a pathological dual-marker moov is rejected as ambiguous", () => {
  const moov = buildMoov({
    keyValues: [
      ["com.arri.camera.ClipFileName", ARRI_CLIP],
      ["com.apple.proapps.clipFileName", "D020C0016_260906_T0GY61"],
    ],
  });
  assert.equal(arriQuicktimeMetadataSource.detect("clip.MOV", moov), true);
  assert.equal(quicktimeMetadataSource.detect("clip.MOV", moov), true);
  assert.throws(
    () => parseMetadataFile(moov, "clip.MOV"),
    (error) => {
      assert.match(error.message, /同时匹配多个来源/);
      assert.match(error.message, /ARRI QuickTime 内嵌元数据/);
      assert.match(error.message, /QuickTime 内嵌元数据/);
      return true;
    },
  );
});

// ---- 解析 ----

test("parseMetadataFile dispatches an ARRI moov to the canonical shape", () => {
  const metadata = parseMetadataFile(
    buildMoov(),
    `Video/260905/${ARRI_CLIP}.mov`,
  );
  assert.deepEqual(metadata, {
    sourceName: `Video/260905/${ARRI_CLIP}.mov`,
    clipName: ARRI_CLIP,
    materialKey: "A:1:1",
    sensorFps: "24",
    shootDay: expectedLocalShootDay(),
  });
});

test("SensorFps ×1000 encoding falls back to the key when no video track exists", () => {
  const metadata = parseMetadataFile(
    buildMoov({ withVideoTrack: false, keyValues: [["com.arri.camera.SensorFps", "23976"]] }),
    `${ARRI_CLIP}.mov`,
  );
  assert.equal(metadata.sensorFps, "23.976");
  assert.equal(metadata.shootDay, expectedLocalShootDay());

  const integer = parseMetadataFile(
    buildMoov({ withVideoTrack: false, keyValues: [["com.arri.camera.SensorFps", "24000"]] }),
    `${ARRI_CLIP}.mov`,
  );
  assert.equal(integer.sensorFps, "24");
});

test("rational fps keys are normalized through the ARRI fps decoder", () => {
  const metadata = parseMetadataFile(
    buildMoov({
      withVideoTrack: false,
      keyValues: [["com.arri.camera.CaptureFrameRate", "24000/1001"]],
    }),
    `${ARRI_CLIP}.mov`,
  );
  assert.equal(metadata.sensorFps, "23.976");
});

test("typed integer payloads (typeFlags=21) decode into the ARRI fps normalizer", () => {
  const metadata = parseMetadataFile(
    buildMoov({
      withVideoTrack: false,
      keyValues: [
        ["com.arri.camera.ClipFileName", ARRI_CLIP],
        // 23976 以 16 位大端整数写入（0x5DA8），非可打印文本
        ["com.arri.camera.SensorFps", { typeFlags: 21, bytes: u16(23976) }],
      ],
    }),
    `${ARRI_CLIP}.mov`,
  );
  assert.equal(metadata.sensorFps, "23.976");
});

test("a missing clipFileName key falls back to the material key in the file name", () => {
  const metadata = parseMetadataFile(
    buildMoov({
      keyValues: [["com.arri.camera.Model", "ALEXA 35"]],
    }),
    `${ARRI_CLIP}.mov`,
  );
  assert.equal(metadata.materialKey, "A:1:1");
  assert.equal(metadata.clipName, "A001C001");
});

test("a ClipFileName pointing at a different material than the file name is rejected", () => {
  assert.throws(
    () =>
      parseMetadataFile(
        buildMoov({ keyValues: [["com.arri.camera.ClipFileName", "B003C004_260905_R2EC"]] }),
        `${ARRI_CLIP}.mov`,
      ),
    /与文件名指向不同素材/,
  );
});

test("slate keys are carried through the optional extra object", () => {
  const metadata = parseMetadataFile(
    buildMoov({
      keyValues: [
        ["com.arri.camera.ClipFileName", ARRI_CLIP],
        ["com.arri.slate.Scene", "12"],
        ["com.arri.slate.Take", "3"],
        ["com.arri.slate.TCStart", "16:24:05:08"],
      ],
    }),
    `${ARRI_CLIP}.mov`,
  );
  assert.deepEqual(metadata.extra, {
    scene: "12",
    take: "3",
    tcStart: "16:24:05:08",
  });
});

// ---- 扫描器集成：ARRI MOV 与 slate.txt 侧车混合发现 ----

test("scanner reads ARRI embedded metadata and mixes with slate sidecars", async () => {
  const root = await mkdtemp(join(tmpdir(), "slatesync-arri-qt-"));
  try {
    // 素材 1：散落在根目录的 ARRI MOV（moov 在尾部）
    await writeFile(join(root, `${ARRI_CLIP}.MOV`), buildMovFile());
    // 素材 2：片段目录内的 ARRI MOV（NTSC 分数帧率）
    await mkdir(join(root, "A001C002"));
    await writeFile(
      join(root, "A001C002", "A001C002_260905_R2EC.mov"),
      buildMovFile({ timescale: 30000, sampleDelta: 1001, keyValues: [["com.arri.camera.ClipFileName", "A001C002_260905_R2EC"]] }),
    );
    // 素材 3：只有 Kinefinity 侧车
    await mkdir(join(root, "A001C003"));
    await writeFile(
      join(root, "A001C003", "A001C003-slate.txt"),
      "Clip Name: A001C003\nSensor FPS: 48",
    );

    const result = await createSlateScanner().scan(root, {
      expectedKeys: ["A:1:1", "A:1:2", "A:1:3"],
      maxDepth: 4,
    });

    assert.deepEqual(result.missingKeys, []);
    assert.equal(result.metadata.length, 3);
    const byKey = new Map(result.metadata.map((entry) => [entry.materialKey, entry]));
    assert.equal(byKey.get("A:1:1").sensorFps, "24");
    assert.equal(byKey.get("A:1:2").sensorFps, "29.97");
    assert.equal(byKey.get("A:1:3").sensorFps, "48");
    assert.equal(result.stats.discoveredVideoFiles, 2);
    assert.equal(result.stats.discoveredSlateFiles, 1);
    assert.equal(result.stats.readVideoFiles, 2);
    assert.equal(result.warnings.length, 0);
  } finally {
    await rm(root, { recursive: true, force: true });
  }
});

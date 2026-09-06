// QuickTime 内嵌元数据（DJI 如影 4D 等）的解析器与扫描器集成测试。
// 真实素材动辄数 GB，这里用合成 MOV（合法 atom 结构 + 少量字节）覆盖：
//   - moov/meta（mdta 键值区）读取 proapps 键
//   - 视频轨 mdhd+stts 推导帧率（CFR 与 NTSC 分数帧率）
//   - mvhd 创建时间按本地时区换算拍摄日期
//   - 扫描器对侧车与视频候选的互斥发现、剪枝与无键名视频过滤
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
import { readQuickTimeMoov } from "../electron/quicktime-meta-reader.mjs";
import { createSlateScanner } from "../electron/slate-scanner.mjs";

// Mac 纪元 → Unix 纪元秒差（mvhd.creationTime 换算用）
const MAC_EPOCH_OFFSET_SECONDS = 2082844800;
// 固定测试时刻：2026-09-05T22:54:06Z；拍摄日期按本地时区取日
const UNIX_SECONDS = 1785915246;
const MAC_SECONDS = UNIX_SECONDS + MAC_EPOCH_OFFSET_SECONDS;

// ---- 合成 atom 构建工具 ----

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
  return atom("stts", u32(0), u32(entries.length), ...entries.flatMap(([count, delta]) => [u32(count), u32(delta)]));
}

// mdta 键值区：meta{ hdlr(mdta), keys, ilst }；withVersionFlags 模拟 iTunes 风格对齐，
// flagsValue 可注入非零 version/flags 以锻炼起点探测
function mdtaMetaAtom(keyValues, { withVersionFlags = false, flagsValue = 0 } = {}) {
  const keyNames = keyValues.map(([key]) => key);
  const keysPayload = [u32(0), u32(keyNames.length)];
  keyNames.forEach((name) => {
    const text = Buffer.from(name, "utf8");
    keysPayload.push(u32(8 + text.length), Buffer.from("mdta", "latin1"), text);
  });
  const ilstItems = keyValues.map(([, value], index) => {
    const data = atom("data", u32(1), u32(0), Buffer.from(value, "utf8"));
    // ilst 项的类型字段是 1 起始的键序号（4 字节大端）
    return atom(String.fromCharCode(0) + String.fromCharCode(0) + String.fromCharCode(0) + String.fromCharCode(index + 1), data);
  });
  const children = [
    handlerAtom("mdta"),
    atom("keys", ...keysPayload),
    atom("ilst", ...ilstItems),
  ];
  // QuickTime 风格 meta 无 version/flags；iTunes 风格在子项前多 4 字节
  return withVersionFlags
    ? Buffer.concat([atom("meta", u32(flagsValue), ...children)])
    : atom("meta", ...children);
}

// 组装一条合成 DJI 风 moov：mvhd + 视频轨 + udta(meta)
function buildMoov({
  creationSeconds = MAC_SECONDS,
  timescale = 24000,
  sampleDelta = 1000,
  keyValues = [
    ["com.apple.proapps.manufacturer", "DJI"],
    ["com.apple.proapps.clipFileName", "D020C0016_260906_T0GY61"],
    ["com.apple.proapps.cameraName", "D"],
  ],
  metaOptions = {},
} = {}) {
  const videoTrak = atom(
    "trak",
    atom("mdia", handlerAtom("vide"), mdhdAtom(timescale),
      atom("minf", atom("stbl", sttsAtom([[665, sampleDelta]])))),
  );
  return atom(
    "moov",
    mvhdAtom({ creationSeconds }),
    videoTrak,
    atom("udta", mdtaMetaAtom(keyValues, metaOptions)),
  );
}

// 组装一个可落盘的最小 MOV：ftyp + mdat + moov（moov 在尾部，DJI 默认布局）
function buildMovFile(options) {
  const ftyp = atom("ftyp", Buffer.from("qt  ", "latin1"), u32(512), Buffer.from("qt  ", "latin1"));
  const mdat = atom("mdat", Buffer.alloc(64));
  return Buffer.concat([ftyp, mdat, buildMoov(options)]);
}

function expectedLocalShootDay() {
  const date = new Date(UNIX_SECONDS * 1000);
  return `${String(date.getFullYear()).slice(-2)}-${String(date.getMonth() + 1).padStart(2, "0")}-${String(date.getDate()).padStart(2, "0")}`;
}

// ---- 注册表与解析器 ----

test("registry exposes the QuickTime source and the union pattern matches video files", () => {
  assert.equal(METADATA_SOURCES.some((source) => source.id === "quicktime"), true);
  assert.equal(METADATA_FILE_PATTERN.test("A004C004.mov"), true);
  assert.equal(METADATA_FILE_PATTERN.test("D020C0016_260906_T0GY61.MOV"), true);
  assert.equal(METADATA_FILE_PATTERN.test("A004C004-slate.txt"), true);
});

test("parseMetadataFile dispatches a DJI-style moov to the canonical shape", () => {
  const metadata = parseMetadataFile(
    buildMoov(),
    "Video/260905/D020C0016_260906_T0GY61.MOV",
  );
  assert.deepEqual(metadata, {
    sourceName: "Video/260905/D020C0016_260906_T0GY61.MOV",
    clipName: "D020C0016_260906_T0GY61",
    materialKey: "D:20:16",
    sensorFps: "24",
    shootDay: expectedLocalShootDay(),
  });
});

test("mdta meta with leading version/flags still parses (iTunes-style alignment)", () => {
  const metadata = parseMetadataFile(
    buildMoov({ metaOptions: { withVersionFlags: true } }),
    "D020C0016_260906_T0GY61.MOV",
  );
  assert.equal(metadata.materialKey, "D:20:16");
  assert.equal(metadata.sensorFps, "24");
});

test("mdta meta with a larger non-zero version/flags prefix still parses", () => {
  // flags=0x20 会让"首项像合法 atom"的单点探测失真，需要按整链自洽性
  // 在 +8/+12 两个起点间抉择——锁定该加固行为
  const metadata = parseMetadataFile(
    buildMoov({ metaOptions: { withVersionFlags: true, flagsValue: 0x20 } }),
    "D020C0016_260906_T0GY61.MOV",
  );
  assert.equal(metadata.materialKey, "D:20:16");
  assert.equal(metadata.sensorFps, "24");
});

test("NTSC fractional frame rates are derived from mdhd timescale and stts delta", () => {
  // 30000/1001 ≈ 29.97003，按 3 位小数对齐为 29.97
  const metadata = parseMetadataFile(
    buildMoov({
      timescale: 30000,
      sampleDelta: 1001,
      keyValues: [["com.apple.proapps.clipFileName", "A001C002_260906_T0GY61"]],
    }),
    "A001C002_260906_T0GY61.MOV",
  );
  assert.equal(metadata.sensorFps, "29.97");
  assert.equal(metadata.materialKey, "A:1:2");
});

test("mvhd version 1 (64-bit creation time) is supported", () => {
  const videoTrak = atom(
    "trak",
    atom("mdia", handlerAtom("vide"), mdhdAtom(24000),
      atom("minf", atom("stbl", sttsAtom([[665, 1000]])))),
  );
  const mvhdV1 = atom(
    "mvhd",
    // v1 布局：version(1)+flags(3)+creation(8)+modification(8)+timescale(4)+duration(8)
    Buffer.from([1, 0, 0, 0]),
    // 64 位 creation / modification
    (() => { const b = Buffer.alloc(8); b.writeBigUInt64BE(BigInt(MAC_SECONDS)); return b; })(),
    (() => { const b = Buffer.alloc(8); b.writeBigUInt64BE(BigInt(MAC_SECONDS)); return b; })(),
    u32(24000),
    (() => { const b = Buffer.alloc(8); b.writeBigUInt64BE(665000n); return b; })(),
    Buffer.alloc(80),
  );
  const moov = atom(
    "moov",
    mvhdV1,
    videoTrak,
    atom("udta", mdtaMetaAtom([["com.apple.proapps.clipFileName", "D020C0016_260906_T0GY61"]])),
  );
  const metadata = parseMetadataFile(moov, "D020C0016_260906_T0GY61.MOV");
  assert.equal(metadata.shootDay, expectedLocalShootDay());
  assert.equal(metadata.sensorFps, "24");
});

test("clipFileName pointing at a different material than the file name is rejected", () => {
  assert.throws(
    () => parseMetadataFile(
      buildMoov({ keyValues: [["com.apple.proapps.clipFileName", "B003C004_260906_T0GY61"]] }),
      "D020C0016_260906_T0GY61.MOV",
    ),
    /与文件名指向不同素材/,
  );
});

test("input without a moov header is rejected with a clear error", () => {
  assert.throws(
    () => parseMetadataFile(Buffer.alloc(64), "clip.MOV"),
    /缺少 moov atom/,
  );
});

test("a video without any usable identity or shooting info is rejected", () => {
  // 无 proapps 键 + 文件名无素材键（如手机花絮）→ 即使有帧率也无法归属
  const moov = atom(
    "moov",
    mvhdAtom({ creationSeconds: MAC_SECONDS }),
    atom("trak", atom("mdia", handlerAtom("vide"), mdhdAtom(24000),
      atom("minf", atom("stbl", sttsAtom([[665, 1000]]))))),
  );
  assert.throws(
    () => parseMetadataFile(moov, "260901导演手机录制/clip.MOV"),
    /缺少可识别的素材标识/,
  );
});

// ---- moov 定位读取器 ----

test("readQuickTimeMoov locates a trailing moov and skips mdat without reading it", async () => {
  const root = await mkdtemp(join(tmpdir(), "slatesync-qt-"));
  try {
    const filePath = join(root, "D020C0016_260906_T0GY61.MOV");
    await writeFile(filePath, buildMovFile());
    const moov = await readQuickTimeMoov(filePath);
    assert.ok(moov);
    assert.equal(moov.toString("latin1", 4, 8), "moov");
    // 与 buildMoov 输出逐字节一致（ftyp/mdat 之后即 moov）
    const built = buildMoov();
    assert.equal(moov.length, built.length);
    assert.ok(moov.equals(built));
  } finally {
    await rm(root, { recursive: true, force: true });
  }
});

test("readQuickTimeMoov supports 64-bit largesize atoms and returns null for non-QuickTime files", async () => {
  const root = await mkdtemp(join(tmpdir(), "slatesync-qt-"));
  try {
    // largesize moov：size=1 + 8 字节 64 位长度
    const payload = buildMoov();
    const header = Buffer.alloc(16);
    header.writeUInt32BE(1, 0);
    header.write("moov", 4, "latin1");
    header.writeBigUInt64BE(BigInt(payload.length + 16), 8);
    const filePath = join(root, "largesize.MOV");
    await writeFile(filePath, Buffer.concat([atom("ftyp", Buffer.from("qt  ", "latin1")), header, payload]));
    const moov = await readQuickTimeMoov(filePath);
    assert.ok(moov);
    assert.equal(moov.toString("latin1", 4, 8), "moov");

    const textPath = join(root, "notes.MOV");
    await writeFile(textPath, "not a quicktime file at all");
    assert.equal(await readQuickTimeMoov(textPath), null);
  } finally {
    await rm(root, { recursive: true, force: true });
  }
});

test("readQuickTimeMoov enforces the moov size cap", async () => {
  const root = await mkdtemp(join(tmpdir(), "slatesync-qt-"));
  try {
    const filePath = join(root, "D020C0016_260906_T0GY61.MOV");
    await writeFile(filePath, buildMovFile());
    await assert.rejects(
      () => readQuickTimeMoov(filePath, 8),
      /超过.*读取上限/,
    );
  } finally {
    await rm(root, { recursive: true, force: true });
  }
});

// ---- 扫描器集成：侧车与内嵌元数据互斥发现 ----

test("scanner reads embedded metadata from video files and mixes with slate sidecars", async () => {
  const root = await mkdtemp(join(tmpdir(), "slatesync-qt-scan-"));
  try {
    // 素材 1：散落的 DJI MOV（moov 在尾部）
    await writeFile(
      join(root, "D020C0016_260906_T0GY61.MOV"),
      buildMovFile(),
    );
    // 素材 2：片段目录内的 MOV
    await mkdir(join(root, "A001C002"));
    await writeFile(
      join(root, "A001C002", "A001C002_260906_T0GY61.MOV"),
      buildMovFile({
        timescale: 30000,
        sampleDelta: 1001,
        keyValues: [["com.apple.proapps.clipFileName", "A001C002_260906_T0GY61"]],
      }),
    );
    // 素材 3：只有侧车
    await mkdir(join(root, "A001C003"));
    await writeFile(
      join(root, "A001C003", "A001C003-slate.txt"),
      "Clip Name: A001C003\nSensor FPS: 48",
    );
    // 干扰项：无键名视频（手机花絮）与非本 CSV 的素材目录，都应被跳过
    await mkdir(join(root, "260901导演手机录制"));
    await writeFile(join(root, "260901导演手机录制", "A001_09011731_C012.mov"), buildMovFile());
    await mkdir(join(root, "A009C009"));
    await writeFile(join(root, "A009C009", "A009C009_260906_T0GY61.MOV"), buildMovFile());

    const result = await createSlateScanner().scan(root, {
      expectedKeys: ["D:20:16", "A:1:2", "A:1:3"],
      maxDepth: 4,
    });

    assert.deepEqual(result.missingKeys, []);
    assert.equal(result.metadata.length, 3);
    const byKey = new Map(result.metadata.map((entry) => [entry.materialKey, entry]));
    assert.deepEqual(
      { ...byKey.get("D:20:16"), sourceName: undefined },
      {
        sourceName: undefined,
        clipName: "D020C0016_260906_T0GY61",
        materialKey: "D:20:16",
        sensorFps: "24",
        shootDay: expectedLocalShootDay(),
      },
    );
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

test("scanner rejects a misplaced video whose name key differs from its clip directory", async () => {
  const root = await mkdtemp(join(tmpdir(), "slatesync-qt-scan-"));
  try {
    // D020C0016 目录里错放了 A001C002 的素材（两个键都在本 CSV 中）：
    // 错位文件不得被静默归属到目录素材，只有自己目录里的那份被接纳
    await mkdir(join(root, "D020C0016"));
    await writeFile(
      join(root, "D020C0016", "A001C002_260906_T0GY61.MOV"),
      buildMovFile({ keyValues: [["com.apple.proapps.clipFileName", "A001C002_260906_T0GY61"]] }),
    );
    await mkdir(join(root, "A001C002"));
    await writeFile(
      join(root, "A001C002", "A001C002_260906_T0GY61.MOV"),
      buildMovFile({ keyValues: [["com.apple.proapps.clipFileName", "A001C002_260906_T0GY61"]] }),
    );

    const result = await createSlateScanner().scan(root, {
      expectedKeys: ["D:20:16", "A:1:2"],
      maxDepth: 4,
    });

    assert.equal(result.metadata.length, 1);
    assert.equal(result.metadata[0].materialKey, "A:1:2");
    assert.equal(result.stats.discoveredVideoFiles, 1);
    assert.deepEqual(result.missingKeys, ["D:20:16"]);
    assert.equal(result.warnings.length, 0);
  } finally {
    await rm(root, { recursive: true, force: true });
  }
});

test("scanner reports videos without embedded metadata via warnings and missing keys", async () => {
  const root = await mkdtemp(join(tmpdir(), "slatesync-qt-scan-"));
  try {
    await mkdir(join(root, "A001C004"));
    // 同名 .MOV 但内容不是 QuickTime → 读取失败应产生警告而非静默丢失
    await writeFile(join(root, "A001C004", "A001C004_260906_T0GY61.MOV"), "junk");
    await mkdir(join(root, "A001C005"));
    await writeFile(
      join(root, "A001C005", "A001C005_260906_T0GY61.MOV"),
      buildMovFile({
        keyValues: [["com.apple.proapps.clipFileName", "A001C005_260906_T0GY61"]],
      }),
    );

    const result = await createSlateScanner().scan(root, {
      expectedKeys: ["A:1:4", "A:1:5"],
      maxDepth: 4,
    });

    assert.equal(result.metadata.length, 1);
    assert.equal(result.metadata[0].materialKey, "A:1:5");
    assert.deepEqual(result.missingKeys, ["A:1:4"]);
    assert.equal(result.warnings.length, 1);
    assert.match(result.warnings[0], /不是有效的 QuickTime 文件/);
  } finally {
    await rm(root, { recursive: true, force: true });
  }
});

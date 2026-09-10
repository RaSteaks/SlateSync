import test from "node:test";
import assert from "node:assert/strict";
import {
  canonicalMaterialKey,
  buildSlateMetadataIndex,
  buildStandaloneResolveTable,
  canonicalResolveComment,
  decodeResolveCsv,
  detectSlateSequenceAnomalies,
  encodeResolveCsv,
  materialPrefix,
  mergeSlateIntoResolveTable,
  normalizeClipNumber,
  normalizeCameraFps,
  normalizeShootDay,
  normalizeSceneValue,
  normalizeShotValue,
  normalizeTakeValue,
  collectResolveMaterialKeys,
  parseCsvText,
  parseSlateMetadataText,
  resolveColumnIndexes,
} from "../public/resolve-csv.js";
import {
  materialKey,
  syntheticProductionDayGroundTruth,
} from "../test-support/synthetic-production-day.mjs";

const ENGLISH_HEADERS = [
  "File Name",
  "Clip Directory",
  "Reel Name",
  "Shot",
  "Scene",
  "Take",
  "Notes",
  "Comments",
];

function sourceTable(rows, overrides = {}) {
  const headers = overrides.headers || [...ENGLISH_HEADERS];
  return {
    headers,
    rows: rows.map((row) => {
      const normalized = [...row];
      while (normalized.length < headers.length) normalized.push("");
      return normalized;
    }),
    format: {
      encoding: "utf-16le",
      bom: true,
      delimiter: ",",
      lineEnding: "\n",
      finalNewline: true,
      ...(overrides.format || {}),
    },
  };
}

function completeRecord(overrides = {}) {
  return {
    cardNumber: "A001",
    videoCode: "C001",
    scene: "37",
    shot: "1",
    take: "2",
    takeStatus: null,
    ...overrides,
  };
}

test("video codes use C0XX while metadata matching ignores extra leading zeroes", () => {
  assert.equal(normalizeClipNumber("15"), "C015");
  assert.equal(normalizeClipNumber("c1"), "C001");
  assert.equal(normalizeClipNumber("C0 15"), "C015");
  assert.equal(normalizeClipNumber("C0015"), "C015");
  assert.equal(normalizeClipNumber("D001C0009"), "C009");
  assert.equal(normalizeClipNumber("C115"), "");
  assert.equal(materialPrefix("A001", "15"), "A001C015");
  assert.equal(canonicalMaterialKey("D001", "C009"), "D:1:9");
});

test("scene suffixes stay uppercase while numeric fields keep zero padding up to the configured width", () => {
  assert.equal(normalizeSceneValue("第 37A 场"), "37A");
  assert.equal(normalizeSceneValue("87a"), "87A");
  assert.equal(normalizeSceneValue("16/72a"), "16 / 72A");
  assert.equal(normalizeSceneValue("57、58"), "57 / 58");
  assert.equal(normalizeSceneValue("57a/58"), "57A / 58");
  assert.equal(normalizeSceneValue("58 / 59 场"), "58 / 59");
  assert.equal(normalizeSceneValue("1"), "001");
  assert.equal(normalizeShotValue("镜 2"), "02");
  assert.equal(normalizeTakeValue("9 次"), "09");
  assert.equal(normalizeSceneValue("1000"), "1000");
  assert.equal(normalizeShotValue("100"), "100");
});

test("numbers wider than the configured template are kept, not truncated", () => {
  assert.equal(normalizeTakeValue("11", "X"), "11");
  assert.equal(normalizeShotValue("11 次", "X"), "11");
  assert.equal(normalizeTakeValue("9", "XX"), "09");
  assert.equal(normalizeTakeValue("11", "XX"), "11");
  assert.equal(normalizeTakeValue("1234567", "X"), "");
});

test("full-width digits and Chinese numerals normalize into padded numbers", () => {
  assert.equal(normalizeTakeValue("０９"), "09");
  assert.equal(normalizeTakeValue("十一"), "11");
  assert.equal(normalizeShotValue("十"), "10");
  assert.equal(normalizeSceneValue("二十三"), "023");
  assert.equal(normalizeSceneValue("十一A"), "11A");
  assert.equal(normalizeSceneValue("五十七、五十八"), "57 / 58");
});

test("clip gaps map to the material key after the gap without cross-camera noise", () => {
  const anomalies = detectSlateSequenceAnomalies([
    { cardNumber: "A001", videoCode: "C003", scene: "012", shot: "01", take: "01" },
    { cardNumber: "A001", videoCode: "C006", scene: "012", shot: "01", take: "02" },
    { cardNumber: "B001", videoCode: "C001", scene: "012", shot: "01", take: "01" },
  ]);
  assert.equal(anomalies.length, 1);
  assert.equal(anomalies[0].type, "clip-gap");
  assert.equal(anomalies[0].key, "A:1:6");
  assert.match(anomalies[0].message, /C003 断档到 C006/);
  assert.match(anomalies[0].message, /缺少 C004、C005/);
  assert.match(anomalies[0].message, /可能漏 2 条/);
});

test("take sequence anomalies flag duplicates and non-restarting takes", () => {
  const anomalies = detectSlateSequenceAnomalies([
    { cardNumber: "A001", videoCode: "C001", scene: "012", shot: "01", take: "01" },
    { cardNumber: "A001", videoCode: "C002", scene: "012", shot: "01", take: "01" },
    { cardNumber: "A001", videoCode: "C003", scene: "012", shot: "02", take: "03" },
  ]);
  assert.deepEqual(
    anomalies.map((anomaly) => [anomaly.type, anomaly.key]),
    [
      ["take-sequence", "A:1:2"],
      ["take-sequence", "A:1:3"],
    ],
  );
  assert.match(anomalies[0].message, /次序可能重复/);
  assert.match(anomalies[1].message, /通常应从 1 开始/);
});

test("configured X templates control Scene, Shot and Take output widths", () => {
  assert.equal(normalizeSceneValue("37", "XXXX"), "0037");
  assert.equal(normalizeShotValue("2", "XXX"), "002");
  assert.equal(normalizeTakeValue("9", "X"), "9");

  const source = sourceTable([
    ["A001C001.mov", "/A", "A001C001", "", "", "", ""],
  ]);
  const output = mergeSlateIntoResolveTable(
    source,
    [completeRecord()],
    [],
    {
      fieldFormats: { scene: "XXXX", shot: "XXX", take: "XXX" },
    },
  );
  assert.deepEqual(output.table.rows[0].slice(3, 6), ["001", "0037", "002"]);
});

test("Kinefinity slate.txt maps Clip Name and Sensor FPS to canonical metadata", () => {
  const metadata = parseSlateMetadataText(
    [
      "# SLATE.TXT Revision 2.0",
      "Clip Name...........: A004C004_DEMO001",
      "Sensor FPS..........: 48",
      "Shot Date...........: 2026-08-04",
      "Project FPS.........: 24",
    ].join("\r\n"),
    "A004C004_DEMO001/A004C004_DEMO001-slate.txt",
  );

  assert.deepEqual(metadata, {
    sourceName:
      "A004C004_DEMO001/A004C004_DEMO001-slate.txt",
    clipName: "A004C004_DEMO001",
    materialKey: "A:4:4",
    sensorFps: "48",
    shootDay: "26-08-04",
  });
  assert.equal(normalizeCameraFps("47.952 fps"), "47.952");
  assert.equal(normalizeCameraFps("0"), "");
  assert.equal(normalizeShootDay("2026/8/1"), "26-08-01");
  assert.equal(normalizeShootDay("20260801"), "26-08-01");
  assert.equal(normalizeShootDay("26-08-01"), "26-08-01");
  assert.equal(normalizeShootDay("2026-02-30"), "");
  assert.throws(
    () =>
      parseSlateMetadataText(
        "Clip Name: A004C005_suffix\nSensor FPS: 48",
        "A004C004-slate.txt",
      ),
    /指向不同素材/,
  );
  assert.throws(
    () =>
      parseSlateMetadataText(
        "Clip Name: unreadable\nSensor FPS: 96",
        "A099C007-slate.txt",
      ),
    /Clip Name.*无法识别/,
  );
  assert.equal(
    parseSlateMetadataText(
      "Sensor FPS: 96",
      "A099C007-slate.txt",
    ).materialKey,
    "A:99:7",
  );
  assert.equal(
    parseSlateMetadataText(
      "Clip Name: A004C004_suffix\nSensor FPS: 48",
      "A001C001-root/A004C004-slate.txt",
    ).materialKey,
    "A:4:4",
  );
});

test("slate.txt Sensor FPS and Shot Date map to Resolve Camera FPS and Shoot Day", () => {
  const source = sourceTable([
    ["A004C004_DEMO001.mov", "/fixtures/media/A004", "A004C004", "", "", "", "", ""],
  ]);
  const slateMetadata = [
    parseSlateMetadataText(
      "Clip Name...........: A004C004_DEMO001\r\nSensor FPS..........: 48\r\nShot Date...........: 2026-08-04\r\n",
      "A004C004_DEMO001-slate.txt",
    ),
  ];
  const output = mergeSlateIntoResolveTable(
    source,
    [
      completeRecord({
        cardNumber: "A004",
        videoCode: "C004",
        scene: "3",
        shot: "2",
        take: "76",
      }),
    ],
    slateMetadata,
  );
  const columns = resolveColumnIndexes(output.table.headers);

  assert.equal(output.table.rows[0][columns.cameraFps], "48");
  assert.equal(output.table.rows[0][columns.shootDay], "26-08-04");
  assert.equal(output.table.rows[0][columns.camera], "A");
  assert.deepEqual(output.addedColumns, ["Camera FPS", "Shoot Day", "Camera #"]);
  assert.equal(output.cameraFpsMatchedMaterialCount, 1);
  assert.equal(output.cameraFpsMatchedRowCount, 1);
  assert.equal(output.shootDayMatchedMaterialCount, 1);
  assert.equal(output.shootDayMatchedRowCount, 1);
  assert.equal(
    output.changes.some(
      (change) => change.field === "cameraFps" && change.next === "48",
    ),
    true,
  );
  assert.equal(
    output.changes.some(
      (change) => change.field === "shootDay" && change.next === "26-08-04",
    ),
    true,
  );
});

test("Shot Date can populate an existing Shoot Day without Sensor FPS", () => {
  const headers = [...ENGLISH_HEADERS, "Shoot Day"];
  const source = sourceTable(
    [["A001C001.mov", "/A", "A001C001", "", "", "", "", "", "25-12-31"]],
    { headers },
  );
  const metadata = [
    parseSlateMetadataText(
      "Clip Name: A001C001\nShot Date: 2026/08/01",
      "A001C001-slate.txt",
    ),
  ];
  const output = mergeSlateIntoResolveTable(
    source,
    [completeRecord()],
    metadata,
  );
  const columns = resolveColumnIndexes(output.table.headers);

  assert.equal(output.table.rows[0][columns.shootDay], "26-08-01");
  assert.equal(output.table.rows[0][columns.cameraFps], "");
  // The merge adds Camera FPS itself, but a recognized clip without a usable
  // Sensor FPS is reported as a warning — never as an empty fps row asking the
  // user to invent a frame rate.
  assert.deepEqual(output.addedColumns, ["Camera FPS", "Camera #"]);
  assert.equal(output.table.rows[0][resolveColumnIndexes(output.table.headers).camera], "A");
  assert.equal(output.shootDayMatchedMaterialCount, 1);
  assert.equal(output.cameraFpsMatchedMaterialCount, 0);
  assert.match(output.warnings.join("\n"), /Sensor FPS 缺失/);
  assert.match(output.warnings.join("\n"), /Camera FPS 保持原值/);
});

test("conflicting Shot Date preserves Shoot Day without suppressing Camera FPS", () => {
  const headers = [...ENGLISH_HEADERS, "Camera FPS", "Shoot Day"];
  const source = sourceTable(
    [["A001C001.mov", "/A", "A001C001", "", "", "", "", "", "24", "25-12-31"]],
    { headers },
  );
  const metadata = [
    {
      sourceName: "copy-1-slate.txt",
      materialKey: "A:1:1",
      sensorFps: "48",
      shootDay: "26-08-01",
    },
    {
      sourceName: "copy-2-slate.txt",
      materialKey: "A:1:1",
      sensorFps: "48",
      shootDay: "26-08-02",
    },
  ];
  const output = mergeSlateIntoResolveTable(
    source,
    [completeRecord()],
    metadata,
  );
  const columns = resolveColumnIndexes(output.table.headers);

  assert.equal(output.table.rows[0][columns.cameraFps], "48");
  assert.equal(output.table.rows[0][columns.shootDay], "25-12-31");
  assert.equal(output.cameraFpsMatchedMaterialCount, 1);
  assert.equal(output.shootDayMatchedMaterialCount, 0);
  assert.match(output.warnings.join("\n"), /冲突.*Shoot Day 不会写入/);
  assert.match(output.warnings.join("\n"), /Shoot Day 保持原值/);
});

test("missing or conflicting Sensor FPS preserves an existing Camera FPS", () => {
  const headers = [...ENGLISH_HEADERS, "Camera FPS"];
  const source = sourceTable(
    [["A001C001.mov", "/A", "A001C001", "", "", "", "", "", "24"]],
    { headers },
  );
  const conflicting = [
    {
      sourceName: "copy-1-slate.txt",
      materialKey: "A:1:1",
      sensorFps: "48",
    },
    {
      sourceName: "copy-2-slate.txt",
      materialKey: "A:1:1",
      sensorFps: "50",
    },
  ];
  const index = buildSlateMetadataIndex(conflicting);
  // Conflicting entries stay in the index (flagged) so the merge can append
  // them as reconciliation rows instead of dropping the frame rates.
  const conflictEntry = index.byMaterialKey.get("A:1:1");
  assert.equal(conflictEntry.sensorFps, "");
  assert.equal(conflictEntry.sensorFpsConflict, true);
  assert.deepEqual(conflictEntry.sensorFpsCandidates, ["48", "50"]);

  const output = mergeSlateIntoResolveTable(
    source,
    [completeRecord()],
    conflicting,
  );
  const columns = resolveColumnIndexes(output.table.headers);
  assert.equal(output.table.rows[0][columns.cameraFps], "24");
  assert.equal(output.cameraFpsMatchedMaterialCount, 0);
  assert.match(output.warnings.join("\n"), /冲突.*Camera FPS 不会写入素材行/);
});

test("Camera FPS is filled even when scene metadata is incomplete", () => {
  const source = sourceTable([
    ["A004C004.mov", "/A004", "A004C004", "", "", "", "", ""],
  ]);
  const slateMetadata = [
    parseSlateMetadataText(
      "Clip Name: A004C004\nSensor FPS: 48",
      "A004C004-slate.txt",
    ),
  ];
  const output = mergeSlateIntoResolveTable(
    source,
    [
      completeRecord({
        cardNumber: "A004",
        videoCode: "C004",
        scene: null,
      }),
    ],
    slateMetadata,
  );
  const columns = resolveColumnIndexes(output.table.headers);

  assert.equal(output.statuses[0].status, "incomplete");
  assert.equal(output.table.rows[0][columns.cameraFps], "48");
  assert.deepEqual(
    [columns.scene, columns.shot, columns.take, columns.comments].map(
      (columnIndex) => output.table.rows[0][columnIndex],
    ),
    ["", "", "", ""],
  );
  assert.equal(output.cameraFpsMatchedMaterialCount, 1);
  assert.equal(output.cameraFpsMatchedRowCount, 1);
  assert.equal(output.exportableCount, 1);
});

test("Camera FPS is filled even when duplicate slate records conflict", () => {
  const source = sourceTable([
    ["A004C004.mov", "/A004", "A004C004", "", "", "", "", ""],
  ]);
  const slateMetadata = [
    parseSlateMetadataText(
      "Clip Name: A004C004\nSensor FPS: 48",
      "A004C004-slate.txt",
    ),
  ];
  const output = mergeSlateIntoResolveTable(
    source,
    [
      completeRecord({ cardNumber: "A004", videoCode: "C004", take: "1" }),
      completeRecord({ cardNumber: "A004", videoCode: "C004", take: "2" }),
    ],
    slateMetadata,
  );
  const columns = resolveColumnIndexes(output.table.headers);

  assert.deepEqual(output.statuses.map((status) => status.status), [
    "conflict",
    "conflict",
  ]);
  assert.equal(output.table.rows[0][columns.cameraFps], "48");
  assert.deepEqual(
    [columns.scene, columns.shot, columns.take, columns.comments].map(
      (columnIndex) => output.table.rows[0][columnIndex],
    ),
    ["", "", "", ""],
  );
  assert.match(output.warnings.join("\n"), /Camera FPS 和 Shoot Day 仍会独立回填/);
});

test("CSV decoding and encoding preserve UTF-16LE BOM, LF and quoted cells", () => {
  const source = sourceTable([
    [
      "A001C001_suffix.mov",
      "/Volumes/A",
      "A001C001",
      "",
      "",
      "",
      "逗号, 引号\"和\r\n换行",
    ],
  ]);
  const encoded = encodeResolveCsv(source);
  assert.deepEqual([...encoded.subarray(0, 2)], [0xff, 0xfe]);

  const decoded = decodeResolveCsv(encoded);
  assert.deepEqual(decoded.headers, source.headers);
  assert.deepEqual(decoded.rows, source.rows);
  assert.deepEqual(decoded.format, source.format);

  const text = new TextDecoder("utf-16le").decode(encoded.subarray(2));
  assert.equal(text.endsWith("\n"), true);
  const headerLineEnd = text.indexOf("\n");
  assert.notEqual(text[headerLineEnd - 1], "\r");
});

test("UTF-8 and UTF-16BE CSV formats round-trip without changing their BOM choice", () => {
  const formats = [
    { encoding: "utf-8", bom: false, lineEnding: "\r\n", finalNewline: false },
    { encoding: "utf-8", bom: true, lineEnding: "\n", finalNewline: true },
    { encoding: "utf-16be", bom: true, lineEnding: "\r", finalNewline: true },
  ];

  for (const format of formats) {
    const source = sourceTable(
      [["E001C001.mov", "/Volumes/E", "E001C001", "", "", "", "测试"]],
      { format },
    );
    const decoded = decodeResolveCsv(encodeResolveCsv(source));
    assert.deepEqual(decoded.headers, source.headers);
    assert.deepEqual(decoded.rows, source.rows);
    assert.deepEqual(decoded.format, source.format);
  }
});

test("merge preserves every original column and row while canonicalizing target metadata", () => {
  const source = sourceTable([
    ["A001C015_suffix.mov", " /Volumes/A ", "A001C015", "old shot", "old scene", "old take", " keep spaces "],
    ["E001C001_suffix.mov", "/Volumes/E", "E001C001", "8", "88", "8", "untouched"],
  ]);
  const original = structuredClone(source);
  const output = mergeSlateIntoResolveTable(source, [
    completeRecord({ videoCode: "15", scene: "第37a场", shot: "2", take: "3" }),
  ]);

  assert.deepEqual(source, original, "source table must stay immutable");
  // Camera # is appended (derived from each clip's own name) while every
  // original column and cell keeps its position and content.
  assert.deepEqual(output.table.headers, [...source.headers, "Camera #"]);
  assert.equal(output.table.rows.length, 2);
  assert.deepEqual(output.table.rows[0].slice(0, source.headers.length), [
    "A001C015_suffix.mov",
    " /Volumes/A ",
    "A001C015",
    "02",
    "37A",
    "03",
    " keep spaces ",
    "",
  ]);
  assert.equal(output.table.rows[0][source.headers.length], "A");
  assert.deepEqual(output.table.rows[1].slice(0, source.headers.length), [
    "E001C001_suffix.mov",
    "/Volumes/E",
    "E001C001",
    "08",
    "088",
    "08",
    "untouched",
    "",
  ]);
  assert.equal(output.table.rows[1][source.headers.length], "E");
  assert.equal(output.matchedRecordCount, 1);
  assert.equal(output.updatedRowCount, 2);
  assert.equal(output.overwrittenCellCount, 6);
  assert.equal(output.statuses[0].status, "matched");
});

test("Resolve backfill preserves both scenes from a multi-scene slate value", () => {
  const source = sourceTable([
    ["A001C001.mov", "/A", "A001C001", "", "", "", ""],
  ]);
  const output = mergeSlateIntoResolveTable(source, [
    completeRecord({ scene: "58 / 59 场" }),
  ]);
  const columns = resolveColumnIndexes(output.table.headers);

  assert.equal(output.table.rows[0][columns.scene], "58 / 59");
});

test("metadata coverage audit exposes the exact 30 missing materials from the synthetic regression", () => {
  const truth = syntheticProductionDayGroundTruth();
  const omitted = new Set([
    ...materialRange("X101", 1, 15),
    ...materialRange("X102", 1, 5),
    ...materialRange("X102", 9, 15),
    ...materialRange("X102", 56, 58),
  ]);
  const table = sourceTable(
    truth.map((record) => [
      `${materialKey(record)}_proxy.mov`,
      "/Volumes/proxy",
      materialKey(record),
      "",
      "",
      "",
      "",
      "",
    ]),
  );
  const records = truth.filter((record) => !omitted.has(materialKey(record)));

  const output = mergeSlateIntoResolveTable(table, records);

  assert.equal(output.expectedMaterialCount, 159);
  assert.equal(output.recognizedMaterialCount, 129);
  assert.equal(output.unrecognizedMaterials.length, 30);
  assert.deepEqual(new Set(output.unrecognizedMaterials), omitted);
  assert.equal(output.unrecognizedRowIndexes.length, 30);
  assert.match(
    output.warnings.join("\n"),
    /30 个素材.*X101 C001–C015、X102 C001–C005、X102 C009–C015、X102 C056–C058/,
  );
});

test("D camera C009 matches Resolve filenames that use C0009", () => {
  const source = sourceTable([
    ["D001C0009_DEMO001.MOV", "/fixtures/media/D", "D001C0009", "", "", "", ""],
  ]);
  const output = mergeSlateIntoResolveTable(source, [
    completeRecord({ cardNumber: "D001", videoCode: "C009", scene: "42", shot: "3", take: "9" }),
  ]);

  assert.equal(output.statuses[0].status, "matched");
  assert.deepEqual(output.table.rows[0].slice(3, 6), ["03", "042", "09"]);
});

test("one slate record updates every Resolve row for the same reel and clip", () => {
  const source = sourceTable([
    ["E001C005_suffix.mov", "/Volumes/A", "E001C005", "", "", "", "copy A"],
    ["E001C005_suffix.mov", "/Volumes/B", "E001C005", "", "", "", "copy B"],
  ]);
  const output = mergeSlateIntoResolveTable(source, [
    completeRecord({ cardNumber: "E001", videoCode: "C005", scene: "37", shot: "1", take: "5" }),
  ]);

  assert.equal(output.updatedRowCount, 2);
  assert.equal(output.statuses[0].matchedRows, 2);
  assert.deepEqual(output.statuses[0].rowIndexes, [0, 1]);
  assert.deepEqual(output.table.rows.map((row) => row.slice(3, 6)), [
    ["01", "037", "05"],
    ["01", "037", "05"],
  ]);
  assert.deepEqual(output.table.rows.map((row) => row[6]), ["copy A", "copy B"]);
});

test("matched rows restrict Resolve Comments to _OK, _KP, or an empty value", () => {
  const source = sourceTable([
    ["A001C001_suffix.mov", "/Volumes/A", "A001C001", "", "", "", "note A", "OK"],
    ["E001C001_suffix.mov", "/Volumes/E", "E001C001", "", "", "", "note E", "原备注"],
    ["D001C0001_suffix.MOV", "/Volumes/D", "D001C0001", "", "", "", "note D", ""],
    ["A002C001_suffix.mov", "/Volumes/A", "A002C001", "", "", "", "note A2", "旧值"],
  ]);
  const output = mergeSlateIntoResolveTable(source, [
    completeRecord({ takeStatus: "保", comments: " 跑焦了 " }),
    completeRecord({ cardNumber: "E001", takeStatus: null, comments: "场记备注" }),
    completeRecord({ cardNumber: "D001", takeStatus: "过", comments: "同阿依莎走过" }),
    completeRecord({ cardNumber: "A002", takeStatus: "废条", comments: "任意文字" }),
  ]);
  const columns = resolveColumnIndexes(output.table.headers);

  assert.equal(output.table.rows[0][columns.comments], "_KP");
  assert.equal(output.table.rows[1][columns.comments], "");
  assert.equal(output.table.rows[2][columns.comments], "_OK");
  assert.equal(output.table.rows[3][columns.comments], "");
  assert.deepEqual(
    output.table.rows.map((row) => row[columns.comments]),
    ["_KP", "", "_OK", ""],
  );
  assert.equal(
    output.table.rows.every((row) =>
      ["", "_KP", "_OK"].includes(row[columns.comments]),
    ),
    true,
  );
  assert.match(output.warnings.join("\n"), /Comments“OK”→“_KP”/);
  assert.match(output.warnings.join("\n"), /Comments“原备注”→“”/);
  assert.match(output.warnings.join("\n"), /Comments“旧值”→“”/);
});

test("raw triangle exports _KP while raw X exports an empty Resolve Comment", () => {
  const source = sourceTable([
    ["A001C001.mov", "/fixtures/A", "A001C001", "", "", "", "", ""],
    ["A001C002.mov", "/fixtures/A", "A001C002", "", "", "", "", "old"],
  ]);
  const output = mergeSlateIntoResolveTable(source, [
    completeRecord({ videoCode: "C001", takeStatus: "△" }),
    completeRecord({ videoCode: "C002", takeStatus: "X" }),
  ]);
  const columns = resolveColumnIndexes(output.table.headers);

  assert.equal(output.table.rows[0][columns.comments], "_KP");
  assert.equal(output.table.rows[1][columns.comments], "");
});

test("different OCR remarks do not conflict when export metadata matches", () => {
  const source = sourceTable([
    ["A001C001_suffix.mov", "/Volumes/A", "A001C001", "", "", "", ""],
  ]);
  const output = mergeSlateIntoResolveTable(source, [
    completeRecord({ comments: "备注一" }),
    completeRecord({ comments: "备注二" }),
  ]);

  assert.deepEqual(output.statuses.map((status) => status.status), [
    "matched",
    "duplicate",
  ]);
  const columns = resolveColumnIndexes(output.table.headers);
  assert.equal(output.table.rows[0][columns.comments], "");
});

test("all exported Comments are globally canonicalized to the allowlist", () => {
  const source = sourceTable([
    ["A001C001.mov", "/A", "A001C001", "", "", "", "", "_OK"],
    ["A001C002.mov", "/A", "A001C002", "", "", "", "", "OK"],
    ["A001C003.mov", "/A", "A001C003", "", "", "", "", "KP"],
    ["A001C004.mov", "/A", "A001C004", "", "", "", "", "同阿依莎"],
    ["A001C005.mov", "/A", "A001C005", "", "", "", "", "_KP"],
  ]);
  const output = mergeSlateIntoResolveTable(source, []);
  const columns = resolveColumnIndexes(output.table.headers);

  assert.deepEqual(
    output.table.rows.map((row) => row[columns.comments]),
    ["_OK", "_OK", "_KP", "", "_KP"],
  );
  assert.equal(
    output.table.rows.every((row) =>
      ["", "_KP", "_OK"].includes(row[columns.comments]),
    ),
    true,
  );
});

test("strict Resolve CSV encoding canonicalizes manually edited Comments", () => {
  assert.equal(canonicalResolveComment(" ok "), "_OK");
  assert.equal(canonicalResolveComment("kp"), "_KP");
  assert.equal(canonicalResolveComment("invalid"), "");

  const source = sourceTable([
    ["A001C001.mov", "/A", "A001C001", "", "", "", "", "invalid"],
  ]);
  const encoded = encodeResolveCsv(source, { canonicalizeComments: true });
  const decoded = decodeResolveCsv(encoded);
  const columns = resolveColumnIndexes(decoded.headers);
  assert.equal(decoded.rows[0][columns.comments], "");
});

test("encoded CSV keeps zero-padded Scene, Shot and Take text", () => {
  const source = sourceTable([
    ["A001C001_suffix.mov", "/Volumes/A", "A001C001", "", "", "", ""],
  ]);
  const output = mergeSlateIntoResolveTable(source, [completeRecord()]);
  const encoded = encodeResolveCsv(output.table);
  const text = new TextDecoder("utf-16le").decode(encoded.subarray(2));

  assert.match(text, /A001C001_suffix\.mov,[^\n]*,01,037,02,/);
  const decoded = decodeResolveCsv(encoded);
  assert.deepEqual(decoded.rows[0].slice(3, 6), ["01", "037", "02"]);
});

test("all exported Scene, Shot and Take values obey scene-suffix or numeric-width rules", () => {
  const source = sourceTable([
    ["A001C001.mov", "/A", "A001C001", "1", "7", "9", ""],
    ["A001C002.mov", "/A", "A001C002", "镜 2", "第 37A 场", "8 次", ""],
    ["A001C003.mov", "/A", "A001C003", "100", "1000", "无", ""],
    ["A001C004.mov", "/A", "A001C004", "", "", "", ""],
  ]);
  const output = mergeSlateIntoResolveTable(source, []);
  const columns = resolveColumnIndexes(output.table.headers);

  assert.deepEqual(
    output.table.rows.map((row) => [
      row[columns.scene],
      row[columns.shot],
      row[columns.take],
    ]),
    [
      ["007", "01", "09"],
      ["37A", "02", "08"],
      ["1000", "100", ""],
      ["", "", ""],
    ],
  );
  assert.equal(
    output.table.rows.every((row) =>
      (!row[columns.scene] || /^(?:\d{3,}|\d{1,3}[A-Z]+)$/.test(row[columns.scene])) &&
      (!row[columns.shot] || /^\d{2,}$/.test(row[columns.shot])) &&
      (!row[columns.take] || /^\d{2,}$/.test(row[columns.take])),
    ),
    true,
  );
});

test("CSV encoder pads to the configured width and keeps wider numbers", () => {
  const source = sourceTable([
    ["A001C001.mov", "/A", "A001C001", "3", "4", "5", ""],
    ["A001C002.mov", "/A", "A001C002", "bad", "1000", "101", ""],
  ]);
  const decoded = decodeResolveCsv(encodeResolveCsv(source));

  assert.deepEqual(decoded.rows[0].slice(3, 6), ["03", "004", "05"]);
  assert.deepEqual(decoded.rows[1].slice(3, 6), ["", "1000", "101"]);
});

test("configured Comments markers flow through merge and export", () => {
  const comments = { goodTake: "OK!", holdTake: "HOLD" };
  const source = sourceTable([
    ["A001C001.mov", "/A", "A001C001", "1", "1", "1", "√", ""],
    ["A001C002.mov", "/A", "A001C002", "1", "1", "2", "△", ""],
    ["A001C003.mov", "/A", "A001C003", "", "", "", "", "_OK"],
    ["A001C004.mov", "/A", "A001C004", "", "", "", "", "kp"],
    ["A001C005.mov", "/A", "A001C005", "", "", "", "", "自由文本"],
  ]);
  const output = mergeSlateIntoResolveTable(
    source,
    [
      completeRecord({ videoCode: "C001", takeStatus: "过" }),
      completeRecord({ videoCode: "C002", takeStatus: "保" }),
    ],
    [],
    { comments },
  );
  const columns = resolveColumnIndexes(output.table.headers);
  const exported = output.table.rows.map((row) => row[columns.comments]);

  assert.deepEqual(exported, ["OK!", "HOLD", "OK!", "HOLD", ""]);
  assert.match(
    output.warnings.join("\n"),
    /Comments“_OK”已规范为“OK!”/,
  );

  const decoded = decodeResolveCsv(
    encodeResolveCsv(output.table, { comments, canonicalizeComments: true }),
  );
  assert.deepEqual(
    decoded.rows.map((row) => row[columns.comments]),
    ["OK!", "HOLD", "OK!", "HOLD", ""],
  );
});

test("standalone table builds Resolve rows from records without a metadata CSV", () => {
  const table = buildStandaloneResolveTable([
    {
      scene: "1",
      shot: "3",
      take: "2",
      comments: "_OK",
    },
    {
      scene: "7",
      shot: "4",
      take: "1",
      comments: "",
    },
    {
      scene: "2",
      shot: "bad",
      take: "9",
      comments: "_KP",
    },
    {
      scene: "3",
      shot: "1",
      take: null,
      comments: "_OK",
    },
  ]);

  assert.deepEqual(table.headers, ["Scene", "Shot", "Take", "Comments"]);
  assert.deepEqual(table.rows, [
    ["001", "03", "02", "_OK"],
    ["007", "04", "01", ""],
  ]);
});

test("standalone table honours custom field formats and encodes cleanly", () => {
  const table = buildStandaloneResolveTable(
    [{ scene: "12", shot: "4", take: "2", comments: "备注,含逗号" }],
    { fieldFormats: { scene: "XXXX", shot: "XX", take: "XX" } },
  );
  assert.deepEqual(table.rows, [["0012", "04", "02", "备注,含逗号"]]);

  const encoded = encodeResolveCsv(table, {
    fieldFormats: { scene: "XXXX", shot: "XX", take: "XX" },
  });
  const text = new TextDecoder("utf-16le").decode(encoded.subarray(2));
  assert.match(text, /Scene,Shot,Take,Comments/);
  assert.match(text, /0012,04,02,"备注,含逗号"/);
});

test("consistent duplicate OCR rows merge once while conflicting rows write nothing", () => {
  const source = sourceTable([
    ["A001C001_suffix.mov", "/Volumes/A", "A001C001", "", "", "", ""],
  ]);
  const consistent = mergeSlateIntoResolveTable(source, [
    completeRecord(),
    completeRecord(),
  ]);
  assert.deepEqual(consistent.statuses.map((status) => status.status), [
    "matched",
    "duplicate",
  ]);
  assert.deepEqual(consistent.table.rows[0].slice(3, 6), ["01", "037", "02"]);

  const conflicting = mergeSlateIntoResolveTable(source, [
    completeRecord({ take: "1" }),
    completeRecord({ take: "2" }),
  ]);
  assert.deepEqual(conflicting.statuses.map((status) => status.status), [
    "conflict",
    "conflict",
  ]);
  // Conflicting OCR fields are not written; only the intrinsic Camera #
  // backfill touches the row, and it is not counted as exportable work.
  assert.deepEqual(conflicting.table.rows[0].slice(0, source.rows[0].length), source.rows[0]);
  assert.equal(conflicting.table.rows[0][source.rows[0].length], "A");
  assert.equal(conflicting.exportableCount, 0);
});

test("a row with conflicting Reel Name and File Name is skipped", () => {
  const source = sourceTable([
    ["A001C001_suffix.mov", "/Volumes/A", "D001C001", "", "", "", ""],
  ]);
  const output = mergeSlateIntoResolveTable(source, [completeRecord()]);

  assert.equal(output.statuses[0].status, "unmatched");
  // The row is skipped for writes (identity is ambiguous) — Camera # stays empty.
  assert.deepEqual(output.table.rows[0].slice(0, source.rows[0].length), source.rows[0]);
  assert.equal(output.table.rows[0][source.rows[0].length], "");
  assert.match(output.warnings.join("\n"), /卷名与文件名指向不同素材/);
});

test("Chinese Resolve headers are supported regardless of column order", () => {
  const headers = ["备注", "鏡頭", "文件名", "場景", "卷名", "鏡次"];
  const source = sourceTable(
    [["保留", "", "A001C001_suffix.mov", "", "A001C001", ""]],
    { headers },
  );
  const output = mergeSlateIntoResolveTable(source, [completeRecord()]);
  const columns = resolveColumnIndexes(output.table.headers);

  assert.equal(output.table.rows[0][columns.scene], "037");
  assert.equal(output.table.rows[0][columns.shot], "01");
  assert.equal(output.table.rows[0][columns.take], "02");
  assert.equal(output.table.rows[0][0], "");
});

test("separate Reel Name and Clip Name are checked against a combined File Name", () => {
  const headers = ["File Name", "Reel Name", "Clip Name", "Shot", "Scene", "Take"];
  const source = sourceTable(
    [
      ["proxy.mov", "D001", "C001", "", "", ""],
      ["A001C001_proxy.mov", "D001", "C001", "", "", ""],
    ],
    { headers },
  );
  const output = mergeSlateIntoResolveTable(source, [
    completeRecord({ cardNumber: "D001" }),
  ]);

  assert.deepEqual(output.table.rows[0].slice(3, 6), ["01", "037", "02"]);
  assert.deepEqual(output.table.rows[1].slice(3, 6), ["", "", ""]);
  assert.equal(output.updatedRowCount, 1);
  assert.match(output.warnings.join("\n"), /卷名与文件名指向不同素材/);
});

test("missing target fields are appended with canonical Resolve headers", () => {
  const source = sourceTable(
    [["A001C001_suffix.mov", "A001C001", "keep"]],
    { headers: ["File Name", "Reel Name", "Notes"] },
  );
  const output = mergeSlateIntoResolveTable(source, [completeRecord()]);

  assert.deepEqual(output.table.headers, [
    "File Name",
    "Reel Name",
    "Notes",
    "Shot",
    "Scene",
    "Take",
    "Comments",
    "Camera #",
  ]);
  assert.deepEqual(output.table.rows[0], [
    "A001C001_suffix.mov",
    "A001C001",
    "keep",
    "01",
    "037",
    "02",
    "",
    "A",
  ]);
  assert.deepEqual(output.addedColumns, [
    "Shot",
    "Scene",
    "Take",
    "Comments",
    "Camera #",
  ]);
});

test("invalid, incomplete and unmatched slate rows do not create CSV rows", () => {
  const source = sourceTable([
    ["A001C001_suffix.mov", "/Volumes/A", "A001C001", "", "", "", ""],
  ]);
  const output = mergeSlateIntoResolveTable(source, [
    completeRecord({ videoCode: "C115" }),
    completeRecord({ scene: null }),
    completeRecord({ cardNumber: "E001", videoCode: "C001" }),
  ]);

  assert.deepEqual(output.statuses.map((status) => status.status), [
    "missing-key",
    "incomplete",
    "unmatched",
  ]);
  // No CSV rows are created and no OCR/Scene fields are written; only the
  // intrinsic Camera # (from the clip's own name) is backfilled, and it is not
  // counted as exportable work.
  assert.equal(output.table.rows.length, source.rows.length);
  assert.deepEqual(output.table.rows[0].slice(0, source.rows[0].length), source.rows[0]);
  assert.equal(output.table.rows[0][source.rows[0].length], "A");
  assert.equal(output.exportableCount, 0);
});

test("CSV parser rejects unclosed quotes and supports an explicit delimiter", () => {
  assert.throws(() => parseCsvText('File Name,Scene\n"broken,37'), /未闭合/);
  assert.deepEqual(parseCsvText("File Name;Scene\nA001C001.mov;37", ";"), [
    ["File Name", "Scene"],
    ["A001C001.mov", "37"],
  ]);
});

test("a recognized clip with no sidecar fps warns instead of appending an empty fps row", () => {
  const source = sourceTable([
    ["A001C001.mov", "/A", "A001C001", "", "", "", "", ""],
    ["A001C002.mov", "/A", "A001C002", "", "", "", "", ""],
  ]);
  const metadata = [
    parseSlateMetadataText(
      "Clip Name: A001C001\nSensor FPS: 48",
      "A001C001-slate.txt",
    ),
  ];
  const records = [
    completeRecord(),
    completeRecord({ videoCode: "C002" }),
  ];
  const output = mergeSlateIntoResolveTable(source, records, metadata);
  const columns = resolveColumnIndexes(output.table.headers);

  // A real clip always carries a frame rate; C002 being recognized but lacking
  // a usable Sensor FPS is a scan/card anomaly to warn about — never a blank
  // fps row for the user to hand-confirm.
  assert.ok(output.addedColumns.includes("Camera FPS"));
  assert.ok(!output.addedColumns.includes("FPS 对账"));
  assert.equal(output.table.rows.length, 2);
  assert.equal(output.table.rows[1][columns.cameraFps], "");
  assert.match(output.warnings.join("\n"), /没有可用 Sensor FPS/);
  assert.match(output.warnings.join("\n"), /A001 C002/);
  assert.doesNotMatch(output.warnings.join("\n"), /未找到 slate\.txt，帧率待人工确认/);
});

test("frame rate backfills to a CSV material even when it has no 场记 record", () => {
  const source = sourceTable([
    ["A001C001.mov", "/A", "A001C001", "", "", "", "", ""],
    ["A001C002.mov", "/A", "A001C002", "", "", "", "", ""],
  ]);
  // The sidecar for C002 is on the card, but recognition only produced a
  // record for C001 — C002's frame rate must still be backfilled.
  const metadata = [
    parseSlateMetadataText(
      "Clip Name: A001C002\nSensor FPS: 50",
      "A001C002-slate.txt",
    ),
  ];
  const output = mergeSlateIntoResolveTable(source, [completeRecord()], metadata);
  const columns = resolveColumnIndexes(output.table.headers);

  assert.equal(output.table.rows[1][columns.cameraFps], "50");
  assert.equal(output.table.rows[0][columns.cameraFps], "");
  assert.equal(output.cameraFpsMatchedMaterialCount, 1);
  assert.match(output.warnings.join("\n"), /未匹配到场记/);
});

test("Camera # backfills the leading camera letter from each clip name", () => {
  const source = sourceTable([
    ["A004C004_20260801_RA259.mov", "/Volumes/A", "A004C004_20260801_RA259", "", "", "", ""],
    ["B002C003.mov", "/Volumes/B", "B002C003", "", "", "", ""],
    ["D001C0009_DEMO.MOV", "/fixtures/media/D", "D001C0009", "", "", "", ""],
  ]);
  const output = mergeSlateIntoResolveTable(source, [
    completeRecord({ cardNumber: "A004", videoCode: "C004" }),
  ]);
  const columns = resolveColumnIndexes(output.table.headers);

  assert.equal(output.table.headers[columns.camera], "Camera #");
  assert.equal(output.table.rows[0][columns.camera], "A");
  assert.equal(output.table.rows[1][columns.camera], "B");
  assert.equal(output.table.rows[2][columns.camera], "D");
});

test("Camera # never overwrites an existing value", () => {
  const headers = [...ENGLISH_HEADERS, "Camera #"];
  const source = sourceTable(
    [["A001C001.mov", "/A", "A001C001", "", "", "", "", "", "自定"]],
    { headers },
  );
  const output = mergeSlateIntoResolveTable(source, [completeRecord()]);
  const columns = resolveColumnIndexes(output.table.headers);

  assert.equal(output.table.rows[0][columns.camera], "自定");
  assert.equal(output.addedColumns.length, 0);
});

test("Camera # writes only the canonical Resolve header and tolerates duplicate headers", () => {
  // A localized "摄影机编号" column is not Resolve's header — it is ignored and
  // never written.
  const headers = [...ENGLISH_HEADERS, "Camera #", "摄影机编号"];
  const source = sourceTable(
    [["A001C001.mov", "/A", "A001C001", "", "", "", "", "", "", ""]],
    { headers },
  );
  const columns = resolveColumnIndexes(source.headers);
  assert.equal(columns.camera, 8);

  const output = mergeSlateIntoResolveTable(source, [completeRecord()]);
  assert.equal(output.table.rows[0][columns.camera], "A");
  assert.equal(output.table.rows[0][columns.camera + 1], "");

  // Two canonical "Camera #" columns do not fail the load; the first receives
  // the backfill and the file still opens for the user to clean up.
  const dup = sourceTable(
    [["A001C001.mov", "/A", "A001C001", "", "", "", "", "", "", ""]],
    { headers: [...ENGLISH_HEADERS, "Camera #", "Camera #"] },
  );
  const dupCols = resolveColumnIndexes(dup.headers);
  assert.equal(dupCols.camera, 8);
  const dupOut = mergeSlateIntoResolveTable(dup, [completeRecord()]);
  assert.equal(dupOut.table.rows[0][dupCols.camera], "A");
  assert.equal(dupOut.table.rows[0][dupCols.camera + 1], "");

  // Other writable targets still reject duplicate headers.
  assert.throws(
    () => resolveColumnIndexes(["Scene", "File Name", "Scene"]),
    /多个 Scene/,
  );
});

function materialRange(cardNumber, start, end) {
  return new Set(
    Array.from(
      { length: end - start + 1 },
      (_, index) => `${cardNumber}C${String(start + index).padStart(3, "0")}`,
    ),
  );
}

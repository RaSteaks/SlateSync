import test from "node:test";
import assert from "node:assert/strict";
import {
  canonicalMaterialKey,
  buildSlateMetadataIndex,
  decodeResolveCsv,
  encodeResolveCsv,
  materialPrefix,
  mergeSlateIntoResolveTable,
  normalizeClipNumber,
  normalizeCameraFps,
  normalizeShootDay,
  normalizeSceneValue,
  normalizeShotValue,
  normalizeTakeValue,
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

test("scene, shot and take keep numeric content and use fixed-width zero padding", () => {
  assert.equal(normalizeSceneValue("第 37A 场"), "037");
  assert.equal(normalizeSceneValue("1"), "001");
  assert.equal(normalizeShotValue("镜 2"), "02");
  assert.equal(normalizeTakeValue("9 次"), "09");
  assert.equal(normalizeSceneValue("1000"), "");
  assert.equal(normalizeShotValue("100"), "");
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
  assert.deepEqual(output.addedColumns, ["Camera FPS", "Shoot Day"]);
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
  assert.deepEqual(output.addedColumns, ["Camera FPS"]);
  assert.equal(output.shootDayMatchedMaterialCount, 1);
  assert.equal(output.cameraFpsMatchedMaterialCount, 0);
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
  assert.equal(index.byMaterialKey.has("A:1:1"), false);

  const output = mergeSlateIntoResolveTable(
    source,
    [completeRecord()],
    conflicting,
  );
  const columns = resolveColumnIndexes(output.table.headers);
  assert.equal(output.table.rows[0][columns.cameraFps], "24");
  assert.equal(output.cameraFpsMatchedMaterialCount, 0);
  assert.match(output.warnings.join("\n"), /冲突.*Camera FPS 不会写入/);
  assert.match(output.warnings.join("\n"), /Camera FPS 保持原值/);
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
  assert.deepEqual(output.table.headers, source.headers);
  assert.equal(output.table.rows.length, 2);
  assert.deepEqual(output.table.rows[0], [
    "A001C015_suffix.mov",
    " /Volumes/A ",
    "A001C015",
    "02",
    "037",
    "03",
    " keep spaces ",
    "",
  ]);
  assert.deepEqual(output.table.rows[1], [
    "E001C001_suffix.mov",
    "/Volumes/E",
    "E001C001",
    "08",
    "088",
    "08",
    "untouched",
    "",
  ]);
  assert.equal(output.matchedRecordCount, 1);
  assert.equal(output.updatedRowCount, 2);
  assert.equal(output.overwrittenCellCount, 6);
  assert.equal(output.statuses[0].status, "matched");
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
    /完整性对账.*30 个素材.*X101 C001–C015、X102 C001–C005、X102 C009–C015、X102 C056–C058/,
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

test("all exported Scene, Shot and Take values obey XXX/XX/XX", () => {
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
      ["037", "02", "08"],
      ["", "", ""],
      ["", "", ""],
    ],
  );
  assert.equal(
    output.table.rows.every((row) =>
      (!row[columns.scene] || /^\d{3}$/.test(row[columns.scene])) &&
      (!row[columns.shot] || /^\d{2}$/.test(row[columns.shot])) &&
      (!row[columns.take] || /^\d{2}$/.test(row[columns.take])),
    ),
    true,
  );
});

test("CSV encoder enforces fixed widths even when merge is bypassed", () => {
  const source = sourceTable([
    ["A001C001.mov", "/A", "A001C001", "3", "4", "5", ""],
    ["A001C002.mov", "/A", "A001C002", "bad", "1000", "101", ""],
  ]);
  const decoded = decodeResolveCsv(encodeResolveCsv(source));

  assert.deepEqual(decoded.rows[0].slice(3, 6), ["03", "004", "05"]);
  assert.deepEqual(decoded.rows[1].slice(3, 6), ["", "", ""]);
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
  assert.deepEqual(conflicting.table.rows, source.rows);
  assert.equal(conflicting.exportableCount, 0);
});

test("a row with conflicting Reel Name and File Name is skipped", () => {
  const source = sourceTable([
    ["A001C001_suffix.mov", "/Volumes/A", "D001C001", "", "", "", ""],
  ]);
  const output = mergeSlateIntoResolveTable(source, [completeRecord()]);

  assert.equal(output.statuses[0].status, "unmatched");
  assert.deepEqual(output.table.rows, source.rows);
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
  ]);
  assert.deepEqual(output.table.rows[0], [
    "A001C001_suffix.mov",
    "A001C001",
    "keep",
    "01",
    "037",
    "02",
    "",
  ]);
  assert.deepEqual(output.addedColumns, ["Shot", "Scene", "Take", "Comments"]);
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
  assert.deepEqual(output.table.rows, source.rows);
  assert.equal(output.exportableCount, 0);
});

test("CSV parser rejects unclosed quotes and supports an explicit delimiter", () => {
  assert.throws(() => parseCsvText('File Name,Scene\n"broken,37'), /未闭合/);
  assert.deepEqual(parseCsvText("File Name;Scene\nA001C001.mov;37", ";"), [
    ["File Name", "Scene"],
    ["A001C001.mov", "37"],
  ]);
});

function materialRange(cardNumber, start, end) {
  return new Set(
    Array.from(
      { length: end - start + 1 },
      (_, index) => `${cardNumber}C${String(start + index).padStart(3, "0")}`,
    ),
  );
}

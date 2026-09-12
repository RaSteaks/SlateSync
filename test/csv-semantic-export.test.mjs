import assert from "node:assert/strict";
import test from "node:test";
import { buildSemanticExportTable, decodeResolveCsv, encodeResolveCsv, normalizeSemanticColumns, parseCsvText } from "../public/resolve-csv.js";
import { createCsvTaskProcessor } from "../public/csv-background-tasks.js";
import { serializeCsvPreviewState, restoreCsvPreviewState } from "../public/task-persistence.js";

const records = [{ cardNumber: "A001", videoCode: "C001", scene: "1", shot: "2", take: "3", takeStatus: "过", sourcePage: 2 }];
const source = () => decodeResolveCsv(new TextEncoder().encode("File Name,Scene,Shot,Take,Comments,Extra\nA001C001.mov,,,,,保留\n"));
const allColumns = normalizeSemanticColumns().map((column) => ({ ...column, enabled: true }));
const frozen = (value) => {
  if (value && typeof value === "object") { Object.values(value).forEach(frozen); Object.freeze(value); }
  return value;
};

// Literal encoded bytes provide independent GBK/GB18030 evidence (中文 / U+10000).
for (const [encoding, suffix, expected] of [["gbk", [0xd6, 0xd0, 0xce, 0xc4], "中文"], ["gb18030", [0x90, 0x30, 0x81, 0x30], "𐀀"]]) {
  test(`${encoding} source converts to every Unicode output without losing source facts`, () => {
    const bytes = new Uint8Array([...new TextEncoder().encode("File Name,Extra\nA001C001.mov,"), ...suffix, 10]);
    const table = decodeResolveCsv(bytes);
    assert.equal(table.sourceEncoding, encoding);
    assert.equal(table.format.encoding, "utf-8");
    assert.equal(table.rows[0][1], expected);
    for (const outputEncoding of ["utf-8", "utf-16le", "utf-16be"]) for (const bom of [false, true]) {
      const built = buildSemanticExportTable({ mode: "resolve", sourceTable: table, records, options: { format: { encoding: outputEncoding, bom } } });
      const decoded = decodeResolveCsv(encodeResolveCsv(built.table));
      assert.equal(decoded.rows[0][1], expected);
      assert.equal(built.table.sourceEncoding, encoding);
      assert.equal(decoded.sourceEncoding, outputEncoding);
    }
    assert.equal(decodeResolveCsv(bytes, { sourceEncoding: encoding }).sourceEncodingDetection, "explicit");
  });
}

test("fatal source errors and output errors have distinct stable codes", () => {
  for (const bytes of [[0xff], [0xef, 0xbb, 0xbf, 0xc3], [0xff, 0xfe, 0x41], [0x81], [0x81, 0x30, 0x81]]) {
    assert.throws(() => decodeResolveCsv(new Uint8Array(bytes)), { code: "CSV_SOURCE_DECODE", name: "CsvSourceDecodeError" });
  }
  for (const format of [{ encoding: "gbk" }, { delimiter: "\n" }, { bom: "yes" }]) {
    assert.throws(() => encodeResolveCsv({ ...source(), format }), { code: "CSV_OUTPUT_ENCODE" });
  }
  assert.throws(() => encodeResolveCsv({ headers: ["Extra"], rows: [["\ud800"]] }), { code: "CSV_OUTPUT_ENCODE" });
});

test("semantic standalone supports default, eight, optional-only and empty records deterministically", () => {
  const input = frozen({ records, options: { columns: allColumns } });
  const built = buildSemanticExportTable(input);
  assert.deepEqual(built, buildSemanticExportTable(input));
  assert.deepEqual(built.table.rows, [["001", "02", "03", "_OK", "过", "A001", "C001", "2"]]);
  assert.equal(buildSemanticExportTable({ records }).table.headers.length, 4);
  assert.deepEqual(buildSemanticExportTable({ records, options: { columns: [{ key: "sourcePage", header: "页", enabled: true }] } }).table.rows, [["2"]]);
  assert.deepEqual(buildSemanticExportTable({ records: [] }).table.rows, []);
  const normalized = normalizeSemanticColumns([{ key: "scene", header: "\n", enabled: true }, { key: "scene", header: "ignored" }, { key: "unknown", enabled: true }, { key: "shot", header: "\u0001", enabled: true }]);
  assert.equal(normalized[0].header, "Scene");
  assert.equal(normalized[1].header, "Shot");
  assert.equal(normalized.filter((column) => column.enabled).length, 2);
});

test("duplicate custom headers survive JSON task restoration by key/index", () => {
  const columns = allColumns.map((column) => ({ ...column, header: "同名" }));
  const built = buildSemanticExportTable({ mode: "resolve", sourceTable: source(), records, options: { columns } });
  const snapshot = serializeCsvPreviewState({ metadataTable: built.table, csvEdits: new Map() });
  const restored = restoreCsvPreviewState(JSON.parse(JSON.stringify(snapshot))).metadataTable;
  const rebuilt = buildSemanticExportTable({ mode: "resolve", sourceTable: frozen(restored), records, options: { columns } });
  assert.deepEqual(rebuilt.table, built.table);
  assert.deepEqual(rebuilt.changes, []);
  assert.deepEqual(rebuilt.warnings, []);
  assert.deepEqual(encodeResolveCsv(rebuilt.table), encodeResolveCsv(built.table));
});

test("preview, direct builder, final export and fallback share edits and format", () => {
  const table = frozen(source());
  const task = frozen({ records, csvEdits: [["0:1", "9"], ["0:2", ""], ["0:4", "unsafe"], ["0:5", "edited"], ["999:0", "bad"], ["0:99", "bad"], ["bad", "bad"], ["-1:0", "bad"]], exportOptions: { columns: allColumns, format: { encoding: "utf-16be", bom: false, delimiter: ";", lineEnding: "\r", finalNewline: false } }, resolvedFilename: "resolved.csv" });
  const processor = createCsvTaskProcessor();
  processor({ type: "prime-metadata", table });
  const preview = processor({ ...task, type: "merge-preview" });
  const direct = buildSemanticExportTable({ ...task, mode: "resolve", sourceTable: table });
  const output = processor({ ...task, type: "export-resolve" });
  assert.deepEqual(preview.table, direct.table);
  assert.deepEqual(output.bytes, encodeResolveCsv(preview.table));
  assert.equal(output.resolvedFilename, "resolved.csv");
  assert.deepEqual(preview.table.rows[0].slice(1, 6), ["009", "", "03", "", "edited"]);
  assert.equal(table.rows[0][5], "保留");
  const fallback = createCsvTaskProcessor();
  fallback({ type: "prime-metadata", table });
  assert.deepEqual(fallback({ ...task, type: "export-resolve" }), output);
  const standalone = processor({ ...task, type: "standalone-preview" });
  assert.deepEqual(processor({ ...task, type: "export-standalone" }).bytes, encodeResolveCsv(standalone.table));
  assert.deepEqual(parseCsvText(new TextDecoder("utf-16be").decode(output.bytes), ";"), [preview.table.headers, ...preview.table.rows]);
});

test("failed decode/export retains the worker source and caller snapshot", () => {
  const processor = createCsvTaskProcessor();
  const table = frozen(source());
  processor({ type: "prime-metadata", table });
  const before = processor({ type: "merge-preview", records });
  assert.throws(() => processor({ type: "decode-metadata", data: new Uint8Array([0xff]) }), { code: "CSV_SOURCE_DECODE" });
  assert.throws(() => processor({ type: "export-resolve", records, outputFormat: { encoding: "gb18030" } }), { code: "CSV_OUTPUT_ENCODE" });
  assert.deepEqual(processor({ type: "merge-preview", records }), before);
});

test("disabled optional columns never append and existing source columns survive", () => {
  const table = { headers: ["File Name", "Camera #", "Camera #", "Extra"], rows: [["A001C001.mov", "", "untouched", "keep"]], format: { encoding: "utf-8" } };
  const built = buildSemanticExportTable({ mode: "resolve", sourceTable: frozen(table), records, options: { columns: [{ key: "sourcePage", header: "页码", enabled: true }] } });
  assert.deepEqual(built.table.headers, ["File Name", "Camera #", "Camera #", "Extra", "页码"]);
  assert.deepEqual(built.table.rows, [["A001C001.mov", "A", "untouched", "keep", "2"]]);
});

test("existing optional fields retain their positions and disabled missing fields have no phantom changes", () => {
  const table = { headers: ["File Name", "Take Status", "Card Number"], rows: [["A001C001.mov", "", ""]], format: { encoding: "utf-8" } };
  const output = buildSemanticExportTable({ mode: "resolve", sourceTable: table, records, options: { columns: [{ key: "takeStatus", header: "条次", enabled: true }] } });
  assert.deepEqual(output.table.headers, ["File Name", "条次", "Card Number", "Camera #"]);
  assert.deepEqual(output.table.rows, [["A001C001.mov", "过", "", "A"]]);
  assert.ok(output.changes.every((change) => typeof change.header === "string"));
});

test("public module Worker preserves error codes, request ids and source after failure", async () => {
  const previousSelf = globalThis.self;
  let receive;
  const replies = [];
  globalThis.self = { addEventListener(_type, listener) { receive = listener; }, postMessage(message) { replies.push(message); } };
  try {
    await import(`../public/csv-worker.js?semantic=${Date.now()}`);
    receive({ data: { id: 1, task: { type: "prime-metadata", table: source() } } });
    receive({ data: { id: 2, version: 1, task: { type: "export-resolve", records, outputFormat: { encoding: "gbk" } } } });
    assert.equal(replies[1].id, 2);
    assert.equal(replies[1].errorCode, "CSV_OUTPUT_ENCODE");
    assert.equal(replies[1].errorName, "CsvOutputEncodeError");
    receive({ data: { id: 3, version: 1, task: { type: "export-resolve", records } } });
    assert.ok(replies[2].result.bytes instanceof ArrayBuffer);
    assert.deepEqual(new Uint8Array(replies[2].result.bytes), encodeResolveCsv(buildSemanticExportTable({ mode: "resolve", sourceTable: source(), records }).table));
  } finally {
    if (previousSelf === undefined) delete globalThis.self;
    else globalThis.self = previousSelf;
  }
});

// Empty/all-disabled selections must produce usable files, not successful
// exports consisting solely of newlines. Check the actual Worker byte path.
for (const [name, columns, headers, row] of [
  ["empty", [], ["Scene", "Shot", "Take", "Comments"], ["001", "02", "03", "_OK"]],
  ["unknown-only", [{ key: "unknown", enabled: true }], ["Scene", "Shot", "Take", "Comments"], ["001", "02", "03", "_OK"]],
  ["all-disabled", [{ key: "sourcePage", header: "页码", enabled: false }, { key: "scene", header: "场次", enabled: false }], ["页码"], ["2"]],
]) {
  test(`${name} columns fall back to a nonempty standalone export`, () => {
    const input = frozen({ records, exportOptions: { columns } });
    const processor = createCsvTaskProcessor();
    const preview = processor({ ...input, type: "standalone-preview" }).table;
    const { bytes } = processor({ ...input, type: "export-standalone" });
    assert.deepEqual(preview.headers, headers);
    assert.deepEqual(preview.rows, [row]);
    assert.deepEqual(parseCsvText(new TextDecoder("utf-16le").decode(bytes)), [headers, row]);
    assert.deepEqual(bytes, encodeResolveCsv(preview));
    assert.deepEqual(buildSemanticExportTable(input).table, preview);
  });
}

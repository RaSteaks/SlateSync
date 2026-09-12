import assert from "node:assert/strict";
import test from "node:test";
import { createResolveExportOptions, RESOLVE_TEMPLATE_ID, remapTemplateEdits } from "../public/resolve-export-template.js";
import { normalizeExportOptions } from "../public/export-options.js";
import { normalizeProjectSettings } from "../lib/project-settings.mjs";
import { createCsvTaskProcessor } from "../public/csv-background-tasks.js";
import { decodeResolveCsv } from "../public/resolve-csv.js";

// Synthetic interoperability cases validate our serializer; these are not
// presented as files exported by Resolve or as a substitute for application QA.
const required = ["File Name", "Start TC", "End TC", "Reel Name", "Clip Directory"];
const record = { cardNumber: "A001", videoCode: "C001", scene: "12A", shot: "B", take: "003", comments: '对白正常，保留\n"第二句"', description: "街口外景" };
const inventory = () => ({
  headers: ["Extra", "Clip Directory", "File Name", "End TC", "Start TC", "Reel Name", "Comments", "Keywords"],
  rows: [["未选择", "D:\\素材\\A001", "A001C001.mov", "10:00:15;23", "10:00:00;00", "A001", "旧备注", "夜景,外景"],
    ["保留源", "/Volumes/素材/B", "B001C002.mov", "11:00:12:04", "11:00:00:01", "B001", "未匹配的自由备注", ""]],
  format: { encoding: "utf-16le", bom: true, delimiter: ",", lineEnding: "\r\n", finalNewline: true },
});

test("built-in normalization locks the five identity columns and headers across Main/browser", () => {
  const options = createResolveExportOptions();
  assert.deepEqual(options.columns.filter((column) => column.enabled).slice(0, 5).map((column) => column.header), required);
  options.columns = [{ key: "description", header: "乱改名", enabled: true }, { key: "fileName", header: "名称", enabled: false }];
  options.format.delimiter = ";";
  for (const normalized of [normalizeExportOptions(options), normalizeProjectSettings({ export: options }).export]) {
    assert.equal(normalized.templateId, RESOLVE_TEMPLATE_ID);
    assert.equal(normalized.format.delimiter, ",");
    assert.equal(normalized.columns[0].header, "Description");
    for (const header of required) assert.ok(normalized.columns.some((column) => column.header === header && column.enabled));
    assert.deepEqual(normalizeExportOptions(normalized), normalized);
  }
});

test("template projects selected fields, preserves identity and free text, and never mutates inventory", () => {
  const worker = createCsvTaskProcessor();
  const source = inventory();
  const before = structuredClone(source);
  worker({ type: "prime-metadata", table: source });
  const options = createResolveExportOptions();
  options.columns = options.columns.map((field) => ({ ...field, enabled: field.enabled || ["description", "keywords"].includes(field.key) }));
  const task = { type: "merge-preview", records: [record], exportOptions: options };
  const preview = worker(task);
  assert.equal(preview.matchedRecordCount, 1);
  assert.deepEqual(preview.table.rows[0].slice(0, 5), ["A001C001.mov", "10:00:00;00", "10:00:15;23", "A001", "D:\\素材\\A001"]);
  assert.deepEqual(preview.table.rows[0].slice(5), ["12A", "B", "003", record.comments, record.description, "夜景,外景"]);
  assert.ok(!preview.table.headers.includes("Extra"));
  assert.ok(!preview.table.headers.includes("Camera #"));
  assert.equal(preview.table.rows[1][8], "未匹配的自由备注");
  const result = worker({ ...task, type: "export-resolve" });
  const decoded = decodeResolveCsv(result.bytes);
  assert.deepEqual(decoded.headers, preview.table.headers);
  assert.deepEqual(decoded.rows, preview.table.rows);
  assert.deepEqual(source, before);
});

test("template projection honors the decoder's localized source aliases", () => {
  const worker = createCsvTaskProcessor();
  // The source uses aliases already accepted by decodeResolveCsv, not the
  // canonical headers emitted by the built-in template.
  const source = {
    headers: ["Filename", "Start TC", "End TC", "Reel", "片段目录"],
    rows: [["A001C001.mov", "10:00:00;00", "10:00:15;23", "A001", "/Volumes/素材/A001"]],
    format: { encoding: "utf-8", bom: false, delimiter: ",", lineEnding: "\n", finalNewline: true },
  };
  worker({ type: "prime-metadata", table: source });
  const preview = worker({
    type: "merge-preview",
    records: [record],
    exportOptions: createResolveExportOptions(),
  });
  assert.deepEqual(preview.table.rows[0].slice(0, 5), [
    "A001C001.mov", "10:00:00;00", "10:00:15;23", "A001", "/Volumes/素材/A001",
  ]);
  assert.deepEqual(preview.table.exportWarnings, []);
});

test("template statuses preserve recognition order when material groups interleave", () => {
  const worker = createCsvTaskProcessor();
  const source = inventory();
  worker({ type: "prime-metadata", table: source });
  const otherRecord = {
    ...record,
    cardNumber: "B001",
    videoCode: "C002",
    scene: "24",
    shot: "C",
    take: "001",
  };
  const output = worker({
    type: "merge-preview",
    records: [record, otherRecord, { ...record }],
    exportOptions: createResolveExportOptions(),
  });
  assert.deepEqual(output.statuses.map(({ recordIndex, status }) => ({ recordIndex, status })), [
    { recordIndex: 0, status: "matched" },
    { recordIndex: 1, status: "matched" },
    { recordIndex: 2, status: "duplicate" },
  ]);
});

test("standalone preview does not invent identities and final export accepts corrected cells", () => {
  const worker = createCsvTaskProcessor();
  const options = createResolveExportOptions();
  const task = { type: "standalone-preview", records: [record], exportOptions: options };
  const preview = worker(task);
  assert.deepEqual(preview.table.rows[0].slice(0, 5), ["", "", "", "", ""]);
  assert.equal(preview.table.exportWarnings.length, 5);
  assert.throws(() => worker({ ...task, type: "export-standalone" }), /缺少素材文件名/);
  const csvEdits = [["0:0", "A001C001.mov"], ["0:1", "01:02:03:04"], ["0:2", "01:02:09:08"], ["0:3", "A001"], ["0:4", "/Volumes/拍摄/A001"]];
  const fixed = worker({ ...task, csvEdits });
  assert.deepEqual(fixed.table.exportWarnings, []);
  const decoded = decodeResolveCsv(worker({ ...task, type: "export-standalone", csvEdits }).bytes);
  assert.deepEqual(decoded.rows, fixed.table.rows);
});

test("persisted positional edits follow headers after template reordering", () => {
  const worker = createCsvTaskProcessor();
  const options = createResolveExportOptions();
  const preview = worker({ type: "standalone-preview", records: [record], exportOptions: options });
  const saved = JSON.parse(JSON.stringify({ csvEditHeaders: preview.table.headers, csvEdits: [["0:0", "真实.mov"], ["0:8", "人工备注"]] }));
  const reordered = { ...options, columns: [...options.columns].reverse() };
  const task = { type: "export-standalone", records: [record], exportOptions: reordered, ...saved };
  const decoded = decodeResolveCsv(worker(task).bytes);
  assert.equal(decoded.rows[0][decoded.headers.indexOf("File Name")], "真实.mov");
  assert.equal(decoded.rows[0][decoded.headers.indexOf("Comments")], "人工备注");
  assert.deepEqual(remapTemplateEdits({ "0:1": "名称" }, ["Comments", "File Name"], ["File Name", "Comments"]), { "0:0": "名称" });
});

test("ambiguous source columns fail and conflicting descriptions never overwrite source", () => {
  const worker = createCsvTaskProcessor();
  const source = inventory();
  worker({ type: "prime-metadata", table: source });
  const task = { type: "merge-preview", exportOptions: createResolveExportOptions(), records: [record, { ...record, description: "另一条" }] };
  const result = worker(task);
  assert.equal(result.matchedRecordCount, 0);
  assert.equal(result.table.rows[0][8], "旧备注");
  source.headers.push("File Name");
  source.rows.forEach((row) => row.push("冲突.mov"));
  worker({ type: "prime-metadata", table: source });
  assert.throws(() => worker(task), /重复的 File Name/);
});

test("unconfigured projects default to Resolve and imported schemas survive project reload and task inheritance", async () => {
  const { DEFAULT_EXPORT_OPTIONS, resolveEffectiveExportOptions } = await import('../public/export-options.js');
  assert.deepEqual(normalizeProjectSettings().export, DEFAULT_EXPORT_OPTIONS);
  const worker = createCsvTaskProcessor();
  worker({ type: 'prime-metadata', table: inventory() });
  const data = new TextEncoder().encode('Comments;File Name;Extra;Scene\nDO NOT COPY;sample.mov;PRIVATE SAMPLE;999\n');
  const imported = worker({ type: 'import-export-template', data, filename: '后期样表.csv' }).options;
  assert.equal(JSON.stringify(imported).includes('PRIVATE SAMPLE'), false);
  const saved = normalizeProjectSettings({ export: imported });
  const reopened = normalizeProjectSettings(JSON.parse(JSON.stringify(saved)));
  assert.deepEqual(reopened.export, imported);
  assert.deepEqual(normalizeExportOptions(imported), imported);
  const effective = resolveEffectiveExportOptions({ projectDefault: reopened.export }).options;
  assert.deepEqual(effective, imported);
  assert.equal(normalizeProjectSettings({ customPrompt: 'change' }, reopened).export.templateName, '后期样表.csv');
  const preview = worker({ type: 'merge-preview', exportOptions: effective, records: [record] }).table;
  assert.deepEqual(preview.headers, ['Comments', 'File Name', 'Extra', 'Scene']);
  assert.deepEqual(preview.rows[0], [record.comments, 'A001C001.mov', '未选择', '12A']);
  const standalone = worker({ type: 'standalone-preview', exportOptions: effective, records: [record] }).table;
  assert.deepEqual(standalone.rows[0], [record.comments, '', '', '12A']);
  const bytes = worker({ type: 'export-standalone', exportOptions: effective, records: [record], csvEdits: [['0:2', '自定义值']] }).bytes;
  assert.match(new TextDecoder().decode(bytes), /^Comments;File Name;Extra;Scene\n/);
  assert.match(new TextDecoder().decode(bytes), /自定义值;12A\n$/);
});

test("template-only CSV accepts header-only schemas and rejects ambiguous headers without changing inventory", () => {
  const worker = createCsvTaskProcessor();
  worker({ type: 'prime-metadata', table: inventory() });
  const decode = (text) => worker({ type: 'import-export-template', data: new TextEncoder().encode(text) });
  assert.deepEqual(decode('Scene,Shot,客户备注').options.columns.map(c => c.header), ['Scene', 'Shot', '客户备注']);
  for (const text of ['', 'Scene,scene', 'Scene,,Comments']) assert.throws(() => decode(text));
  assert.throws(() => worker({ type: 'import-export-template', data: new Uint8Array(5 * 1024 * 1024 + 1) }), /5 MB/);
  assert.equal(worker({ type: 'merge-preview', records: [record], exportOptions: createResolveExportOptions() }).table.rows[0][0], 'A001C001.mov');
});

// Resolve 21.1 Reference Manual, ch. 18 pp. 406–412, 421–423;
// Resolve 18 Editor's Guide, printed pp. 254, 257–260.
// Field semantics and interoperability limits are recorded in
// docs/resolve-metadata-template.md. This is a CSV adapter, not an ALE schema.
export const RESOLVE_TEMPLATE_ID = "resolve-21.1-csv-v1";
export const IMPORTED_TEMPLATE_ID = "imported-csv-v1";
export const isMetadataTemplate = (options) => [RESOLVE_TEMPLATE_ID, IMPORTED_TEMPLATE_ID].includes(options?.templateId);

// Keep source-header aliases in the template boundary so CSV decoding and
// template projection resolve the same localized or punctuation-variant names.
export const HEADER_ALIASES = Object.freeze({
  fileName: ["File Name", "Filename", "文件名"],
  clipDirectory: ["Clip Directory", "片段目录", "素材目录"],
  reelName: ["Reel Name", "Reel", "卷名"],
  clipName: ["Clip Name", "条名", "片段名", "片段名称"],
  shot: ["Shot", "镜次", "鏡次"],
  scene: ["Scene", "场景", "場景"],
  take: ["Take", "镜头", "鏡頭"],
  comments: ["Comments", "Comment", "备注", "備註", "注释", "註釋"],
  takeStatus: ["Take Status"],
  cardNumber: ["Card Number"],
  videoCode: ["Video Code"],
  sourcePage: ["Source Page"],
  cameraFps: ["Camera FPS", "CameraFPS", "摄影机帧率", "攝影機幀率"],
  shootDay: ["Shoot Day", "ShootDay", "拍摄日期", "拍攝日期"],
  // Resolve reads only its canonical "Camera #" header; localized variants
  // are not emitted and are not treated as the camera column.
  camera: ["Camera #"],
});

export function findHeaderIndexes(headers, aliases) {
  const accepted = new Set(aliases.map(normalizeHeader));
  return headers
    .map((header, index) => (accepted.has(normalizeHeader(header)) ? index : -1))
    .filter((index) => index >= 0);
}

function normalizeHeader(value) {
  return String(value || "")
    .trim()
    .toLowerCase()
    .replace(/[\s_-]+/g, "");
}

// Persist schema only. Sample values belong to a particular shoot, never to a
// project default. Unknown headers remain editable, literal passthrough columns.
export function normalizeImportedColumns(columns) {
  if (!Array.isArray(columns) || !columns.length || columns.length > 256) throw new Error("模板需要 1–256 个列标题。");
  const seen = new Set();
  const normalized = columns.map((column, index) => {
    const header = String(column?.header ?? "");
    const match = header.trim().toLowerCase();
    if (!match || header.length > 160 || /[\u0000-\u001f\u007f]/.test(header)) throw new Error("模板包含空白或无效列标题。");
    if (seen.has(match)) throw new Error(`模板包含重复列标题：${header}`);
    seen.add(match);
    const field = RESOLVE_METADATA_FIELDS.find((item) => item.header.toLowerCase() === match);
    return { key: field?.key || `imported:${index}`, header, enabled: column.enabled !== false };
  });
  if (!normalized.some((column) => column.enabled)) normalized[0].enabled = true;
  return normalized;
}

export function createImportedExportOptions(table, filename) {
  return { templateId: IMPORTED_TEMPLATE_ID, templateName: String(filename || "导入的 CSV").slice(0, 200),
    columns: normalizeImportedColumns(table.headers.map((header) => ({ header }))),
    format: { ...table.format }, filenameTemplate: "{source}_后期元数据.csv" };
}

export const RESOLVE_METADATA_FIELDS = Object.freeze([
  { key: "fileName", header: "File Name", label: "素材文件名", required: true, page: 422 },
  { key: "startTimecode", header: "Start TC", label: "素材起始时码", required: true, page: 422 },
  { key: "endTimecode", header: "End TC", label: "素材结束时码", required: true, page: 422 },
  { key: "reelName", header: "Reel Name", label: "卷名", required: true, page: 422 },
  { key: "clipDirectory", header: "Clip Directory", label: "源文件目录", required: true, page: 422 },
  { key: "scene", header: "Scene", label: "场次", enabled: true, page: 412 },
  { key: "shot", header: "Shot", label: "镜号", enabled: true, page: 412 },
  { key: "take", header: "Take", label: "条次", enabled: true, page: 412 },
  { key: "comments", header: "Comments", label: "备注", enabled: true, page: 412 },
  { key: "description", header: "Description", label: "内容描述", page: 406 },
  { key: "keywords", header: "Keywords", label: "关键词", page: 408 },
  { key: "camera", header: "Camera #", label: "机位", page: 412 },
  { key: "shootDay", header: "Shoot Day", label: "拍摄日", page: 406 },
  { key: "cameraType", header: "Camera Type", label: "摄影机类型", page: 406 },
  { key: "audioNotes", header: "Audio Notes", label: "声音备注", page: 406 },
].map((field) => Object.freeze(field)));

// Required means the column is always included, not that Resolve demands all
// five values for every import. Missing values must disable that match option.
export function normalizeResolveTemplateColumns(columns) {
  const supplied = Array.isArray(columns) ? columns : [];
  const seen = new Set();
  const ordered = [...supplied, ...RESOLVE_METADATA_FIELDS].flatMap((column) => {
    const field = RESOLVE_METADATA_FIELDS.find((item) => item.key === column?.key);
    if (!field || seen.has(field.key)) return [];
    seen.add(field.key);
    return [{ key: field.key, header: field.header,
      enabled: Boolean(field.required || (typeof column.enabled === "boolean" ? column.enabled : field.enabled)) }];
  });
  return ordered;
}

export function createResolveExportOptions() {
  return {
    templateId: RESOLVE_TEMPLATE_ID,
    columns: normalizeResolveTemplateColumns(),
    // Unicode CSV defaults are an application choice, not a claimed manual mandate.
    format: { encoding: "utf-8", bom: true, delimiter: ",", lineEnding: "\r\n", finalNewline: true },
    filenameTemplate: "{source}_Resolve元数据.csv",
  };
}

const text = (value) => value == null ? "" : String(value);

function resolveTemplateSourceIndexes(source, columns) {
  const indexes = new Map();
  const bindings = new Map();
  const bound = new Set();
  for (const column of Array.isArray(source.semanticColumns) ? source.semanticColumns : []) {
    if (!column?.key || !Number.isInteger(column.index) || column.index < 0 ||
        column.index >= source.headers.length || bindings.has(column.key) || bound.has(column.index)) continue;
    bindings.set(column.key, column.index);
    bound.add(column.index);
  }
  for (const field of columns) {
    const semanticIndex = bindings.get(field.key);
    const matches = semanticIndex === undefined
      ? findHeaderIndexes(source.headers, HEADER_ALIASES[field.key] || [field.header]).filter((index) => !bound.has(index))
      : [semanticIndex];
    if (matches.length > 1) throw new Error(`Resolve 模板无法确定重复的 ${field.header} 列，请先修正素材清单。`);
    indexes.set(field.key, matches[0] ?? -1);
  }
  return indexes;
}

// Save the column schema with positional edits; template reorder and task
// restoration must not move a filename correction into a timecode cell.
export function remapTemplateEdits(edits, previousHeaders, nextHeaders) {
  const entries = edits instanceof Map ? [...edits] : Array.isArray(edits) ? edits : Object.entries(edits || {});
  if (!Array.isArray(previousHeaders)) return Object.fromEntries(entries);
  return Object.fromEntries(entries.flatMap(([key, value]) => {
    const match = /^(\d+):(\d+)$/.exec(text(key));
    if (!match) return [];
    const header = previousHeaders[Number(match[2])];
    const matches = nextHeaders.flatMap((next, index) => next === header ? [index] : []);
    return matches.length === 1 ? [[`${match[1]}:${matches[0]}`, value]] : [];
  }));
}

/** Project only selected official text fields; never guess clip identity from slate IDs. */
export function buildResolveTemplateTable(input, mergeResult) {
  const options = input.exportOptions ?? input.options;
  const imported = options.templateId === IMPORTED_TEMPLATE_ID;
  const columns = (imported ? normalizeImportedColumns(options.columns) : normalizeResolveTemplateColumns(options.columns)).filter((field) => field.enabled);
  const source = input.mode === "resolve" ? input.sourceTable : null;
  const records = input.records || [];
  // Reuse the decoder's aliases and persisted semantic bindings so projection
  // cannot blank a valid localized source column or move a user-bound field.
  const sourceIndexes = source ? resolveTemplateSourceIndexes(source, columns) : new Map();
  const rows = source
    ? source.rows.map((row) => columns.map((field) => text(row[sourceIndexes.get(field.key)])))
    : records.map((record) => columns.map((field) => text(record[field.key])));
  // Existing matching owns slate→clip association. The template reads original
  // cells rather than legacy normalized Comments, Camera # or numeric Scene values.
  const writable = new Set(["scene", "shot", "take", "comments", "description"]);
  if (source) for (const status of mergeResult.statuses) {
    if (status.status !== "matched") continue;
    const record = records[status.recordIndex];
    for (const rowIndex of status.rowIndexes) columns.forEach((field, index) => {
      const value = text(record[field.key]);
      if (writable.has(field.key) && value.trim()) rows[rowIndex][index] = value;
    });
  }
  const entries = Object.entries(remapTemplateEdits(input.csvEdits, input.csvEditHeaders, columns.map((field) => field.header)));
  let appliedEditCount = 0;
  for (const [key, value] of entries) {
    const match = /^(\d+):(\d+)$/.exec(text(key));
    if (!match) continue;
    const row = Number(match[1]), column = Number(match[2]);
    if (rows[row] && column < columns.length) { rows[row][column] = text(value); appliedEditCount++; }
  }
  const semanticColumns = columns.map((column, index) => ({ ...column, index }));
  const missing = RESOLVE_METADATA_FIELDS.filter((field) => field.required && (!imported || columns.some((column) => column.key === field.key))).flatMap((field) => {
    const index = columns.findIndex((column) => column.key === field.key);
    const count = rows.filter((row) => !row[index]?.trim()).length;
    return count ? [field.key === "fileName" && !imported
      ? `File Name 有 ${count} 行缺失；请补齐素材文件名后导出。`
      : `${field.header} 有 ${count} 行缺失；请补齐，或在 Resolve 导入时关闭相应匹配条件。`] : [];
  });
  const table = { headers: columns.map((field) => field.header), rows, semanticColumns,
    semanticBuilt: true, exportTemplateId: options.templateId, exportWarnings: missing,
    format: { ...createResolveExportOptions().format, ...options.format, ...input.outputFormat, ...(!imported ? { delimiter: "," } : {}) },
    // Match the Worker prime upgrade when called directly with an older table.
    ...(source ? { sourceEncoding: source.sourceEncoding || source.format?.encoding || "utf-8" } : {}),
  };
  return { ...mergeResult, table, semanticColumns, appliedEditCount, resolvedFilename: input.resolvedFilename,
    exportableCount: rows.length, warnings: [...(mergeResult?.warnings || []), ...missing] };
}

/** A slate document name, card number, or invented extension is never a filename fallback. */
export function assertResolveTemplateExport(table) {
  if (table.exportTemplateId !== RESOLVE_TEMPLATE_ID) return;
  const index = table.headers.indexOf("File Name");
  const count = table.rows.filter((row) => !row[index]?.trim()).length;
  if (count) throw new Error(`Resolve 导出有 ${count} 行缺少素材文件名。请在回填预览中填写 File Name，或载入素材元数据 CSV 后重试。`);
}

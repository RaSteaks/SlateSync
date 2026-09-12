// DaVinci Resolve CSV parsing and slate metadata backfill.
//
// Decodes Resolve's exported CSV, matches its rows to recognized slate records
// and camera sidecar metadata (frame rate, shoot day), merges them into a
// Resolve-ready table, and encodes the result back to CSV. Also re-exports the
// shared metadata helpers from metadata-common.js / metadata-sources/.
import {
  canonicalRecognitionValue,
  canonicalKeyToMaterialPrefix,
  cleanValue,
  detectCsvFormat,
  extractCombinedMaterialKey,
  isCanonicalRecognitionValue,
  normalizeCameraFps,
  normalizeRecognitionField,
  normalizeShootDay,
  parseCanonicalMaterialKey,
  reviewFieldsFromQuality,
} from "./metadata-common.js";
import { parseSlateMetadataText } from "./metadata-sources/kinefinity.js";

export {
  extractCombinedMaterialKey,
  normalizeCameraFps,
  normalizeShootDay,
  parseSlateMetadataText,
};

const HEADER_ALIASES = Object.freeze({
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

const TARGET_COLUMNS = Object.freeze([
  { field: "shot", header: "Shot" },
  { field: "scene", header: "Scene" },
  { field: "take", header: "Take" },
  { field: "comments", header: "Comments" },
]);

const CAMERA_FPS_COLUMN = Object.freeze({
  field: "cameraFps",
  header: "Camera FPS",
});

const SHOOT_DAY_COLUMN = Object.freeze({
  field: "shootDay",
  header: "Shoot Day",
});

const SLATE_METADATA_COLUMNS = Object.freeze([
  CAMERA_FPS_COLUMN,
  SHOOT_DAY_COLUMN,
]);

// The camera number is an intrinsic property of the clip's own name (the first
// letter of its camera code, e.g. A from A004C004_20260801_RA259). It is
// derived from the material identity, independent of the slate sidecars.
const CAMERA_COLUMN = Object.freeze({
  field: "camera",
  header: "Camera #",
});

const TARGET_COLUMN_FIELDS = new Set(
  [...TARGET_COLUMNS, ...SLATE_METADATA_COLUMNS, CAMERA_COLUMN].map(
    (target) => target.field,
  ).concat(["takeStatus", "cardNumber", "videoCode", "sourcePage"]),
);

// Writable target columns whose duplicate headers resolve to the FIRST match
// instead of rejecting the whole CSV at load time. A Resolve export may carry
// two "Camera #" columns (e.g. added by an external tool); the backfill writes
// to the first and the file still opens for the user to fix.
const FIRST_MATCH_TARGET_FIELDS = new Set(["camera", "takeStatus", "cardNumber", "videoCode", "sourcePage"]);

const FIXED_WIDTH_METADATA_FIELDS = Object.freeze([
  { field: "scene", label: "Scene" },
  { field: "shot", label: "Shot" },
  { field: "take", label: "Take" },
]);

export const DEFAULT_RESOLVE_FIELD_FORMATS = Object.freeze({
  scene: "XXX",
  shot: "XX",
  take: "XX",
});

// Resolve Comments markers written for recognized take statuses. Mirrored in
// lib/config.mjs (DEFAULT_WORKFLOW_CONFIG.resolve.comments) and configurable
// through slatesync.config.json.
export const DEFAULT_RESOLVE_COMMENTS = Object.freeze({
  goodTake: "_OK",
  holdTake: "_KP",
});

export function decodeResolveCsv(input, options = {}) {
  const bytes =
    input instanceof Uint8Array
      ? input
      : input instanceof ArrayBuffer
        ? new Uint8Array(input)
        : null;
  if (!bytes?.length) throw csvError("source", "源 CSV 文件为空");

  const format = detectCsvFormat(bytes);
  let text;
  let sourceEncoding;
  const explicit = options.sourceEncoding;
  const encodings = explicit ? [explicit] : format.bomBytes || format.encoding !== "utf-8"
    ? [format.encoding] : ["utf-8", "gbk", "gb18030"];
  // Fatal decoding never substitutes damaged bytes. GBK wins ambiguous Chinese
  // input; four-byte GB18030 sequences are accepted only by the final decoder.
  for (const encoding of encodings) {
    if (!["utf-8", "utf-16le", "utf-16be", "gbk", "gb18030"].includes(encoding)) break;
    try {
      if (encoding.startsWith("gb") && !validChineseEncodingBytes(bytes, encoding)) continue;
      text = new TextDecoder(encoding, { fatal: true }).decode(bytes.subarray(format.bomBytes));
      sourceEncoding = encoding;
      break;
    } catch { /* Try the next supported source encoding. */ }
  }
  if (text === undefined) throw csvError("source", "源 CSV 编码无法解码：字节截断、内容损坏或不支持的输入编码");

  text = text.replace(/^\uFEFF/, "");
  const delimiter = detectDelimiter(text);
  const matrix = parseCsvText(text, delimiter);
  if (!matrix.length || !matrix[0].some((value) => String(value).trim())) {
    throw new Error("CSV 缺少表头");
  }

  const headers = matrix[0].map((value) => String(value));
  const rows = matrix.slice(1).map((row) => normalizeRowWidth(row, headers.length));
  const columns = resolveColumnIndexes(headers);
  if (!hasIdentifierColumns(columns)) {
    throw new Error(
      "CSV 中未找到 File Name（文件名）、Reel Name（卷名）或 Clip Name（条名）列。",
    );
  }

  return {
    headers,
    rows,
    // Keep the detected input encoding separate from the output format. The
    // format remains unchanged so existing round-trip bytes stay identical.
    sourceEncoding,
    sourceEncodingDetection: explicit ? "explicit" : "detected",
    format: {
      encoding: sourceEncoding.startsWith("utf-") ? sourceEncoding : "utf-8",
      bom: format.bomBytes > 0,
      delimiter,
      lineEnding: detectLineEnding(text),
      finalNewline: /(?:\r\n|\n|\r)$/.test(text),
    },
  };
}

// Some ICU GBK decoders accept 0xFF as a private-use character even in fatal
// mode. Validate the byte grammar first to keep Node and Chromium consistent.
function validChineseEncodingBytes(bytes, encoding) {
  for (let index = 0; index < bytes.length; index += 1) {
    const first = bytes[index];
    if (first < 0x80 || (encoding === "gbk" && first === 0x80)) continue;
    if (first < 0x81 || first > 0xfe) return false;
    const second = bytes[++index];
    if (second >= 0x40 && second <= 0xfe && second !== 0x7f) continue;
    if (encoding !== "gb18030" || !(second >= 0x30 && second <= 0x39)) return false;
    const third = bytes[++index], fourth = bytes[++index];
    if (!(third >= 0x81 && third <= 0xfe && fourth >= 0x30 && fourth <= 0x39)) return false;
  }
  return true;
}

export function buildSlateMetadataIndex(entries = []) {
  const grouped = groupBy(
    entries.filter((entry) => entry?.materialKey),
    (entry) => entry.materialKey,
  );
  const byMaterialKey = new Map();
  const warnings = [];

  for (const [materialKey, group] of grouped) {
    const sensorFpsValues = new Set(
      group.map((entry) => normalizeCameraFps(entry.sensorFps)).filter(Boolean),
    );
    // Conflicting values keep their candidates so the conflict warning can
    // list every observed frame rate.
    const sensorFpsCandidates = [...sensorFpsValues];
    let sensorFps = "";
    let sensorFpsConflict = false;
    if (sensorFpsValues.size > 1) {
      sensorFpsConflict = true;
      warnings.push(
        `${canonicalKeyToMaterialPrefix(materialKey)} 的相机元数据存在互相冲突或无效的 Sensor FPS（${sensorFpsCandidates.join(" / ")}），Camera FPS 不会写入素材行，需人工确认帧率。`,
      );
    } else if (sensorFpsValues.size === 1) {
      sensorFps = sensorFpsCandidates[0];
    }

    const shootDayValues = new Set(
      group.map((entry) => normalizeShootDay(entry.shootDay)).filter(Boolean),
    );
    let shootDay = "";
    if (shootDayValues.size > 1) {
      warnings.push(
        `${canonicalKeyToMaterialPrefix(materialKey)} 的相机元数据存在互相冲突的 Shot Date，Shoot Day 不会写入。`,
      );
    } else if (shootDayValues.size === 1) {
      shootDay = [...shootDayValues][0];
    }

    if (!sensorFps && !shootDay && !sensorFpsConflict) continue;
    byMaterialKey.set(materialKey, {
      materialKey,
      sensorFps,
      shootDay,
      sensorFpsConflict,
      sensorFpsCandidates,
      sourceNames: group.map((entry) => entry.sourceName).filter(Boolean),
    });
  }

  return { byMaterialKey, warnings };
}

// The camera letter for a material: the first character of its camera code,
// derived from the canonical key's leading segment (A:4:4 → "A"). Mirrors the
// clip-name convention where A004C004_... starts with the camera letter.
function materialCameraLetter(key) {
  const camera = String(key || "").split(":")[0] || "";
  const letter = camera.trim().charAt(0);
  return /[A-Za-z]/.test(letter) ? letter.toUpperCase() : "";
}

function mergeResolveSource(
  sourceTable,
  records,
  slateMetadata = [],
  options = {},
) {
  if (!sourceTable?.headers || !Array.isArray(sourceTable.rows)) {
    throw new Error("尚未载入有效的 Resolve CSV");
  }

  // The Resolve CSV is the source of truth: columns already present are kept in
  // place and only genuinely missing Resolve fields are appended. No synthetic
  // rows are ever written into the exported file.
  const headers = sourceTable.headers.map((value) => String(value));
  const rows = sourceTable.rows.map((row) =>
    normalizeRowWidth(row.map(stringValue), headers.length),
  );
  const warnings = [];
  const addedColumns = [];
  const fieldFormats = resolveFieldFormats(options.fieldFormats);
  const commentsConfig = resolveCommentsConfig(options.comments);
  const slateIndex = buildSlateMetadataIndex(slateMetadata);
  warnings.push(...slateIndex.warnings);

  let columns = resolveColumnIndexes(headers, sourceTable.semanticColumns);
  const hasSlateSource = slateMetadata.length > 0;
  const hasEnrichment = hasSlateSource || records.length > 0;
  const columnsToEnsure = [
    ...TARGET_COLUMNS.filter((target) => !options.columns || options.columns.some((column) => column.key === target.field && column.enabled)),
    ...(hasSlateSource ? SLATE_METADATA_COLUMNS : []),
  ];
  // Camera # is derived from the clip's own name, never from the slate, so it
  // is ensured whenever this merge enriches a Resolve table at all (whether or
  // not a card was scanned).
  if (hasEnrichment) columnsToEnsure.push(CAMERA_COLUMN);
  for (const target of columnsToEnsure) {
    if (columns[target.field] >= 0) continue;
    headers.push(target.header);
    for (const row of rows) row.push("");
    addedColumns.push(target.header);
    warnings.push(`原 CSV 缺少 ${target.header} 列，已按 Resolve 字段名添加。`);
    columns = resolveColumnIndexes(headers, sourceTable.semanticColumns);
  }

  const rowIndex = buildMetadataRowIndex(rows, columns, warnings);
  // Invert the key→rows index so the caller can map each output row back to its
  // canonical material key (used by the UI to flag rows whose sidecar is missing).
  const rowKeys = new Array(rows.length).fill("");
  for (const [key, rowNumbers] of rowIndex) {
    for (const rowNumber of rowNumbers) rowKeys[rowNumber] = key;
  }
  const recognizedMaterialKeys = new Set(
    records
      .map((record) => canonicalMaterialKey(record.cardNumber, record.videoCode))
      .filter(Boolean),
  );
  let cameraFpsMatchedMaterialCount = 0;
  let shootDayMatchedMaterialCount = 0;
  const updatedRows = new Set();
  const cameraFpsMatchedRows = new Set();
  const shootDayMatchedRows = new Set();
  const missingCameraFpsKeys = new Set();
  const missingShootDayKeys = new Set();
  const changes = [];

  // Camera metadata comes from the camera-generated sidecar and only needs a
  // trustworthy material identity (the CSV row it belongs to). Apply it
  // independently of recognition records: missing or conflicting Scene/Shot/
  // Take recognition must never suppress these fields, and a CSV row that
  // never matched a 场记 record still receives its frame rate whenever the
  // card sidecar corresponds — a real clip always carries a frame rate, so
  // "no 场记" must never read as "no fps".
  const slateKeyedRows = new Set();
  for (const key of rowIndex.keys()) {
    if (slateIndex.byMaterialKey.has(key)) slateKeyedRows.add(key);
  }
  const cameraMetadataKeys = [
    ...new Set([...recognizedMaterialKeys, ...slateKeyedRows]),
  ].sort(compareCanonicalMaterialKeys);
  for (const key of cameraMetadataKeys) {
    const matchedRows = rowIndex.get(key) || [];
    if (!matchedRows.length) continue;

    const slateEntry = slateIndex.byMaterialKey.get(key);
    const recognized = recognizedMaterialKeys.has(key);
    const slateFields = [
      {
        field: "cameraFps",
        value: slateEntry?.sensorFps || "",
        matchedRows: cameraFpsMatchedRows,
        missingKeys: missingCameraFpsKeys,
        // fps conflicts are surfaced by the conflict warning, so they must not
        // be counted again as a missing Sensor FPS.
        reportMissingWhenRecognized: !slateEntry?.sensorFpsConflict,
      },
      {
        field: "shootDay",
        value: slateEntry?.shootDay || "",
        matchedRows: shootDayMatchedRows,
        missingKeys: missingShootDayKeys,
        reportMissingWhenRecognized: true,
      },
    ];

    for (const slateField of slateFields) {
      if (!slateField.value) {
        if (
          recognized &&
          slateMetadata.length &&
          slateField.reportMissingWhenRecognized
        ) {
          slateField.missingKeys.add(key);
        }
        continue;
      }

      if (slateField.field === "cameraFps") {
        cameraFpsMatchedMaterialCount += 1;
      } else {
        shootDayMatchedMaterialCount += 1;
      }

      for (const rowNumber of matchedRows) {
        const row = rows[rowNumber];
        const columnIndex = columns[slateField.field];
        if (columnIndex < 0) continue;
        const previous = cleanValue(row[columnIndex]);
        const next = slateField.value;
        slateField.matchedRows.add(rowNumber);
        if (previous === next) continue;

        row[columnIndex] = next;
        changes.push({
          rowIndex: rowNumber,
          field: slateField.field,
          header: headers[columnIndex],
          previous,
          next,
        });
        updatedRows.add(rowNumber);
        if (previous) {
          const fileName =
            rowDisplayName(row, columns) || canonicalKeyToMaterialPrefix(key);
          warnings.push(
            `CSV 第 ${rowNumber + 2} 行 ${fileName} 已覆盖：${headers[columnIndex]}“${previous}”→“${next}”。`,
          );
        }
      }
    }
  }

  // Camera # is intrinsic to the clip name (e.g. A from A004C004_20260801_RA259),
  // so every CSV material row whose identity resolves gets its leading camera
  // letter backfilled — independent of both sidecars and recognition. Existing
  // non-empty cells are respected and never overwritten. This is a pure cell
  // backfill and is deliberately not counted as "writable work": it is derived
  // from the row's own name and must not flip exportability or the reel-mismatch
  // gate.
  if (columns.camera >= 0) {
    for (let rowNumber = 0; rowNumber < rows.length; rowNumber += 1) {
      const key = rowKeys[rowNumber];
      if (!key) continue;
      const camera = materialCameraLetter(key);
      if (!camera) continue;
      const row = rows[rowNumber];
      if (cleanValue(row[columns.camera])) continue;
      row[columns.camera] = camera;
    }
  }

  const unrecognizedMaterialKeys = [...rowIndex.keys()]
    .filter((key) => !recognizedMaterialKeys.has(key))
    .sort(compareCanonicalMaterialKeys);
  const unrecognizedMaterials = unrecognizedMaterialKeys.map(
    canonicalKeyToMaterialPrefix,
  );
  const unrecognizedRowIndexes = unrecognizedMaterialKeys.flatMap(
    (key) => rowIndex.get(key) || [],
  );
  if (unrecognizedMaterials.length) {
    warnings.push(
      `Resolve CSV 中有 ${unrecognizedMaterials.length} 个素材未匹配到场记（${compactMaterialRanges(unrecognizedMaterialKeys)}）。这些行不会回填场镜次；若有对应 slate.txt，Camera FPS/Shoot Day 仍会独立回填。请检查是否漏页或漏识别。`,
    );
  }
  const statuses = Array.from({ length: records.length }, () => null);
  const candidates = [];

  for (const [recordIndex, record] of records.entries()) {
    const key = canonicalMaterialKey(record.cardNumber, record.videoCode);
    const fileName = materialPrefix(record.cardNumber, record.videoCode);
    if (!key || !fileName) {
      statuses[recordIndex] = {
        recordIndex,
        status: "missing-key",
        fileName: null,
      };
      warnings.push(
        `第 ${recordIndex + 1} 条缺少卷号，或视频码不是 C0XX 格式，不会写入 CSV。`,
      );
      continue;
    }

    const values = semanticRecordValues(record, fieldFormats, commentsConfig);
    const missingFields = [
      [values.scene, "场次"],
      [values.shot, "镜"],
      [values.take, "次"],
    ]
      .filter(([value]) => !value)
      .map(([, label]) => label);

    if (missingFields.length) {
      statuses[recordIndex] = {
        recordIndex,
        status: "incomplete",
        fileName,
        missingFields,
      };
      warnings.push(
        `第 ${recordIndex + 1} 条 ${fileName} 缺少${missingFields.join("、")}，Scene、Shot、Take 和 Comments 不会写入；有效的 Camera FPS 和 Shoot Day 仍会独立回填。`,
      );
      continue;
    }

    candidates.push({
      recordIndex,
      key,
      fileName,
      values,
      signature: `${values.scene}\u0000${values.shot}\u0000${values.take}\u0000${values.takeStatus}`,
    });
  }

  const groupedRecords = groupBy(candidates, (candidate) => candidate.key);
  let matchedRecordCount = 0;

  for (const group of groupedRecords.values()) {
    const signatures = new Set(group.map((candidate) => candidate.signature));
    if (signatures.size > 1) {
      for (const candidate of group) {
        statuses[candidate.recordIndex] = {
          recordIndex: candidate.recordIndex,
          status: "conflict",
          fileName: candidate.fileName,
        };
      }
      warnings.push(
        `${group[0].fileName} 在识别结果中出现了互相冲突的场、镜、次或条次状态，这些场记字段已停止写入，请人工校对；有效的 Camera FPS 和 Shoot Day 仍会独立回填。`,
      );
      continue;
    }

    const primary = group[0];
    for (const duplicate of group.slice(1)) {
      statuses[duplicate.recordIndex] = {
        recordIndex: duplicate.recordIndex,
        status: "duplicate",
        fileName: duplicate.fileName,
      };
    }

    const matchedRows = rowIndex.get(primary.key) || [];
    if (!matchedRows.length) {
      statuses[primary.recordIndex] = {
        recordIndex: primary.recordIndex,
        status: "unmatched",
        fileName: primary.fileName,
      };
      warnings.push(
        `${primary.fileName} 未在 Resolve CSV 的卷名或文件名中找到，不会新增虚构素材行。`,
      );
      continue;
    }

    const matchedFileNames = [];
    for (const rowNumber of matchedRows) {
      const row = rows[rowNumber];
      const rowChanges = [];
      // Resolve Comments is a strict export field: only _OK, _KP, or an empty
      // cell may be written, regardless of any OCR text in record.comments.
      const fieldsToWrite = ["scene", "shot", "take", "comments"];
      for (const field of fieldsToWrite) {
        const columnIndex = columns[field];
        if (columnIndex < 0) continue;
        const previous = cleanValue(row[columnIndex]);
        const next = primary.values[field];
        if (previous === next) continue;
        row[columnIndex] = next;
        const change = {
          rowIndex: rowNumber,
          field,
          header: headers[columnIndex],
          previous,
          next,
        };
        changes.push(change);
        rowChanges.push(change);
      }

      const fileName = rowDisplayName(row, columns) || primary.fileName;
      matchedFileNames.push(fileName);
      updatedRows.add(rowNumber);
      const overwritten = rowChanges.filter((change) => change.previous);
      if (overwritten.length) {
        warnings.push(
          `CSV 第 ${rowNumber + 2} 行 ${fileName} 已覆盖：${overwritten
            .map(
              (change) =>
                `${change.header}“${change.previous}”→“${change.next}”`,
            )
            .join("，")}。`,
        );
      }
    }

    matchedRecordCount += 1;
    statuses[primary.recordIndex] = {
      recordIndex: primary.recordIndex,
      status: "matched",
      fileName: matchedFileNames[0] || primary.fileName,
      fileNames: matchedFileNames,
      rowIndexes: [...matchedRows],
      matchedRows: matchedRows.length,
    };
  }

  if (missingCameraFpsKeys.size) {
    const sortedKeys = [...missingCameraFpsKeys].sort(compareCanonicalMaterialKeys);
    warnings.push(
      `Sensor FPS 缺失：${sortedKeys.length} 个已识别且匹配 CSV 的素材没有可用 Sensor FPS（${compactMaterialRanges(sortedKeys)}），其 Camera FPS 保持原值，请检查侧车或卡片对应。`,
    );
  }

  if (missingShootDayKeys.size) {
    const sortedKeys = [...missingShootDayKeys].sort(
      compareCanonicalMaterialKeys,
    );
    warnings.push(
      `Shoot Day 缺失：${sortedKeys.length} 个已识别且匹配 CSV 的素材没有可用 Shot Date（${compactMaterialRanges(sortedKeys)}），其 Shoot Day 保持原值。`,
    );
  }

  // Canonicalize the entire Scene/Shot/Take table, not only rows matched in
  // this run. Numeric scenes use XXX, while suffixes and multi-scene values
  // are kept and uppercased (87a becomes 87A, 58 / 59 stays 58 / 59).
  for (const [rowNumber, row] of rows.entries()) {
    for (const target of FIXED_WIDTH_METADATA_FIELDS) {
      const columnIndex = columns[target.field];
      if (columnIndex < 0) continue;
      const previous = cleanValue(row[columnIndex]);
      const fieldResult = normalizeMetadataFieldResult(
        target.field,
        previous,
        fieldFormats,
      );
      const next = normalizedMetadataValue(
        target.field,
        previous,
        fieldFormats,
        { preserveUncertain: true },
      );
      if (fieldResult.reviewRequired && isFailedMetadataResult(fieldResult) && next === previous) {
        const fileName = rowDisplayName(row, columns) || "未知素材";
        warnings.push(
          `CSV 第 ${rowNumber + 2} 行 ${fileName} 的 ${target.label}“${previous}”无法安全规范化，已保留原值，请人工复核。`,
        );
      }
      if (previous === next) continue;
      row[columnIndex] = next;
      const change = {
        rowIndex: rowNumber,
        field: target.field,
        header: headers[columnIndex],
        previous,
        next,
      };
      const firstWarning = fieldResult.warnings[0];
      if (firstWarning) {
        change.warningCode = firstWarning.code;
        change.reviewRequired = fieldResult.reviewRequired;
      }
      changes.push(change);
      updatedRows.add(rowNumber);
      const fileName = rowDisplayName(row, columns) || "未知素材";
      warnings.push(
        `CSV 第 ${rowNumber + 2} 行 ${fileName} 的 ${target.label}“${previous}”已规范为“${next}”。`,
      );
    }
  }

  // Enforce the allowlist across the complete exported table, including rows
  // that were not matched in this recognition run. This prevents legacy or
  // previously misrecognized text from surviving in Resolve Comments.
  for (const [rowNumber, row] of rows.entries()) {
    const columnIndex = columns.comments;
    if (columnIndex < 0) continue;
    const previous = cleanValue(row[columnIndex]);
    const next = canonicalResolveComment(previous, commentsConfig);
    if (previous === next) continue;
    row[columnIndex] = next;
    changes.push({
      rowIndex: rowNumber,
      field: "comments",
      header: headers[columnIndex],
      previous,
      next,
    });
    updatedRows.add(rowNumber);
    const fileName = rowDisplayName(row, columns) || "未知素材";
    warnings.push(
      `CSV 第 ${rowNumber + 2} 行 ${fileName} 的 Comments“${previous}”已规范为“${next}”。`,
    );
  }

  return {
    table: {
      headers,
      rows,
      // Preview/merge tables retain the imported source fact even though their
      // output format remains inherited from the source table.
      sourceEncoding: sourceTable.sourceEncoding || sourceTable.format?.encoding,
      ...(sourceTable.sourceEncodingDetection ? { sourceEncodingDetection: sourceTable.sourceEncodingDetection } : {}),
      format: { ...defaultFormat(), ...(sourceTable.format || {}) },
    },
    statuses,
    warnings,
    addedColumns,
    matchedRecordCount,
    cameraFpsMatchedMaterialCount,
    cameraFpsMatchedRowCount: cameraFpsMatchedRows.size,
    shootDayMatchedMaterialCount,
    shootDayMatchedRowCount: shootDayMatchedRows.size,
    updatedRowCount: updatedRows.size,
    changedCellCount: changes.length,
    overwrittenCellCount: changes.filter((change) => change.previous).length,
    changes,
    exportableCount: updatedRows.size,
    expectedMaterialCount: rowIndex.size,
    recognizedMaterialCount: rowIndex.size - unrecognizedMaterialKeys.length,
    unrecognizedMaterials,
    unrecognizedRowIndexes,
    rowKeys,
  };
}

// Keep every output failure distinguishable from source decoding, including
// malformed restored cells and unsupported output configuration.
export function encodeResolveCsv(table, options = {}) {
  try {
    return encodeSemanticCsv(table, options);
  } catch (error) {
    if (error?.code === "CSV_OUTPUT_ENCODE") throw error;
    throw csvError("output", `导出 CSV 编码失败：${error?.message || "表格值无效"}`);
  }
}

function encodeSemanticCsv(table, options = {}) {
  if (!table?.headers || !Array.isArray(table.rows)) {
    throw csvError("output", "没有可编码的 CSV 表格");
  }
  const format = { ...defaultFormat(), ...(table.format || {}) };
  const delimiter = format.delimiter || ",";
  const headers = table.headers.map(stringValue);
  validateOutputFormat(format);
  const rows = table.semanticBuilt ? table.rows : normalizeExportRows(table, options);
  const matrix = [
    headers,
    ...rows,
  ];
  let text = matrix
    .map((row) => row.map((value) => csvCell(value, delimiter)).join(delimiter))
    .join(format.lineEnding);
  if (format.finalNewline) text += format.lineEnding;
  // Reject lone UTF-16 surrogates instead of silently replacing them in UTF-8.
  if (!text.isWellFormed()) throw csvError("output", "导出 CSV 包含无法编码的 Unicode 字符");
  return encodeText(text, format.encoding, format.bom);
}

// Legacy raw tables keep their historic normalization; built tables encode verbatim.
function normalizeExportRows(table, options) {
  const headers = table.headers;
  const columns = resolveColumnIndexes(headers, table.semanticColumns);
  const fieldFormats = resolveFieldFormats(options.fieldFormats);
  const commentsConfig = resolveCommentsConfig(options.comments);
  const canonicalizeComments = options.canonicalizeComments === true;
  const rows = table.rows.map((row) =>
    normalizeRowWidth(row.map(stringValue), headers.length),
  );
  for (const row of rows) {
    for (const target of FIXED_WIDTH_METADATA_FIELDS) {
      const columnIndex = columns[target.field];
      if (columnIndex < 0) continue;
      row[columnIndex] = normalizeMetadataField(
        target.field,
        row[columnIndex],
        fieldFormats,
      );
    }
    if (canonicalizeComments && columns.comments >= 0) {
      // Metadata-backed Resolve exports must not let manual edits reintroduce
      // arbitrary text into the strict Comments allowlist.
      row[columns.comments] = canonicalResolveComment(
        row[columns.comments],
        commentsConfig,
      );
    }
  }
  return rows;
}

function csvError(direction, message) {
  return Object.assign(new Error(message), {
    name: direction === "source" ? "CsvSourceDecodeError" : "CsvOutputEncodeError",
    code: direction === "source" ? "CSV_SOURCE_DECODE" : "CSV_OUTPUT_ENCODE",
  });
}

function validateOutputFormat(format) {
  if (!["utf-8", "utf-16le", "utf-16be"].includes(format.encoding) ||
      typeof format.delimiter !== "string" || format.delimiter.length !== 1 ||
      /["\r\n\u0000]/.test(format.delimiter) ||
      typeof format.bom !== "boolean" || typeof format.finalNewline !== "boolean" ||
      !["\r\n", "\n", "\r"].includes(format.lineEnding)) {
    throw csvError("output", "导出 CSV 编码或格式配置非法；仅支持 UTF-8、UTF-16LE、UTF-16BE");
  }
}

export function parseCsvText(text, delimiter = ",") {
  const source = String(text || "").replace(/^\uFEFF/, "");
  const rows = [];
  let row = [];
  let cell = "";
  let quoted = false;

  for (let index = 0; index < source.length; index += 1) {
    const char = source[index];
    if (quoted) {
      if (char === '"' && source[index + 1] === '"') {
        cell += '"';
        index += 1;
      } else if (char === '"') {
        quoted = false;
      } else {
        cell += char;
      }
    } else if (char === '"') {
      quoted = true;
    } else if (char === delimiter) {
      row.push(cell);
      cell = "";
    } else if (char === "\r" || char === "\n") {
      if (char === "\r" && source[index + 1] === "\n") index += 1;
      row.push(cell);
      rows.push(row);
      row = [];
      cell = "";
    } else {
      cell += char;
    }
  }

  if (quoted) throw new Error("CSV 中存在未闭合的引号");
  if (cell || row.length) {
    row.push(cell);
    rows.push(row);
  }
  return rows;
}

export function resolveColumnIndexes(headers, semanticColumns = []) {
  const indexes = {};
  const seenKeys = new Set();
  const bound = new Set();
  const bindings = (Array.isArray(semanticColumns) ? semanticColumns : []).filter((column) => {
    if (!column || !SEMANTIC_DEFAULTS.some(([key]) => key === column.key) ||
        !Number.isInteger(column.index) || column.index < 0 || column.index >= headers.length ||
        seenKeys.has(column.key) || bound.has(column.index)) return false;
    seenKeys.add(column.key);
    bound.add(column.index);
    return true;
  });
  for (const [field, aliases] of Object.entries(HEADER_ALIASES)) {
    const semantic = bindings.find((column) => column.key === field);
    // Persisted key/index bindings take precedence over display text, including
    // duplicate custom labels and labels that resemble another semantic field.
    const matches = semantic ? [semantic.index] : findHeaderIndexes(headers, aliases).filter((index) => !bound.has(index));
    if (
      TARGET_COLUMN_FIELDS.has(field) &&
      matches.length > 1 &&
      !FIRST_MATCH_TARGET_FIELDS.has(field)
    ) {
      throw new Error(
        `CSV 中存在多个 ${aliases[0]} 对应列，无法确定应写入哪一列。`,
      );
    }
    indexes[field] = TARGET_COLUMN_FIELDS.has(field)
      ? (matches[0] ?? -1)
      : matches;
  }
  return indexes;
}

export function collectResolveMaterialKeys(table) {
  if (!table?.headers || !Array.isArray(table.rows)) {
    throw new Error("尚未载入有效的 Resolve CSV");
  }
  const warnings = [];
  const columns = resolveColumnIndexes(table.headers, table.semanticColumns);
  const index = buildMetadataRowIndex(table.rows, columns, warnings);
  return {
    keys: [...index.keys()].sort(compareCanonicalMaterialKeys),
    warnings,
  };
}

export function canonicalMaterialKey(cardNumber, videoCode) {
  const card = canonicalRecognitionValue("cardNumber", cardNumber);
  const video = canonicalRecognitionValue("videoCode", videoCode);
  if (!card || !video) return "";
  return `${card.charAt(0)}:${Number(card.slice(1))}:${Number(video.slice(1))}`;
}

export function materialPrefix(cardNumber, videoCode) {
  const card = canonicalRecognitionValue("cardNumber", cardNumber);
  const video = canonicalRecognitionValue("videoCode", videoCode);
  if (!card || !video) return null;
  return `${card}${video}`;
}

// Warning-only sequence checks over recognized records, keyed by canonical
// material key so the merge preview can flag the affected rows in red.
// Detects clip-number gaps and Scene/Shot/Take sequence anomalies; nothing
// is auto-corrected here.
export function detectSlateSequenceAnomalies(records = []) {
  const anomalies = [];
  const byReel = new Map();
  records.forEach((record, index) => {
    const materialKey = canonicalMaterialKey(record?.cardNumber, record?.videoCode);
    const clipCode = canonicalRecognitionValue("videoCode", record?.videoCode);
    if (!materialKey || !clipCode) return;
    const parsed = parseCanonicalMaterialKey(materialKey);
    if (!parsed) return;
    const reelKey = `${parsed.camera}${parsed.reel}`;
    const group = byReel.get(reelKey) || [];
    group.push({ record, index, clip: Number(clipCode.slice(1)) });
    byReel.set(reelKey, group);
  });

  const numberValue = (field, value) => {
    const normalized = canonicalRecognitionValue(field, value, {
      fieldFormats: { [field]: field === "scene" ? "XXX" : "XX" },
    });
    return normalized && /^\d+$/.test(normalized) ? Number(normalized) : null;
  };
  const normalizedScene = (value) => canonicalRecognitionValue("scene", value, {
    fieldFormats: { scene: "XXX" },
  });
  const normalizedOrdinal = (field, value) => canonicalRecognitionValue(field, value, {
    fieldFormats: { [field]: "XX" },
  }) || String(value || "");
  const needsReview = (record, field) => reviewFieldsFromQuality(record).includes(field);
  const clipLabel = (clip) => `C${String(clip).padStart(3, "0")}`;

  for (const group of byReel.values()) {
    group.sort((left, right) => left.clip - right.clip || left.index - right.index);
    for (let index = 1; index < group.length; index += 1) {
      const previous = group[index - 1];
      const current = group[index];
      const key = canonicalMaterialKey(
        current.record.cardNumber,
        current.record.videoCode,
      );

      if (current.clip > previous.clip + 1) {
        const missingCount = current.clip - previous.clip - 1;
        const missingLabels = [];
        for (let clip = previous.clip + 1; clip <= current.clip - 1; clip += 1) {
          if (missingLabels.length === 5) {
            missingLabels.push(`等 ${missingCount} 条`);
            break;
          }
          missingLabels.push(clipLabel(clip));
        }
        anomalies.push({
          key,
          type: "clip-gap",
          message: `条号从 ${clipLabel(previous.clip)} 断档到 ${clipLabel(current.clip)}，缺少 ${missingLabels.join("、")}，可能漏 ${missingCount} 条`,
        });
        continue;
      }

      if (
        needsReview(current.record, "scene") ||
        needsReview(current.record, "shot") ||
        needsReview(current.record, "take")
      ) {
        continue;
      }
      const previousTake = numberValue("take", previous.record.take);
      const currentTake = numberValue("take", current.record.take);
      const previousShot = numberValue("shot", previous.record.shot);
      const currentShot = numberValue("shot", current.record.shot);
      if (
        previousTake == null ||
        currentTake == null ||
        normalizedScene(previous.record.scene) == null ||
        normalizedScene(current.record.scene) == null ||
        normalizedScene(previous.record.scene) !== normalizedScene(current.record.scene)
      ) {
        continue;
      }

      if (previousShot != null && currentShot != null && previousShot === currentShot) {
        const sceneLabel = normalizedScene(current.record.scene) || String(current.record.scene || "");
        const shotLabel = normalizedOrdinal("shot", current.record.shot);
        if (currentTake === previousTake) {
          anomalies.push({
            key,
            type: "take-sequence",
            message: `与上一条同为 ${sceneLabel} ${shotLabel} 镜 ${currentTake} 次，次序可能重复`,
          });
        } else if (currentTake > previousTake + 1) {
          anomalies.push({
            key,
            type: "take-sequence",
            message: `${sceneLabel} ${shotLabel} 镜的次从 ${previousTake} 跳到 ${currentTake}，中间可能漏 ${currentTake - previousTake - 1} 条`,
          });
        } else if (currentTake < previousTake) {
          anomalies.push({
            key,
            type: "take-sequence",
            message: `${sceneLabel} ${shotLabel} 镜的次从 ${previousTake} 回落到 ${currentTake}`,
          });
        }
        continue;
      }

      if (
        previousShot != null &&
        currentShot != null &&
        currentShot !== previousShot &&
        currentTake > 1
      ) {
        const sceneLabel = normalizedScene(current.record.scene) || String(current.record.scene || "");
        const shotLabel = normalizedOrdinal("shot", current.record.shot);
        anomalies.push({
          key,
          type: "take-sequence",
          message: `进入 ${sceneLabel} ${shotLabel} 镜的第一条次为 ${currentTake}，通常应从 1 开始`,
        });
      }
    }
  }
  return anomalies;
}

export function normalizeClipNumber(value) {
  const normalizedToken = normalizeToken(value);
  const combined = normalizedToken.match(/^[A-Z]+\d+C(\d+)$/);
  const candidate = combined ? `C${combined[1]}` : value;
  return canonicalRecognitionValue("videoCode", candidate) || "";
}

// Strict CSV builders omit the option; recognition display projections can
// opt into retaining numeric evidence that still needs human confirmation.
export function normalizeSceneValue(value, format = "XXX", options = {}) {
  return normalizedMetadataValue("scene", value, { scene: format }, options);
}

export function normalizeShotValue(value, format = "XX", options = {}) {
  return normalizedMetadataValue("shot", value, { shot: format }, options);
}

export function normalizeTakeValue(value, format = "XX", options = {}) {
  return normalizedMetadataValue("take", value, { take: format }, options);
}

// Builds a Resolve-compatible table straight from recognized records, so a
// slate can be processed without loading an existing metadata CSV. Rows with
// incomplete Scene/Shot/Take are skipped; Comments pass through as recognized.
export function buildStandaloneResolveTable(records = [], options = {}) {
  return buildSemanticExportTable({ mode: "standalone", records, ...options }).table;
}

export function mergeSlateIntoResolveTable(sourceTable, records, slateMetadata = [], options = {}) {
  return buildSemanticExportTable({ mode: "resolve", sourceTable, records, slateMetadata, ...options });
}

const SEMANTIC_DEFAULTS = [
  ["scene", "Scene"], ["shot", "Shot"], ["take", "Take"], ["comments", "Comments"],
  ["takeStatus", "Take Status"], ["cardNumber", "Card Number"],
  ["videoCode", "Video Code"], ["sourcePage", "Source Page"],
];

// One normalizer governs all export entry points; only recognized keys survive.
export function normalizeSemanticColumns(columns) {
  const validColumns = Array.isArray(columns)
    ? columns.filter((column) => SEMANTIC_DEFAULTS.some(([key]) => column?.key === key))
    : [];
  const supplied = validColumns.length > 0;
  const normalized = SEMANTIC_DEFAULTS.map(([key, header], index) => {
    const value = supplied ? validColumns.find((column) => column.key === key) : null;
    const label = String(value?.header ?? header).trim().slice(0, 80);
    return { key, header: label && !/[\u0000-\u001f\u007f]/.test(label) ? label : header,
      enabled: supplied ? Boolean(value && (value.enabled ?? index < 4)) : index < 4 };
  });
  // Match settings normalization: an empty valid selection restores defaults;
  // an entirely disabled selection enables its first supplied valid column.
  // This prevents successful exports containing rows with no cells.
  if (!normalized.some((column) => column.enabled)) {
    normalized.find((column) => column.key === validColumns[0].key).enabled = true;
  }
  return normalized;
}

// Both table modes read the same canonical values and status markers. The
// optional legacy Comments behavior preserves pre-options standalone bytes.
function semanticRecordValues(record, formats, markers, legacyComments = false) {
  const takeStatus = normalizeTakeStatus(record?.takeStatus, record?.goodTake);
  return {
    ...record,
    scene: normalizeSceneValue(record?.scene, formats.scene),
    shot: normalizeShotValue(record?.shot, formats.shot),
    take: normalizeTakeValue(record?.take, formats.take),
    comments: legacyComments ? String(record?.comments || "") : commentValueForTakeStatus(takeStatus, markers),
    takeStatus,
  };
}

/** Pure semantic boundary shared by preview, export, and legacy wrappers. */
export function buildSemanticExportTable(input = {}) {
  const { mode = "standalone", sourceTable, records = [], slateMetadata = [],
    fieldFormats, comments, resolvedFilename } = input;
  const options = input.exportOptions ?? input.options;
  const definitions = normalizeSemanticColumns(options?.columns ?? input.semanticColumns ?? sourceTable?.semanticColumns);
  const formats = resolveFieldFormats(fieldFormats);
  const markers = resolveCommentsConfig(comments);
  const valuesFor = (record) => semanticRecordValues(record, formats, markers, !options);
  let output;
  let bindings;
  if (mode === "resolve") {
    const source = input.semanticColumns ? { ...sourceTable, semanticColumns: input.semanticColumns } : sourceTable;
    output = mergeResolveSource(source, records, slateMetadata, { fieldFormats, comments, columns: options ? definitions : undefined });
    const indexes = resolveColumnIndexes(output.table.headers, source?.semanticColumns);
    bindings = definitions.map((column) => {
      let index = indexes[column.key] ?? -1;
      if (index < 0 && column.enabled) {
        index = output.table.headers.length;
        output.table.headers.push(column.header);
        output.table.rows.forEach((row) => row.push(""));
      }
      if (index >= 0 && options) output.table.headers[index] = column.header;
      return { ...column, header: index >= 0 ? output.table.headers[index] : column.header, index };
    });
    for (const status of output.statuses) {
      if (status.status !== "matched") continue;
      const values = valuesFor(records[status.recordIndex]);
      for (const rowIndex of status.rowIndexes) for (const column of bindings) {
        if (column.index >= 0 && column.enabled && !["scene", "shot", "take", "comments"].includes(column.key)) {
          const previous = output.table.rows[rowIndex][column.index];
          const next = stringValue(values[column.key]);
          if (previous !== next) output.changes.push({ rowIndex, field: column.key, header: column.header, previous, next });
          output.table.rows[rowIndex][column.index] = next;
        }
      }
    }
  } else if (mode === "standalone") {
    bindings = definitions.map((column) => ({ ...column, index: -1 }));
    const enabled = bindings.filter((column) => column.enabled);
    enabled.forEach((column, index) => { column.index = index; });
    const values = records.map(valuesFor).filter((record) => record.scene && record.shot && record.take);
    output = { table: { headers: enabled.map((column) => column.header), rows: values.map((record) => enabled.map((column) => stringValue(record[column.key]))) },
      changes: [], warnings: [], statuses: [], matchedRecordCount: 0, exportableCount: values.length };
  } else throw new Error(`未知 CSV 导出模式：${mode}`);
  const table = { ...output.table, semanticColumns: bindings,
    format: { ...defaultFormat(), ...output.table.format, ...options?.format, ...input.outputFormat } };
  if (!table.sourceEncoding && input.sourceEncoding) table.sourceEncoding = input.sourceEncoding;
  validateOutputFormat(table.format);
  // Sparse edits are applied once, before canonicalization, so preview bytes
  // and saved bytes use the exact same values without mutating the source.
  const edits = input.csvEdits instanceof Map ? [...input.csvEdits] : Array.isArray(input.csvEdits) ? input.csvEdits : Object.entries(input.csvEdits || {});
  let appliedEditCount = 0;
  for (const entry of edits) {
    if (!Array.isArray(entry)) continue;
    const [key, value] = entry;
    const match = String(key).match(/^(\d+):(\d+)$/);
    if (!match) continue;
    const row = Number(match[1]), column = Number(match[2]);
    if (table.rows[row] && column < table.headers.length) {
      table.rows[row][column] = stringValue(value);
      appliedEditCount += 1;
    }
  }
  table.rows = normalizeExportRows(table, { fieldFormats, comments, canonicalizeComments: mode === "resolve" });
  table.semanticBuilt = true;
  return {
    ...output,
    ...(output.changedCellCount !== undefined ? {
      changedCellCount: output.changes.length,
      overwrittenCellCount: output.changes.filter((change) => change.previous).length,
    } : {}),
    table, semanticColumns: bindings, resolvedFilename, appliedEditCount,
  };
}

function isFailedMetadataResult(result) {
  return result.warnings.some((item) =>
    ["ambiguous-numeric-token", "invalid-numeric-token", "out-of-range"].includes(item.code),
  );
}

function isNumericEvidence(value) {
  return /[0-9零〇一壹二两贰三叁四肆五伍六陆七柒八捌九玖十百OoОоIiLl|丨Ss]/.test(String(value || ""));
}

function metadataFieldResult(field, value, formats = {}) {
  return normalizeRecognitionField(field, value, {
    fieldFormats: formats,
  });
}

export function normalizeMetadataFieldResult(field, value, formats = {}) {
  return metadataFieldResult(field, value, formats);
}

function normalizedMetadataValue(field, value, formats = {}, { preserveUncertain = false } = {}) {
  const result = metadataFieldResult(field, value, formats);
  if (!isFailedMetadataResult(result) && isCanonicalRecognitionValue(field, result.normalizedValue)) {
    return result.normalizedValue;
  }
  return preserveUncertain && result.originalValue != null && isNumericEvidence(result.originalValue)
    ? result.originalValue
    : "";
}

function resolveFieldFormats(value = {}) {
  return Object.fromEntries(
    Object.entries(DEFAULT_RESOLVE_FIELD_FORMATS).map(([field, fallback]) => {
      const format = String(value?.[field] || "").trim().toUpperCase();
      return [field, /^X{1,6}$/.test(format) ? format : fallback];
    }),
  );
}

function resolveCommentsConfig(value = {}) {
  return Object.fromEntries(
    Object.entries(DEFAULT_RESOLVE_COMMENTS).map(([field, fallback]) => {
      const token = typeof value?.[field] === "string" ? value[field].trim() : "";
      const valid =
        token && token.length <= 32 && !/[\r\n]/.test(token) ? token : fallback;
      return [field, valid];
    }),
  );
}

function fieldFormatWidth(value, fallback) {
  const format = String(value || "").trim().toUpperCase();
  return /^X{1,6}$/.test(format) ? format.length : fallback;
}

function normalizeMetadataField(field, value, formats) {
  if (field === "scene" || field === "shot" || field === "take") {
    return normalizedMetadataValue(field, value, formats, { preserveUncertain: true });
  }
  return cleanValue(value);
}

function normalizeTakeStatus(value, legacyGoodTake) {
  const normalized = cleanValue(value);
  if (normalized === "过" || normalized === "_OK") return "过";
  if (
    normalized === "保" ||
    normalized === "_KP" ||
    /^(?:三角形?|triangle|△|▲)$/i.test(normalized)
  ) return "保";
  if (/^(?:废条|废|ng|x|×|✕|✖)$/i.test(normalized)) return "废条";
  if (legacyGoodTake === true) return "过";
  if (legacyGoodTake === false) return "保";
  return "";
}

function commentValueForTakeStatus(takeStatus, comments) {
  if (takeStatus === "过") return comments.goodTake;
  if (takeStatus === "保") return comments.holdTake;
  return "";
}

// Resolve serializes take status in Comments using the configured markers;
// anything outside the marker set (or its legacy _OK/_KP aliases) is cleared.
export function canonicalResolveComment(value, comments = DEFAULT_RESOLVE_COMMENTS) {
  const normalized = cleanValue(value).toUpperCase();
  if (normalized === cleanValue(comments.goodTake).toUpperCase()) {
    return comments.goodTake;
  }
  if (normalized === cleanValue(comments.holdTake).toUpperCase()) {
    return comments.holdTake;
  }
  if (normalized === "OK" || normalized === "_OK") return comments.goodTake;
  if (normalized === "KP" || normalized === "_KP") return comments.holdTake;
  return "";
}

function buildMetadataRowIndex(rows, columns, warnings) {
  const index = new Map();
  for (const [rowNumber, row] of rows.entries()) {
    const identity = identifyMetadataRow(row, columns);
    if (identity.conflict) {
      warnings.push(
        `CSV 第 ${rowNumber + 2} 行的卷名与文件名指向不同素材，已跳过该行。`,
      );
      continue;
    }
    if (!identity.key) continue;
    if (!index.has(identity.key)) index.set(identity.key, []);
    index.get(identity.key).push(rowNumber);
  }
  return index;
}

function compareCanonicalMaterialKeys(left, right) {
  const leftParts = parseCanonicalMaterialKey(left);
  const rightParts = parseCanonicalMaterialKey(right);
  if (!leftParts || !rightParts) return String(left).localeCompare(String(right));
  return (
    leftParts.camera.localeCompare(rightParts.camera) ||
    leftParts.reel - rightParts.reel ||
    leftParts.clip - rightParts.clip
  );
}

function compactMaterialRanges(keys) {
  const groups = new Map();
  for (const key of keys) {
    const parsed = parseCanonicalMaterialKey(key);
    if (!parsed) continue;
    const reelKey = `${parsed.camera}:${parsed.reel}`;
    const clips = groups.get(reelKey) || [];
    clips.push(parsed.clip);
    groups.set(reelKey, clips);
  }

  const ranges = [];
  for (const [reelKey, clips] of groups) {
    const [camera, reel] = reelKey.split(":");
    const reelLabel = `${camera}${String(Number(reel)).padStart(3, "0")}`;
    clips.sort((left, right) => left - right);
    let start = clips[0];
    let end = clips[0];
    const flush = () => {
      const startLabel = `C${String(start).padStart(3, "0")}`;
      const endLabel = `C${String(end).padStart(3, "0")}`;
      ranges.push(`${reelLabel} ${start === end ? startLabel : `${startLabel}–${endLabel}`}`);
    };
    for (const clip of clips.slice(1)) {
      if (clip === end + 1) {
        end = clip;
      } else {
        flush();
        start = clip;
        end = clip;
      }
    }
    flush();
  }
  return ranges.join("、");
}

function identifyMetadataRow(row, columns) {
  const reelKeys = uniqueKeys(
    columns.reelName.map((index) => extractCombinedMaterialKey(row[index])),
  );
  const fileKeys = uniqueKeys([
    ...columns.fileName.map((index) => extractCombinedMaterialKey(row[index])),
    ...columns.clipName.map((index) => extractCombinedMaterialKey(row[index])),
    ...columns.clipDirectory.map((index) =>
      extractCombinedMaterialKey(row[index]),
    ),
  ]);

  if (reelKeys.length > 1 || fileKeys.length > 1) {
    return { key: "", conflict: true };
  }
  if (reelKeys[0] && fileKeys[0] && reelKeys[0] !== fileKeys[0]) {
    return { key: "", conflict: true };
  }

  const cards = uniqueCards(
    columns.reelName.map((index) => parseCardNumber(row[index])),
  );
  const clips = uniqueClipOrdinals([
    ...columns.clipName.map((index) => extractLooseClipOrdinal(row[index])),
    ...columns.fileName.map((index) => extractLooseClipOrdinal(row[index])),
  ]);
  if (cards.length > 1 || clips.length > 1) {
    return { key: "", conflict: true };
  }
  const separateKey =
    cards[0] && clips[0] != null
      ? `${cards[0].camera}:${cards[0].reel}:${clips[0]}`
      : "";
  const combinedKey = reelKeys[0] || fileKeys[0] || "";
  if (separateKey && combinedKey && separateKey !== combinedKey) {
    return { key: "", conflict: true };
  }
  if (reelKeys[0] || separateKey || fileKeys[0]) {
    return {
      key: reelKeys[0] || separateKey || fileKeys[0],
      conflict: false,
    };
  }
  return { key: "", conflict: false };
}

function extractLooseClipOrdinal(value) {
  const text = String(value || "").toUpperCase();
  const match = text.match(/(?:^|[^A-Z0-9])C[\s_-]*0*(\d+)(?=[^0-9]|$)/);
  return match ? Number(match[1]) : null;
}

function parseCardNumber(value) {
  const normalized = canonicalRecognitionValue("cardNumber", value);
  if (!normalized) return null;
  return { camera: normalized.charAt(0), reel: Number(normalized.slice(1)) };
}

function rowDisplayName(row, columns) {
  for (const index of columns.fileName) {
    if (cleanValue(row[index])) return cleanValue(row[index]);
  }
  for (const index of columns.reelName) {
    if (cleanValue(row[index])) return cleanValue(row[index]);
  }
  return "";
}

function hasIdentifierColumns(columns) {
  return (
    columns.fileName.length > 0 ||
    columns.reelName.length > 0 ||
    columns.clipName.length > 0
  );
}

function findHeaderIndexes(headers, aliases) {
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

function detectDelimiter(text) {
  const counts = new Map([
    [",", 0],
    ["\t", 0],
    [";", 0],
  ]);
  let quoted = false;
  for (let index = 0; index < text.length; index += 1) {
    const char = text[index];
    if (char === '"') {
      if (quoted && text[index + 1] === '"') index += 1;
      else quoted = !quoted;
      continue;
    }
    if (!quoted && (char === "\r" || char === "\n")) break;
    if (!quoted && counts.has(char)) counts.set(char, counts.get(char) + 1);
  }
  return [...counts.entries()].sort((left, right) => right[1] - left[1])[0][0];
}

function detectLineEnding(text) {
  let quoted = false;
  for (let index = 0; index < text.length; index += 1) {
    const char = text[index];
    if (char === '"') {
      if (quoted && text[index + 1] === '"') index += 1;
      else quoted = !quoted;
      continue;
    }
    if (quoted) continue;
    if (char === "\r") return text[index + 1] === "\n" ? "\r\n" : "\r";
    if (char === "\n") return "\n";
  }
  return "\r\n";
}

function encodeText(text, encoding, includeBom) {
  if (encoding === "utf-16le" || encoding === "utf-16be") {
    const bomBytes = includeBom ? 2 : 0;
    const bytes = new Uint8Array(bomBytes + text.length * 2);
    const littleEndian = encoding === "utf-16le";
    if (includeBom) {
      bytes[0] = littleEndian ? 0xff : 0xfe;
      bytes[1] = littleEndian ? 0xfe : 0xff;
    }
    for (let index = 0; index < text.length; index += 1) {
      const codeUnit = text.charCodeAt(index);
      const offset = bomBytes + index * 2;
      bytes[offset] = littleEndian ? codeUnit & 0xff : codeUnit >> 8;
      bytes[offset + 1] = littleEndian ? codeUnit >> 8 : codeUnit & 0xff;
    }
    return bytes;
  }

  const encoded = new TextEncoder().encode(text);
  if (!includeBom) return encoded;
  const bytes = new Uint8Array(encoded.length + 3);
  bytes.set([0xef, 0xbb, 0xbf], 0);
  bytes.set(encoded, 3);
  return bytes;
}

function defaultFormat() {
  return {
    encoding: "utf-16le",
    bom: true,
    delimiter: ",",
    lineEnding: "\r\n",
    finalNewline: true,
  };
}

function normalizeRowWidth(row, width) {
  const normalized = Array.from(row || [], stringValue).slice(0, width);
  while (normalized.length < width) normalized.push("");
  return normalized;
}

function uniqueKeys(values) {
  return [...new Set(values.filter(Boolean))];
}

function uniqueCards(values) {
  const byKey = new Map();
  for (const card of values.filter(Boolean)) {
    byKey.set(`${card.camera}:${card.reel}`, card);
  }
  return [...byKey.values()];
}

function uniqueClipOrdinals(values) {
  return [...new Set(values.filter((value) => value != null))];
}

function groupBy(values, keyOf) {
  const groups = new Map();
  for (const value of values) {
    const key = keyOf(value);
    if (!groups.has(key)) groups.set(key, []);
    groups.get(key).push(value);
  }
  return groups;
}

function normalizeToken(value) {
  return String(value || "").toUpperCase().replace(/[^A-Z0-9]/g, "");
}

function stringValue(value) {
  return value == null ? "" : String(value);
}

function csvCell(value, delimiter) {
  const string = value == null ? "" : String(value);
  return string.includes(delimiter) || /["\r\n]/.test(string)
    ? `"${string.replaceAll('"', '""')}"`
    : string;
}

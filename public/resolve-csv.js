// DaVinci Resolve CSV parsing and slate metadata backfill.
//
// Decodes Resolve's exported CSV, matches its rows to recognized slate records
// and camera sidecar metadata (frame rate, shoot day), merges them into a
// Resolve-ready table, and encodes the result back to CSV. Also re-exports the
// shared metadata helpers from metadata-common.js / metadata-sources/.
import {
  canonicalKeyToMaterialPrefix,
  chineseNumeralsToArabic,
  cleanValue,
  detectCsvFormat,
  extractCombinedMaterialKey,
  normalizeCameraFps,
  normalizeShootDay,
  parseCanonicalMaterialKey,
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
  cameraFps: ["Camera FPS", "CameraFPS", "摄影机帧率", "攝影機幀率"],
  shootDay: ["Shoot Day", "ShootDay", "拍摄日期", "拍攝日期"],
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

const TARGET_COLUMN_FIELDS = new Set(
  [...TARGET_COLUMNS, ...SLATE_METADATA_COLUMNS].map((target) => target.field),
);

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

const FIELD_NUMBER_LIMIT = 10 ** 6;

export function decodeResolveCsv(input) {
  const bytes =
    input instanceof Uint8Array
      ? input
      : input instanceof ArrayBuffer
        ? new Uint8Array(input)
        : null;
  if (!bytes?.length) throw new Error("CSV 文件为空");

  const format = detectCsvFormat(bytes);
  let text;
  try {
    text = new TextDecoder(format.encoding, { fatal: true }).decode(
      bytes.subarray(format.bomBytes),
    );
  } catch {
    throw new Error("无法读取 CSV 编码；请从 Resolve 重新导出 UTF-8 或 UTF-16 CSV。");
  }

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
    format: {
      encoding: format.encoding,
      bom: format.bomBytes > 0,
      delimiter,
      lineEnding: detectLineEnding(text),
      finalNewline: /(?:\r\n|\n|\r)$/.test(text),
    },
  };
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
    let sensorFps = "";
    if (sensorFpsValues.size > 1) {
      warnings.push(
        `${canonicalKeyToMaterialPrefix(materialKey)} 的 slate.txt 存在互相冲突或无效的 Sensor FPS，Camera FPS 不会写入。`,
      );
    } else if (sensorFpsValues.size === 1) {
      sensorFps = [...sensorFpsValues][0];
    }

    const shootDayValues = new Set(
      group.map((entry) => normalizeShootDay(entry.shootDay)).filter(Boolean),
    );
    let shootDay = "";
    if (shootDayValues.size > 1) {
      warnings.push(
        `${canonicalKeyToMaterialPrefix(materialKey)} 的 slate.txt 存在互相冲突的 Shot Date，Shoot Day 不会写入。`,
      );
    } else if (shootDayValues.size === 1) {
      shootDay = [...shootDayValues][0];
    }

    if (!sensorFps && !shootDay) continue;
    byMaterialKey.set(materialKey, {
      materialKey,
      sensorFps,
      shootDay,
      sourceNames: group.map((entry) => entry.sourceName).filter(Boolean),
    });
  }

  return { byMaterialKey, warnings };
}

export function mergeSlateIntoResolveTable(
  sourceTable,
  records,
  slateMetadata = [],
  options = {},
) {
  if (!sourceTable?.headers || !Array.isArray(sourceTable.rows)) {
    throw new Error("尚未载入有效的 Resolve CSV");
  }

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

  let columns = resolveColumnIndexes(headers);
  const columnsToEnsure = slateMetadata.length
    ? [...TARGET_COLUMNS, ...SLATE_METADATA_COLUMNS]
    : TARGET_COLUMNS;
  for (const target of columnsToEnsure) {
    if (columns[target.field] >= 0) continue;
    headers.push(target.header);
    for (const row of rows) row.push("");
    addedColumns.push(target.header);
    warnings.push(`原 CSV 缺少 ${target.header} 列，已按 Resolve 字段名添加。`);
    columns = resolveColumnIndexes(headers);
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
  // trustworthy material identity. Apply it independently so incomplete or
  // conflicting Scene/Shot/Take recognition cannot suppress these fields.
  for (const key of recognizedMaterialKeys) {
    const matchedRows = rowIndex.get(key) || [];
    if (!matchedRows.length) continue;

    const slateEntry = slateIndex.byMaterialKey.get(key);
    const slateFields = [
      {
        field: "cameraFps",
        value: slateEntry?.sensorFps || "",
        matchedRows: cameraFpsMatchedRows,
        missingKeys: missingCameraFpsKeys,
      },
      {
        field: "shootDay",
        value: slateEntry?.shootDay || "",
        matchedRows: shootDayMatchedRows,
        missingKeys: missingShootDayKeys,
      },
    ];

    for (const slateField of slateFields) {
      if (!slateField.value) {
        if (slateMetadata.length) slateField.missingKeys.add(key);
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
          const fileName = rowDisplayName(row, columns) ||
            canonicalKeyToMaterialPrefix(key);
          warnings.push(
            `CSV 第 ${rowNumber + 2} 行 ${fileName} 已覆盖：${headers[columnIndex]}“${previous}”→“${next}”。`,
          );
        }
      }
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
      `完整性对账：Resolve CSV 中有 ${unrecognizedMaterials.length} 个素材未在场记识别结果中出现（${compactMaterialRanges(unrecognizedMaterialKeys)}）。这些行不会自动回填，请检查是否漏页或漏识别。`,
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

    const values = {
      scene: normalizeSceneValue(record.scene, fieldFormats.scene),
      shot: normalizeShotValue(record.shot, fieldFormats.shot),
      take: normalizeTakeValue(record.take, fieldFormats.take),
      takeStatus: normalizeTakeStatus(record.takeStatus, record.goodTake),
    };
    values.comments = commentValueForTakeStatus(values.takeStatus, commentsConfig);
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
      `Sensor FPS 对账：${sortedKeys.length} 个已识别且匹配 CSV 的素材没有可用 slate.txt（${compactMaterialRanges(sortedKeys)}），其 Camera FPS 保持原值。`,
    );
  }

  if (missingShootDayKeys.size) {
    const sortedKeys = [...missingShootDayKeys].sort(
      compareCanonicalMaterialKeys,
    );
    warnings.push(
      `Shoot Day 对账：${sortedKeys.length} 个已识别且匹配 CSV 的素材没有可用 Shot Date（${compactMaterialRanges(sortedKeys)}），其 Shoot Day 保持原值。`,
    );
  }

  // Canonicalize the entire Scene/Shot/Take table, not only rows matched in
  // this run. Numeric scenes use XXX, while suffixes and multi-scene values
  // are kept and uppercased (87a becomes 87A, 58 / 59 stays 58 / 59).
  for (const [rowNumber, row] of rows.entries()) {
    for (const target of FIXED_WIDTH_METADATA_FIELDS) {
      const columnIndex = columns[target.field];
      const previous = cleanValue(row[columnIndex]);
      const next = normalizeMetadataField(
        target.field,
        previous,
        fieldFormats,
      );
      if (previous === next) continue;
      row[columnIndex] = next;
      changes.push({
        rowIndex: rowNumber,
        field: target.field,
        header: headers[columnIndex],
        previous,
        next,
      });
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

export function encodeResolveCsv(table, options = {}) {
  if (!table?.headers || !Array.isArray(table.rows)) {
    throw new Error("没有可编码的 CSV 表格");
  }
  const format = { ...defaultFormat(), ...(table.format || {}) };
  const delimiter = format.delimiter || ",";
  const headers = table.headers.map(stringValue);
  const columns = resolveColumnIndexes(headers);
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
  const matrix = [
    headers,
    ...rows,
  ];
  let text = matrix
    .map((row) => row.map((value) => csvCell(value, delimiter)).join(delimiter))
    .join(format.lineEnding);
  if (format.finalNewline) text += format.lineEnding;
  return encodeText(text, format.encoding, format.bom);
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

export function resolveColumnIndexes(headers) {
  const indexes = {};
  for (const [field, aliases] of Object.entries(HEADER_ALIASES)) {
    const matches = findHeaderIndexes(headers, aliases);
    if (TARGET_COLUMN_FIELDS.has(field) && matches.length > 1) {
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
  const columns = resolveColumnIndexes(table.headers);
  const index = buildMetadataRowIndex(table.rows, columns, warnings);
  return {
    keys: [...index.keys()].sort(compareCanonicalMaterialKeys),
    warnings,
  };
}

export function canonicalMaterialKey(cardNumber, videoCode) {
  const card = parseCardNumber(cardNumber);
  const video = normalizeClipNumber(videoCode);
  if (!card || !video) return "";
  return `${card.camera}:${card.reel}:${Number(video.slice(1))}`;
}

export function materialPrefix(cardNumber, videoCode) {
  const card = normalizeToken(cardNumber);
  const video = normalizeClipNumber(videoCode);
  if (!parseCardNumber(card) || !video) return null;
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
    const card = parseCardNumber(record?.cardNumber);
    const clipCode = normalizeClipNumber(record?.videoCode);
    if (!card || !clipCode) return;
    const reelKey = `${card.camera}${card.reel}`;
    const group = byReel.get(reelKey) || [];
    group.push({ record, index, clip: Number(clipCode.slice(1)) });
    byReel.set(reelKey, group);
  });

  const numberValue = (value) =>
    /^\d+$/.test(String(value || "")) ? Number(value) : null;
  const needsReview = (record, field) =>
    Array.isArray(record?.reviewRequiredFields) &&
    record.reviewRequiredFields.includes(field);
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
      const previousTake = numberValue(previous.record.take);
      const currentTake = numberValue(current.record.take);
      const previousShot = numberValue(previous.record.shot);
      const currentShot = numberValue(current.record.shot);
      if (
        previousTake == null ||
        currentTake == null ||
        !previous.record.scene ||
        !current.record.scene ||
        previous.record.scene !== current.record.scene
      ) {
        continue;
      }

      if (previousShot != null && currentShot != null && previousShot === currentShot) {
        if (currentTake === previousTake) {
          anomalies.push({
            key,
            type: "take-sequence",
            message: `与上一条同为 ${current.record.scene} ${current.record.shot} 镜 ${currentTake} 次，次序可能重复`,
          });
        } else if (currentTake > previousTake + 1) {
          anomalies.push({
            key,
            type: "take-sequence",
            message: `${current.record.scene} ${current.record.shot} 镜的次从 ${previousTake} 跳到 ${currentTake}，中间可能漏 ${currentTake - previousTake - 1} 条`,
          });
        } else if (currentTake < previousTake) {
          anomalies.push({
            key,
            type: "take-sequence",
            message: `${current.record.scene} ${current.record.shot} 镜的次从 ${previousTake} 回落到 ${currentTake}`,
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
        anomalies.push({
          key,
          type: "take-sequence",
          message: `进入 ${current.record.scene} ${current.record.shot} 镜的第一条次为 ${currentTake}，通常应从 1 开始`,
        });
      }
    }
  }
  return anomalies;
}

export function normalizeClipNumber(value) {
  let video = normalizeToken(value);
  const combined = video.match(/^[A-Z]+\d+C(\d+)$/);
  if (combined) video = combined[1];

  const match = video.match(/^C?(\d+)$/);
  if (!match) return "";

  let digits = match[1];
  while (digits.length > 3 && digits.startsWith("0")) {
    digits = digits.slice(1);
  }
  if (digits.length > 3) return "";

  digits = digits.padStart(3, "0");
  if (!digits.startsWith("0")) return "";
  return `C${digits}`;
}

export function normalizeSceneValue(value, format = "XXX") {
  return normalizeSceneCode(
    chineseNumeralsToArabic(value),
    fieldFormatWidth(format, 3),
  );
}

export function normalizeShotValue(value, format = "XX") {
  return normalizeFixedWidthNumber(
    chineseNumeralsToArabic(value),
    fieldFormatWidth(format, 2),
  );
}

export function normalizeTakeValue(value, format = "XX") {
  return normalizeFixedWidthNumber(
    chineseNumeralsToArabic(value),
    fieldFormatWidth(format, 2),
  );
}

// Builds a Resolve-compatible table straight from recognized records, so a
// slate can be processed without loading an existing metadata CSV. Rows with
// incomplete Scene/Shot/Take are skipped; Comments pass through as recognized.
export function buildStandaloneResolveTable(records = [], options = {}) {
  const fieldFormats = resolveFieldFormats(options.fieldFormats);
  const headers = ["Scene", "Shot", "Take", "Comments"];
  const rows = [];
  for (const record of records) {
    const scene = normalizeSceneValue(record?.scene, fieldFormats.scene);
    const shot = normalizeShotValue(record?.shot, fieldFormats.shot);
    const take = normalizeTakeValue(record?.take, fieldFormats.take);
    if (!scene || !shot || !take) continue;
    rows.push([scene, shot, take, String(record?.comments || "")]);
  }
  return { headers, rows };
}

function normalizeFixedWidthNumber(value, width) {
  const match = cleanValue(value).match(/\d+/);
  if (!match) return "";
  const number = Number(match[0]);
  if (
    !Number.isSafeInteger(number) ||
    number < 0 ||
    number >= FIELD_NUMBER_LIMIT
  ) {
    return "";
  }
  return String(number).padStart(width, "0");
}

// Keep every scene token and use the canonical " / " separator for
// multi-scene values instead of dropping all but the last number; suffix
// letters are always uppercase.
function normalizeSceneCode(value, width) {
  const normalized = cleanValue(value).toUpperCase();
  const matches = [...normalized.matchAll(/(\d+)\s*([A-Z]+)?/g)];
  if (!matches.length) return "";

  const parts = matches.map((match) => {
    const number = Number(match[1]);
    if (
      !Number.isSafeInteger(number) ||
      number < 0 ||
      number >= FIELD_NUMBER_LIMIT
    ) {
      return null;
    }
    const suffix = match[2] || "";
    return suffix ? `${number}${suffix}` : String(number);
  });
  if (parts.some((part) => part == null)) return "";
  if (parts.length > 1 || /[A-Z]/.test(parts[0])) return parts.join(" / ");
  return parts[0].padStart(width, "0");
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
  if (field === "scene") return normalizeSceneValue(value, formats.scene);
  if (field === "shot") return normalizeShotValue(value, formats.shot);
  if (field === "take") return normalizeTakeValue(value, formats.take);
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
  const match = normalizeToken(value).match(/^([A-Z]+)0*(\d+)$/);
  if (!match) return null;
  return { camera: match[1], reel: Number(match[2]) };
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

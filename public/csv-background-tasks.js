// Pure CSV jobs executed by the renderer's module Worker.
//
// Keeping decode, merge, normalization, and encoding in one stateful processor
// lets the Worker retain the large source Resolve table. Export requests then
// send only the comparatively small recognition/edit payload back to it.
import {
  buildStandaloneResolveTable,
  decodeResolveCsv,
  encodeResolveCsv,
  mergeSlateIntoResolveTable,
} from "./resolve-csv.js";

const EDIT_KEY_PATTERN = /^(\d+):(\d+)$/;

export function createCsvTaskProcessor() {
  let metadataTable = null;

  return function processCsvTask(task = {}) {
    switch (task.type) {
      case "decode-metadata": {
        metadataTable = decodeResolveCsv(task.data);
        return { table: metadataTable };
      }
      case "prime-metadata": {
        assertTable(task.table);
        metadataTable = task.table;
        return { ready: true };
      }
      case "clear-metadata": {
        metadataTable = null;
        return { ready: false };
      }
      case "export-resolve": {
        assertTable(metadataTable);
        const records = Array.isArray(task.records) ? task.records : [];
        const edits = normalizeEdits(task.csvEdits);
        const output = mergeSlateIntoResolveTable(
          metadataTable,
          records,
          Array.isArray(task.slateMetadata) ? task.slateMetadata : [],
          {
            fieldFormats: task.fieldFormats,
            comments: task.comments,
          },
        );
        if (!records.length || (!output.exportableCount && !edits.length)) {
          throw new Error("没有匹配到可写入的完整记录，请检查卷号、视频码、场次、镜和次。");
        }
        const table = applySparseCsvEdits(output.table, edits);
        return {
          bytes: encodeResolveCsv(table, {
            fieldFormats: task.fieldFormats,
            comments: task.comments,
            // Resolve Comments only accepts the configured take-status markers.
            canonicalizeComments: true,
          }),
        };
      }
      case "export-standalone": {
        const table = buildStandaloneResolveTable(task.records, {
          fieldFormats: task.fieldFormats,
          comments: task.comments,
        });
        if (!table.rows.length) {
          throw new Error("没有场次、镜、次完整的识别记录可导出。");
        }
        return {
          bytes: encodeResolveCsv(table, {
            fieldFormats: task.fieldFormats,
            comments: task.comments,
          }),
        };
      }
      default:
        throw new Error(`未知 CSV 后台任务：${String(task.type || "")}`);
    }
  };
}

function assertTable(table) {
  if (!table?.headers || !Array.isArray(table.rows)) {
    throw new Error("尚未载入有效的 Resolve CSV");
  }
}

function normalizeEdits(edits) {
  return (Array.isArray(edits) ? edits : [])
    .map(([key, value]) => {
      const match = String(key).match(EDIT_KEY_PATTERN);
      return match
        ? [Number(match[1]), Number(match[2]), String(value ?? "")]
        : null;
    })
    .filter(Boolean);
}

// Manual edits are sparse in normal use. Clone only rows that are actually
// touched instead of copying every cell in a potentially very large CSV.
function applySparseCsvEdits(table, edits) {
  if (!edits.length) return table;
  const rows = table.rows.slice();
  const copiedRows = new Set();
  for (const [rowIndex, columnIndex, value] of edits) {
    if (!rows[rowIndex] || columnIndex >= table.headers.length) continue;
    if (!copiedRows.has(rowIndex)) {
      rows[rowIndex] = rows[rowIndex].slice();
      copiedRows.add(rowIndex);
    }
    rows[rowIndex][columnIndex] = value;
  }
  return { ...table, rows };
}

// Pure CSV jobs executed by the renderer's module Worker.
//
// Keeping decode, merge, normalization, and encoding in one stateful processor
// lets the Worker retain the large source Resolve table. Export requests then
// send only the comparatively small recognition/edit payload back to it.
import {
  buildStandaloneResolveTable,
  collectResolveMaterialKeys,
  decodeResolveCsv,
  encodeResolveCsv,
  mergeSlateIntoResolveTable,
} from "./resolve-csv.js";
import { parseSlateCsv } from "./slate-csv-parser.js";

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
      case "collect-material-keys": {
        assertTable(metadataTable);
        const materialKeys = collectResolveMaterialKeys(metadataTable);
        return { keys: materialKeys.keys, warnings: materialKeys.warnings };
      }
      case "decode-slate-csv": {
        const bytes = task.data instanceof ArrayBuffer
          ? new Uint8Array(task.data)
          : task.data instanceof Uint8Array
            ? task.data
            : null;
        if (!bytes?.length) throw new Error("场记 CSV 文件为空");
        const text = new TextDecoder("utf-8", { fatal: true }).decode(bytes).replace(/^\uFEFF/, "");
        return parseSlateCsv(text);
      }
      case "records-from-slate-csv": {
        return { records: recognitionRecordsFromSlateCsv(task.records) };
      }
      case "merge-preview": {
        assertTable(metadataTable);
        // Reuse the authoritative merge algorithm for the visible preview;
        // export still starts from the retained raw table and applies edits.
        const output = mergeSlateIntoResolveTable(
          metadataTable,
          Array.isArray(task.records) ? task.records : [],
          Array.isArray(task.slateMetadata) ? task.slateMetadata : [],
          {
            fieldFormats: task.fieldFormats,
            comments: task.comments,
          },
        );
        return { table: output.table };
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
        // Exporting without any recognized records, or with records none of
        // which actually matched a row in this CSV, is a reel/video-code
        // mismatch worth surfacing. Judging by matchedRecordCount (not
        // exportableCount) keeps slate fps backfills from masking the mismatch.
        if (
          !records.length ||
          (!output.matchedRecordCount && !edits.length)
        ) {
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

function recognitionRecordsFromSlateCsv(records) {
  return (Array.isArray(records) ? records : []).map((record, index) => {
    const key = String(record?.materialKey || "").toUpperCase();
    const match = key.match(/^([A-Z]+\d+)(C\d+)$/);
    return {
      id: `slate-csv-${index}`,
      sourcePage: null,
      cardNumber: record?.cardNumber || match?.[1] || null,
      videoCode: record?.videoCode || match?.[2] || null,
      scene: record?.scene || null,
      shot: record?.shot || null,
      take: record?.take || null,
      takeStatus: record?.comments || null,
      description: null,
      comments: null,
      shotSize: null,
      cameraPosition: null,
      confidence: "high",
    };
  });
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

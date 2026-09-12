// Pure CSV jobs executed by the renderer's module Worker.
//
// Keeping decode, merge, normalization, and encoding in one stateful processor
// lets the Worker retain the large source Resolve table. Export requests then
// send only the comparatively small recognition/edit payload back to it.
import {
  buildSemanticExportTable,
  collectResolveMaterialKeys,
  decodeResolveCsv,
  encodeResolveCsv,
} from "./resolve-csv.js";
import { manualRecognitionTargetId } from "./recognition-target.js";
import { parseSlateCsv } from "./slate-csv-parser.js";

export function createCsvTaskProcessor() {
  let metadataTable = null;

  return function processCsvTask(task = {}) {
    switch (task.type) {
      case "decode-metadata": {
        metadataTable = decodeResolveCsv(task.data, { sourceEncoding: task.sourceEncoding });
        return { table: metadataTable };
      }
      case "prime-metadata": {
        assertTable(task.table);
        // Upgrade old task tables in the Worker-owned copy only; the persisted
        // snapshot remains byte-compatible while exports gain source metadata.
        metadataTable = sourceAwareTable({
          ...task.table,
          ...(task.semanticColumns ? { semanticColumns: task.semanticColumns } : {}),
          ...(task.sourceEncoding && !task.table.sourceEncoding ? { sourceEncoding: task.sourceEncoding } : {}),
        });
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
      case "merge-preview":
      case "export-resolve":
      case "export-standalone":
      case "standalone-preview": {
        const mode = task.type.includes("standalone") ? "standalone" : "resolve";
        if (mode === "resolve") assertTable(metadataTable);
        // All clients and infrastructure fallbacks use this exact builder;
        // retained source state is never replaced by preview or export output.
        const records = Array.isArray(task.records) ? task.records : [];
        const output = buildSemanticExportTable({
          ...task, mode, sourceTable: metadataTable, records,
          slateMetadata: Array.isArray(task.slateMetadata) ? task.slateMetadata : [],
        });
        if (task.type.endsWith("preview")) return { table: output.table, semanticColumns: output.semanticColumns, resolvedFilename: output.resolvedFilename };
        if (mode === "resolve" && (!records.length || (!output.matchedRecordCount && !output.appliedEditCount))) {
          throw new Error("没有匹配到可写入的完整记录，请检查卷号、视频码、场次、镜和次。");
        }
        if (mode === "standalone" && !output.table.rows.length) {
          throw new Error("没有场次、镜、次完整的识别记录可导出。");
        }
        return { bytes: encodeResolveCsv(output.table), resolvedFilename: output.resolvedFilename };
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
      targetId: manualRecognitionTargetId(`slate-csv-${index}`),
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

function sourceAwareTable(table) {
  if (table.sourceEncoding || !table.format?.encoding) return table;
  return {
    ...table,
    sourceEncoding: table.format.encoding,
  };
}

function assertTable(table) {
  if (!table?.headers || !Array.isArray(table.rows)) {
    throw new Error("尚未载入有效的 Resolve CSV");
  }
}

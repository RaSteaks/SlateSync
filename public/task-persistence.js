// Serializable task snapshots for the Resolve CSV preview.
//
// The renderer keeps the source table and manual cell overrides in memory,
// while the task store only accepts JSON. These helpers keep the snapshot
// format explicit and rebuild a safe table/Map when an older task is loaded.

const EDIT_KEY_PATTERN = /^\d+:\d+$/;

export function serializeCsvPreviewState({
  metadataTable,
  metadataFilename,
  csvEdits,
  slateMetadata = [],
  slateWarnings = [],
  missingMetadataKeys = [],
  slateDirectoryName = "",
} = {}) {
  return {
    resolveCsvFilename: cleanFilename(metadataFilename),
    resolveCsvTable: cloneTable(metadataTable),
    resolveCsvEdits: serializeEdits(csvEdits),
    slateMetadata: Array.isArray(slateMetadata)
      ? slateMetadata.map((entry) => ({ ...entry }))
      : [],
    slateWarnings: Array.isArray(slateWarnings)
      ? slateWarnings.map((warning) => String(warning))
      : [],
    missingMetadataKeys: Array.isArray(missingMetadataKeys)
      ? missingMetadataKeys.map((key) => String(key))
      : [],
    slateDirectoryName: cleanFilename(slateDirectoryName),
  };
}

export function restoreCsvPreviewState(task = {}) {
  const metadataTable = cloneTable(task.resolveCsvTable);
  if (!metadataTable) return null;

  const edits = new Map();
  for (const [key, value] of Object.entries(task.resolveCsvEdits || {})) {
    if (EDIT_KEY_PATTERN.test(key)) edits.set(key, String(value ?? ""));
  }

  return {
    metadataTable,
    metadataFilename: cleanFilename(task.resolveCsvFilename) || "Resolve.csv",
    csvEdits: edits,
    slateMetadata: Array.isArray(task.slateMetadata)
      ? task.slateMetadata.map((entry) => ({ ...entry }))
      : [],
    slateWarnings: Array.isArray(task.slateWarnings)
      ? task.slateWarnings.map((warning) => String(warning))
      : [],
    missingMetadataKeys: Array.isArray(task.missingMetadataKeys)
      ? task.missingMetadataKeys.map((key) => String(key))
      : [],
    slateDirectoryName: cleanFilename(task.slateDirectoryName),
  };
}

function serializeEdits(edits) {
  const entries = edits instanceof Map
    ? [...edits.entries()]
    : Object.entries(edits || {});
  return Object.fromEntries(
    entries
      .filter(([key]) => EDIT_KEY_PATTERN.test(String(key)))
      .map(([key, value]) => [String(key), String(value ?? "")]),
  );
}

function cloneTable(table) {
  if (!table || !Array.isArray(table.headers) || !Array.isArray(table.rows)) {
    return null;
  }
  const headers = table.headers.map((header) => String(header));
  return {
    headers,
    rows: table.rows.map((row) =>
      Array.from({ length: headers.length }, (_, index) =>
        String(row?.[index] ?? ""),
      ),
    ),
    format: table.format && typeof table.format === "object"
      ? { ...table.format }
      : {},
  };
}

function cleanFilename(value) {
  const filename = String(value || "").trim();
  return filename || null;
}

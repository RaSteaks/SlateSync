// Pure workflow gating predicates for the renderer.
//
// Centralizes the "can I do X yet?" rules (start recognition, load a CSV,
// merge slate metadata, export) so the UI stays consistent as state changes.
export function canStartRecognition({
  reportReady,
  providerConfigured,
  modelSelected,
}) {
  return Boolean(reportReady && providerConfigured && modelSelected);
}

export function canMergeSlateCsv({
  slateCsvLoaded,
  metadataLoaded,
}) {
  return Boolean(slateCsvLoaded && metadataLoaded);
}

export function canExportResolveCsv({
  metadataLoaded,
  recordCount,
  exportableCount,
  hasManualEdits = false,
}) {
  // A user-edited preview is itself a valid export change, even when the
  // automatic merge did not alter any Resolve rows.
  return Boolean(
    metadataLoaded &&
      recordCount > 0 &&
      (exportableCount > 0 || hasManualEdits),
  );
}

export function canLoadResolveCsv({ reportReady, slateCsvLoaded }) {
  // Allow loading Resolve CSV when a slate CSV is present (validation mode)
  // even without a slate report file.
  return Boolean(reportReady || slateCsvLoaded);
}

export function canLoadSlateCsv() {
  // Slate CSV can always be loaded independently.
  return true;
}

export function shouldResetSlateCsvResults(inputMode) {
  return inputMode === "slate-csv";
}

export function canSelectSlateDirectory({ reportReady, metadataLoaded }) {
  return Boolean(reportReady && metadataLoaded);
}

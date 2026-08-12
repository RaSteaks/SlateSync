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
}) {
  return Boolean(metadataLoaded && recordCount > 0 && exportableCount > 0);
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

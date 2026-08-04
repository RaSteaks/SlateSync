export function canStartRecognition({
  reportReady,
  providerConfigured,
  modelSelected,
}) {
  return Boolean(reportReady && providerConfigured && modelSelected);
}

export function canExportResolveCsv({
  metadataLoaded,
  recordCount,
  exportableCount,
}) {
  return Boolean(metadataLoaded && recordCount > 0 && exportableCount > 0);
}

export function canLoadResolveCsv({ reportReady }) {
  return Boolean(reportReady);
}

export function canSelectSlateDirectory({ reportReady, metadataLoaded }) {
  return Boolean(reportReady && metadataLoaded);
}

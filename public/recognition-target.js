// Stable recognition identity helpers shared by Main-side result assembly and
// the Renderer. Target identity describes final-sheet position, not editable
// material fields, so retries and later corrections keep the same target.

export function recognitionTargetId(sourcePage, recordIndex) {
  const page = Number(sourcePage);
  const index = Number(recordIndex);
  if (!Number.isInteger(index) || index < 0) return null;
  const pagePart = Number.isInteger(page) && page >= 1 ? String(page) : "unknown";
  return `page:${pagePart}:record:${index}`;
}

export function isRecognitionTargetId(value) {
  return /^page:(?:unknown|[1-9]\d*):record:\d+$/.test(String(value || ""));
}

export function isManualRecognitionTargetId(value) {
  return /^manual:[a-zA-Z0-9._~-]+$/.test(String(value || ""));
}

export function restoreRecognitionTargetId(existing, sourcePage, recordIndex) {
  const target = String(existing || "").trim();
  if (isRecognitionTargetId(target) || isManualRecognitionTargetId(target)) return target;
  return recognitionTargetId(sourcePage, recordIndex)
    || manualRecognitionTargetId(`restored-${recordIndex}`);
}

export function manualRecognitionTargetId(seed) {
  const normalized = String(seed || "")
    .trim()
    .replace(/[^a-zA-Z0-9._~-]+/g, "-")
    .replace(/^-+|-+$/g, "");
  return `manual:${normalized || "record"}`;
}

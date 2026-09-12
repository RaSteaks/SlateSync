// High-accuracy crop recheck selection and result safety boundary.
//
// This module deliberately contains no provider or image-decoder dependency.
// OCR engines may attach a real cropDataUrl to a block; when they do, the
// selector can request a focused recheck. Without that crop (or a valid bbox),
// the target is skipped rather than asking a model to guess from an arbitrary
// region of the page.

import { canonicalRecognitionValue } from "../public/metadata-common.js";

export const CROP_RECHECK_FIELDS = Object.freeze([
  "cardNumber",
  "videoCode",
  "scene",
  "shot",
  "take",
]);

export const DEFAULT_CROP_RECHECK_CONFIG = Object.freeze({
  enabled: false,
  maxTargets: 12,
  timeoutMs: 120_000,
  batchSize: 3,
});

export function normalizeCropRecheckConfig(input = {}) {
  const enabled = booleanValue(input.enabled, false);
  // Zero is an intentional budget setting: it keeps the feature enabled for
  // diagnostics while guaranteeing that no provider request is made.
  const maxTargets = integerValue(input.maxTargets ?? input.SLATESYNC_CROP_RECHECK_MAX_TARGETS, 12, 0, 64);
  const timeoutMs = integerValue(input.timeoutMs, DEFAULT_CROP_RECHECK_CONFIG.timeoutMs, 5_000, 600_000);
  const batchSize = integerValue(input.batchSize, DEFAULT_CROP_RECHECK_CONFIG.batchSize, 1, 8);
  return { enabled, maxTargets, timeoutMs, batchSize };
}

export function emptyCropRecheckSummary(enabled = false) {
  return {
    enabled: Boolean(enabled),
    attempted: 0,
    confirmed: 0,
    rejected: 0,
    skipped: 0,
    batchCount: 0,
    selectedCount: 0,
    deduplicatedCount: 0,
    providerCallCount: 0,
    timedOut: false,
    canceled: false,
    warning: null,
  };
}

/**
 * Selects stable record-field targets from OCR evidence. The caller must pass
 * high-accuracy mode explicitly; this function will not broaden standard mode.
 */
export function selectCropRecheckTargets({ records = [], ocrResult = {}, imageDataGroups = [], accuracyMode = "standard" } = {}, config = {}) {
  const normalized = normalizeCropRecheckConfig(config);
  if (!normalized.enabled || accuracyMode !== "high") {
    return { targets: [], skipped: 0, deduplicated: 0, config: normalized };
  }
  if (normalized.maxTargets === 0) {
    return { targets: [], skipped: 0, deduplicated: 0, config: normalized };
  }
  const targets = [];
  let skipped = 0;
  let deduplicated = 0;
  const seen = new Set();
  const orderedRecords = (Array.isArray(records) ? records : [])
    .map((record, index) => ({ record, index }))
    .sort((left, right) => (Number(left.record?.sourcePage) || 0) - (Number(right.record?.sourcePage) || 0) || left.index - right.index);
  for (const { record } of orderedRecords) {
    const targetId = clean(record?.targetId);
    const sourcePage = Number(record?.sourcePage);
    if (!targetId || !Number.isInteger(sourcePage) || sourcePage < 1 || sourcePage > 10_000) {
      skipped += 1;
      continue;
    }
    for (const field of CROP_RECHECK_FIELDS) {
      const quality = record?.quality?.fields?.[field];
      const lowConfidence = quality?.confidence === "low" || record?.confidence === "low";
      const reviewRequired = Boolean(quality?.reviewRequired) || (Array.isArray(record?.reviewRequiredFields) && record.reviewRequiredFields.includes(field));
      if (!lowConfidence && !reviewRequired) continue;
      const value = clean(record?.[field]);
      if (!value) {
        skipped += 1;
        continue;
      }
      const page = ocrResult?.pages?.find((item) => Number(item?.pageNumber) === sourcePage);
      const evidence = hasUniqueFieldValue(orderedRecords, sourcePage, value)
        ? findEvidenceBlock(page, value)
        : null;
      const key = `${targetId}:${field}`;
      if (seen.has(key)) {
        deduplicated += 1;
        skipped += 1;
        continue;
      }
      if (!evidence) {
        skipped += 1;
        continue;
      }
      const pageImages = Array.isArray(imageDataGroups[sourcePage - 1]) ? imageDataGroups[sourcePage - 1] : [];
      // Bboxes are relative to the emitting view, which may be a lower-page crop.
      const coreImage = pageImages[evidence.viewIndex] || "";
      const cropImage = clean(evidence.block.cropImage || evidence.block.cropDataUrl || evidence.block.imageDataUrl);
      if (!coreImage || !cropImage || !validBbox(evidence.block.bboxNormalized)) {
        // A bbox by itself is evidence, not a crop. Do not silently send a
        // full page and label it as a focused recheck.
        skipped += 1;
        continue;
      }
      seen.add(key);
      targets.push({
        targetId,
        sourcePage,
        field,
        currentValue: value,
        coreImage,
        cropImage,
        bboxNormalized: evidence.block.bboxNormalized.map(Number),
        reason: reviewRequired ? "review-required" : "low-confidence",
      });
      if (targets.length >= normalized.maxTargets) return { targets, skipped, deduplicated, config: normalized };
    }
  }
  return { targets, skipped, deduplicated, config: normalized };
}

export function batchCropRecheckTargets(targets, batchSize = DEFAULT_CROP_RECHECK_CONFIG.batchSize) {
  const size = integerValue(batchSize, 3, 1, 8);
  const batches = [];
  for (let index = 0; index < (Array.isArray(targets) ? targets.length : 0); index += size) {
    batches.push(targets.slice(index, index + size));
  }
  return batches;
}

/** Apply only confirmed, normalized recheck values with a stale-value guard. */
export function applyCropRecheckResults(records = [], results = [], targets = [], options = {}) {
  const resultByKey = new Map();
  const targetByKey = new Map((Array.isArray(targets) ? targets : []).map((target) => [`${clean(target?.targetId)}:${clean(target?.field)}`, target]));
  for (const result of Array.isArray(results) ? results : []) {
    const key = `${clean(result?.targetId)}:${clean(result?.field)}`;
    if (!key.startsWith(":")) resultByKey.set(key, result);
  }
  let confirmed = 0;
  let rejected = 0;
  const nextRecords = (Array.isArray(records) ? records : []).map((record) => {
    let next = record;
    for (const field of CROP_RECHECK_FIELDS) {
      const key = `${clean(record?.targetId)}:${field}`;
      const result = resultByKey.get(key);
      if (!result) continue;
      const value = clean(result.value || result.candidate?.[field]);
      const currentValue = clean(record?.[field]);
      const target = targetByKey.get(key);
      const fieldQuality = record?.quality?.fields?.[field];
      const canReplace = !currentValue || fieldQuality?.reviewRequired === true || fieldQuality?.confidence === "low";
      const status = result.status || (result.confirmed === true ? "confirmed" : "failed");
      const sourcePageMatches = !result.sourcePage || Number(result.sourcePage) === Number(record?.sourcePage);
      const originalValueMatches = !target || clean(target.currentValue) === currentValue;
      const normalized = canonicalRecognitionValue(field, value, { fieldFormats: options.fieldFormats, confidence: result.confidence || "high" });
      if (status !== "confirmed" || !value || !normalized || !canReplace || !sourcePageMatches || !originalValueMatches) {
        if (status === "confirmed" && currentValue && !canReplace) confirmed += 1;
        else rejected += 1;
        continue;
      }
      const currentQuality = next.quality;
      const currentFieldQuality = currentQuality?.fields?.[field];
      // Legacy or hand-authored snapshots may carry reviewRequiredFields
      // without the newer quality.fields object; create additive provenance
      // instead of updating a value with no audit trail.
      const nextFieldQuality = currentFieldQuality || {
        field,
        originalValue: currentValue || null,
        normalizedValue: normalized,
        changed: currentValue !== normalized,
        confidence: result.confidence || "high",
        reviewRequired: true,
        warnings: [],
      };
      next = {
        ...next,
        [field]: normalized,
        quality: {
          ...(currentQuality || {}),
          fields: {
            ...(currentQuality?.fields || {}),
            [field]: { ...nextFieldQuality, cropRechecked: true },
          },
        },
      };
      confirmed += 1;
    }
    return next;
  });
  return { records: nextRecords, confirmed, rejected };
}

// Without row/column geometry, a repeated value cannot identify a cell.
// Count all records and fields, including high-confidence cells that are not
// themselves recheck targets; otherwise they can donate the wrong evidence.
function hasUniqueFieldValue(orderedRecords, sourcePage, value) {
  let count = 0;
  for (const { record } of orderedRecords) {
    if (Number(record?.sourcePage) !== sourcePage) continue;
    for (const field of CROP_RECHECK_FIELDS) {
      if (textMatches(record?.[field], value)) count += 1;
    }
  }
  return count === 1;
}

function findEvidenceBlock(page, value) {
  const blocks = (page?.views || []).flatMap((view, index) =>
    (view?.blocks || []).map((block) => ({ block, viewIndex: view.viewIndex ?? index })));
  const matches = blocks.filter(({ block }) => textMatches(block?.text, value));
  // Confidence measures transcription quality, not row identity. Multiple
  // regions/views remain ambiguous even when one score is much higher.
  if (matches.length !== 1 || !validBbox(matches[0].block?.bboxNormalized)) return null;
  return matches[0];
}

function textMatches(text, value) {
  const normalizedText = comparable(String(text || ""));
  const normalizedValue = comparable(String(value || ""));
  return Boolean(normalizedText && normalizedValue && normalizedText === normalizedValue);
}

function comparable(value) {
  // Preserve field punctuation: 1-2 and 12 are different scene values.
  return value.normalize("NFKC").trim().toLowerCase();
}

function validBbox(value) {
  return Array.isArray(value) && value.length === 4 && value.every((item) => Number.isFinite(Number(item)) && Number(item) >= 0 && Number(item) <= 1);
}

function booleanValue(value, fallback) {
  if (typeof value === "boolean") return value;
  const normalized = String(value ?? "").trim().toLowerCase();
  if (["1", "true", "yes", "on"].includes(normalized)) return true;
  if (["0", "false", "no", "off"].includes(normalized)) return false;
  return fallback;
}

function integerValue(value, fallback, minimum, maximum) {
  if (typeof value === "string" && !value.trim()) return fallback;
  const number = Number(value);
  return Number.isFinite(number) ? Math.max(minimum, Math.min(maximum, Math.trunc(number))) : fallback;
}

function clean(value) {
  return typeof value === "string" ? value.trim() : "";
}

// Vendor-neutral metadata helpers shared by every camera metadata source and
// the Resolve CSV merge layer. Kept free of any Kinefinity / ARRI / DJI / RED
// specifics so a new vendor only adds one adapter file under metadata-sources/.

export function cleanValue(value) {
  // NFKC folds full-width digits (０９ → 09) and circled digits (⑪ → 11) so
  // camera metadata and CSV cells compare cleanly against recognized values.
  return value == null ? "" : String(value).normalize("NFKC").trim();
}

// This module is deliberately dependency-free: the Node recognition path and
// both browser renderers import the same pure normalization functions. The
// final gate keeps uncertain text intact and records why a person must review
// it, rather than silently turning an OCR guess into a new material identity.
export const RECOGNITION_NUMERIC_FIELDS = Object.freeze([
  "cardNumber",
  "videoCode",
  "scene",
  "shot",
  "take",
]);

export const RECOGNITION_REVIEW_FIELD_ORDER = Object.freeze([
  "cardNumber",
  "videoCode",
  "scene",
  "shot",
  "take",
]);

const FIELD_NUMBER_LIMIT = 10 ** 6;
const CHINESE_NUMERAL_PATTERN = /[零〇一壹二两贰三叁四肆五伍六陆七柒八捌九玖十百]+/g;
const CHINESE_DIGITS = Object.freeze({
  零: 0,
  〇: 0,
  一: 1,
  壹: 1,
  二: 2,
  两: 2,
  贰: 2,
  三: 3,
  叁: 3,
  四: 4,
  肆: 4,
  五: 5,
  伍: 5,
  六: 6,
  陆: 6,
  七: 7,
  柒: 7,
  八: 8,
  捌: 8,
  九: 9,
  玖: 9,
});
const CHINESE_UNITS = Object.freeze({ 十: 10, 百: 100 });
const CONFUSABLE_DIGITS = Object.freeze({
  O: "0",
  o: "0",
  О: "0",
  о: "0",
  I: "1",
  i: "1",
  l: "1",
  "|": "1",
  丨: "1",
  S: "5",
  s: "5",
});
const WARNING_MESSAGES = Object.freeze({
  "ambiguous-numeric-token": "数值存在多种可能解释，请人工确认",
  "invalid-numeric-token": "数值格式无法确定，请人工确认",
  "out-of-range": "数值超出可安全处理范围，请人工确认",
  "confusable-character": "已按数字上下文转换易混淆字符，请人工确认",
  "chinese-numeral-converted": "已将中文数字归一化为阿拉伯数字，请人工确认",
  "missing-value": "字段缺失",
});

function isChineseDigit(char) {
  return Object.hasOwn(CHINESE_DIGITS, char);
}

function isArabicDigit(char) {
  return char != null && /^[0-9]$/.test(String(char).normalize("NFKC"));
}

// Parses only the supported slate vocabulary. Unit order and repeated units
// are checked explicitly so strings such as 十百、百十十、十一二 cannot be
// partially interpreted as a plausible number.
export function parseChineseNumber(text) {
  const normalized = String(text ?? "").normalize("NFKC");
  if (!normalized || [...normalized].some((char) =>
    !isChineseDigit(char) && !Object.hasOwn(CHINESE_UNITS, char)
  )) return null;

  const chars = [...normalized];
  const hasUnit = chars.some((char) => Object.hasOwn(CHINESE_UNITS, char));
  if (!hasUnit) {
    const digits = chars.map((char) => CHINESE_DIGITS[char]).join("");
    const value = Number(digits);
    return Number.isSafeInteger(value) && value >= 0 && value < FIELD_NUMBER_LIMIT
      ? value
      : null;
  }

  let total = 0;
  let pendingDigit = null;
  let lastUnit = Infinity;
  let zeroPlaceholder = false;
  for (const char of chars) {
    if (isChineseDigit(char)) {
      if (pendingDigit != null) {
        // A second digit is only valid after an explicit 零/〇 placeholder.
        if (pendingDigit !== 0) return null;
        zeroPlaceholder = true;
      }
      pendingDigit = CHINESE_DIGITS[char];
      continue;
    }

    const unit = CHINESE_UNITS[char];
    if (unit >= lastUnit) return null;
    const coefficient = pendingDigit == null ? 1 : pendingDigit;
    total += coefficient * unit;
    lastUnit = unit;
    if (pendingDigit === 0) zeroPlaceholder = true;
    pendingDigit = null;
  }

  // In this limited grammar “一百二” is ambiguous (120 vs 102); require the
  // explicit zero placeholder for a trailing digit after 百.
  if (lastUnit === 100 && pendingDigit != null && !zeroPlaceholder) return null;
  total += pendingDigit ?? 0;
  return Number.isSafeInteger(total) && total >= 0 && total < FIELD_NUMBER_LIMIT
    ? total
    : null;
}

export function chineseNumeralsToArabic(value) {
  const source = String(value ?? "");
  return source.replace(CHINESE_NUMERAL_PATTERN, (run, offset) => {
    const containsUnit = [...run].some((char) => Object.hasOwn(CHINESE_UNITS, char));
    // Do not convert only the Chinese part of a mixed token such as 1百 or
    // 一百5. A guessed partial conversion can look canonical and change the
    // material key, so the normalizer must retain the original for review.
    if (containsUnit && (isArabicDigit(source[offset - 1]) || isArabicDigit(source[offset + run.length]))) {
      return run;
    }
    const number = parseChineseNumber(run);
    if (number == null) return run;
    // Digit-by-digit runs retain leading zero meaning (〇七 → 07), while unit
    // expressions are emitted as their integer value (十一 → 11).
    return [...run].every(isChineseDigit)
      ? [...run].map((char) => CHINESE_DIGITS[char]).join("")
      : String(number);
  });
}

function fieldWidth(value, fallback) {
  const format = String(value || "").trim().toUpperCase();
  return /^X{1,6}$/.test(format) ? format.length : fallback;
}

function originalFieldValue(value) {
  if (value == null) return null;
  const original = String(value);
  return original.trim() ? original : null;
}

function warning(code, field, originalValue, normalizedValue) {
  return {
    code,
    field,
    message: WARNING_MESSAGES[code] || "需要人工确认",
    originalValue,
    normalizedValue,
  };
}

function uniqueWarnings(warnings) {
  const seen = new Set();
  return warnings.filter((item) => {
    const key = [item.code, item.field, item.originalValue, item.normalizedValue].join("\u0000");
    if (seen.has(key)) return false;
    seen.add(key);
    return true;
  });
}

function resultFor(field, originalValue, normalizedValue, confidence, reviewRequired, warnings = []) {
  const unique = uniqueWarnings(warnings);
  return {
    field,
    originalValue,
    normalizedValue,
    changed: originalValue !== normalizedValue,
    confidence,
    reviewRequired,
    warnings: [...unique],
  };
}

function failureCode(text, { multiple = false } = {}) {
  if (multiple || /[\/／、,，;；]/.test(text)) return "ambiguous-numeric-token";
  if (/[A-Za-zА-Яа-я]/.test(text)) return "ambiguous-numeric-token";
  return "invalid-numeric-token";
}

function mapConfusableNumericToken(value) {
  let converted = "";
  let used = false;
  for (const [index, char] of [...value].entries()) {
    const mapped = CONFUSABLE_DIGITS[char];
    if (!mapped) {
      converted += char;
      continue;
    }
    if ((char === "S" || char === "s") &&
      !/[0-9]/.test([...value][index - 1] || "") &&
      !/[0-9]/.test([...value][index + 1] || "")) {
      return { value, used: false, ambiguous: true };
    }
    converted += mapped;
    used = true;
  }
  return { value: converted, used, ambiguous: false };
}

function numericToken(text, { allowSuffix = false, compactSpaces = false } = {}) {
  const candidate = compactSpaces ? text.replace(/\s+/g, "") : text;
  const pattern = allowSuffix
    ? /^([0-9OoОоIiLl|丨Ss]+)([A-Za-z]+)?$/
    : /^([0-9OoОоIiLl|丨Ss]+)$/;
  const match = pattern.exec(candidate);
  if (!match) {
    return {
      ok: false,
      code: failureCode(candidate),
    };
  }
  const numericPart = match[1];
  const suffix = match[2] || "";
  // The last O/I/L/S could be a legal scene suffix rather than a digit. Keep
  // the raw token whenever that interpretation is possible.
  if (allowSuffix && /\d[OoОоIiLlSs]$/.test(numericPart)) {
    return { ok: false, code: "ambiguous-numeric-token" };
  }
  const mapped = mapConfusableNumericToken(numericPart);
  if (mapped.ambiguous) return { ok: false, code: "ambiguous-numeric-token" };
  if (!/^\d+$/.test(mapped.value)) {
    return { ok: false, code: "invalid-numeric-token" };
  }
  const number = Number(mapped.value);
  if (!Number.isSafeInteger(number) || number < 0 || number >= FIELD_NUMBER_LIMIT) {
    return { ok: false, code: "out-of-range" };
  }
  return {
    ok: true,
    number,
    suffix: suffix.toUpperCase(),
    confusableConverted: mapped.used,
  };
}

function convertedChineseText(value) {
  const text = chineseNumeralsToArabic(value);
  const sourceHasChinese = CHINESE_NUMERAL_PATTERN.test(value);
  CHINESE_NUMERAL_PATTERN.lastIndex = 0;
  const failedChinese = CHINESE_NUMERAL_PATTERN.test(text);
  CHINESE_NUMERAL_PATTERN.lastIndex = 0;
  return {
    text,
    converted: sourceHasChinese && text !== value,
    failed: failedChinese,
  };
}

function stripSceneWrappers(value) {
  let text = value.trim();
  text = text.replace(/^第\s*/, "");
  text = text.replace(/^场(?:次)?\s*/, "");
  text = text.replace(/\s*(?:场次|场)$/, "");
  return text.trim();
}

function stripOrdinalWrapper(value) {
  let text = value.trim().replace(/^第\s*/, "");
  // Some legacy exports label both ordinal columns with the same visible
  // wrapper. Accept either known wrapper here, while still rejecting unknown
  // prose and keeping the field-specific numeric rules intact.
  const leadingWrapper = /^(?:镜|次)(?:号)?\s*/.exec(text);
  if (leadingWrapper) {
    text = text.slice(leadingWrapper[0].length);
    // “镜 11 号” and “次 2 号” are common handwritten labels; the 号 is
    // part of the wrapper only after a leading 镜/次 has been confirmed.
    text = text.replace(/\s*号$/, "");
  } else {
    text = text.replace(/\s*(?:镜号|镜|次号|次)$/, "");
  }
  return text.trim();
}

function makeFailure(field, originalValue, confidence, code) {
  return resultFor(
    field,
    originalValue,
    originalValue,
    confidence,
    true,
    [warning(code, field, originalValue, originalValue)],
  );
}

function normalizeSceneField(field, originalValue, text, width, confidence, chineseConverted) {
  const stripped = stripSceneWrappers(text);
  const rawParts = stripped.split(/[\/／、,，;；]/);
  const parts = rawParts.map((part) => part.trim());
  if (!parts.length || parts.some((part) => !part)) {
    return makeFailure(field, originalValue, confidence, "ambiguous-numeric-token");
  }

  const normalizedParts = [];
  let confusableConverted = false;
  for (const part of parts) {
    const parsed = numericToken(part, { allowSuffix: true });
    if (!parsed.ok) return makeFailure(field, originalValue, confidence, parsed.code);
    if (parsed.suffix && /[OILＳS]/i.test(parsed.suffix)) {
      return makeFailure(field, originalValue, confidence, "ambiguous-numeric-token");
    }
    confusableConverted ||= parsed.confusableConverted;
    normalizedParts.push(`${parsed.number}${parsed.suffix}`);
  }

  const normalizedValue = normalizedParts.length === 1 && !normalizedParts[0].match(/[A-Z]/)
    ? normalizedParts[0].padStart(width, "0")
    : normalizedParts.join(" / ");
  const warnings = [];
  if (chineseConverted) warnings.push(warning("chinese-numeral-converted", field, originalValue, normalizedValue));
  if (confusableConverted) warnings.push(warning("confusable-character", field, originalValue, normalizedValue));
  return resultFor(field, originalValue, normalizedValue, confidence, warnings.length > 0, warnings);
}

function normalizeOrdinalField(field, originalValue, text, width, confidence, chineseConverted) {
  const parsed = numericToken(stripOrdinalWrapper(text));
  if (!parsed.ok) return makeFailure(field, originalValue, confidence, parsed.code);
  const normalizedValue = String(parsed.number).padStart(width, "0");
  const warnings = [];
  if (chineseConverted) warnings.push(warning("chinese-numeral-converted", field, originalValue, normalizedValue));
  if (parsed.confusableConverted) warnings.push(warning("confusable-character", field, originalValue, normalizedValue));
  return resultFor(field, originalValue, normalizedValue, confidence, warnings.length > 0, warnings);
}

function normalizeCardField(field, originalValue, text, confidence, chineseConverted) {
  const compact = text.replace(/[\s_-]+/g, "");
  const match = /^([A-Z])(.+)$/.exec(compact);
  if (!match) return makeFailure(field, originalValue, confidence, "ambiguous-numeric-token");
  const parsed = numericToken(match[2], { compactSpaces: true });
  if (!parsed.ok) return makeFailure(field, originalValue, confidence, parsed.code);
  const normalizedValue = `${match[1]}${String(parsed.number).padStart(3, "0")}`;
  const warnings = [];
  if (chineseConverted) warnings.push(warning("chinese-numeral-converted", field, originalValue, normalizedValue));
  if (parsed.confusableConverted) warnings.push(warning("confusable-character", field, originalValue, normalizedValue));
  return resultFor(field, originalValue, normalizedValue, confidence, warnings.length > 0, warnings);
}

function normalizeVideoField(field, originalValue, text, confidence, chineseConverted) {
  const compact = text.replace(/\s+/g, "");
  const match = /^(?:C)?(.+)$/.exec(compact);
  if (!match || !match[1]) return makeFailure(field, originalValue, confidence, "ambiguous-numeric-token");
  const parsed = numericToken(match[1]);
  if (!parsed.ok) return makeFailure(field, originalValue, confidence, parsed.code);
  const digits = String(parsed.number).padStart(3, "0");
  if (!digits.startsWith("0") || digits.length > 3) {
    return makeFailure(field, originalValue, confidence, "invalid-numeric-token");
  }
  const normalizedValue = `C${digits}`;
  const warnings = [];
  if (chineseConverted) warnings.push(warning("chinese-numeral-converted", field, originalValue, normalizedValue));
  if (parsed.confusableConverted) warnings.push(warning("confusable-character", field, originalValue, normalizedValue));
  return resultFor(field, originalValue, normalizedValue, confidence, warnings.length > 0, warnings);
}

export function normalizeRecognitionField(field, value, options = {}) {
  const confidence = ["high", "medium", "low"].includes(options.confidence)
    ? options.confidence
    : null;
  const originalValue = originalFieldValue(value);
  if (originalValue == null) {
    const warnings = options.warnMissing
      ? [warning("missing-value", field, null, null)]
      : [];
    return resultFor(field, null, null, confidence, false, warnings);
  }
  if (!RECOGNITION_NUMERIC_FIELDS.includes(field)) {
    return resultFor(field, originalValue, originalValue, confidence, false, []);
  }

  const prepared = originalValue.normalize("NFKC").trim();
  const conversion = convertedChineseText(prepared);
  if (conversion.failed) {
    return makeFailure(field, originalValue, confidence, failureCode(conversion.text));
  }
  const width = field === "scene"
    ? fieldWidth(options.fieldFormats?.scene || options.formats?.scene || options.format, 3)
    : fieldWidth(options.fieldFormats?.[field] || options.formats?.[field] || options.format, 2);
  if (field === "scene") {
    return normalizeSceneField(field, originalValue, conversion.text, width, confidence, conversion.converted);
  }
  if (field === "shot" || field === "take") {
    return normalizeOrdinalField(field, originalValue, conversion.text, width, confidence, conversion.converted);
  }
  if (field === "cardNumber") {
    return normalizeCardField(field, originalValue, conversion.text.toUpperCase(), confidence, conversion.converted);
  }
  return normalizeVideoField(field, originalValue, conversion.text.toUpperCase(), confidence, conversion.converted);
}

function isInvalidNormalizationWarning(code) {
  return code === "ambiguous-numeric-token" ||
    code === "invalid-numeric-token" ||
    code === "out-of-range";
}

export function isCanonicalRecognitionValue(field, value) {
  const text = String(value ?? "");
  const safeNumber = (digits) => {
    const number = Number(digits);
    return Number.isSafeInteger(number) && number >= 0 && number < FIELD_NUMBER_LIMIT;
  };
  if (field === "cardNumber") {
    const match = /^([A-Z])(\d{3,6})$/.exec(text);
    return Boolean(match && safeNumber(match[2]));
  }
  if (field === "videoCode") return /^C0\d{2}$/.test(text) && safeNumber(text.slice(1));
  if (field === "scene") {
    return /^\d+[A-Z]*(?: \/ \d+[A-Z]*)*$/.test(text) &&
      !text.split(" / ").some((part) => /\d[OILS]$/i.test(part)) &&
      text.split(" / ").every((part) => safeNumber(part.match(/^\d+/)[0]));
  }
  if (field === "shot" || field === "take") return /^\d+$/.test(text) && safeNumber(text);
  return false;
}

// Matching code may use a normalized value only when the shared result did
// not fail validation. Confusable/chinese conversions are valid candidates;
// ambiguous results intentionally return null so they cannot create a key.
export function canonicalRecognitionValue(field, value, options = {}) {
  const result = normalizeRecognitionField(field, value, options);
  if (result.warnings.some((item) => isInvalidNormalizationWarning(item.code))) return null;
  return isCanonicalRecognitionValue(field, result.normalizedValue)
    ? result.normalizedValue
    : null;
}

function cloneQualityField(field) {
  return {
    ...field,
    warnings: Array.isArray(field?.warnings)
      ? field.warnings.map((item) => ({ ...item }))
      : [],
  };
}

export function orderReviewRequiredFields(fields = []) {
  const unique = [];
  for (const field of fields) {
    if (typeof field !== "string" || !field || unique.includes(field)) continue;
    unique.push(field);
  }
  const known = RECOGNITION_REVIEW_FIELD_ORDER.filter((field) => unique.includes(field));
  const unknown = unique.filter((field) => !RECOGNITION_REVIEW_FIELD_ORDER.includes(field));
  return [...known, ...unknown];
}

export function reviewFieldsFromQuality(record) {
  const fields = Array.isArray(record?.reviewRequiredFields)
    ? [...record.reviewRequiredFields]
    : [];
  for (const [fieldKey, quality] of Object.entries(record?.quality?.fields || {})) {
    if (quality?.reviewRequired) fields.push(quality.field || fieldKey);
  }
  return orderReviewRequiredFields(fields);
}

export function normalizeRecognitionRecord(record, options = {}) {
  if (!record || typeof record !== "object") return record;
  const existingQuality = record.quality && typeof record.quality === "object"
    ? record.quality
    : null;
  const qualityFields = Object.fromEntries(
    Object.entries(existingQuality?.fields || {}).map(([field, value]) => [field, cloneQualityField(value)]),
  );
  const existingReviewFields = Array.isArray(record.reviewRequiredFields)
    ? [...record.reviewRequiredFields]
    : [];
  const normalizedRecord = { ...record };

  for (const field of RECOGNITION_REVIEW_FIELD_ORDER) {
    if (!Object.hasOwn(record, field)) continue;
    const existingFieldQuality = qualityFields[field];
    if (existingFieldQuality) {
      // Restored/edited quality is historical evidence. Do not recompute it
      // from the current value or erase its originalValue and warnings.
      continue;
    }
    const fieldResult = normalizeRecognitionField(field, record[field], {
      ...options,
      confidence: record.confidence,
    });
    normalizedRecord[field] = fieldResult.normalizedValue;
    if (options.createQuality !== false &&
      (fieldResult.changed || fieldResult.reviewRequired || fieldResult.warnings.length || existingReviewFields.includes(field))) {
      qualityFields[field] = {
        ...fieldResult,
        reviewRequired: fieldResult.reviewRequired || existingReviewFields.includes(field),
      };
    }
  }

  const reviewRequiredFields = orderReviewRequiredFields([
    ...existingReviewFields,
    ...Object.values(qualityFields)
      .filter((field) => field?.reviewRequired)
      .map((field) => field.field),
  ]);
  if (reviewRequiredFields.length) normalizedRecord.reviewRequiredFields = reviewRequiredFields;
  else delete normalizedRecord.reviewRequiredFields;

  if (existingQuality || Object.keys(qualityFields).length) {
    normalizedRecord.quality = {
      ...(existingQuality || {}),
      fields: qualityFields,
    };
  }
  return normalizedRecord;
}

export function normalizeRecognitionSheetFields(result, options = {}) {
  if (!result || typeof result !== "object" || !Array.isArray(result.records)) return result;
  return {
    ...result,
    records: result.records.map((record) => normalizeRecognitionRecord(record, options)),
  };
}

export function normalizeCameraFps(value) {
  const normalized = cleanValue(value).replace(",", ".");
  const match = normalized.match(/^(\d{1,4}(?:\.\d{1,6})?)\s*(?:fps)?$/i);
  if (!match) return "";
  const number = Number(match[1]);
  if (!Number.isFinite(number) || number <= 0 || number > 1000) return "";
  return String(number);
}

export function normalizeShootDay(value) {
  const normalized = cleanValue(value);
  const compact = normalized.match(/^(\d{2}|\d{4})(\d{2})(\d{2})$/);
  const separated = normalized.match(
    /^(\d{2}|\d{4})\s*[-/.]\s*(\d{1,2})\s*[-/.]\s*(\d{1,2})(?:[T\s].*)?$/,
  );
  const match = compact || separated;
  if (!match) return "";

  const yearText = match[1];
  const fullYear = yearText.length === 2
    ? 2000 + Number(yearText)
    : Number(yearText);
  const month = Number(match[2]);
  const day = Number(match[3]);
  const date = new Date(Date.UTC(fullYear, month - 1, day));
  if (
    date.getUTCFullYear() !== fullYear ||
    date.getUTCMonth() !== month - 1 ||
    date.getUTCDate() !== day
  ) return "";

  return `${String(fullYear).slice(-2)}-${String(month).padStart(2, "0")}-${String(day).padStart(2, "0")}`;
}

// Extracts the canonical "A:4:4" material key from reel/clip identifiers that
// appear in file names, directory names, or Clip Name metadata.
export function extractCombinedMaterialKey(value) {
  const text = String(value || "").toUpperCase();
  const match = text.match(
    /(?:^|[^A-Z0-9])([A-Z]+)[\s_-]*0*(\d+)[\s_-]*C[\s_-]*0*(\d+)(?=[^0-9]|$)/,
  );
  if (!match) return "";
  return `${match[1]}:${Number(match[2])}:${Number(match[3])}`;
}

export function parseCanonicalMaterialKey(key) {
  const match = String(key || "").match(/^([^:]+):(\d+):(\d+)$/);
  if (!match) return null;
  return {
    camera: match[1],
    reel: Number(match[2]),
    clip: Number(match[3]),
  };
}

export function canonicalKeyToMaterialPrefix(key) {
  const parsed = parseCanonicalMaterialKey(key);
  if (!parsed) return String(key);
  return `${parsed.camera}${String(parsed.reel).padStart(3, "0")}C${String(parsed.clip).padStart(3, "0")}`;
}

// Detects the text encoding of a byte buffer by BOM and, failing that, by the
// zero-byte density that UTF-16 leaves in ASCII-heavy text. Used by both the
// Resolve CSV decoder and the metadata source adapters.
export function detectCsvFormat(bytes) {
  if (bytes[0] === 0xff && bytes[1] === 0xfe) {
    return { encoding: "utf-16le", bomBytes: 2 };
  }
  if (bytes[0] === 0xfe && bytes[1] === 0xff) {
    return { encoding: "utf-16be", bomBytes: 2 };
  }
  if (bytes[0] === 0xef && bytes[1] === 0xbb && bytes[2] === 0xbf) {
    return { encoding: "utf-8", bomBytes: 3 };
  }

  const sampleLength = Math.min(bytes.length, 2048);
  let evenZeros = 0;
  let oddZeros = 0;
  for (let index = 0; index < sampleLength; index += 1) {
    if (bytes[index] !== 0) continue;
    if (index % 2) oddZeros += 1;
    else evenZeros += 1;
  }
  if (oddZeros > sampleLength / 8 && oddZeros > evenZeros * 4) {
    return { encoding: "utf-16le", bomBytes: 0 };
  }
  if (evenZeros > sampleLength / 8 && evenZeros > oddZeros * 4) {
    return { encoding: "utf-16be", bomBytes: 0 };
  }
  return { encoding: "utf-8", bomBytes: 0 };
}

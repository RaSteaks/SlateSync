// Vendor-neutral metadata helpers shared by every camera metadata source and
// the Resolve CSV merge layer. Kept free of any Kinefinity / ARRI / DJI / RED
// specifics so a new vendor only adds one adapter file under metadata-sources/.

export function cleanValue(value) {
  // NFKC folds full-width digits (０９ → 09) and circled digits (⑪ → 11) so
  // camera metadata and CSV cells compare cleanly against recognized values.
  return value == null ? "" : String(value).normalize("NFKC").trim();
}

// Converts Chinese numeral runs (十一 → 11, 二十三 → 23, 一百零五 → 105) so
// handwritten slate values can flow through the regular numeric normalizers.
// Shared by the main-process recognition schema and the renderer's Resolve
// merge layer so both normalize identically.
const CHINESE_DIGITS = { 零: 0, 一: 1, 二: 2, 两: 2, 三: 3, 四: 4, 五: 5, 六: 6, 七: 7, 八: 8, 九: 9 };
const CHINESE_UNITS = { 十: 10, 百: 100 };

export function parseChineseNumber(text) {
  let section = 0;
  let digit = -1;
  let matched = false;
  for (const char of text) {
    if (char in CHINESE_DIGITS) {
      digit = CHINESE_DIGITS[char];
      matched = true;
    } else if (char in CHINESE_UNITS) {
      section += (digit < 0 ? 1 : digit) * CHINESE_UNITS[char];
      digit = -1;
      matched = true;
    } else {
      return null;
    }
  }
  if (!matched) return null;
  const total = section + Math.max(digit, 0);
  return total >= 0 && total < 1000 ? total : null;
}

export function chineseNumeralsToArabic(value) {
  return String(value ?? "").replace(
    /[零一二两三四五六七八九十百]+/g,
    (run) => {
      const number = parseChineseNumber(run);
      return number == null ? run : String(number);
    },
  );
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

import type { GlobalSettingKey } from "../../shared/contracts/index.js";
import type { ValidationResult } from "./input-validation";

/** Inclusive numeric bounds for global settings that accept plain numbers. */
export interface NumericRange {
  readonly min: number;
  readonly max: number;
  /** Integers reject decimal input instead of silently rounding. */
  readonly integer?: boolean;
  /** Maximum digits after the decimal point; undefined means unrestricted. */
  readonly decimals?: number;
}

// Keep these bounds aligned with the Main-side .env defaults and the inline
// field hints; validation only guards typed input, an empty value always
// falls back to the inherited default and stays valid.
export const GLOBAL_NUMERIC_RANGES: Partial<Record<GlobalSettingKey, NumericRange>> = {
  MAX_BODY_MB: { min: 20, max: 200, integer: true },
  MODEL_REQUEST_TIMEOUT_MS: { min: 30000, max: 3600000, integer: true },
  MODEL_REQUEST_MAX_RETRIES: { min: 0, max: 3, integer: true },
  MODEL_PAGE_CONCURRENCY: { min: 1, max: 6, integer: true },
  MAX_CONCURRENT_RECOGNITIONS: { min: 1, max: 16, integer: true },
  VISIONOCR_MIN_CONFIDENCE: { min: 0, max: 1, decimals: 2 },
  PADDLEOCR_MIN_CONFIDENCE: { min: 0, max: 1, decimals: 2 },
  VISIONOCR_MAX_BLOCKS_PER_VIEW: { min: 0, max: 10000, integer: true },
  PADDLEOCR_MAX_BLOCKS_PER_VIEW: { min: 0, max: 10000, integer: true },
  PADDLEOCR_RECOGNITION_BATCH_SIZE: { min: 1, max: 64, integer: true },
  PADDLEOCR_TEXT_DET_LIMIT_SIDE_LEN: { min: 320, max: 4096, integer: true },
};

/** Timeout keys accept the literal "auto" plus a per-engine millisecond range. */
export const GLOBAL_TIMEOUT_RANGES: Partial<Record<GlobalSettingKey, NumericRange>> = {
  VISIONOCR_TIMEOUT_MS: { min: 10000, max: 1800000, integer: true },
  PADDLEOCR_TIMEOUT_MS: { min: 10000, max: 3600000, integer: true },
};

const NUMBER_PATTERN = /^-?\d+(?:\.\d+)?$/;
const INTEGER_PATTERN = /^-?\d+$/;

function decimalPlaces(value: string): number {
  const dot = value.indexOf(".");
  return dot === -1 ? 0 : value.length - dot - 1;
}

export function validateNumericField(key: GlobalSettingKey, value: string): ValidationResult {
  const range = GLOBAL_NUMERIC_RANGES[key];
  if (!range) return { ok: true };
  const trimmed = value.trim();
  // An empty field means "inherit the .env or built-in default" and is valid.
  if (!trimmed) return { ok: true };
  if (!NUMBER_PATTERN.test(trimmed)) return { ok: false, message: "请输入数字。" };
  const parsed = Number(trimmed);
  if (range.integer && !Number.isInteger(parsed)) {
    return { ok: false, message: `请输入 ${range.min}–${range.max} 之间的整数。` };
  }
  if (range.decimals !== undefined && decimalPlaces(trimmed) > range.decimals) {
    return { ok: false, message: `小数位不能超过 ${range.decimals} 位。` };
  }
  if (parsed < range.min || parsed > range.max) {
    return { ok: false, message: `请输入 ${range.min}–${range.max} 之间的数值。` };
  }
  return { ok: true };
}

export function validateTimeoutField(key: GlobalSettingKey, value: string): ValidationResult {
  const range = GLOBAL_TIMEOUT_RANGES[key];
  if (!range) return { ok: true };
  const trimmed = value.trim();
  // "auto" and empty both defer to the per-view computed timeout in Main.
  if (!trimmed || trimmed.toLowerCase() === "auto") return { ok: true };
  if (!INTEGER_PATTERN.test(trimmed)) {
    return { ok: false, message: "请输入 auto 或毫秒数值。" };
  }
  const parsed = Number(trimmed);
  if (parsed < range.min || parsed > range.max) {
    return { ok: false, message: `请输入 ${range.min}–${range.max} 之间的毫秒值。` };
  }
  return { ok: true };
}

/** Single entry point for blur/save validation of a global numeric setting. */
export function validateGlobalSettingValue(key: GlobalSettingKey, value: string): ValidationResult {
  return key in GLOBAL_TIMEOUT_RANGES
    ? validateTimeoutField(key, value)
    : validateNumericField(key, value);
}

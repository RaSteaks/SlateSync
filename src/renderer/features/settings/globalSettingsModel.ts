import type { GlobalSettingKey, GlobalSettingValues, OcrSelection } from "../../../shared/contracts/index.js";
import type { StatusTone } from "./ocrEngineStatus";

export type OcrPreference = "auto" | "vision" | "paddleocr" | "disabled";
export type PaddlePreset = "custom" | "performance" | "balanced" | "fast";
export type PaddleModelVersion = "PP-OCRv5" | "PP-OCRv6";

export type PaddlePresetValues = {
  label: string;
  modelVersion: PaddleModelVersion;
  detectionModel: string;
  recognitionModel: string;
  recognitionBatchSize: string;
  minimumConfidence: string;
  maxBlocksPerView: string;
  textDetLimitSideLen: string;
  // The legacy profile is only used when a named preset is copied to custom.
  profile: "fast" | "balanced" | "accurate";
};
export type PaddleModelDraft = Pick<PaddlePresetValues, "detectionModel" | "recognitionModel">;

// Keep this display table aligned with the Main-side preset resolver. The
// actual OCR request never trusts Renderer values; this only previews the
// effective read-only values before the next global-settings save.
export const PADDLE_PRESET_VALUES: Record<Exclude<PaddlePreset, "custom">, PaddlePresetValues> = {
  performance: {
    label: "性能（质量优先）",
    modelVersion: "PP-OCRv6",
    detectionModel: "PP-OCRv6_medium_det",
    recognitionModel: "PP-OCRv6_medium_rec",
    recognitionBatchSize: "4",
    minimumConfidence: "0.05",
    maxBlocksPerView: "0",
    textDetLimitSideLen: "1280",
    profile: "accurate",
  },
  balanced: {
    label: "平衡（推荐）",
    modelVersion: "PP-OCRv6",
    detectionModel: "PP-OCRv6_small_det",
    recognitionModel: "PP-OCRv6_small_rec",
    recognitionBatchSize: "8",
    minimumConfidence: "0.10",
    maxBlocksPerView: "256",
    textDetLimitSideLen: "960",
    profile: "balanced",
  },
  fast: {
    label: "快速（低延迟）",
    modelVersion: "PP-OCRv6",
    detectionModel: "PP-OCRv6_tiny_det",
    recognitionModel: "PP-OCRv6_tiny_rec",
    recognitionBatchSize: "16",
    minimumConfidence: "0.25",
    maxBlocksPerView: "64",
    textDetLimitSideLen: "736",
    profile: "fast",
  },
};

export const PADDLE_MODEL_VERSION_OPTIONS: Array<{ value: PaddleModelVersion; label: string }> = [
  { value: "PP-OCRv6", label: "PP-OCRv6（推荐）" },
  { value: "PP-OCRv5", label: "PP-OCRv5（兼容）" },
];

// PP-OCRv6 exposes the three official size tiers for both pipeline stages.
// Keep an empty option for the existing profile default and retain an unknown
// saved value as a labelled option; the adjacent text field also allows new
// custom/local model IDs without making the recommended tiers harder to find.
export const PADDLE_V6_DETECTION_MODEL_OPTIONS: Array<{ value: string; label: string }> = [
  { value: "", label: "使用当前版本默认模型" },
  { value: "PP-OCRv6_medium_det", label: "PP-OCRv6_medium_det · 性能" },
  { value: "PP-OCRv6_small_det", label: "PP-OCRv6_small_det · 平衡" },
  { value: "PP-OCRv6_tiny_det", label: "PP-OCRv6_tiny_det · 快速" },
];
export const PADDLE_V6_RECOGNITION_MODEL_OPTIONS: Array<{ value: string; label: string }> = [
  { value: "", label: "使用当前版本默认模型" },
  { value: "PP-OCRv6_medium_rec", label: "PP-OCRv6_medium_rec · 性能" },
  { value: "PP-OCRv6_small_rec", label: "PP-OCRv6_small_rec · 平衡" },
  { value: "PP-OCRv6_tiny_rec", label: "PP-OCRv6_tiny_rec · 快速" },
];

// The four routing keys behind the top-level OCR preference. The segmented
// control owns all of them; the per-card required flag stays in the advanced
// panel and is validated against these when rendering the active segment.
export const OCR_ROUTING_KEYS = [
  "VISIONOCR_ENABLED",
  "PADDLEOCR_ENABLED",
  "VISIONOCR_REQUIRED",
  "PADDLEOCR_REQUIRED",
] as const satisfies readonly GlobalSettingKey[];

// Advanced-panel ownership per engine card; these drive the "未保存" markers
// on each card's disclosure and on the section navigation.
export const VISION_ADVANCED_KEYS: readonly GlobalSettingKey[] = [
  "VISIONOCR_ENABLED",
  "VISIONOCR_REQUIRED",
  "VISIONOCR_LANGUAGE",
  "VISIONOCR_RECOGNITION_LEVEL",
  "VISIONOCR_USE_LANGUAGE_CORRECTION",
  "VISIONOCR_MIN_CONFIDENCE",
  "VISIONOCR_MAX_BLOCKS_PER_VIEW",
  "VISIONOCR_TIMEOUT_MS",
  "VISIONOCR_BINARY",
];

export const PADDLE_ADVANCED_KEYS: readonly GlobalSettingKey[] = [
  "PADDLEOCR_ENABLED",
  "PADDLEOCR_REQUIRED",
  "PADDLEOCR_PRESET",
  "PADDLEOCR_MODEL_VERSION",
  "PADDLEOCR_PROFILE",
  "PADDLEOCR_LANGUAGE",
  "PADDLEOCR_DEVICE",
  "PADDLEOCR_DETECTION_MODEL",
  "PADDLEOCR_RECOGNITION_MODEL",
  "PADDLEOCR_RECOGNITION_BATCH_SIZE",
  "PADDLEOCR_MIN_CONFIDENCE",
  "PADDLEOCR_MAX_BLOCKS_PER_VIEW",
  "PADDLEOCR_TEXT_DET_LIMIT_SIDE_LEN",
  "PADDLEOCR_TIMEOUT_MS",
  "PADDLEOCR_PYTHON",
];

export const OCR_ROUTING_SEGMENTS: ReadonlyArray<{ value: OcrPreference; label: string }> = [
  { value: "auto", label: "自动" },
  { value: "vision", label: "Apple Vision" },
  { value: "paddleocr", label: "PaddleOCR" },
  { value: "disabled", label: "关闭本地 OCR" },
];

export function selectionTone(selection: OcrSelection | undefined): StatusTone {
  if (!selection?.id) return "neutral";
  if (selection.enabled && selection.available) return "success";
  return selection.required ? "danger" : "warning";
}

export function selectionModeLabel(mode: string): string {
  if (mode === "required") return "必需模式";
  if (mode === "explicit") return "显式指定";
  if (mode === "fallback") return "自动回退";
  if (mode === "auto") return "自动选择";
  return "未启用";
}

export function engineModeLabel(mode: string): string {
  if (mode === "auto") return "自动";
  if (["1", "true", "yes", "on"].includes(mode)) return "开启";
  if (["0", "false", "no", "off"].includes(mode)) return "关闭";
  return mode || "默认";
}

export function selectionLabel(selection: OcrSelection | undefined): string {
  if (!selection) return "正在读取 OCR 能力";
  if (selection.id === "vision") return "Apple Vision OCR";
  if (selection.id === "paddleocr") return "PaddleOCR";
  return "未启用本地 OCR";
}

export function selectionStatusLabel(selection: OcrSelection | undefined): string {
  if (!selection?.id) return "将降级为页面图片识别";
  if (selection.enabled && selection.available) return "已选中且可运行";
  if (selection.required) return "必需引擎当前不可用";
  return "已选中但当前不可用";
}

export function isCustomPaddleModel(
  options: Array<{ value: string; label: string }>,
  selectedValue: string,
) {
  return Boolean(selectedValue) && !options.some((option) => option.value === selectedValue);
}

export function settingValue(values: Partial<GlobalSettingValues>, key: GlobalSettingKey, fallback = "") {
  return values[key] ?? fallback;
}

export function paddlePresetFromValues(values: Partial<GlobalSettingValues>): PaddlePreset {
  const value = settingValue(values, "PADDLEOCR_PRESET", "custom").toLowerCase();
  return value === "performance" || value === "balanced" || value === "fast" ? value : "custom";
}

export function paddleModelVersionFromValues(values: Partial<GlobalSettingValues>): PaddleModelVersion {
  const value = settingValue(values, "PADDLEOCR_MODEL_VERSION", "PP-OCRv6").toLowerCase();
  return value === "pp-ocrv5"
    ? "PP-OCRv5"
    : "PP-OCRv6";
}

export function paddleModelOptions(
  options: Array<{ value: string; label: string }>,
  selectedValue: string,
) {
  if (selectedValue && !options.some((option) => option.value === selectedValue)) {
    return [
      { value: selectedValue, label: `${selectedValue}（当前自定义）` },
      ...options,
    ];
  }
  return options;
}

export function paddleEffectiveValues(
  values: Partial<GlobalSettingValues>,
  preset: PaddlePreset,
): PaddlePresetValues {
  if (preset !== "custom") return PADDLE_PRESET_VALUES[preset];
  return {
    label: "自定义",
    modelVersion: paddleModelVersionFromValues(values),
    detectionModel: settingValue(values, "PADDLEOCR_DETECTION_MODEL"),
    recognitionModel: settingValue(values, "PADDLEOCR_RECOGNITION_MODEL"),
    recognitionBatchSize: settingValue(values, "PADDLEOCR_RECOGNITION_BATCH_SIZE"),
    minimumConfidence: settingValue(values, "PADDLEOCR_MIN_CONFIDENCE", "0.10"),
    maxBlocksPerView: settingValue(values, "PADDLEOCR_MAX_BLOCKS_PER_VIEW", "0"),
    textDetLimitSideLen: settingValue(values, "PADDLEOCR_TEXT_DET_LIMIT_SIDE_LEN"),
    profile: settingValue(values, "PADDLEOCR_PROFILE", "balanced") as PaddlePresetValues["profile"],
  };
}

export function paddlePresetCopyPatch(preset: PaddlePreset, values: PaddlePresetValues): Partial<Record<GlobalSettingKey, string>> {
  return {
    PADDLEOCR_PRESET: preset,
    PADDLEOCR_MODEL_VERSION: values.modelVersion,
    PADDLEOCR_PROFILE: values.profile,
    PADDLEOCR_DETECTION_MODEL: values.detectionModel,
    PADDLEOCR_RECOGNITION_MODEL: values.recognitionModel,
    PADDLEOCR_RECOGNITION_BATCH_SIZE: values.recognitionBatchSize,
    PADDLEOCR_MIN_CONFIDENCE: values.minimumConfidence,
    PADDLEOCR_MAX_BLOCKS_PER_VIEW: values.maxBlocksPerView,
    PADDLEOCR_TEXT_DET_LIMIT_SIDE_LEN: values.textDetLimitSideLen,
  };
}

export function paddleModelDraftFromValues(values: Partial<GlobalSettingValues>): PaddleModelDraft {
  return {
    detectionModel: settingValue(values, "PADDLEOCR_DETECTION_MODEL"),
    recognitionModel: settingValue(values, "PADDLEOCR_RECOGNITION_MODEL"),
  };
}

export function ocrPreferenceFromValues(values: Partial<GlobalSettingValues>): OcrPreference {
  const visionMode = settingValue(values, "VISIONOCR_ENABLED", "auto");
  const paddleMode = settingValue(values, "PADDLEOCR_ENABLED", "auto");
  const visionRequired = settingValue(values, "VISIONOCR_REQUIRED", "false") === "true";
  const paddleRequired = settingValue(values, "PADDLEOCR_REQUIRED", "false") === "true";
  // Mirror Main's required/explicit precedence so the selector never promises a
  // different engine from the recognition request that will actually run.
  if (visionRequired) return "vision";
  if (paddleRequired) return "paddleocr";
  if (visionMode === "true") return "vision";
  if (paddleMode === "true") return "paddleocr";
  if (visionMode === "false" && paddleMode === "false") return "disabled";
  return "auto";
}

export function ocrPreferencePatch(preference: OcrPreference): Partial<Record<GlobalSettingKey, string>> {
  // A top-level preference owns routing. Resetting both required flags prevents
  // a hidden advanced value from overriding the engine the user just selected.
  const required = { VISIONOCR_REQUIRED: "false", PADDLEOCR_REQUIRED: "false" } as const;
  if (preference === "vision") return { ...required, VISIONOCR_ENABLED: "true", PADDLEOCR_ENABLED: "false" };
  if (preference === "paddleocr") return { ...required, VISIONOCR_ENABLED: "false", PADDLEOCR_ENABLED: "true" };
  if (preference === "disabled") return { ...required, VISIONOCR_ENABLED: "false", PADDLEOCR_ENABLED: "false" };
  return { ...required, VISIONOCR_ENABLED: "auto", PADDLEOCR_ENABLED: "auto" };
}

/**
 * Draft-vs-saved explanation shown under the routing segmented control. The
 * text describes what the next save will change so the consolidation of the
 * old card toggles stays transparent before the user commits it.
 */
export function ocrRoutingFeedback(preference: OcrPreference, savedValues: Partial<GlobalSettingValues> | null): string {
  const patch = ocrPreferencePatch(preference);
  const savedValue = (key: GlobalSettingKey) => savedValues?.[key];
  const changedKeys = OCR_ROUTING_KEYS.filter((key) => savedValue(key) !== undefined && savedValue(key) !== patch[key]);
  if (savedValues && changedKeys.length === 0) {
    return "当前已保存配置与所选路由一致。";
  }
  const requiredPrefix = [savedValue("VISIONOCR_REQUIRED"), savedValue("PADDLEOCR_REQUIRED")]
    .some((value) => value === "true")
    ? "所选路由会清除已开启的必需模式。"
    : "";
  let body: string;
  if (preference === "vision") {
    body = `保存后将显式启用 Apple Vision OCR${savedValue("PADDLEOCR_ENABLED") === "true" ? "，并关闭 PaddleOCR" : ""}。`;
  } else if (preference === "paddleocr") {
    body = `保存后将显式启用 PaddleOCR${savedValue("VISIONOCR_ENABLED") === "true" ? "，并关闭 Apple Vision OCR" : ""}。`;
  } else if (preference === "disabled") {
    body = "保存后将同时关闭两套引擎。";
  } else {
    body = "保存后恢复自动路由；macOS 上优先使用 Apple Vision OCR。";
  }
  return `${requiredPrefix}${body}`;
}

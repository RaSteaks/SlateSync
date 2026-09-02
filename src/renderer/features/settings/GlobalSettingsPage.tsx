import { Braces, CheckCircle2, Download, Eye, EyeOff, KeyRound, Monitor, Moon, RotateCcw, Save, Sun, Terminal, Wrench } from "lucide-react";
import { useEffect, useRef, useState } from "react";
import type { ConfigData, GlobalSettingKey, GlobalSettingsData, GlobalSettingsPatch, JsonSchemaCapabilityResult, OcrCheckResult, OcrEngineStatus, OcrSelection, OcrSettings, PaddleOcrInstallProgress, VisionOcrCheckResult } from "../../../shared/contracts/index.js";
import { Badge, Button, Field, Icon, InlineError, Input, Progress, Select, Stack, StatusIndicator, Surface, Text } from "../../design-system";
import { appErrorFromUnknown, getSlateSync, requireGlobalSettingsApi, unwrap } from "../../services/api";
import { useProjectStore, useSettingsStore, useUiStore, type Theme } from "../../state";
import styles from "../../app/app.module.css";
import { CustomProviderSettingsPanel } from "./CustomProviderSettingsPanel";

const KEY_PROVIDERS = new Set(["openai", "openrouter", "tokenplan", "dashscope", "openai-compatible"]);
const PROVIDER_BASE_URL_KEYS: Partial<Record<string, GlobalSettingKey>> = {
  openai: "OPENAI_BASE_URL",
  openrouter: "OPENROUTER_BASE_URL",
  tokenplan: "TOKENPLAN_BASE_URL",
  dashscope: "DASHSCOPE_BASE_URL",
  "openai-compatible": "OPENAI_COMPATIBLE_BASE_URL",
};

type StatusTone = "neutral" | "success" | "warning" | "danger";
type GlobalSaveState = "idle" | "saving" | "saved" | "error";
type PaddleOcrInstallState = "idle" | "installing" | "installed" | "canceled" | "error";
type OcrPreference = "auto" | "vision" | "paddleocr" | "disabled";
type PaddlePreset = "custom" | "performance" | "balanced" | "fast";
type PaddleModelVersion = "PP-OCRv5" | "PP-OCRv6";

type PaddlePresetValues = {
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
type PaddleModelDraft = Pick<PaddlePresetValues, "detectionModel" | "recognitionModel">;

// Keep this display table aligned with the Main-side preset resolver. The
// actual OCR request never trusts Renderer values; this only previews the
// effective read-only values before the next global-settings save.
const PADDLE_PRESET_VALUES: Record<Exclude<PaddlePreset, "custom">, PaddlePresetValues> = {
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

const PADDLE_MODEL_VERSION_OPTIONS: Array<{ value: PaddleModelVersion; label: string }> = [
  { value: "PP-OCRv6", label: "PP-OCRv6（推荐）" },
  { value: "PP-OCRv5", label: "PP-OCRv5（兼容）" },
];

// PP-OCRv6 exposes the three official size tiers for both pipeline stages.
// Keep an empty option for the existing profile default and retain an unknown
// saved value as a labelled option; the adjacent text field also allows new
// custom/local model IDs without making the recommended tiers harder to find.
const PADDLE_V6_DETECTION_MODEL_OPTIONS: Array<{ value: string; label: string }> = [
  { value: "", label: "使用当前版本默认模型" },
  { value: "PP-OCRv6_medium_det", label: "PP-OCRv6_medium_det · 性能" },
  { value: "PP-OCRv6_small_det", label: "PP-OCRv6_small_det · 平衡" },
  { value: "PP-OCRv6_tiny_det", label: "PP-OCRv6_tiny_det · 快速" },
];
const PADDLE_V6_RECOGNITION_MODEL_OPTIONS: Array<{ value: string; label: string }> = [
  { value: "", label: "使用当前版本默认模型" },
  { value: "PP-OCRv6_medium_rec", label: "PP-OCRv6_medium_rec · 性能" },
  { value: "PP-OCRv6_small_rec", label: "PP-OCRv6_small_rec · 平衡" },
  { value: "PP-OCRv6_tiny_rec", label: "PP-OCRv6_tiny_rec · 快速" },
];

function isCustomPaddleModel(
  options: Array<{ value: string; label: string }>,
  selectedValue: string,
) {
  return Boolean(selectedValue) && !options.some((option) => option.value === selectedValue);
}

function engineStatus(config: ConfigData | null, id: "vision" | "paddleocr"): OcrEngineStatus | null {
  return config?.ocrEngines.find((engine) => engine.id === id) || null;
}

function engineStatusLabel(engine: OcrEngineStatus | null): string {
  if (!engine) return "未读取";
  if (engine.enabled && engine.available) return "环境可用";
  if (engine.enabled) return "已启用但不可用";
  return engine.mode === "auto" ? "未启用" : "已关闭";
}

function engineStatusTone(engine: OcrEngineStatus | null): StatusTone {
  if (!engine) return "neutral";
  if (engine.enabled && engine.available) return "success";
  if (engine.enabled && engine.required) return "danger";
  if (engine.enabled) return "warning";
  return "neutral";
}

function selectionTone(selection: OcrSelection | undefined): StatusTone {
  if (!selection?.id) return "neutral";
  if (selection.enabled && selection.available) return "success";
  return selection.required ? "danger" : "warning";
}

function selectionModeLabel(mode: string): string {
  if (mode === "required") return "必需模式";
  if (mode === "explicit") return "显式指定";
  if (mode === "fallback") return "自动回退";
  if (mode === "auto") return "自动选择";
  return "未启用";
}

function engineModeLabel(mode: string): string {
  if (mode === "auto") return "自动";
  if (["1", "true", "yes", "on"].includes(mode)) return "开启";
  if (["0", "false", "no", "off"].includes(mode)) return "关闭";
  return mode || "默认";
}

function selectionLabel(selection: OcrSelection | undefined): string {
  if (!selection) return "正在读取 OCR 能力";
  if (selection.id === "vision") return "Apple Vision OCR";
  if (selection.id === "paddleocr") return "PaddleOCR";
  return "未启用本地 OCR";
}

function selectionStatusLabel(selection: OcrSelection | undefined): string {
  if (!selection?.id) return "将降级为页面图片识别";
  if (selection.enabled && selection.available) return "已选中且可运行";
  if (selection.required) return "必需引擎当前不可用";
  return "已选中但当前不可用";
}

function settingValue(values: Partial<GlobalSettingsData["values"]>, key: GlobalSettingKey, fallback = "") {
  return values[key] ?? fallback;
}

function paddlePresetFromValues(values: Partial<GlobalSettingsData["values"]>): PaddlePreset {
  const value = settingValue(values, "PADDLEOCR_PRESET", "custom").toLowerCase();
  return value === "performance" || value === "balanced" || value === "fast" ? value : "custom";
}

function paddleModelVersionFromValues(values: Partial<GlobalSettingsData["values"]>): PaddleModelVersion {
  const value = settingValue(values, "PADDLEOCR_MODEL_VERSION", "PP-OCRv6").toLowerCase();
  return value === "pp-ocrv5"
    ? "PP-OCRv5"
    : "PP-OCRv6";
}

function paddleModelOptions(
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

function paddleEffectiveValues(
  values: Partial<GlobalSettingsData["values"]>,
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

function paddlePresetCopyPatch(preset: PaddlePreset, values: PaddlePresetValues): Partial<Record<GlobalSettingKey, string>> {
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

function paddleModelDraftFromValues(values: Partial<GlobalSettingsData["values"]>): PaddleModelDraft {
  return {
    detectionModel: settingValue(values, "PADDLEOCR_DETECTION_MODEL"),
    recognitionModel: settingValue(values, "PADDLEOCR_RECOGNITION_MODEL"),
  };
}

function ocrPreferenceFromValues(values: Partial<GlobalSettingsData["values"]>): OcrPreference {
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

function ocrPreferencePatch(preference: OcrPreference): Partial<Record<GlobalSettingKey, string>> {
  // A top-level preference owns routing. Resetting both required flags prevents
  // a hidden advanced value from overriding the engine the user just selected.
  const required = { VISIONOCR_REQUIRED: "false", PADDLEOCR_REQUIRED: "false" } as const;
  if (preference === "vision") return { ...required, VISIONOCR_ENABLED: "true", PADDLEOCR_ENABLED: "false" };
  if (preference === "paddleocr") return { ...required, VISIONOCR_ENABLED: "false", PADDLEOCR_ENABLED: "true" };
  if (preference === "disabled") return { ...required, VISIONOCR_ENABLED: "false", PADDLEOCR_ENABLED: "false" };
  return { ...required, VISIONOCR_ENABLED: "auto", PADDLEOCR_ENABLED: "auto" };
}

interface OcrStatusPanelProps {
  config: ConfigData | null;
  ocr: OcrSettings | null;
  values: Partial<GlobalSettingsData["values"]>;
  savedValues: GlobalSettingsData["values"] | null;
  setValue: (key: GlobalSettingKey, value: string) => void;
  paddleCheck: OcrCheckResult | null;
  ocrState: "idle" | "checking" | "saving" | "saved";
  checkAndSaveOcr: () => void;
  visionCheck: VisionOcrCheckResult | null;
  visionCheckState: "idle" | "checking" | "checked";
  checkVision: () => Promise<void>;
  saveGlobalSettings: () => Promise<void>;
  globalSaveState: GlobalSaveState;
  paddleInstallState: PaddleOcrInstallState;
  paddleInstallProgress: PaddleOcrInstallProgress | null;
  paddleInstallError: string | null;
  installPaddleOcr: () => void;
  cancelPaddleOcrInstall: () => void;
}

function OcrStatusPanel({
  config,
  ocr,
  values,
  savedValues,
  setValue,
  paddleCheck,
  ocrState,
  checkAndSaveOcr,
  visionCheck,
  visionCheckState,
  checkVision,
  saveGlobalSettings,
  globalSaveState,
  paddleInstallState,
  paddleInstallProgress,
  paddleInstallError,
  installPaddleOcr,
  cancelPaddleOcrInstall,
}: OcrStatusPanelProps) {
  const paddleModelDraftsRef = useRef<Partial<Record<PaddleModelVersion, PaddleModelDraft>>>({});
  const seededSavedValuesRef = useRef<GlobalSettingsData["values"] | null>(null);
  useEffect(() => {
    if (!savedValues || savedValues === seededSavedValuesRef.current) return;
    // A reset or successful save is a new server snapshot; discard only the
    // old per-version cache and seed the version that the snapshot owns.
    seededSavedValuesRef.current = savedValues;
    paddleModelDraftsRef.current = {};
    if (paddlePresetFromValues(savedValues) === "custom") {
      const version = paddleModelVersionFromValues(savedValues);
      paddleModelDraftsRef.current[version] = paddleModelDraftFromValues(savedValues);
    }
  }, [savedValues]);
  const selection = config?.ocrSelection;
  const vision = engineStatus(config, "vision");
  const paddle = engineStatus(config, "paddleocr");
  const visionSelected = selection?.id === "vision";
  const paddleSelected = selection?.id === "paddleocr";
  const ocrPreference = ocrPreferenceFromValues(values);
  const paddlePreset = paddlePresetFromValues(values);
  const paddleEffective = paddleEffectiveValues(values, paddlePreset);
  const paddleV6DetectionModels = paddleModelOptions(
    PADDLE_V6_DETECTION_MODEL_OPTIONS,
    paddleEffective.detectionModel,
  );
  const paddleV6RecognitionModels = paddleModelOptions(
    PADDLE_V6_RECOGNITION_MODEL_OPTIONS,
    paddleEffective.recognitionModel,
  );
  const paddleV6DetectionIsCustom = isCustomPaddleModel(
    PADDLE_V6_DETECTION_MODEL_OPTIONS,
    paddleEffective.detectionModel,
  );
  const paddleV6RecognitionIsCustom = isCustomPaddleModel(
    PADDLE_V6_RECOGNITION_MODEL_OPTIONS,
    paddleEffective.recognitionModel,
  );
  const paddleUsesV6Models = paddleEffective.modelVersion === "PP-OCRv6";

  const setOcrPreference = (preference: OcrPreference) => {
    for (const [key, value] of Object.entries(ocrPreferencePatch(preference))) {
      setValue(key as GlobalSettingKey, value);
    }
  };

  const setOcrEngineMode = (id: "vision" | "paddleocr", value: string) => {
    // Enabling a card is equivalent to choosing it as the next recognition
    // route; keep the advanced controls and the top-level preference aligned
    // before the user presses Save.
    if (value === "true") {
      setOcrPreference(id);
      return;
    }
    setValue(id === "vision" ? "VISIONOCR_ENABLED" : "PADDLEOCR_ENABLED", value);
    // The required mode only makes sense while this engine is enabled; clear
    // a stale advanced flag immediately so the visible draft matches Main.
    if (value === "false") {
      setValue(id === "vision" ? "VISIONOCR_REQUIRED" : "PADDLEOCR_REQUIRED", "false");
    }
  };

  const setPaddlePreset = (nextPreset: PaddlePreset) => {
    if (nextPreset === "custom" && paddlePreset !== "custom") {
      // Materialize the visible preset before entering custom mode so the
      // editor never jumps back to unrelated stale values from the last save.
      paddleModelDraftsRef.current[paddleEffective.modelVersion] = {
        detectionModel: paddleEffective.detectionModel,
        recognitionModel: paddleEffective.recognitionModel,
      };
      for (const [key, value] of Object.entries(paddlePresetCopyPatch("custom", paddleEffective))) {
        if (key === "PADDLEOCR_PRESET") continue;
        setValue(key as GlobalSettingKey, value || "");
      }
    }
    setValue("PADDLEOCR_PRESET", nextPreset);
  };

  const setPaddleModelVersion = (nextVersion: PaddleModelVersion) => {
    if (paddlePreset !== "custom") return;
    const currentVersion = paddleModelVersionFromValues(values);
    paddleModelDraftsRef.current[currentVersion] = paddleModelDraftFromValues(values);
    const restored = paddleModelDraftsRef.current[nextVersion] || { detectionModel: "", recognitionModel: "" };
    setValue("PADDLEOCR_MODEL_VERSION", nextVersion);
    if (currentVersion !== nextVersion) {
      // Detection/recognition model names are version-specific. Isolate the
      // drafts to avoid mixed pipelines, then restore them on a round trip so
      // an unsaved custom ID is not silently discarded.
      setValue("PADDLEOCR_DETECTION_MODEL", restored.detectionModel);
      setValue("PADDLEOCR_RECOGNITION_MODEL", restored.recognitionModel);
    }
  };

  const setPaddleField = (key: Exclude<GlobalSettingKey, "PADDLEOCR_PRESET">, value: string) => {
    if (paddlePreset === "custom") {
      const modelKey = key === "PADDLEOCR_DETECTION_MODEL"
        ? "detectionModel"
        : key === "PADDLEOCR_RECOGNITION_MODEL"
          ? "recognitionModel"
          : null;
      if (modelKey) {
        const version = paddleModelVersionFromValues(values);
        paddleModelDraftsRef.current[version] = {
          ...(paddleModelDraftsRef.current[version] || paddleModelDraftFromValues(values)),
          [modelKey]: value,
        };
      }
      setValue(key, value);
      return;
    }
    // Read-only preset controls normally prevent this branch. Keeping the
    // fallback makes keyboard/programmatic edits safe and automatically opts
    // into custom with the currently visible preset values.
    const customPatch = paddlePresetCopyPatch("custom", paddleEffective);
    for (const [copyKey, copyValue] of Object.entries(customPatch)) {
      if (copyKey === "PADDLEOCR_PRESET") {
        setValue("PADDLEOCR_PRESET", "custom");
      } else {
        setValue(copyKey as GlobalSettingKey, copyKey === key ? value : copyValue || "");
      }
    }
  };

  return <Surface className={`${styles.panel} ${styles.ocrPanel}`} aria-labelledby="local-ocr-title">
    <div className={styles.sectionHeader}>
      <div className={styles.ocrHeaderCopy}>
        <p className={styles.kicker}>执行路由</p>
        <div className={styles.ocrHeaderLine}>
          <h2 className={styles.sectionTitle} id="local-ocr-title">本地 OCR</h2>
          <Button
            className={styles.ocrInstallButton}
            size="sm"
            variant="secondary"
            loading={paddleInstallState === "installing"}
            onClick={installPaddleOcr}
            startIcon={<Download size={15} />}
          >
            {paddleInstallState === "installed" ? "重新安装 PaddleOCR" : "安装 PaddleOCR"}
          </Button>
        </div>
      </div>
      <Terminal size={19} aria-hidden="true" />
    </div>
    <Text tone="muted" size="sm">状态来自 Main 进程；这里的参数会写入本机全局配置，不需要再编辑 .env。</Text>

    {paddleInstallState === "installing" && <div className={styles.ocrInstallFeedback} data-tone="accent" role="status" aria-live="polite">
      <div className={styles.ocrInstallFeedbackHeader}>
        <div className={styles.ocrInstallFeedbackCopy}>
          <Text tone="accent" size="sm" weight="bold">正在安装 PaddleOCR</Text>
          <Text tone="muted" size="xs">{paddleInstallProgress?.message || "正在准备安装环境…"}</Text>
        </div>
        <Button size="sm" variant="ghost" onClick={cancelPaddleOcrInstall}>取消安装</Button>
      </div>
      <Progress
        value={paddleInstallProgress?.percent ?? 0}
        label={`PaddleOCR 安装进度 ${Math.round(paddleInstallProgress?.percent ?? 0)}%`}
      />
    </div>}
    {paddleInstallState === "installed" && <div className={styles.ocrInstallFeedback} data-tone="success" role="status">
      <Text tone="success" size="sm"><Icon icon={CheckCircle2} size={15} /> PaddleOCR 已安装并验证通过，后续识别可以直接使用。</Text>
    </div>}
    {paddleInstallState === "canceled" && <div className={styles.ocrInstallFeedback} data-tone="warning" role="status">
      <Stack direction="row" justify="between" align="center" gap={3} wrap>
        <Text tone="warning" size="sm">安装已取消；已创建的运行环境会在下次安装时复用。</Text>
        <Button size="sm" variant="ghost" onClick={installPaddleOcr}>重试安装</Button>
      </Stack>
    </div>}
    {paddleInstallState === "error" && paddleInstallError && <div className={styles.ocrInstallFeedback} data-tone="danger">
      <InlineError message={paddleInstallError} onRetry={installPaddleOcr} />
    </div>}

    <div className={styles.ocrDecision} aria-live="polite">
      <div>
        <Text tone="subtle" size="xs" mono>下一次识别将使用</Text>
        <Text as="p" size="lg" weight="bold" className={styles.ocrDecisionTitle}>{selectionLabel(selection)}</Text>
        <Text tone="muted" size="sm">{selection?.id ? selection.label : selection?.reason || "正在从 Main 进程读取 OCR 选择。"}</Text>
      </div>
      <div className={styles.ocrDecisionMeta}>
        <StatusIndicator tone={selectionTone(selection)} label={selectionStatusLabel(selection)} />
        <Text tone="subtle" size="xs">选择方式：{selection ? selectionModeLabel(selection.mode) : "等待能力状态"}</Text>
        <Field label="首选 OCR 引擎" hint="保存全局配置后作用于下一次识别。">
          <Select value={ocrPreference} onChange={(event) => setOcrPreference(event.target.value as OcrPreference)}>
            <option value="auto">自动选择</option>
            <option value="vision">Apple Vision OCR</option>
            <option value="paddleocr">PaddleOCR</option>
            <option value="disabled">关闭本地 OCR</option>
          </Select>
        </Field>
      </div>
    </div>

    <div className={styles.ocrEngineGrid}>
      <article className={styles.ocrEngineCard} data-selected={visionSelected ? "true" : undefined} aria-labelledby="vision-ocr-title">
        <div className={styles.ocrEngineHeader}>
          <div>
            <Text as="h3" id="vision-ocr-title" size="md" weight="bold">Apple Vision OCR</Text>
            <Text tone="muted" size="sm">macOS Vision Framework，本机提取文字与坐标，不需要 Python。</Text>
          </div>
          <StatusIndicator tone={engineStatusTone(vision)} label={engineStatusLabel(vision)} />
        </div>
        {visionSelected && <Badge tone="accent">当前优先</Badge>}
        <dl className={styles.ocrEngineDetails}>
          <div><dt>运行模式</dt><dd>{engineModeLabel(vision?.mode || "")}</dd></div>
          <div><dt>能力来源</dt><dd>{vision?.available ? "已发现 Vision bridge 或 Swift 工具链" : "未发现 bridge 或 swiftc"}</dd></div>
          <div><dt>识别配置</dt><dd>{vision ? `${vision.recognitionLevel === "fast" ? "快速" : "高精度"} · ${vision.language || "自动语言"}` : "—"}</dd></div>
        </dl>
        <details className={styles.settingsDetails}>
          <summary>调整 Vision OCR 参数</summary>
          <div className={styles.formGrid}>
            <Field label="启用模式" hint="自动会在 macOS 能力可用时优先选择 Vision。"><Select value={settingValue(values, "VISIONOCR_ENABLED", "auto")} onChange={(event) => setOcrEngineMode("vision", event.target.value)}><option value="auto">自动</option><option value="true">开启</option><option value="false">关闭</option></Select></Field>
            <Field label="必需模式" hint="开启后 Vision 不可用会阻止识别。"><Select value={settingValue(values, "VISIONOCR_REQUIRED", "false")} onChange={(event) => setValue("VISIONOCR_REQUIRED", event.target.value)}><option value="false">可选</option><option value="true">必需</option></Select></Field>
            <Field label="识别语言" hint="可填写逗号分隔的语言，如 zh-Hans,en-US。"><Input value={settingValue(values, "VISIONOCR_LANGUAGE", "zh-Hans")} onChange={(event) => setValue("VISIONOCR_LANGUAGE", event.target.value)} /></Field>
            <Field label="识别精度"><Select value={settingValue(values, "VISIONOCR_RECOGNITION_LEVEL", "accurate")} onChange={(event) => setValue("VISIONOCR_RECOGNITION_LEVEL", event.target.value)}><option value="accurate">高精度</option><option value="fast">快速</option></Select></Field>
            <Field label="语言校正"><Select value={settingValue(values, "VISIONOCR_USE_LANGUAGE_CORRECTION", "true")} onChange={(event) => setValue("VISIONOCR_USE_LANGUAGE_CORRECTION", event.target.value)}><option value="true">启用</option><option value="false">关闭</option></Select></Field>
            <Field label="最低置信度" hint="0–1，低于此值的文字块不会作为证据。"><Input type="number" min="0" max="1" step="0.01" value={settingValue(values, "VISIONOCR_MIN_CONFIDENCE", "0.10")} onChange={(event) => setValue("VISIONOCR_MIN_CONFIDENCE", event.target.value)} /></Field>
            <Field label="每个视图最多文字块" hint="0 表示不限制。"><Input type="number" min="0" max="10000" step="1" value={settingValue(values, "VISIONOCR_MAX_BLOCKS_PER_VIEW", "0")} onChange={(event) => setValue("VISIONOCR_MAX_BLOCKS_PER_VIEW", event.target.value)} /></Field>
            <Field label="超时" hint="auto 按视图数量计算，也可填 10000–1800000 毫秒。"><Input value={settingValue(values, "VISIONOCR_TIMEOUT_MS", "auto")} onChange={(event) => setValue("VISIONOCR_TIMEOUT_MS", event.target.value)} /></Field>
            <Field label="Vision bridge 路径" hint="留空则优先使用打包内置 bridge；开发环境会自动编译。"><Input value={settingValue(values, "VISIONOCR_BINARY")} onChange={(event) => setValue("VISIONOCR_BINARY", event.target.value)} placeholder="自动" spellCheck={false} /></Field>
          </div>
          <Stack direction="row" justify="end" gap={2} wrap>
            <Button size="sm" variant="secondary" loading={globalSaveState === "saving"} onClick={() => void saveGlobalSettings()} startIcon={<Save size={15} />}>保存 Vision 参数</Button>
          </Stack>
        </details>
        {visionCheck?.ok === true && <div className={styles.ocrCheckResult} data-tone="success" role="status">
          <Text tone="success" size="sm"><Icon icon={CheckCircle2} size={15} /> 检查通过 · {visionCheck.engine} {visionCheck.modelVersion}</Text>
          <Text tone="subtle" size="xs">macOS {visionCheck.systemVersion}</Text>
        </div>}
        {visionCheck?.ok === false && <div className={styles.ocrCheckResult} data-tone="danger" role="alert">
          <Text tone="danger" size="sm">检查失败 · {visionCheck.error.message}</Text>
        </div>}
        <Stack direction="row" justify="between" align="center" wrap>
          <Text tone="subtle" size="xs">{visionCheckState === "idle" ? "尚未执行运行检查" : visionCheckState === "checking" ? "正在启动 Vision bridge…" : visionCheck?.ok ? "最近检查通过" : "最近检查失败"}</Text>
          <Button size="sm" variant="secondary" loading={visionCheckState === "checking"} onClick={() => void checkVision()} startIcon={<Wrench size={15} />}>检查 Vision OCR</Button>
        </Stack>
      </article>

      <article className={styles.ocrEngineCard} data-selected={paddleSelected ? "true" : undefined} aria-labelledby="paddle-ocr-title">
        <div className={styles.ocrEngineHeader}>
          <div>
            <Text as="h3" id="paddle-ocr-title" size="md" weight="bold">PaddleOCR</Text>
            <Text tone="muted" size="sm">Python + PaddleOCR，本地可选引擎。</Text>
          </div>
          <StatusIndicator tone={engineStatusTone(paddle)} label={engineStatusLabel(paddle)} />
        </div>
        {paddleSelected && <Badge tone="accent">当前优先</Badge>}
        <dl className={styles.ocrEngineDetails}>
          <div><dt>运行模式</dt><dd>{engineModeLabel(paddle?.mode || "")}</dd></div>
          <div><dt>能力来源</dt><dd>{paddle?.available ? "已发现 Python 环境与 PaddleOCR" : "未发现可用 Python 环境"}</dd></div>
          <div><dt>模型配置</dt><dd>{paddle ? `${paddle.modelVersion || "PP-OCRv6"} · ${paddle.presetLabel || paddle.profileLabel || paddle.profile || "自定义"}` : "—"}</dd></div>
        </dl>
        <details className={styles.settingsDetails}>
          <summary>调整 PaddleOCR 参数</summary>
          <div className={styles.formGrid}>
            <Field label="启用模式" hint="自动会在检测到 Python 环境时启用。开启后将优先使用 PaddleOCR。"><Select value={settingValue(values, "PADDLEOCR_ENABLED", "auto")} onChange={(event) => setOcrEngineMode("paddleocr", event.target.value)}><option value="auto">自动</option><option value="true">开启</option><option value="false">关闭</option></Select></Field>
            <Field label="必需模式" hint="开启后 PaddleOCR 不可用会阻止识别。"><Select value={settingValue(values, "PADDLEOCR_REQUIRED", "false")} onChange={(event) => setValue("PADDLEOCR_REQUIRED", event.target.value)}><option value="false">可选</option><option value="true">必需</option></Select></Field>
            <Field label="参数预设" hint="命名预设会同时切换 PP-OCRv6 模型、批量、检测边长和输出过滤；自定义保留手动参数。"><Select value={paddlePreset} onChange={(event) => setPaddlePreset(event.target.value as PaddlePreset)}><option value="custom">自定义</option><option value="performance">性能（质量优先）</option><option value="balanced">平衡（推荐）</option><option value="fast">快速（低延迟）</option></Select></Field>
            <Field label="模型版本" hint="切换版本会隔离检测/识别模型覆盖；切回时恢复本次未保存的版本草稿。"><Select value={paddleEffective.modelVersion} onChange={(event) => setPaddleModelVersion(event.target.value as PaddleModelVersion)} disabled={paddlePreset !== "custom"}>{PADDLE_MODEL_VERSION_OPTIONS.map((option) => <option key={option.value} value={option.value}>{option.label}</option>)}</Select></Field>
            <Field label="兼容性能档" hint="仅自定义模式使用；用于兼容已有 PP-OCRv5 配置。"><Select value={paddleEffective.profile || "balanced"} onChange={(event) => setPaddleField("PADDLEOCR_PROFILE", event.target.value)} disabled={paddlePreset !== "custom"}><option value="fast">快速</option><option value="balanced">平衡</option><option value="accurate">高精度</option></Select></Field>
            <Field label="识别语言"><Input value={settingValue(values, "PADDLEOCR_LANGUAGE", "ch")} onChange={(event) => setValue("PADDLEOCR_LANGUAGE", event.target.value)} /></Field>
            <Field label="计算设备"><Input value={settingValue(values, "PADDLEOCR_DEVICE", "cpu")} onChange={(event) => setValue("PADDLEOCR_DEVICE", event.target.value)} /></Field>
            <Field label="检测模型" htmlFor="paddle-detection-model-select" hint={paddleUsesV6Models ? "PP-OCRv6 可选择 medium、small 或 tiny；也可输入自定义模型 ID。" : "PP-OCRv5 自定义模型可手动填写；留空使用当前版本默认模型。"}>
              {paddleUsesV6Models
                ? <div className={styles.paddleModelControl}>
                  <Select id="paddle-detection-model-select" aria-describedby="paddle-detection-model-select-hint" value={paddleEffective.detectionModel} onChange={(event) => setPaddleField("PADDLEOCR_DETECTION_MODEL", event.target.value)} disabled={paddlePreset !== "custom"}>{paddleV6DetectionModels.map((option) => <option key={option.value || "default"} value={option.value}>{option.label}</option>)}</Select>
                  <Input aria-describedby="paddle-detection-model-select-hint" value={paddleV6DetectionIsCustom ? paddleEffective.detectionModel : ""} onChange={(event) => setPaddleField("PADDLEOCR_DETECTION_MODEL", event.target.value)} placeholder="输入自定义模型 ID（可选）" aria-label="自定义检测模型 ID" disabled={paddlePreset !== "custom"} />
                </div>
                : <Input id="paddle-detection-model-select" value={paddleEffective.detectionModel} onChange={(event) => setPaddleField("PADDLEOCR_DETECTION_MODEL", event.target.value)} placeholder="使用默认" disabled={paddlePreset !== "custom"} />}
            </Field>
            <Field label="识别模型" htmlFor="paddle-recognition-model-select" hint={paddleUsesV6Models ? "PP-OCRv6 可选择 medium、small 或 tiny；也可输入自定义模型 ID。" : "PP-OCRv5 自定义模型可手动填写；留空使用当前版本默认模型。"}>
              {paddleUsesV6Models
                ? <div className={styles.paddleModelControl}>
                  <Select id="paddle-recognition-model-select" aria-describedby="paddle-recognition-model-select-hint" value={paddleEffective.recognitionModel} onChange={(event) => setPaddleField("PADDLEOCR_RECOGNITION_MODEL", event.target.value)} disabled={paddlePreset !== "custom"}>{paddleV6RecognitionModels.map((option) => <option key={option.value || "default"} value={option.value}>{option.label}</option>)}</Select>
                  <Input aria-describedby="paddle-recognition-model-select-hint" value={paddleV6RecognitionIsCustom ? paddleEffective.recognitionModel : ""} onChange={(event) => setPaddleField("PADDLEOCR_RECOGNITION_MODEL", event.target.value)} placeholder="输入自定义模型 ID（可选）" aria-label="自定义识别模型 ID" disabled={paddlePreset !== "custom"} />
                </div>
                : <Input id="paddle-recognition-model-select" value={paddleEffective.recognitionModel} onChange={(event) => setPaddleField("PADDLEOCR_RECOGNITION_MODEL", event.target.value)} placeholder="使用默认" disabled={paddlePreset !== "custom"} />}
            </Field>
            <Field label="识别批量大小"><Input type="number" min="1" max="64" step="1" value={paddleEffective.recognitionBatchSize} onChange={(event) => setPaddleField("PADDLEOCR_RECOGNITION_BATCH_SIZE", event.target.value)} placeholder="使用性能档" disabled={paddlePreset !== "custom"} /></Field>
            <Field label="最低置信度" hint="0–1；低于此值的文字块不会作为证据。"><Input type="number" min="0" max="1" step="0.01" value={paddleEffective.minimumConfidence} onChange={(event) => setPaddleField("PADDLEOCR_MIN_CONFIDENCE", event.target.value)} disabled={paddlePreset !== "custom"} /></Field>
            <Field label="每个视图最多文字块" hint="0 表示不限制；限制时仍均匀覆盖整页。"><Input type="number" min="0" max="10000" step="1" value={paddleEffective.maxBlocksPerView} onChange={(event) => setPaddleField("PADDLEOCR_MAX_BLOCKS_PER_VIEW", event.target.value)} disabled={paddlePreset !== "custom"} /></Field>
            <Field label="检测最长边" hint="320–4096；越小通常越快，但小字细节可能减少。"><Input type="number" min="320" max="4096" step="1" value={paddleEffective.textDetLimitSideLen} onChange={(event) => setPaddleField("PADDLEOCR_TEXT_DET_LIMIT_SIDE_LEN", event.target.value)} placeholder="Paddle 默认" disabled={paddlePreset !== "custom"} /></Field>
            <Field label="OCR 超时" hint="auto 按视图数量计算，也可填 10000–3600000 毫秒。"><Input value={settingValue(values, "PADDLEOCR_TIMEOUT_MS", "auto")} onChange={(event) => setValue("PADDLEOCR_TIMEOUT_MS", event.target.value)} /></Field>
            <Field label="Python 环境路径" hint="开发环境可填 .venv-paddleocr/bin/python；打包版请填写已安装 PaddleOCR 的 Python 路径。"><Input value={settingValue(values, "PADDLEOCR_PYTHON")} onChange={(event) => setValue("PADDLEOCR_PYTHON", event.target.value)} placeholder="python3 或绝对路径" spellCheck={false} /></Field>
          </div>
          {paddlePreset === "fast" && <Text tone="warning" size="sm">快速预设使用 tiny 模型和更高置信度门槛；复杂手写、低置信度文字可能减少。</Text>}
          <Stack direction="row" justify="between" align="center" wrap>
            <Text tone="subtle" size="xs">{ocr?.setupCompleted ? "当前环境已完成设置" : "先检查路径，再保存参数"}</Text>
            <Stack direction="row" gap={2} wrap>
              <Button size="sm" variant="secondary" loading={ocrState === "checking" || ocrState === "saving"} onClick={checkAndSaveOcr} startIcon={<Wrench size={15} />}>验证并保存环境</Button>
              <Button size="sm" variant="secondary" loading={globalSaveState === "saving"} onClick={() => void saveGlobalSettings()} startIcon={<Save size={15} />}>保存 Paddle 参数</Button>
            </Stack>
          </Stack>
          {paddleCheck?.ok === true && <div className={styles.ocrCheckResult} data-tone="success" role="status">
            <Text tone="success" size="sm"><Icon icon={CheckCircle2} size={15} /> 检查通过 · Paddle {paddleCheck.paddleVersion} / PaddleOCR {paddleCheck.paddleOcrVersion}</Text>
          </div>}
          {paddleCheck?.ok === false && <div className={styles.ocrCheckResult} data-tone="danger" role="alert">
            <Text tone="danger" size="sm">检查失败 · {paddleCheck.error.message}</Text>
          </div>}
        </details>
      </article>
    </div>

    <Text tone="subtle" size="xs" className={styles.ocrFootnote}>首选引擎会同步配置两套 OCR 的启用状态；手动选择会关闭另一引擎及冲突的必需模式。自动模式在 macOS 上优先 Vision OCR。OCR 只提供文字证据，最终结果仍由视觉模型结合页面图片确认。</Text>
  </Surface>;
}

export function GlobalSettingsPage() {
  const config = useProjectStore((state) => state.config);
  const setConfig = useProjectStore((state) => state.setConfig);
  const ocr = useSettingsStore((state) => state.ocr);
  const setOcr = useSettingsStore((state) => state.setOcr);
  const theme = useUiStore((state) => state.theme);
  const density = useUiStore((state) => state.density);
  const setTheme = useUiStore((state) => state.setTheme);
  const setDensity = useUiStore((state) => state.setDensity);
  const setToast = useUiStore((state) => state.setToast);
  const [providerId, setProviderId] = useState(config?.providers[0]?.id || "");
  const [apiKey, setApiKey] = useState("");
  const [showApiKey, setShowApiKey] = useState(false);
  const [globalSettings, setGlobalSettings] = useState<GlobalSettingsData | null>(null);
  const [globalValues, setGlobalValues] = useState<Partial<GlobalSettingsData["values"]>>({});
  const [dirtyGlobalKeys, setDirtyGlobalKeys] = useState<Set<GlobalSettingKey>>(() => new Set());
  const [globalSaveState, setGlobalSaveState] = useState<GlobalSaveState>("idle");
  const [globalError, setGlobalError] = useState<string | null>(null);
  const [paddleCheck, setPaddleCheck] = useState<OcrCheckResult | null>(null);
  const [visionCheck, setVisionCheck] = useState<VisionOcrCheckResult | null>(null);
  const [visionCheckState, setVisionCheckState] = useState<"idle" | "checking" | "checked">("idle");
  const [keyState, setKeyState] = useState<"idle" | "saving" | "saved" | "error">("idle");
  const [ocrState, setOcrState] = useState<"idle" | "checking" | "saving" | "saved">("idle");
  const [paddleInstallState, setPaddleInstallState] = useState<PaddleOcrInstallState>("idle");
  const [paddleInstallProgress, setPaddleInstallProgress] = useState<PaddleOcrInstallProgress | null>(null);
  const [paddleInstallError, setPaddleInstallError] = useState<string | null>(null);
  const [jsonSchemaState, setJsonSchemaState] = useState<"idle" | "checking">("idle");
  const [jsonSchemaResult, setJsonSchemaResult] = useState<JsonSchemaCapabilityResult | null>(null);
  const [jsonSchemaError, setJsonSchemaError] = useState<string | null>(null);

  useEffect(() => {
    setProviderId((previous) => {
      const builtins = config?.providers.filter((provider) => !provider.id.startsWith("openai-compatible:")) || [];
      return builtins.some((provider) => provider.id === previous) ? previous : builtins[0]?.id || "";
    });
  }, [config]);

  useEffect(() => {
    setJsonSchemaResult(null);
    setJsonSchemaError(null);
  }, [providerId]);

  useEffect(() => {
    let active = true;
    void (async () => {
      try {
        const api = requireGlobalSettingsApi();
        const [savedGlobalSettings, savedOcrSettings] = await Promise.all([
          unwrap(await api.settings.getGlobalSettings()),
          unwrap(await api.settings.getOcrSettings()),
        ]);
        if (!active) return;
        setGlobalSettings(savedGlobalSettings);
        setGlobalValues(savedGlobalSettings.values);
        setDirtyGlobalKeys(new Set());
        setOcr(savedOcrSettings);
      } catch (error) {
        if (active) setGlobalError(appErrorFromUnknown(error).message);
      }
    })();
    return () => { active = false; };
  }, [setOcr]);

  useEffect(() => {
    let active = true;
    try {
      const api = requireGlobalSettingsApi();
      if (typeof api.settings?.onPaddleOcrInstallProgress !== "function") return undefined;
      const unsubscribe = api.settings.onPaddleOcrInstallProgress((progress) => {
        if (!active) return;
        setPaddleInstallState("installing");
        setPaddleInstallError(null);
        setPaddleInstallProgress(progress);
      });
      return () => {
        active = false;
        unsubscribe();
      };
    } catch {
      // The settings page remains usable when HMR leaves an older Preload in
      // the window; the install action will show its own recovery error.
      return () => { active = false; };
    }
  }, []);

  const provider = config?.providers.find((item) => item.id === providerId);
  const providerBaseUrlKey = provider ? PROVIDER_BASE_URL_KEYS[provider.id] : undefined;
  const providerKeyConfigured = provider ? (globalSettings?.keyConfigured[provider.id] ?? provider.configured) : false;

  const setValue = (key: GlobalSettingKey, value: string) => {
    setGlobalValues((previous) => ({ ...previous, [key]: value }));
    setDirtyGlobalKeys((previous) => new Set(previous).add(key));
    setGlobalError(null);
    setGlobalSaveState((previous) => previous === "saved" || previous === "error" ? "idle" : previous);
  };

  const saveGlobalSettings = async (reset = false) => {
    setGlobalSaveState("saving");
    setGlobalError(null);
    try {
      const api = requireGlobalSettingsApi();
      // `globalValues` is the resolved view (.env + defaults), so only send
      // fields the user actually touched; otherwise a normal save would turn
      // every inherited default into a stored override.
      const patch = Object.fromEntries(
        [...dirtyGlobalKeys].map((key) => [key, globalValues[key] ?? ""]),
      ) as GlobalSettingsPatch;
      const saved = await unwrap(await api.settings.saveGlobalSettings(reset ? { reset: true } : { values: patch }));
      setGlobalSettings(saved);
      setGlobalValues(saved.values);
      setDirtyGlobalKeys(new Set());
      setConfig(await unwrap(await api.app.getConfig()));
      setGlobalSaveState("saved");
      setToast({ tone: "success", message: saved.restartRequired ? "全局配置已保存；工作流路径将在下次启动生效" : reset ? "已恢复 .env 与内置默认值" : "全局配置已保存" });
    } catch (error) {
      setGlobalSaveState("error");
      setGlobalError(appErrorFromUnknown(error).message);
    }
  };

  const saveKey = async () => {
    if (!provider || !KEY_PROVIDERS.has(provider.id)) return;
    setKeyState("saving");
    setGlobalError(null);
    try {
      const api = getSlateSync();
      const savedKey = await unwrap(await api.settings.saveProviderKey({ provider: provider.id, apiKey: apiKey.trim() }));
      setApiKey("");
      setShowApiKey(false);
      setConfig(await unwrap(await api.app.getConfig()));
      // Keep unsaved endpoint/OCR edits in the form while updating only the
      // provider readiness flag returned by the key-save operation.
      setGlobalSettings((previous) => previous ? {
        ...previous,
        keyConfigured: { ...previous.keyConfigured, [provider.id]: savedKey.configured },
      } : previous);
      setKeyState("saved");
      setToast({ tone: "success", message: "Provider 配置已保存；密钥不会回显" });
    } catch (error) {
      setKeyState("error");
      setGlobalError(appErrorFromUnknown(error).message);
    }
  };

  const checkAndSaveOcr = async () => {
    setGlobalError(null);
    setPaddleCheck(null);
    setOcrState("checking");
    try {
      const api = getSlateSync();
      const pythonPath = settingValue(globalValues, "PADDLEOCR_PYTHON").trim();
      const check = await unwrap(await api.settings.checkOcr({ pythonPath }));
      setPaddleCheck(check);
      if (!check.ok) throw new Error(check.error.message);
      setOcrState("saving");
      const saved = await unwrap(await api.settings.saveOcrSettings({ pythonPath }));
      setOcr(saved);
      setGlobalValues((previous) => ({ ...previous, PADDLEOCR_PYTHON: saved.pythonPath }));
      setGlobalSettings((previous) => previous ? {
        ...previous,
        values: { ...previous.values, PADDLEOCR_PYTHON: saved.pythonPath },
        overrides: previous.overrides.includes("PADDLEOCR_PYTHON")
          ? previous.overrides
          : [...previous.overrides, "PADDLEOCR_PYTHON"],
      } : previous);
      setDirtyGlobalKeys((previous) => {
        const next = new Set(previous);
        next.delete("PADDLEOCR_PYTHON");
        return next;
      });
      setConfig(await unwrap(await api.app.getConfig()));
      setOcrState("saved");
      setToast({ tone: "success", message: "OCR 环境已验证并保存" });
    } catch (error) {
      setOcrState("idle");
      setGlobalError(appErrorFromUnknown(error).message);
    }
  };

  const checkVision = async () => {
    setVisionCheck(null);
    setVisionCheckState("checking");
    try {
      const result = await unwrap(await getSlateSync().settings.checkVisionOcr());
      setVisionCheck(result);
      setVisionCheckState("checked");
      if (result.ok) setToast({ tone: "success", message: "Apple Vision OCR 检查通过" });
    } catch (error) {
      const appError = appErrorFromUnknown(error);
      setVisionCheck({ ok: false, error: { code: appError.code, message: appError.message } });
      setVisionCheckState("checked");
    }
  };

  const installPaddleOcr = async () => {
    if (paddleInstallState === "installing") return;
    setPaddleInstallState("installing");
    setPaddleInstallProgress({ stage: "detect-python", percent: 0, message: "正在准备 PaddleOCR 安装…" });
    setPaddleInstallError(null);
    try {
      const api = requireGlobalSettingsApi();
      if (typeof api.settings?.installPaddleOcr !== "function") {
        throw new Error("当前 Renderer 与 Preload 版本不一致，无法安装 PaddleOCR。请完全退出 SlateSync 后重新启动；不要只刷新窗口。");
      }
      const installed = await unwrap(await api.settings.installPaddleOcr());
      setOcr(installed);
      // A one-click install intentionally owns this path: leaving an old
      // manual path dirty would make the successful installation unreachable.
      setGlobalValues((previous) => ({ ...previous, PADDLEOCR_PYTHON: installed.pythonPath }));
      setGlobalSettings((previous) => previous ? {
        ...previous,
        values: { ...previous.values, PADDLEOCR_PYTHON: installed.pythonPath },
        overrides: previous.overrides.includes("PADDLEOCR_PYTHON")
          ? previous.overrides
          : [...previous.overrides, "PADDLEOCR_PYTHON"],
      } : previous);
      setDirtyGlobalKeys((previous) => {
        const next = new Set(previous);
        next.delete("PADDLEOCR_PYTHON");
        return next;
      });
      setConfig(await unwrap(await api.app.getConfig()));
      setPaddleInstallProgress({ stage: "completed", percent: 100, message: "PaddleOCR 已安装并验证通过。" });
      setPaddleInstallState("installed");
      setToast({ tone: "success", message: "PaddleOCR 已安装并验证通过" });
    } catch (error) {
      const appError = appErrorFromUnknown(error);
      setPaddleInstallError(appError.message);
      setPaddleInstallState(appError.code === "PADDLEOCR_INSTALL_CANCELED" ? "canceled" : "error");
    }
  };

  const cancelPaddleOcrInstall = async () => {
    if (paddleInstallState !== "installing") return;
    try {
      const api = requireGlobalSettingsApi();
      if (typeof api.settings?.cancelPaddleOcrInstall !== "function") {
        throw new Error("当前 Renderer 与 Preload 版本不一致，无法取消 PaddleOCR 安装。请完全退出 SlateSync 后重新启动；不要只刷新窗口。");
      }
      await unwrap(await api.settings.cancelPaddleOcrInstall());
    } catch (error) {
      setPaddleInstallError(appErrorFromUnknown(error).message);
      setPaddleInstallState("error");
    }
  };

  // The capability probe stays in Main so endpoint details, API keys and
  // project images never enter a Renderer request body.
  const checkCompatibleJsonSchema = async () => {
    setJsonSchemaState("checking");
    setJsonSchemaError(null);
    try {
      setJsonSchemaResult(await unwrap(await getSlateSync().settings.checkCompatibleJsonSchema()));
    } catch (error) {
      setJsonSchemaResult(null);
      setJsonSchemaError(appErrorFromUnknown(error).message);
    } finally {
      setJsonSchemaState("idle");
    }
  };

  // Keep this header concise; the dedicated 说明 page owns the longer setup guide.
  return <div className={styles.page}>
    <div className={styles.pageHeader}>
      <div>
        <p className={styles.eyebrow}>设备设置</p>
        <h1 className={styles.heading}>全局设置</h1>
      </div>
      <div className={styles.pageActions}>
        <Button loading={globalSaveState === "saving"} onClick={() => void saveGlobalSettings()} startIcon={<Save size={15} />}>保存全局配置</Button>
        <Button variant="ghost" disabled={globalSaveState === "saving"} onClick={() => void saveGlobalSettings(true)} startIcon={<RotateCcw size={15} />}>恢复环境默认</Button>
      </div>
    </div>

    {globalError && <InlineError message={globalError} />}

    <div className={`${styles.grid} ${styles.gridTwo}`}>
      <div className={styles.settingsOverviewGrid} data-testid="settings-overview-grid">
        <Surface className={styles.panel}>
        <div className={styles.sectionHeader}><div><p className={styles.kicker}>Provider</p><h2 className={styles.sectionTitle}>访问密钥与接口</h2></div><KeyRound size={19} aria-hidden="true" /></div>
        <Text tone="muted" size="sm">密钥保存在独立的本机凭据文件，保存后不会回显；Base URL 等普通参数写入全局配置。</Text>
        <div className={styles.formGrid} style={{ marginTop: 18 }}>
          <Field label="Provider"><Select value={providerId} onChange={(event) => setProviderId(event.target.value)}>{config?.providers.filter((item) => !item.id.startsWith("openai-compatible:")).map((item) => <option key={item.id} value={item.id}>{item.label}{item.configured ? " · 已配置" : " · 未配置"}</option>)}</Select></Field>
          <Field label="API Key" hint={providerKeyConfigured ? "已保存密钥；输入新值可替换，留空并保存可清除应用覆盖。" : "密钥只在 Main 进程中使用，不会显示在页面或项目数据里。"}>
            <div className={styles.secretInputRow}>
              <Input type={showApiKey ? "text" : "password"} value={apiKey} onChange={(event) => setApiKey(event.target.value)} autoComplete="new-password" spellCheck={false} disabled={!provider || !KEY_PROVIDERS.has(provider.id)} placeholder={providerKeyConfigured ? "已配置 · 输入新 Key 可替换" : "粘贴 API Key"} />
              <Button type="button" size="sm" variant="ghost" aria-label={showApiKey ? "隐藏 API Key" : "显示 API Key"} onClick={() => setShowApiKey((visible) => !visible)} disabled={!provider || !KEY_PROVIDERS.has(provider.id)}>{showApiKey ? <EyeOff size={15} aria-hidden="true" /> : <Eye size={15} aria-hidden="true" />}{showApiKey ? "隐藏" : "显示"}</Button>
            </div>
          </Field>
          {providerBaseUrlKey && <Field label="Base URL" hint="只支持 http(s)，不能包含账号、密码、查询参数或片段。"><Input value={settingValue(globalValues, providerBaseUrlKey)} onChange={(event) => setValue(providerBaseUrlKey, event.target.value)} spellCheck={false} /></Field>}
          {provider?.id === "openrouter" && <Field label="OpenRouter 应用标识 URL" hint="会作为 HTTP-Referer 发送；可留空。"><Input value={settingValue(globalValues, "OPENROUTER_SITE_URL")} onChange={(event) => setValue("OPENROUTER_SITE_URL", event.target.value)} spellCheck={false} /></Field>}
          <Stack direction="row" justify="between" align="center" className={styles.formFieldFull}>
            <Text tone={keyState === "error" ? "danger" : "subtle"} size="xs">{keyState === "saved" ? "密钥已保存" : provider?.requiredEnv?.join(" / ") || ""}</Text>
            <Button onClick={() => void saveKey()} loading={keyState === "saving"} startIcon={<Save size={15} />}>保存密钥</Button>
          </Stack>
        </div>
        </Surface>

        <Surface className={styles.panel}>
          <div className={styles.sectionHeader}><div><p className={styles.kicker}>外观</p><h2 className={styles.sectionTitle}>工作台外观</h2></div>{theme === "system" ? <Monitor size={18} aria-hidden="true" /> : theme === "dark" ? <Moon size={18} aria-hidden="true" /> : <Sun size={18} aria-hidden="true" />}</div>
          <div className={styles.grid} style={{ marginTop: 14 }}><Field label="主题" hint={theme === "system" ? "自动跟随 macOS 的浅色/深色外观。" : "侧栏主题图标与此设置保持同步。"}><Select value={theme} onChange={(event) => setTheme(event.target.value as Theme)}><option value="system">自动 · 跟随系统</option><option value="dark">深色 · Graphite</option><option value="light">浅色 · Paper</option></Select></Field><Field label="信息密度"><Select value={density} onChange={(event) => setDensity(event.target.value as "comfortable" | "compact")}><option value="comfortable">标准</option><option value="compact">紧凑 · 大表格</option></Select></Field></div>
        </Surface>
      </div>

      {provider?.id === "openai-compatible" && <Surface className={`${styles.panel} ${styles.runtimeSettingsPanel}`} tone="accent">
        <div className={styles.sectionHeader}><div><p className={styles.kicker}>兼容接口</p><h2 className={styles.sectionTitle}>模型与响应格式</h2></div><Braces size={19} aria-hidden="true" /></div>
        <Text tone="muted" size="sm">Key、Base URL 与模型 ID 都需要配置；其他选项决定兼容服务商接受哪一种请求格式。</Text>
        <div className={styles.formGrid} style={{ marginTop: 18 }}>
          <Field label="模型 ID"><Input value={settingValue(globalValues, "OPENAI_COMPATIBLE_MODEL")} onChange={(event) => setValue("OPENAI_COMPATIBLE_MODEL", event.target.value)} placeholder="your-vision-model" spellCheck={false} /></Field>
          <Field label="请求接口"><Select value={settingValue(globalValues, "OPENAI_COMPATIBLE_API_MODE", "chat-completions")} onChange={(event) => setValue("OPENAI_COMPATIBLE_API_MODE", event.target.value)}><option value="chat-completions">Chat Completions</option><option value="responses">Responses</option></Select></Field>
          <Field label="JSON 模式"><Select value={settingValue(globalValues, "OPENAI_COMPATIBLE_JSON_MODE", "json_object")} onChange={(event) => setValue("OPENAI_COMPATIBLE_JSON_MODE", event.target.value)}><option value="json_schema">JSON Schema</option><option value="json_object">JSON Object</option><option value="prompt">Prompt 约束</option></Select></Field>
          <Field label="图片细节"><Select value={settingValue(globalValues, "OPENAI_COMPATIBLE_IMAGE_DETAIL", "high")} onChange={(event) => setValue("OPENAI_COMPATIBLE_IMAGE_DETAIL", event.target.value)}><option value="auto">自动</option><option value="low">低</option><option value="high">高</option><option value="original">原始</option></Select></Field>
          <Stack direction="row" justify="between" align="center" className={styles.formFieldFull}>
            <Text tone={jsonSchemaResult?.supported ? "success" : "subtle"} size="xs">{jsonSchemaResult ? `${jsonSchemaResult.transport} · HTTP ${jsonSchemaResult.status || "未知"}` : "尚未检测接口能力"}</Text>
            <Button onClick={() => void checkCompatibleJsonSchema()} loading={jsonSchemaState === "checking"} disabled={!provider.configured} startIcon={<Braces size={15} />}>测试 JSON Schema</Button>
          </Stack>
        </div>
        {jsonSchemaResult && <Text tone={jsonSchemaResult.supported ? "success" : "warning"} size="sm" style={{ marginTop: 12 }}><Icon icon={jsonSchemaResult.supported ? CheckCircle2 : Braces} size={15} /> {jsonSchemaResult.message}</Text>}
        {jsonSchemaError && <div style={{ marginTop: 12 }}><InlineError message={jsonSchemaError} /></div>}
      </Surface>}

      <CustomProviderSettingsPanel />

      <Surface className={`${styles.panel} ${styles.runtimeSettingsPanel}`}>
        <div className={styles.sectionHeader}><div><p className={styles.kicker}>运行参数</p><h2 className={styles.sectionTitle}>识别与存储</h2></div><Terminal size={19} aria-hidden="true" /></div>
        <Text tone="muted" size="sm">这些参数会即时作用于后续任务；清空某个字段即可回退到 .env 或内置默认值。</Text>
        <div className={styles.formGrid} style={{ marginTop: 18 }}>
          <Field label="请求体上限（MB）"><Input type="number" min="20" max="200" step="1" value={settingValue(globalValues, "MAX_BODY_MB", "80")} onChange={(event) => setValue("MAX_BODY_MB", event.target.value)} /></Field>
          <Field label="模型请求超时（毫秒）" hint="30000–3600000。"><Input type="number" min="30000" max="3600000" step="1000" value={settingValue(globalValues, "MODEL_REQUEST_TIMEOUT_MS", "180000")} onChange={(event) => setValue("MODEL_REQUEST_TIMEOUT_MS", event.target.value)} /></Field>
          <Field label="超时重试次数" hint="0–3。"><Input type="number" min="0" max="3" step="1" value={settingValue(globalValues, "MODEL_REQUEST_MAX_RETRIES", "1")} onChange={(event) => setValue("MODEL_REQUEST_MAX_RETRIES", event.target.value)} /></Field>
          <Field label="并行提交页数" hint="1–6。服务商限流时可降为 1。"><Input type="number" min="1" max="6" step="1" value={settingValue(globalValues, "MODEL_PAGE_CONCURRENCY", "2")} onChange={(event) => setValue("MODEL_PAGE_CONCURRENCY", event.target.value)} /></Field>
          <Field label="并行识别任务数" hint="1–16。调低可减少本机资源占用。"><Input type="number" min="1" max="16" step="1" value={settingValue(globalValues, "MAX_CONCURRENT_RECOGNITIONS", "1")} onChange={(event) => setValue("MAX_CONCURRENT_RECOGNITIONS", event.target.value)} /></Field>
          <Field label="工作流配置路径" hint="开发环境读取；修改后下次启动生效。"><Input value={settingValue(globalValues, "SLATESYNC_CONFIG_PATH", "slatesync.config.json")} onChange={(event) => setValue("SLATESYNC_CONFIG_PATH", event.target.value)} spellCheck={false} /></Field>
          <Field label="Paddle 模型缓存路径" hint="留空使用应用默认缓存目录。"><Input value={settingValue(globalValues, "PADDLE_PDX_CACHE_HOME")} onChange={(event) => setValue("PADDLE_PDX_CACHE_HOME", event.target.value)} placeholder="应用默认" spellCheck={false} /></Field>
        </div>
        <div className={styles.settingsSaveRow}>
          <Text tone="subtle" size="xs">已覆盖 {globalSettings?.overrides.length ?? 0} 项非敏感配置</Text>
          <Button size="sm" loading={globalSaveState === "saving"} onClick={() => void saveGlobalSettings()} startIcon={<Save size={15} />}>保存运行参数</Button>
        </div>
      </Surface>

      <OcrStatusPanel config={config} ocr={ocr} values={globalValues} savedValues={globalSettings?.values || null} setValue={setValue} paddleCheck={paddleCheck} ocrState={ocrState} checkAndSaveOcr={checkAndSaveOcr} visionCheck={visionCheck} visionCheckState={visionCheckState} checkVision={checkVision} saveGlobalSettings={() => saveGlobalSettings()} globalSaveState={globalSaveState} paddleInstallState={paddleInstallState} paddleInstallProgress={paddleInstallProgress} paddleInstallError={paddleInstallError} installPaddleOcr={() => void installPaddleOcr()} cancelPaddleOcrInstall={() => void cancelPaddleOcrInstall()} />
    </div>
  </div>;
}

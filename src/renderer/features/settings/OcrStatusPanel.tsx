import { memo, useEffect, useMemo, useRef } from "react";
import { useShallow } from "zustand/react/shallow";
import { CheckCircle2, Download, Terminal, Wrench } from "lucide-react";
import type { ConfigData, GlobalSettingKey, GlobalSettingValues, OcrCheckResult, OcrEngineStatus, OcrSettings, PaddleOcrInstallProgress, VisionOcrCheckResult } from "../../../shared/contracts/index.js";
import { Badge, Button, Field, Icon, InlineError, Input, Progress, Select, Stack, StatusIndicator, Surface, Text } from "../../design-system";
import { useGlobalSettingsStore } from "../../state";
import styles from "../../app/app.module.css";
import {
  PADDLE_ADVANCED_KEYS,
  PADDLE_MODEL_VERSION_OPTIONS,
  PADDLE_V6_DETECTION_MODEL_OPTIONS,
  PADDLE_V6_RECOGNITION_MODEL_OPTIONS,
  VISION_ADVANCED_KEYS,
  engineModeLabel,
  isCustomPaddleModel,
  paddleEffectiveValues,
  paddleModelDraftFromValues,
  paddleModelOptions,
  paddleModelVersionFromValues,
  paddlePresetCopyPatch,
  paddlePresetFromValues,
  selectionLabel,
  selectionModeLabel,
  selectionStatusLabel,
  selectionTone,
  type PaddleModelDraft,
  type PaddleModelVersion,
  type PaddlePreset,
} from "./globalSettingsModel";
import { engineStatus, engineStatusLabel, engineStatusTone, type PaddleOcrInstallState } from "./ocrEngineStatus";
import { OcrRoutingSection } from "./OcrRoutingSection";
import { NumericSettingField, TextSettingField, useSettingLocked } from "./NumericSettingField";

// Per-card draft subscription: each card only re-renders when one of its own
// keys changes, so typing in the Paddle panel never repaints the Vision card
// or the page shell.
function useAdvancedValues(keys: readonly GlobalSettingKey[]): Partial<GlobalSettingValues> {
  return useGlobalSettingsStore(useShallow((state) => {
    // GlobalSettingValues is a Readonly record; build on a mutable shape and
    // cast once for the card field helpers.
    const values: Partial<Record<GlobalSettingKey, string>> = {};
    for (const key of keys) values[key] = state.draftValues[key] ?? state.saved?.values[key] ?? "";
    return values as Partial<GlobalSettingValues>;
  }));
}

function useCardDirty(keys: readonly GlobalSettingKey[]): boolean {
  // Boolean selector: re-renders only when the marker state flips.
  return useGlobalSettingsStore((state) => keys.some((key) => state.dirtyKeys.has(key)));
}

function setDraftValue(key: GlobalSettingKey, value: string) {
  useGlobalSettingsStore.getState().setDraftValue(key, value);
}

function setDraftValues(patch: Partial<Record<GlobalSettingKey, string>>) {
  useGlobalSettingsStore.getState().setDraftValues(patch);
}

interface VisionEngineCardProps {
  vision: OcrEngineStatus | null;
  selected: boolean;
  visionCheck: VisionOcrCheckResult | null;
  visionCheckState: "idle" | "checking" | "checked";
  checkVision: () => Promise<void>;
}

const VisionEngineCard = memo(function VisionEngineCard({ vision, selected, visionCheck, visionCheckState, checkVision }: VisionEngineCardProps) {
  const locked = useSettingLocked();
  const values = useAdvancedValues(VISION_ADVANCED_KEYS);
  const dirty = useCardDirty(VISION_ADVANCED_KEYS);

  return <article className={styles.ocrEngineCard} data-selected={selected ? "true" : undefined} aria-labelledby="vision-ocr-title">
    <div className={styles.ocrEngineHeader}>
      <div>
        <Text as="h3" id="vision-ocr-title" size="md" weight="bold">Apple Vision OCR</Text>
        <Text tone="muted" size="sm">macOS Vision Framework，本机提取文字与坐标，不需要 Python。</Text>
      </div>
      <StatusIndicator tone={engineStatusTone(vision)} label={engineStatusLabel(vision)} />
    </div>
    {selected && <Badge tone="accent">当前优先</Badge>}
    <dl className={styles.ocrEngineDetails}>
      <div><dt>运行模式</dt><dd>{engineModeLabel(vision?.mode || "")}</dd></div>
      <div><dt>能力来源</dt><dd>{vision?.available ? "已发现 Vision bridge 或 Swift 工具链" : "未发现 bridge 或 swiftc"}</dd></div>
      <div><dt>识别配置</dt><dd>{vision ? `${vision.recognitionLevel === "fast" ? "快速" : "高精度"} · ${vision.language || "自动语言"}` : "—"}</dd></div>
    </dl>
    <details className={styles.settingsDetails} data-dirty={dirty || undefined}>
      <summary>调整 Vision OCR 参数</summary>
      <div className={styles.settingsDetailsBody}>
        <div className={styles.settingsFieldGroup}>
          <p className={styles.settingsFieldGroupTitle}>路由</p>
          <div className={styles.formGrid}>
            <Field label="必需模式" hint="开启后 Vision 不可用会阻止识别。"><Select disabled={locked} value={values.VISIONOCR_REQUIRED || "false"} onChange={(event) => setDraftValue("VISIONOCR_REQUIRED", event.target.value)}><option value="false">可选</option><option value="true">必需</option></Select></Field>
          </div>
        </div>
        <div className={styles.settingsFieldGroup}>
          <p className={styles.settingsFieldGroupTitle}>识别</p>
          <div className={styles.formGrid}>
            <TextSettingField settingKey="VISIONOCR_LANGUAGE" label="识别语言" hint="可填写逗号分隔的语言，如 zh-Hans,en-US。" fallback="zh-Hans" />
            <Field label="识别精度"><Select disabled={locked} value={values.VISIONOCR_RECOGNITION_LEVEL || "accurate"} onChange={(event) => setDraftValue("VISIONOCR_RECOGNITION_LEVEL", event.target.value)}><option value="accurate">高精度</option><option value="fast">快速</option></Select></Field>
            <Field label="语言校正"><Select disabled={locked} value={values.VISIONOCR_USE_LANGUAGE_CORRECTION || "true"} onChange={(event) => setDraftValue("VISIONOCR_USE_LANGUAGE_CORRECTION", event.target.value)}><option value="true">启用</option><option value="false">关闭</option></Select></Field>
            <NumericSettingField settingKey="VISIONOCR_MIN_CONFIDENCE" label="最低置信度" hint="0–1，低于此值的文字块不会作为证据。" fallback="0.10" min="0" max="1" step="0.01" />
            <NumericSettingField settingKey="VISIONOCR_MAX_BLOCKS_PER_VIEW" label="每个视图最多文字块" hint="0 表示不限制。" fallback="0" min="0" max="10000" step="1" />
          </div>
        </div>
        <div className={styles.settingsFieldGroup}>
          <p className={styles.settingsFieldGroupTitle}>环境</p>
          <div className={styles.formGrid}>
            <NumericSettingField settingKey="VISIONOCR_TIMEOUT_MS" label="超时" hint="auto 按视图数量计算，也可填 10000–1800000 毫秒。" fallback="auto" />
            <TextSettingField settingKey="VISIONOCR_BINARY" label="Vision bridge 路径" hint="留空则优先使用打包内置 bridge；开发环境会自动编译。" placeholder="自动" spellCheck={false} />
          </div>
        </div>
      </div>
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
  </article>;
});

interface PaddleEngineCardProps {
  paddle: OcrEngineStatus | null;
  selected: boolean;
  ocr: OcrSettings | null;
  paddleCheck: OcrCheckResult | null;
  ocrState: "idle" | "checking" | "saving" | "saved";
  checkAndSaveOcr: () => void;
}

const PaddleEngineCard = memo(function PaddleEngineCard({ paddle, selected, ocr, paddleCheck, ocrState, checkAndSaveOcr }: PaddleEngineCardProps) {
  const locked = useSettingLocked();
  const writeBusy = useGlobalSettingsStore((state) => state.mutationOwner !== null);
  const values = useAdvancedValues(PADDLE_ADVANCED_KEYS);
  const dirty = useCardDirty(PADDLE_ADVANCED_KEYS);
  const savedValues = useGlobalSettingsStore((state) => state.saved?.values ?? null);
  // Per-version model drafts stay component-local: they cache unsaved custom
  // IDs across version switches but never leak into the shared draft store.
  const paddleModelDraftsRef = useRef<Partial<Record<PaddleModelVersion, PaddleModelDraft>>>({});
  const seededSavedValuesRef = useRef<GlobalSettingValues | null>(null);
  useEffect(() => {
    if (!savedValues || savedValues === seededSavedValuesRef.current) return;
    // A reset or successful save is a new server snapshot; discard only the
    // old per-version cache and seed the version that the snapshot owns. Key
    // metadata updates retain values identity and must not erase model drafts.
    seededSavedValuesRef.current = savedValues;
    paddleModelDraftsRef.current = {};
    if (paddlePresetFromValues(savedValues) === "custom") {
      paddleModelDraftsRef.current[paddleModelVersionFromValues(savedValues)] = paddleModelDraftFromValues(savedValues);
    }
  }, [savedValues]);

  const preset = paddlePresetFromValues(values);
  const paddleEffective = useMemo(() => paddleEffectiveValues(values, preset), [values, preset]);
  const paddleV6DetectionModels = useMemo(
    () => paddleModelOptions(PADDLE_V6_DETECTION_MODEL_OPTIONS, paddleEffective.detectionModel),
    [paddleEffective.detectionModel],
  );
  const paddleV6RecognitionModels = useMemo(
    () => paddleModelOptions(PADDLE_V6_RECOGNITION_MODEL_OPTIONS, paddleEffective.recognitionModel),
    [paddleEffective.recognitionModel],
  );
  const paddleV6DetectionIsCustom = isCustomPaddleModel(PADDLE_V6_DETECTION_MODEL_OPTIONS, paddleEffective.detectionModel);
  const paddleV6RecognitionIsCustom = isCustomPaddleModel(PADDLE_V6_RECOGNITION_MODEL_OPTIONS, paddleEffective.recognitionModel);
  const paddleUsesV6Models = paddleEffective.modelVersion === "PP-OCRv6";

  const setPaddlePreset = (nextPreset: PaddlePreset) => {
    if (locked) return;
    if (nextPreset === "custom" && preset !== "custom") {
      // Materialize the visible preset before entering custom mode so the
      // editor never jumps back to unrelated stale values from the last save.
      paddleModelDraftsRef.current[paddleEffective.modelVersion] = {
        detectionModel: paddleEffective.detectionModel,
        recognitionModel: paddleEffective.recognitionModel,
      };
      const patch: Partial<Record<GlobalSettingKey, string>> = { PADDLEOCR_PRESET: "custom" };
      for (const [key, value] of Object.entries(paddlePresetCopyPatch("custom", paddleEffective))) {
        if (key === "PADDLEOCR_PRESET") continue;
        patch[key as GlobalSettingKey] = value || "";
      }
      setDraftValues(patch);
      return;
    }
    setDraftValue("PADDLEOCR_PRESET", nextPreset);
  };

  const setPaddleModelVersion = (nextVersion: PaddleModelVersion) => {
    if (locked || preset !== "custom") return;
    const currentVersion = paddleModelVersionFromValues(values);
    paddleModelDraftsRef.current[currentVersion] = paddleModelDraftFromValues(values);
    const restored = paddleModelDraftsRef.current[nextVersion] || { detectionModel: "", recognitionModel: "" };
    // Detection/recognition model names are version-specific. Isolate the
    // drafts to avoid mixed pipelines, then restore them on a round trip so
    // an unsaved custom ID is not silently discarded.
    setDraftValues(currentVersion === nextVersion
      ? { PADDLEOCR_MODEL_VERSION: nextVersion }
      : {
        PADDLEOCR_MODEL_VERSION: nextVersion,
        PADDLEOCR_DETECTION_MODEL: restored.detectionModel,
        PADDLEOCR_RECOGNITION_MODEL: restored.recognitionModel,
      });
  };

  const setPaddleField = (key: Exclude<GlobalSettingKey, "PADDLEOCR_PRESET">, value: string) => {
    if (locked) return;
    if (preset === "custom") {
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
      setDraftValue(key, value);
      return;
    }
    // Read-only preset controls normally prevent this branch. Keeping the
    // fallback makes keyboard/programmatic edits safe and automatically opts
    // into custom with the currently visible preset values.
    const patch: Partial<Record<GlobalSettingKey, string>> = { PADDLEOCR_PRESET: "custom" };
    for (const [copyKey, copyValue] of Object.entries(paddlePresetCopyPatch("custom", paddleEffective))) {
      if (copyKey === "PADDLEOCR_PRESET") continue;
      patch[copyKey as GlobalSettingKey] = copyKey === key ? value : copyValue || "";
    }
    setDraftValues(patch);
  };

  return <article className={styles.ocrEngineCard} data-selected={selected ? "true" : undefined} aria-labelledby="paddle-ocr-title">
    <div className={styles.ocrEngineHeader}>
      <div>
        <Text as="h3" id="paddle-ocr-title" size="md" weight="bold">PaddleOCR</Text>
        <Text tone="muted" size="sm">Python + PaddleOCR，本地可选引擎。</Text>
      </div>
      <StatusIndicator tone={engineStatusTone(paddle)} label={engineStatusLabel(paddle)} />
    </div>
    {selected && <Badge tone="accent">当前优先</Badge>}
    <dl className={styles.ocrEngineDetails}>
      <div><dt>运行模式</dt><dd>{engineModeLabel(paddle?.mode || "")}</dd></div>
      <div><dt>能力来源</dt><dd>{paddle?.available ? "已发现 Python 环境与 PaddleOCR" : "未发现可用 Python 环境"}</dd></div>
      <div><dt>模型配置</dt><dd>{paddle ? `${paddle.modelVersion || "PP-OCRv6"} · ${paddle.presetLabel || paddle.profileLabel || paddle.profile || "自定义"}` : "—"}</dd></div>
    </dl>
    <details className={styles.settingsDetails} data-dirty={dirty || undefined}>
      <summary>调整 PaddleOCR 参数</summary>
      <div className={styles.settingsDetailsBody}>
        <div className={styles.settingsFieldGroup}>
          <p className={styles.settingsFieldGroupTitle}>路由</p>
          <div className={styles.formGrid}>
            <Field label="必需模式" hint="开启后 PaddleOCR 不可用会阻止识别。"><Select disabled={locked} value={values.PADDLEOCR_REQUIRED || "false"} onChange={(event) => setDraftValue("PADDLEOCR_REQUIRED", event.target.value)}><option value="false">可选</option><option value="true">必需</option></Select></Field>
          </div>
        </div>
        <div className={styles.settingsFieldGroup}>
          <p className={styles.settingsFieldGroupTitle}>模型</p>
          <div className={styles.formGrid}>
            <Field label="参数预设" hint="命名预设会同时切换 PP-OCRv6 模型、批量、检测边长和输出过滤；自定义保留手动参数。"><Select disabled={locked} value={preset} onChange={(event) => setPaddlePreset(event.target.value as PaddlePreset)}><option value="custom">自定义</option><option value="performance">性能（质量优先）</option><option value="balanced">平衡（推荐）</option><option value="fast">快速（低延迟）</option></Select></Field>
            <Field label="模型版本" hint="切换版本会隔离检测/识别模型覆盖；切回时恢复本次未保存的版本草稿。"><Select value={paddleEffective.modelVersion} onChange={(event) => setPaddleModelVersion(event.target.value as PaddleModelVersion)} disabled={locked || preset !== "custom"}>{PADDLE_MODEL_VERSION_OPTIONS.map((option) => <option key={option.value} value={option.value}>{option.label}</option>)}</Select></Field>
            <Field label="兼容性能档" hint="仅自定义模式使用；用于兼容已有 PP-OCRv5 配置。"><Select value={paddleEffective.profile || "balanced"} onChange={(event) => setPaddleField("PADDLEOCR_PROFILE", event.target.value)} disabled={locked || preset !== "custom"}><option value="fast">快速</option><option value="balanced">平衡</option><option value="accurate">高精度</option></Select></Field>
            <Field label="检测模型" htmlFor="paddle-detection-model-select" hint={paddleUsesV6Models ? "PP-OCRv6 可选择 medium、small 或 tiny；也可输入自定义模型 ID。" : "PP-OCRv5 自定义模型可手动填写；留空使用当前版本默认模型。"}>
              {paddleUsesV6Models
                ? <div className={styles.paddleModelControl}>
                  <Select id="paddle-detection-model-select" aria-describedby="paddle-detection-model-select-hint" value={paddleEffective.detectionModel} onChange={(event) => setPaddleField("PADDLEOCR_DETECTION_MODEL", event.target.value)} disabled={locked || preset !== "custom"}>{paddleV6DetectionModels.map((option) => <option key={option.value || "default"} value={option.value}>{option.label}</option>)}</Select>
                  <Input aria-describedby="paddle-detection-model-select-hint" value={paddleV6DetectionIsCustom ? paddleEffective.detectionModel : ""} onChange={(event) => setPaddleField("PADDLEOCR_DETECTION_MODEL", event.target.value)} placeholder="输入自定义模型 ID（可选）" aria-label="自定义检测模型 ID" disabled={locked || preset !== "custom"} />
                </div>
                : <Input id="paddle-detection-model-select" value={paddleEffective.detectionModel} onChange={(event) => setPaddleField("PADDLEOCR_DETECTION_MODEL", event.target.value)} placeholder="使用默认" disabled={locked || preset !== "custom"} />}
            </Field>
            <Field label="识别模型" htmlFor="paddle-recognition-model-select" hint={paddleUsesV6Models ? "PP-OCRv6 可选择 medium、small 或 tiny；也可输入自定义模型 ID。" : "PP-OCRv5 自定义模型可手动填写；留空使用当前版本默认模型。"}>
              {paddleUsesV6Models
                ? <div className={styles.paddleModelControl}>
                  <Select id="paddle-recognition-model-select" aria-describedby="paddle-recognition-model-select-hint" value={paddleEffective.recognitionModel} onChange={(event) => setPaddleField("PADDLEOCR_RECOGNITION_MODEL", event.target.value)} disabled={locked || preset !== "custom"}>{paddleV6RecognitionModels.map((option) => <option key={option.value || "default"} value={option.value}>{option.label}</option>)}</Select>
                  <Input aria-describedby="paddle-recognition-model-select-hint" value={paddleV6RecognitionIsCustom ? paddleEffective.recognitionModel : ""} onChange={(event) => setPaddleField("PADDLEOCR_RECOGNITION_MODEL", event.target.value)} placeholder="输入自定义模型 ID（可选）" aria-label="自定义识别模型 ID" disabled={locked || preset !== "custom"} />
                </div>
                : <Input id="paddle-recognition-model-select" value={paddleEffective.recognitionModel} onChange={(event) => setPaddleField("PADDLEOCR_RECOGNITION_MODEL", event.target.value)} placeholder="使用默认" disabled={locked || preset !== "custom"} />}
            </Field>
          </div>
        </div>
        <div className={styles.settingsFieldGroup}>
          <p className={styles.settingsFieldGroupTitle}>性能</p>
          <div className={styles.formGrid}>
            <TextSettingField settingKey="PADDLEOCR_LANGUAGE" label="识别语言" fallback="ch" />
            <TextSettingField settingKey="PADDLEOCR_DEVICE" label="计算设备" fallback="cpu" />
            <NumericSettingField settingKey="PADDLEOCR_RECOGNITION_BATCH_SIZE" label="识别批量大小" fallback="" min="1" max="64" step="1" placeholder="使用性能档" disabled={locked || preset !== "custom"} overrideValue={preset !== "custom" ? paddleEffective.recognitionBatchSize : undefined} />
            <NumericSettingField settingKey="PADDLEOCR_MIN_CONFIDENCE" label="最低置信度" hint="0–1；低于此值的文字块不会作为证据。" fallback="0.10" min="0" max="1" step="0.01" disabled={locked || preset !== "custom"} overrideValue={preset !== "custom" ? paddleEffective.minimumConfidence : undefined} />
            <NumericSettingField settingKey="PADDLEOCR_MAX_BLOCKS_PER_VIEW" label="每个视图最多文字块" hint="0 表示不限制；限制时仍均匀覆盖整页。" fallback="0" min="0" max="10000" step="1" disabled={locked || preset !== "custom"} overrideValue={preset !== "custom" ? paddleEffective.maxBlocksPerView : undefined} />
            <NumericSettingField settingKey="PADDLEOCR_TEXT_DET_LIMIT_SIDE_LEN" label="检测最长边" hint="320–4096；越小通常越快，但小字细节可能减少。" fallback="" min="320" max="4096" step="1" placeholder="Paddle 默认" disabled={locked || preset !== "custom"} overrideValue={preset !== "custom" ? paddleEffective.textDetLimitSideLen : undefined} />
          </div>
        </div>
        <div className={styles.settingsFieldGroup}>
          <p className={styles.settingsFieldGroupTitle}>环境</p>
          <div className={styles.formGrid}>
            <NumericSettingField settingKey="PADDLEOCR_TIMEOUT_MS" label="OCR 超时" hint="auto 按视图数量计算，也可填 10000–3600000 毫秒。" fallback="auto" />
            <TextSettingField settingKey="PADDLEOCR_PYTHON" label="Python 环境路径" hint="开发环境可填 .venv-paddleocr/bin/python；打包版请填写已安装 PaddleOCR 的 Python 路径。" placeholder="python3 或绝对路径" spellCheck={false} />
          </div>
        </div>
        {preset === "fast" && <Text tone="warning" size="sm">快速预设使用 tiny 模型和更高置信度门槛；复杂手写、低置信度文字可能减少。</Text>}
        <Stack direction="row" justify="between" align="center" wrap>
          <Text tone="subtle" size="xs">{ocr?.setupCompleted ? "当前环境已完成设置" : "先检查路径，再保存参数"}</Text>
          <Button size="sm" variant="secondary" loading={ocrState === "checking" || ocrState === "saving"} disabled={writeBusy} onClick={checkAndSaveOcr} startIcon={<Wrench size={15} />}>验证并保存环境</Button>
        </Stack>
        {paddleCheck?.ok === true && <div className={styles.ocrCheckResult} data-tone="success" role="status">
          <Text tone="success" size="sm"><Icon icon={CheckCircle2} size={15} /> 检查通过 · Paddle {paddleCheck.paddleVersion} / PaddleOCR {paddleCheck.paddleOcrVersion}</Text>
        </div>}
        {paddleCheck?.ok === false && <div className={styles.ocrCheckResult} data-tone="danger" role="alert">
          <Text tone="danger" size="sm">检查失败 · {paddleCheck.error.message}</Text>
        </div>}
      </div>
    </details>
  </article>;
});

interface OcrStatusPanelProps {
  config: ConfigData | null;
  ocr: OcrSettings | null;
  paddleCheck: OcrCheckResult | null;
  ocrState: "idle" | "checking" | "saving" | "saved";
  checkAndSaveOcr: () => void;
  visionCheck: VisionOcrCheckResult | null;
  visionCheckState: "idle" | "checking" | "checked";
  checkVision: () => Promise<void>;
  paddleInstallState: PaddleOcrInstallState;
  paddleInstallProgress: PaddleOcrInstallProgress | null;
  paddleInstallError: string | null;
  installPaddleOcr: () => void;
  cancelPaddleOcrInstall: () => void;
  openEnvironmentDialog: () => void;
}

export function OcrStatusPanel({
  config,
  ocr,
  paddleCheck,
  ocrState,
  checkAndSaveOcr,
  visionCheck,
  visionCheckState,
  checkVision,
  paddleInstallState,
  paddleInstallProgress,
  paddleInstallError,
  installPaddleOcr,
  cancelPaddleOcrInstall,
  openEnvironmentDialog,
}: OcrStatusPanelProps) {
  const writeBusy = useGlobalSettingsStore((state) => state.mutationOwner !== null);
  const selection = config?.ocrSelection;
  const vision = engineStatus(config, "vision");
  const paddle = engineStatus(config, "paddleocr");
  const visionSelected = selection?.id === "vision";
  const paddleSelected = selection?.id === "paddleocr";

  return <Surface as="section" id="settings-ocr" className={styles.helpSection} aria-labelledby="local-ocr-title">
    <div className={styles.sectionHeader}>
      <div className={styles.ocrHeaderCopy}>
        <p className={styles.kicker}>执行路由</p>
        <div className={styles.ocrHeaderLine}>
          <h2 className={styles.sectionTitle} id="local-ocr-title">本地 OCR</h2>
          <Button
            className={styles.ocrToolsButton}
            size="sm"
            variant="secondary"
            onClick={openEnvironmentDialog}
            startIcon={<Download size={15} />}
          >
            OCR 环境检测与下载
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
        <Button size="sm" variant="ghost" disabled={writeBusy} onClick={installPaddleOcr}>重试安装</Button>
      </Stack>
    </div>}
    {paddleInstallState === "error" && paddleInstallError && <div className={styles.ocrInstallFeedback} data-tone="danger">
      <InlineError message={paddleInstallError} {...(writeBusy ? {} : { onRetry: installPaddleOcr })} />
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
        <OcrRoutingSection />
      </div>
    </div>

    <div className={styles.ocrEngineGrid}>
      <VisionEngineCard vision={vision} selected={visionSelected} visionCheck={visionCheck} visionCheckState={visionCheckState} checkVision={checkVision} />
      <PaddleEngineCard paddle={paddle} selected={paddleSelected} ocr={ocr} paddleCheck={paddleCheck} ocrState={ocrState} checkAndSaveOcr={checkAndSaveOcr} />
    </div>

    <Text tone="subtle" size="xs" className={styles.ocrFootnote}>OCR 只提供文字证据，最终结果仍由视觉模型结合页面图片确认。</Text>
  </Surface>;
}

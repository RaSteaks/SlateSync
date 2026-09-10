import { Badge, SegmentedControl, Text } from "../../design-system";
import { useGlobalSettingsStore } from "../../state";
import {
  OCR_ROUTING_SEGMENTS,
  ocrPreferenceFromValues,
  ocrPreferencePatch,
  ocrRoutingFeedback,
  type OcrPreference,
} from "./globalSettingsModel";
import { useSettingLocked } from "./NumericSettingField";
import styles from "../../app/app.module.css";

/**
 * The consolidated OCR routing control. It owns the four routing keys as one
 * segmented choice (replacing the old per-card enable selects), subscribes to
 * exactly those keys, and explains the pending save outcome inline.
 */
export function OcrRoutingSection() {
  const locked = useSettingLocked();
  // Four raw-value selectors: only a change to one of the routing keys
  // re-renders this subtree.
  const visionEnabled = useGlobalSettingsStore((state) => state.draftValues.VISIONOCR_ENABLED ?? state.saved?.values.VISIONOCR_ENABLED ?? "auto");
  const paddleEnabled = useGlobalSettingsStore((state) => state.draftValues.PADDLEOCR_ENABLED ?? state.saved?.values.PADDLEOCR_ENABLED ?? "auto");
  const visionRequired = useGlobalSettingsStore((state) => state.draftValues.VISIONOCR_REQUIRED ?? state.saved?.values.VISIONOCR_REQUIRED ?? "false");
  const paddleRequired = useGlobalSettingsStore((state) => state.draftValues.PADDLEOCR_REQUIRED ?? state.saved?.values.PADDLEOCR_REQUIRED ?? "false");
  const savedValues = useGlobalSettingsStore((state) => state.saved?.values ?? null);

  const preference = ocrPreferenceFromValues({
    VISIONOCR_ENABLED: visionEnabled,
    PADDLEOCR_ENABLED: paddleEnabled,
    VISIONOCR_REQUIRED: visionRequired,
    PADDLEOCR_REQUIRED: paddleRequired,
  });
  const bothRequired = visionRequired === "true" && paddleRequired === "true";
  // A required mode pins the segment; surface it so the pinned state is not
  // mistaken for a free choice (Vision wins, matching Main's precedence).
  const pinnedByRequired = (preference === "vision" && visionRequired === "true")
    || (preference === "paddleocr" && paddleRequired === "true");

  const applyPreference = (next: OcrPreference) => {
    useGlobalSettingsStore.getState().setDraftValues(ocrPreferencePatch(next));
  };

  const feedback = bothRequired
    ? "Vision 与 PaddleOCR 同时处于必需模式；保存后只有 Apple Vision OCR 会生效。"
    : ocrRoutingFeedback(preference, savedValues);

  return <div className={styles.ocrRoutingSection}>
    <div className={styles.settingsSegmentedRow}>
      <SegmentedControl
        label="首选 OCR 引擎"
        disabled={locked}
        value={preference}
        options={OCR_ROUTING_SEGMENTS}
        onChange={applyPreference}
      />
      {pinnedByRequired && <Badge tone="warning">必需</Badge>}
    </div>
    <Text tone={bothRequired ? "danger" : "muted"} size="xs" aria-live="polite">{feedback}</Text>
  </div>;
}

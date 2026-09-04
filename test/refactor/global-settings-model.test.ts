import { describe, expect, it } from "vitest";
import type { GlobalSettingValues } from "../../src/shared/contracts/index.js";
import {
  OCR_ROUTING_KEYS,
  ocrPreferenceFromValues,
  ocrPreferencePatch,
  ocrRoutingFeedback,
  paddleEffectiveValues,
  paddlePresetCopyPatch,
} from "../../src/renderer/features/settings/globalSettingsModel";
import { isGlobalSettingsDirty, isRouteChangeBlocked, validateDirtyNumericFields } from "../../src/renderer/features/settings/globalSettingsActions";
import { useGlobalSettingsStore } from "../../src/renderer/state";
import { GLOBAL_NUMERIC_RANGES, validateNumericField, validateTimeoutField } from "../../src/renderer/validation/global-settings-validation";
import { afterEach } from "vitest";

afterEach(() => {
  useGlobalSettingsStore.getState().clear();
});

function values(overrides: Partial<GlobalSettingValues>): Partial<GlobalSettingValues> {
  return overrides;
}

describe("ocrPreferenceFromValues precedence", () => {
  const cases: Array<{ name: string; input: Partial<GlobalSettingValues>; expected: string }> = [
    { name: "auto is the default when nothing is pinned", input: {}, expected: "auto" },
    { name: "a required Vision flag wins over explicit PaddleOCR", input: values({ VISIONOCR_REQUIRED: "true", PADDLEOCR_ENABLED: "true" }), expected: "vision" },
    { name: "a required PaddleOCR flag wins over explicit Vision", input: values({ PADDLEOCR_REQUIRED: "true", VISIONOCR_ENABLED: "true" }), expected: "paddleocr" },
    { name: "required beats explicit on the same engine", input: values({ VISIONOCR_ENABLED: "true", VISIONOCR_REQUIRED: "true" }), expected: "vision" },
    { name: "explicit Vision beats explicit PaddleOCR", input: values({ VISIONOCR_ENABLED: "true", PADDLEOCR_ENABLED: "true" }), expected: "vision" },
    { name: "two explicit disables mean disabled", input: values({ VISIONOCR_ENABLED: "false", PADDLEOCR_ENABLED: "false" }), expected: "disabled" },
    { name: "a single disable stays auto", input: values({ VISIONOCR_ENABLED: "false" }), expected: "auto" },
  ];
  for (const testCase of cases) {
    it(testCase.name, () => {
      expect(ocrPreferenceFromValues(testCase.input)).toBe(testCase.expected);
    });
  }
});

describe("ocrPreferencePatch mapping", () => {
  it("maps each segment to the four routing keys", () => {
    expect(ocrPreferencePatch("auto")).toEqual({
      VISIONOCR_ENABLED: "auto",
      PADDLEOCR_ENABLED: "auto",
      VISIONOCR_REQUIRED: "false",
      PADDLEOCR_REQUIRED: "false",
    });
    expect(ocrPreferencePatch("vision")).toEqual({
      VISIONOCR_ENABLED: "true",
      PADDLEOCR_ENABLED: "false",
      VISIONOCR_REQUIRED: "false",
      PADDLEOCR_REQUIRED: "false",
    });
    expect(ocrPreferencePatch("paddleocr")).toEqual({
      VISIONOCR_ENABLED: "false",
      PADDLEOCR_ENABLED: "true",
      VISIONOCR_REQUIRED: "false",
      PADDLEOCR_REQUIRED: "false",
    });
    expect(ocrPreferencePatch("disabled")).toEqual({
      VISIONOCR_ENABLED: "false",
      PADDLEOCR_ENABLED: "false",
      VISIONOCR_REQUIRED: "false",
      PADDLEOCR_REQUIRED: "false",
    });
    // The patch owns exactly the four routing keys and nothing else.
    expect([...OCR_ROUTING_KEYS].sort()).toEqual(Object.keys(ocrPreferencePatch("auto")).sort());
  });
});

describe("ocrRoutingFeedback", () => {
  it("reports an already-consistent saved configuration", () => {
    const saved = ocrPreferencePatch("vision");
    expect(ocrRoutingFeedback("vision", saved)).toBe("当前已保存配置与所选路由一致。");
  });

  it("describes an explicit engine switch and the engine it turns off", () => {
    const saved = ocrPreferencePatch("auto");
    expect(ocrRoutingFeedback("vision", saved)).toBe("保存后将显式启用 Apple Vision OCR。");
    const paddleSaved = { ...saved, PADDLEOCR_ENABLED: "true" };
    expect(ocrRoutingFeedback("vision", paddleSaved)).toBe("保存后将显式启用 Apple Vision OCR，并关闭 PaddleOCR。");
    const visionSaved = { ...saved, VISIONOCR_ENABLED: "true" };
    expect(ocrRoutingFeedback("paddleocr", visionSaved)).toBe("保存后将显式启用 PaddleOCR，并关闭 Apple Vision OCR。");
  });

  it("describes the disable and auto outcomes", () => {
    expect(ocrRoutingFeedback("disabled", ocrPreferencePatch("auto"))).toBe("保存后将同时关闭两套引擎。");
    expect(ocrRoutingFeedback("auto", ocrPreferencePatch("vision"))).toContain("恢复自动路由");
  });

  it("warns before clearing a saved required mode", () => {
    const saved = { ...ocrPreferencePatch("vision"), VISIONOCR_REQUIRED: "true" };
    expect(ocrRoutingFeedback("paddleocr", saved)).toContain("所选路由会清除已开启的必需模式。");
    expect(ocrRoutingFeedback("paddleocr", saved)).toContain("保存后将显式启用 PaddleOCR");
  });

  it("treats an unknown snapshot as speculative instead of consistent", () => {
    expect(ocrRoutingFeedback("vision", null)).toBe("保存后将显式启用 Apple Vision OCR。");
  });
});

describe("numeric validation boundaries", () => {
  it("treats empty input as inherit-default", () => {
    expect(validateNumericField("MAX_BODY_MB", "")).toEqual({ ok: true });
    expect(validateNumericField("MAX_BODY_MB", "   ")).toEqual({ ok: true });
  });

  it("rejects non-numeric and non-integer input", () => {
    expect(validateNumericField("MAX_BODY_MB", "abc").ok).toBe(false);
    expect(validateNumericField("MAX_BODY_MB", "80.5").ok).toBe(false);
  });

  it("enforces the documented ranges", () => {
    expect(validateNumericField("MAX_BODY_MB", "20").ok).toBe(true);
    expect(validateNumericField("MAX_BODY_MB", "200").ok).toBe(true);
    expect(validateNumericField("MAX_BODY_MB", "19").ok).toBe(false);
    expect(validateNumericField("MODEL_REQUEST_MAX_RETRIES", "3").ok).toBe(true);
    expect(validateNumericField("MODEL_REQUEST_MAX_RETRIES", "4").ok).toBe(false);
    expect(validateNumericField("PADDLEOCR_TEXT_DET_LIMIT_SIDE_LEN", "320").ok).toBe(true);
    expect(validateNumericField("PADDLEOCR_TEXT_DET_LIMIT_SIDE_LEN", "4097").ok).toBe(false);
  });

  it("caps confidence decimals at two places", () => {
    expect(validateNumericField("PADDLEOCR_MIN_CONFIDENCE", "0.25").ok).toBe(true);
    expect(validateNumericField("PADDLEOCR_MIN_CONFIDENCE", "0.255").ok).toBe(false);
    expect(validateNumericField("PADDLEOCR_MIN_CONFIDENCE", "1").ok).toBe(true);
  });

  it("accepts auto or the per-engine timeout range only", () => {
    expect(validateTimeoutField("VISIONOCR_TIMEOUT_MS", "auto")).toEqual({ ok: true });
    expect(validateTimeoutField("VISIONOCR_TIMEOUT_MS", "AUTO")).toEqual({ ok: true });
    expect(validateTimeoutField("VISIONOCR_TIMEOUT_MS", "10000").ok).toBe(true);
    expect(validateTimeoutField("VISIONOCR_TIMEOUT_MS", "1800000").ok).toBe(true);
    expect(validateTimeoutField("VISIONOCR_TIMEOUT_MS", "1800001").ok).toBe(false);
    expect(validateTimeoutField("PADDLEOCR_TIMEOUT_MS", "3600000").ok).toBe(true);
    expect(validateTimeoutField("PADDLEOCR_TIMEOUT_MS", "3600001").ok).toBe(false);
    expect(validateTimeoutField("VISIONOCR_TIMEOUT_MS", "abc").ok).toBe(false);
  });

  it("keys without a range stay valid", () => {
    expect(validateNumericField("SLATESYNC_CONFIG_PATH", "x")).toEqual({ ok: true });
    expect(GLOBAL_NUMERIC_RANGES.VISIONOCR_LANGUAGE).toBeUndefined();
  });
});

describe("route change guard truth table", () => {
  function seedDirty(dirty: boolean) {
    const store = useGlobalSettingsStore.getState();
    store.clear();
    store.adoptServerSnapshot({
      values: { MAX_BODY_MB: "80" } as GlobalSettingValues,
      overrides: [],
      keyConfigured: {},
      restartRequired: false,
    });
    if (dirty) store.setDraftValue("MAX_BODY_MB", "100");
  }

  it.each([
    ["global-settings", "logs", true],
    ["global-settings", "workspace", true],
    ["global-settings", "global-settings", false],
    ["logs", "projects", false],
    ["workspace", "global-settings", false],
  ] as const)("blocks %s -> %s when dirty: %s", (current, next, blocked) => {
    seedDirty(true);
    expect(isRouteChangeBlocked(current, next)).toBe(blocked);
  });

  it("never blocks a clean draft", () => {
    seedDirty(false);
    expect(isRouteChangeBlocked("global-settings", "logs")).toBe(false);
    expect(isGlobalSettingsDirty()).toBe(false);
  });

  it("counts a reverted edit as clean", () => {
    seedDirty(true);
    expect(isGlobalSettingsDirty()).toBe(true);
    useGlobalSettingsStore.getState().setDraftValue("MAX_BODY_MB", "80");
    expect(isGlobalSettingsDirty()).toBe(false);
    expect(validateDirtyNumericFields()).toBe(0);
  });
});

describe("paddle preset helpers", () => {
  it("copies the visible preset into a custom patch", () => {
    const effective = paddleEffectiveValues({}, "balanced");
    const patch = paddlePresetCopyPatch("custom", effective);
    expect(patch.PADDLEOCR_PRESET).toBe("custom");
    expect(patch.PADDLEOCR_DETECTION_MODEL).toBe("PP-OCRv6_small_det");
    expect(patch.PADDLEOCR_RECOGNITION_BATCH_SIZE).toBe("8");
    expect(patch.PADDLEOCR_TEXT_DET_LIMIT_SIDE_LEN).toBe("960");
  });
});

// @vitest-environment jsdom
/// <reference types="node" />
// This jsdom component test also reads the CSS source through Node's test runtime.
import { readFile } from "node:fs/promises";
import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { afterEach, describe, expect, it, vi } from "vitest";
import type { ConfigData, GlobalSettingsData, SlateSyncApi } from "../../../src/shared/contracts/index.js";
import { GlobalSettingsPage } from "../../../src/renderer/features/settings/GlobalSettingsPage";
import { useProjectStore, useSettingsStore, useUiStore } from "../../../src/renderer/state";

// React 19 requires the act marker for deterministic async settings hydration.
(globalThis as { IS_REACT_ACT_ENVIRONMENT?: boolean }).IS_REACT_ACT_ENVIRONMENT = true;

const mounted: Array<{ host: HTMLDivElement; root: Root }> = [];

const config = {
  providers: [{ id: "openai", label: "OpenAI", configured: false, requiredEnv: ["OPENAI_API_KEY"] }],
  ocrEngines: [
    { id: "vision", label: "Apple Vision OCR", mode: "auto", enabled: true, available: true, required: false, language: "zh-Hans", recognitionLevel: "accurate" },
    { id: "paddleocr", label: "PaddleOCR", mode: "auto", enabled: true, available: true, required: false, modelVersion: "PP-OCRv5", profile: "balanced", profileLabel: "平衡" },
  ],
  ocrSelection: { id: "vision", label: "Apple Vision OCR", mode: "auto", reason: "自动模式优先 Vision OCR。", available: true, enabled: true, required: false },
} as unknown as ConfigData;

const initialGlobalSettings = {
  values: {
    VISIONOCR_ENABLED: "auto",
    VISIONOCR_REQUIRED: "false",
    PADDLEOCR_ENABLED: "auto",
    PADDLEOCR_REQUIRED: "false",
  } as GlobalSettingsData["values"],
  overrides: [],
  keyConfigured: { openai: false },
  restartRequired: false,
} satisfies GlobalSettingsData;

const environmentSnapshot = {
  platform: "darwin",
  platformLabel: "macOS 15.5",
  architecture: "arm64",
  architectureLabel: "Apple Silicon（arm64）",
  packaged: false,
  python: { found: true, command: "python3", version: "Python 3.12.4", meetsMinimum: true, candidates: ["python3"], error: null },
  paddle: {
    venvPath: "/user-data/paddleocr-venv",
    pythonPath: "/user-data/paddleocr-venv/bin/python",
    venvExists: false,
    configuredPythonPath: "",
    activePythonPath: "",
    activePythonExists: null,
  },
  vision: { binaryPath: "/app/bin/vision-ocr", binaryExists: false, source: "missing", swiftToolchain: false },
};

afterEach(() => {
  for (const { host, root } of mounted.splice(0)) {
    act(() => root.unmount());
    host.remove();
  }
  useProjectStore.setState({ config: null, projects: [], current: null, scenarios: [], error: null });
  useSettingsStore.setState({ ocr: null });
  useUiStore.setState({ theme: "system", density: "comfortable", toast: null });
  Object.defineProperty(window, "slateSync", { configurable: true, value: undefined });
});

async function renderSettings(
  saveGlobalSettings: ReturnType<typeof vi.fn>,
  settings = initialGlobalSettings,
  installPaddleOcr = vi.fn(async () => ({
    ok: true as const,
    data: {
      pythonPath: "/user-data/paddleocr-venv/bin/python",
      setupCompleted: true,
      setupSkipped: false,
      paddleVersion: "3.3.1",
      paddleOcrVersion: "3.7.0",
    },
  })),
  overrides: {
    config?: ConfigData;
    environmentSnapshot?: typeof environmentSnapshot | null;
  } = {},
) {
  const renderedConfig = overrides.config ?? config;
  const getOcrEnvironment = vi.fn(async () => ({
    ok: true as const,
    data: overrides.environmentSnapshot === undefined ? environmentSnapshot : overrides.environmentSnapshot,
  }));
  const api = {
    app: { getConfig: vi.fn(async () => ({ ok: true as const, data: renderedConfig })) },
    settings: {
      getGlobalSettings: vi.fn(async () => ({ ok: true as const, data: settings })),
      getOcrSettings: vi.fn(async () => ({ ok: true as const, data: { pythonPath: "", setupCompleted: false, setupSkipped: false } })),
      saveGlobalSettings,
      installPaddleOcr,
      cancelPaddleOcrInstall: vi.fn(async () => ({ ok: true as const, data: { canceled: true } })),
      onPaddleOcrInstallProgress: vi.fn(() => () => {}),
      getOcrEnvironment,
    },
  } as unknown as SlateSyncApi;
  Object.defineProperty(window, "slateSync", { configurable: true, value: api });
  useProjectStore.setState({ config: renderedConfig });
  const host = document.createElement("div");
  document.body.append(host);
  const root = createRoot(host);
  mounted.push({ host, root });
  await act(async () => {
    root.render(<GlobalSettingsPage />);
    await Promise.resolve();
    await Promise.resolve();
  });
  return { host, getOcrEnvironment };
}

function changeSelect(select: HTMLSelectElement, value: string) {
  const valueSetter = Object.getOwnPropertyDescriptor(HTMLSelectElement.prototype, "value")?.set;
  valueSetter?.call(select, value);
  select.dispatchEvent(new Event("change", { bubbles: true }));
}

function changeInput(input: HTMLInputElement, value: string) {
  const valueSetter = Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, "value")?.set;
  valueSetter?.call(input, value);
  input.dispatchEvent(new Event("input", { bubbles: true }));
}

function findField(host: HTMLDivElement, labelText: string) {
  return [...host.querySelectorAll("label")].find(
    (label) => label.querySelector("span")?.textContent?.trim() === labelText,
  );
}

describe("global settings layout and OCR routing", () => {
  it("keeps credentials and appearance in the same explicit overview row", async () => {
    const save = vi.fn(async () => ({ ok: true as const, data: initialGlobalSettings }));
    const { host } = await renderSettings(save);
    const overview = host.querySelector('[data-testid="settings-overview-grid"]');
    const titles = [...(overview?.querySelectorAll("h2") || [])].map((heading) => heading.textContent);

    expect(titles).toEqual(["访问密钥与接口", "工作台外观"]);
    expect(overview?.children).toHaveLength(2);
  });

  it("maps a manual PaddleOCR choice to mutually exclusive saved flags", async () => {
    const save = vi.fn(async (request) => ({
      ok: true as const,
      data: {
        ...initialGlobalSettings,
        values: { ...initialGlobalSettings.values, ...request.values },
      },
    }));
    const { host } = await renderSettings(save);
    const preferenceLabel = [...host.querySelectorAll("label")].find((label) => label.textContent?.includes("首选 OCR 引擎"));
    const preference = preferenceLabel?.querySelector("select");
    if (!(preference instanceof HTMLSelectElement)) throw new Error("missing OCR preference select");

    act(() => changeSelect(preference, "paddleocr"));
    const saveButton = [...host.querySelectorAll("button")].find((button) => button.textContent?.trim() === "保存全局配置");
    if (!(saveButton instanceof HTMLButtonElement)) throw new Error("missing global save button");
    await act(async () => {
      saveButton.click();
      await Promise.resolve();
      await Promise.resolve();
    });

    expect(save).toHaveBeenCalledWith({
      values: {
        VISIONOCR_REQUIRED: "false",
        PADDLEOCR_REQUIRED: "false",
        VISIONOCR_ENABLED: "false",
        PADDLEOCR_ENABLED: "true",
      },
    });
  });

  it("offers one-click PaddleOCR installation inside the detection dialog", async () => {
    const save = vi.fn(async () => ({ ok: true as const, data: initialGlobalSettings }));
    const install = vi.fn(async () => ({
      ok: true as const,
      data: {
        pythonPath: "/user-data/paddleocr-venv/bin/python",
        setupCompleted: true,
        setupSkipped: false,
        paddleVersion: "3.3.1",
        paddleOcrVersion: "3.7.0",
      },
    }));
    const { host } = await renderSettings(save, initialGlobalSettings, install);
    const toolsButton = [...host.querySelectorAll("button")].find((candidate) => candidate.textContent?.trim() === "OCR 环境检测与下载");
    if (!(toolsButton instanceof HTMLButtonElement)) throw new Error("missing OCR tools button");

    await act(async () => {
      toolsButton.click();
      await Promise.resolve();
      await Promise.resolve();
    });
    // The environment probe resolves a few microtasks after the dialog opens.
    await act(async () => {
      await Promise.resolve();
      await Promise.resolve();
    });

    // The dialog portals to document.body instead of the page host.
    const dialog = document.querySelector('[role="dialog"]');
    expect(dialog?.textContent).toContain("本机环境");
    const installButton = [...(dialog?.querySelectorAll("button") || [])].find((candidate) => candidate.textContent?.trim() === "安装 PaddleOCR");
    if (!(installButton instanceof HTMLButtonElement)) throw new Error("missing one-click PaddleOCR button");

    await act(async () => {
      installButton.click();
      await Promise.resolve();
      await Promise.resolve();
    });

    expect(install).toHaveBeenCalledTimes(1);
    expect(dialog?.textContent).toContain("PaddleOCR 已安装并验证通过");
    expect(host.querySelector<HTMLInputElement>('input[placeholder="python3 或绝对路径"]')?.value).toBe("/user-data/paddleocr-venv/bin/python");
  });

  it("auto-opens the detection dialog when no local OCR engine is available", async () => {
    const save = vi.fn(async () => ({ ok: true as const, data: initialGlobalSettings }));
    const unavailableConfig = {
      ...config,
      ocrEngines: config.ocrEngines.map((engine) => ({ ...engine, available: false })),
      ocrSelection: { id: null, label: null, mode: "auto", reason: "未启用本地 OCR。", available: false, enabled: false, required: false },
    } as unknown as ConfigData;
    const { getOcrEnvironment } = await renderSettings(save, initialGlobalSettings, undefined, {
      config: unavailableConfig,
    });
    await act(async () => {
      await Promise.resolve();
      await Promise.resolve();
    });

    expect(document.querySelector('[role="dialog"]')?.textContent).toContain("OCR 环境检测与下载");
    expect(getOcrEnvironment).toHaveBeenCalledTimes(1);
  });

  it("keeps the detection dialog closed when local OCR is deliberately disabled", async () => {
    const save = vi.fn(async () => ({ ok: true as const, data: initialGlobalSettings }));
    const unavailableConfig = {
      ...config,
      ocrEngines: config.ocrEngines.map((engine) => ({ ...engine, available: false })),
    } as unknown as ConfigData;
    const disabledSettings = {
      ...initialGlobalSettings,
      values: { ...initialGlobalSettings.values, VISIONOCR_ENABLED: "false", PADDLEOCR_ENABLED: "false" },
    };
    const { getOcrEnvironment } = await renderSettings(save, disabledSettings, undefined, {
      config: unavailableConfig,
    });

    expect(document.querySelector('[role="dialog"]')).toBeNull();
    expect(getOcrEnvironment).not.toHaveBeenCalled();
  });

  it("treats the PaddleOCR card enable control as a routing choice", async () => {
    const save = vi.fn(async (request) => ({
      ok: true as const,
      data: {
        ...initialGlobalSettings,
        values: { ...initialGlobalSettings.values, ...request.values },
      },
    }));
    const { host } = await renderSettings(save);
    const enableFields = [...host.querySelectorAll("label")].filter((label) => label.textContent?.includes("启用模式"));
    const paddleEnable = enableFields.at(-1)?.querySelector("select");
    if (!(paddleEnable instanceof HTMLSelectElement)) throw new Error("missing PaddleOCR enable select");

    // Directly enabling the engine card must produce the same patch as the
    // top-level preference, otherwise Vision can remain the active route.
    act(() => changeSelect(paddleEnable, "true"));

    const saveButton = [...host.querySelectorAll("button")].find((button) => button.textContent?.trim() === "保存全局配置");
    if (!(saveButton instanceof HTMLButtonElement)) throw new Error("missing global save button");
    await act(async () => {
      saveButton.click();
      await Promise.resolve();
      await Promise.resolve();
    });

    expect(save).toHaveBeenCalledWith({
      values: {
        VISIONOCR_ENABLED: "false",
        PADDLEOCR_ENABLED: "true",
        VISIONOCR_REQUIRED: "false",
        PADDLEOCR_REQUIRED: "false",
      },
    });
  });

  it("clears a stale PaddleOCR required flag when the card is disabled", async () => {
    const settings = {
      ...initialGlobalSettings,
      values: {
        ...initialGlobalSettings.values,
        PADDLEOCR_ENABLED: "true",
        PADDLEOCR_REQUIRED: "true",
      },
    };
    const save = vi.fn(async (request) => ({
      ok: true as const,
      data: {
        ...settings,
        values: { ...settings.values, ...request.values },
      },
    }));
    const { host } = await renderSettings(save, settings);
    const enableFields = [...host.querySelectorAll("label")].filter((label) => label.textContent?.includes("启用模式"));
    const paddleEnable = enableFields.at(-1)?.querySelector("select");
    if (!(paddleEnable instanceof HTMLSelectElement)) throw new Error("missing PaddleOCR enable select");

    act(() => changeSelect(paddleEnable, "false"));

    const saveButton = [...host.querySelectorAll("button")].find((button) => button.textContent?.trim() === "保存全局配置");
    if (!(saveButton instanceof HTMLButtonElement)) throw new Error("missing global save button");
    await act(async () => {
      saveButton.click();
      await Promise.resolve();
      await Promise.resolve();
    });

    expect(save).toHaveBeenCalledWith({
      values: {
        PADDLEOCR_ENABLED: "false",
        PADDLEOCR_REQUIRED: "false",
      },
    });
  });

  it("shows named preset values read-only and materializes them on custom", async () => {
    const save = vi.fn(async (request) => ({
      ok: true as const,
      data: {
        ...initialGlobalSettings,
        values: { ...initialGlobalSettings.values, ...request.values },
      },
    }));
    const { host } = await renderSettings(save);
    const presetLabel = [...host.querySelectorAll("label")].find((label) => label.textContent?.includes("参数预设"));
    const preset = presetLabel?.querySelector("select");
    if (!(preset instanceof HTMLSelectElement)) throw new Error("missing PaddleOCR preset select");

    act(() => changeSelect(preset, "balanced"));
    const modelLabel = [...host.querySelectorAll("label")].find((label) => label.textContent?.includes("模型版本"));
    const modelSelect = modelLabel?.querySelector("select");
    expect(modelSelect?.disabled).toBe(true);
    expect(modelSelect?.value).toBe("PP-OCRv6");

    act(() => changeSelect(preset, "custom"));
    const saveButton = [...host.querySelectorAll("button")].find((button) => button.textContent?.trim() === "保存全局配置");
    if (!(saveButton instanceof HTMLButtonElement)) throw new Error("missing global save button");
    await act(async () => {
      saveButton.click();
      await Promise.resolve();
      await Promise.resolve();
    });

    expect(save).toHaveBeenCalledWith({
      values: expect.objectContaining({
        PADDLEOCR_PRESET: "custom",
        PADDLEOCR_MODEL_VERSION: "PP-OCRv6",
        PADDLEOCR_DETECTION_MODEL: "PP-OCRv6_small_det",
        PADDLEOCR_RECOGNITION_MODEL: "PP-OCRv6_small_rec",
        PADDLEOCR_RECOGNITION_BATCH_SIZE: "8",
        PADDLEOCR_MIN_CONFIDENCE: "0.10",
        PADDLEOCR_MAX_BLOCKS_PER_VIEW: "256",
        PADDLEOCR_TEXT_DET_LIMIT_SIDE_LEN: "960",
      }),
    });
  });

  it("switches model versions with compatible model defaults", async () => {
    const save = vi.fn(async (request) => ({
      ok: true as const,
      data: {
        ...initialGlobalSettings,
        values: { ...initialGlobalSettings.values, ...request.values },
      },
    }));
    const settings = {
      ...initialGlobalSettings,
      values: {
        ...initialGlobalSettings.values,
        PADDLEOCR_PRESET: "custom",
        PADDLEOCR_MODEL_VERSION: "PP-OCRv5",
        PADDLEOCR_DETECTION_MODEL: "PP-OCRv5_mobile_det",
        PADDLEOCR_RECOGNITION_MODEL: "PP-OCRv5_server_rec",
      },
    };
    const { host } = await renderSettings(save, settings);
    const modelLabel = [...host.querySelectorAll("label")].find((label) => label.textContent?.includes("模型版本"));
    const modelSelect = modelLabel?.querySelector("select");
    if (!(modelSelect instanceof HTMLSelectElement)) throw new Error("missing PaddleOCR model version select");

    const v5DetectionLabel = findField(host, "检测模型");
    const v5RecognitionLabel = findField(host, "识别模型");
    expect(v5DetectionLabel?.querySelector("input")?.value).toBe("PP-OCRv5_mobile_det");
    expect(v5RecognitionLabel?.querySelector("input")?.value).toBe("PP-OCRv5_server_rec");

    act(() => changeSelect(modelSelect, "PP-OCRv6"));
    const saveButton = [...host.querySelectorAll("button")].find((button) => button.textContent?.trim() === "保存全局配置");
    if (!(saveButton instanceof HTMLButtonElement)) throw new Error("missing global save button");
    await act(async () => {
      saveButton.click();
      await Promise.resolve();
      await Promise.resolve();
    });

    expect(save).toHaveBeenCalledWith({
      values: expect.objectContaining({
        PADDLEOCR_MODEL_VERSION: "PP-OCRv6",
        PADDLEOCR_DETECTION_MODEL: "",
        PADDLEOCR_RECOGNITION_MODEL: "",
      }),
    });

    const detectionLabel = findField(host, "检测模型");
    const recognitionLabel = findField(host, "识别模型");
    expect(detectionLabel?.querySelector("select")).not.toBeNull();
    expect(recognitionLabel?.querySelector("select")).not.toBeNull();
  });

  it("restores custom model IDs after an unsaved version round trip", async () => {
    const save = vi.fn(async (request) => ({
      ok: true as const,
      data: {
        ...initialGlobalSettings,
        values: { ...initialGlobalSettings.values, ...request.values },
      },
    }));
    const settings = {
      ...initialGlobalSettings,
      values: {
        ...initialGlobalSettings.values,
        PADDLEOCR_PRESET: "custom",
        PADDLEOCR_MODEL_VERSION: "PP-OCRv6",
        PADDLEOCR_DETECTION_MODEL: "local_det_v6",
        PADDLEOCR_RECOGNITION_MODEL: "local_rec_v6",
      },
    };
    const { host } = await renderSettings(save, settings);
    const modelLabel = [...host.querySelectorAll("label")].find((label) => label.textContent?.includes("模型版本"));
    const modelSelect = modelLabel?.querySelector("select");
    if (!(modelSelect instanceof HTMLSelectElement)) throw new Error("missing PaddleOCR model version select");

    act(() => changeSelect(modelSelect, "PP-OCRv5"));
    expect(findField(host, "检测模型")?.querySelector<HTMLInputElement>("input")?.value).toBe("");
    expect(findField(host, "识别模型")?.querySelector<HTMLInputElement>("input")?.value).toBe("");

    const v5ModelSelect = [...host.querySelectorAll("label")]
      .find((label) => label.textContent?.includes("模型版本"))
      ?.querySelector("select");
    if (!(v5ModelSelect instanceof HTMLSelectElement)) throw new Error("missing v5 model version select");
    act(() => changeSelect(v5ModelSelect, "PP-OCRv6"));
    expect(findField(host, "检测模型")?.querySelector<HTMLInputElement>("input")?.value).toBe("local_det_v6");
    expect(findField(host, "识别模型")?.querySelector<HTMLInputElement>("input")?.value).toBe("local_rec_v6");
  });

  it("offers PP-OCRv6 detector and recognizer model lists", async () => {
    const save = vi.fn(async (request) => ({
      ok: true as const,
      data: {
        ...initialGlobalSettings,
        values: { ...initialGlobalSettings.values, ...request.values },
      },
    }));
    const settings = {
      ...initialGlobalSettings,
      values: {
        ...initialGlobalSettings.values,
        PADDLEOCR_PRESET: "custom",
        PADDLEOCR_MODEL_VERSION: "PP-OCRv6",
        PADDLEOCR_DETECTION_MODEL: "",
        PADDLEOCR_RECOGNITION_MODEL: "",
      },
    };
    const { host } = await renderSettings(save, settings);
    const detectionLabel = findField(host, "检测模型");
    const recognitionLabel = findField(host, "识别模型");
    const detection = detectionLabel?.querySelector("select");
    const recognition = recognitionLabel?.querySelector("select");
    if (!(detection instanceof HTMLSelectElement) || !(recognition instanceof HTMLSelectElement)) {
      throw new Error("missing PP-OCRv6 model selects");
    }

    // Field must keep the explicit target on the nested select instead of
    // cloning the same ID onto the composite control wrapper.
    expect(host.querySelectorAll("#paddle-detection-model-select")).toHaveLength(1);
    expect(host.querySelectorAll("#paddle-recognition-model-select")).toHaveLength(1);
    expect(detection.closest("label")?.htmlFor).toBe("paddle-detection-model-select");
    expect(recognition.closest("label")?.htmlFor).toBe("paddle-recognition-model-select");

    expect([...detection.options].map((option) => option.value)).toEqual([
      "",
      "PP-OCRv6_medium_det",
      "PP-OCRv6_small_det",
      "PP-OCRv6_tiny_det",
    ]);
    expect([...recognition.options].map((option) => option.value)).toEqual([
      "",
      "PP-OCRv6_medium_rec",
      "PP-OCRv6_small_rec",
      "PP-OCRv6_tiny_rec",
    ]);

    // Choosing a tier must persist the exact detector and recognizer IDs that
    // Main/Python use to build the matching PP-OCRv6 pipeline.
    act(() => changeSelect(detection, "PP-OCRv6_medium_det"));
    act(() => changeSelect(recognition, "PP-OCRv6_tiny_rec"));
    const saveButton = [...host.querySelectorAll("button")].find((button) => button.textContent?.trim() === "保存全局配置");
    if (!(saveButton instanceof HTMLButtonElement)) throw new Error("missing global save button");
    await act(async () => {
      saveButton.click();
      await Promise.resolve();
      await Promise.resolve();
    });

    expect(save).toHaveBeenCalledWith({
      values: expect.objectContaining({
        PADDLEOCR_DETECTION_MODEL: "PP-OCRv6_medium_det",
        PADDLEOCR_RECOGNITION_MODEL: "PP-OCRv6_tiny_rec",
      }),
    });
  });

  it("keeps custom PP-OCRv6 model IDs editable alongside the recommendations", async () => {
    const save = vi.fn(async (request) => ({
      ok: true as const,
      data: {
        ...initialGlobalSettings,
        values: { ...initialGlobalSettings.values, ...request.values },
      },
    }));
    const settings = {
      ...initialGlobalSettings,
      values: {
        ...initialGlobalSettings.values,
        PADDLEOCR_PRESET: "custom",
        PADDLEOCR_MODEL_VERSION: "PP-OCRv6",
        PADDLEOCR_DETECTION_MODEL: "",
        PADDLEOCR_RECOGNITION_MODEL: "",
      },
    };
    const { host } = await renderSettings(save, settings);
    const detection = findField(host, "检测模型")?.querySelector<HTMLInputElement>("input[aria-label='自定义检测模型 ID']");
    const recognition = findField(host, "识别模型")?.querySelector<HTMLInputElement>("input[aria-label='自定义识别模型 ID']");
    if (!(detection instanceof HTMLInputElement) || !(recognition instanceof HTMLInputElement)) {
      throw new Error("missing custom PP-OCRv6 model inputs");
    }

    act(() => changeInput(detection, "local_det_v6"));
    act(() => changeInput(recognition, "local_rec_v6"));
    const saveButton = [...host.querySelectorAll("button")].find((button) => button.textContent?.trim() === "保存全局配置");
    if (!(saveButton instanceof HTMLButtonElement)) throw new Error("missing global save button");
    await act(async () => {
      saveButton.click();
      await Promise.resolve();
      await Promise.resolve();
    });

    expect(save).toHaveBeenCalledWith({
      values: expect.objectContaining({
        PADDLEOCR_DETECTION_MODEL: "local_det_v6",
        PADDLEOCR_RECOGNITION_MODEL: "local_rec_v6",
      }),
    });
  });

  it("top-aligns OCR engine cards so disclosures size independently", async () => {
    const css = await readFile("src/renderer/app/app.module.css", "utf8");

    // Grid cross-axis start alignment is the ownership boundary for independent
    // card height; opening Vision details must not stretch the Paddle card.
    expect(css).toMatch(/\.ocrEngineGrid \{[^}]*align-items: start;/s);
  });
});

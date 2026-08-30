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
) {
  const api = {
    app: { getConfig: vi.fn(async () => ({ ok: true as const, data: config })) },
    settings: {
      getGlobalSettings: vi.fn(async () => ({ ok: true as const, data: settings })),
      getOcrSettings: vi.fn(async () => ({ ok: true as const, data: { pythonPath: "", setupCompleted: false, setupSkipped: false } })),
      saveGlobalSettings,
    },
  } as unknown as SlateSyncApi;
  Object.defineProperty(window, "slateSync", { configurable: true, value: api });
  useProjectStore.setState({ config });
  const host = document.createElement("div");
  document.body.append(host);
  const root = createRoot(host);
  mounted.push({ host, root });
  await act(async () => {
    root.render(<GlobalSettingsPage />);
    await Promise.resolve();
    await Promise.resolve();
  });
  return host;
}

function changeSelect(select: HTMLSelectElement, value: string) {
  const valueSetter = Object.getOwnPropertyDescriptor(HTMLSelectElement.prototype, "value")?.set;
  valueSetter?.call(select, value);
  select.dispatchEvent(new Event("change", { bubbles: true }));
}

describe("global settings layout and OCR routing", () => {
  it("keeps credentials and appearance in the same explicit overview row", async () => {
    const save = vi.fn(async () => ({ ok: true as const, data: initialGlobalSettings }));
    const host = await renderSettings(save);
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
    const host = await renderSettings(save);
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

  it("treats the PaddleOCR card enable control as a routing choice", async () => {
    const save = vi.fn(async (request) => ({
      ok: true as const,
      data: {
        ...initialGlobalSettings,
        values: { ...initialGlobalSettings.values, ...request.values },
      },
    }));
    const host = await renderSettings(save);
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

  it("shows named preset values read-only and materializes them on custom", async () => {
    const save = vi.fn(async (request) => ({
      ok: true as const,
      data: {
        ...initialGlobalSettings,
        values: { ...initialGlobalSettings.values, ...request.values },
      },
    }));
    const host = await renderSettings(save);
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
    const host = await renderSettings(save, settings);
    const modelLabel = [...host.querySelectorAll("label")].find((label) => label.textContent?.includes("模型版本"));
    const modelSelect = modelLabel?.querySelector("select");
    if (!(modelSelect instanceof HTMLSelectElement)) throw new Error("missing PaddleOCR model version select");

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
  });

  it("top-aligns OCR engine cards so disclosures size independently", async () => {
    const css = await readFile("src/renderer/app/app.module.css", "utf8");

    // Grid cross-axis start alignment is the ownership boundary for independent
    // card height; opening Vision details must not stretch the Paddle card.
    expect(css).toMatch(/\.ocrEngineGrid \{[^}]*align-items: start;/s);
  });
});

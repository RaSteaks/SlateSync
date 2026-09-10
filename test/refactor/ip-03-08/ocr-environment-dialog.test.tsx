// @vitest-environment jsdom
/// <reference types="node" />
// Component tests for the OCR detection/download dialog. The dialog portals
// into document.body, so assertions read the document instead of the host.
import { readFile } from "node:fs/promises";
import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { afterEach, describe, expect, it, vi } from "vitest";
import type { ConfigData, OcrEnvironmentSnapshot, SlateSyncApi } from "../../../src/shared/contracts/index.js";
import { OcrEnvironmentDialog } from "../../../src/renderer/features/settings/OcrEnvironmentDialog";
import type { PaddleOcrInstallState } from "../../../src/renderer/features/settings/ocrEngineStatus";

// React 19 requires the act marker for deterministic async settings hydration.
(globalThis as { IS_REACT_ACT_ENVIRONMENT?: boolean }).IS_REACT_ACT_ENVIRONMENT = true;

const mounted: Array<{ host: HTMLDivElement; root: Root }> = [];

const config = {
  providers: [],
  ocrEngines: [
    { id: "vision", label: "Apple Vision OCR", mode: "auto", enabled: true, available: true, required: false, language: "zh-Hans", recognitionLevel: "accurate" },
    { id: "paddleocr", label: "PaddleOCR", mode: "auto", enabled: true, available: false, required: false, modelVersion: "PP-OCRv5", profile: "balanced" },
  ],
  ocrSelection: { id: "vision", label: "Apple Vision OCR", mode: "auto", reason: "自动模式优先 Vision OCR。", available: true, enabled: true, required: false },
} as unknown as ConfigData;

const snapshot: OcrEnvironmentSnapshot = {
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

const paddleInstalledResult = {
  pythonPath: "/user-data/paddleocr-venv/bin/python",
  setupCompleted: true,
  setupSkipped: false,
  paddleVersion: "3.3.1",
  paddleOcrVersion: "3.7.0",
};

function baseProps() {
  return {
    open: true,
    onClose: vi.fn(),
    config,
    paddleInstallState: "idle" as PaddleOcrInstallState,
    paddleInstallProgress: null,
    paddleInstallError: null,
    onInstallPaddleOcr: vi.fn(),
    onCancelPaddleOcrInstall: vi.fn(),
    visionCheck: null,
    visionCheckState: "idle" as const,
    onCheckVision: vi.fn(),
  };
}

type DialogProps = ReturnType<typeof baseProps>;

afterEach(() => {
  for (const { host, root } of mounted.splice(0)) {
    act(() => root.unmount());
    host.remove();
  }
  Object.defineProperty(window, "slateSync", { configurable: true, value: undefined });
});

async function renderDialog(props: DialogProps, getOcrEnvironment?: SlateSyncApi["settings"]["getOcrEnvironment"]) {
  const api = {
    settings: {
      getOcrEnvironment:
        getOcrEnvironment ??
        vi.fn(async () => ({ ok: true as const, data: snapshot })),
    },
  } as unknown as SlateSyncApi;
  Object.defineProperty(window, "slateSync", { configurable: true, value: api });
  const host = document.createElement("div");
  document.body.append(host);
  const root = createRoot(host);
  mounted.push({ host, root });
  await act(async () => {
    root.render(<OcrEnvironmentDialog {...props} />);
    await Promise.resolve();
    await Promise.resolve();
  });
  await act(async () => {
    await Promise.resolve();
    await Promise.resolve();
  });
  return host;
}

function dialogElement() {
  const dialog = document.querySelector('[role="dialog"]');
  if (!dialog) throw new Error("missing OCR environment dialog");
  return dialog;
}

function findButton(container: Element, text: string) {
  const button = [...container.querySelectorAll("button")].find((candidate) => candidate.textContent?.trim() === text);
  if (!(button instanceof HTMLButtonElement)) throw new Error(`missing button: ${text}`);
  return button;
}

describe("OCR environment dialog", () => {
  it("renders the machine snapshot beside per-engine detection results", async () => {
    const props = baseProps();
    await renderDialog(props);

    const dialog = dialogElement();
    expect(dialog.textContent).toContain("本机环境");
    expect(dialog.textContent).toContain("macOS 15.5");
    expect(dialog.textContent).toContain("Apple Silicon（arm64）");
    expect(dialog.textContent).toContain("开发版");
    expect(dialog.textContent).toContain("满足要求 · Python 3.12.4");
    // Engine rows mirror the Main probe: Vision bridge missing, Paddle venv absent.
    expect(dialog.textContent).toContain("未找到");
    expect(dialog.textContent).toContain("未安装");
    expect(dialog.textContent).toContain("自动发现（python3）");
    expect(dialog.textContent).toContain("/user-data/paddleocr-venv/bin/python");
  });

  it("shows a pinned PaddleOCR Python path as the effective interpreter", async () => {
    const props = baseProps();
    await renderDialog(props, vi.fn(async () => ({
      ok: true as const,
      data: {
        ...snapshot,
        paddle: {
          ...snapshot.paddle,
          configuredPythonPath: "/opt/paddle/bin/python",
          activePythonPath: "/opt/paddle/bin/python",
          activePythonExists: true,
        },
      },
    })));

    const dialog = dialogElement();
    expect(dialog.textContent).toContain("/opt/paddle/bin/python");
    expect(dialog.textContent).toContain("路径来源");
    expect(dialog.textContent).toContain("PADDLEOCR_PYTHON");
    expect(dialog.textContent).toContain("不会覆盖当前配置");
  });

  it("warns when the pinned Python path no longer exists", async () => {
    const props = baseProps();
    await renderDialog(props, vi.fn(async () => ({
      ok: true as const,
      data: {
        ...snapshot,
        paddle: {
          ...snapshot.paddle,
          configuredPythonPath: "/gone/paddle/bin/python",
          activePythonPath: "/gone/paddle/bin/python",
          activePythonExists: false,
        },
      },
    })));

    const dialog = dialogElement();
    expect(dialog.textContent).toContain("/gone/paddle/bin/python（未找到）");
    expect(dialog.textContent).toContain("固定的 Python 路径当前不存在");
  });

  it("labels the Vision bridge source for bundled and explicit setups", async () => {
    const props = baseProps();
    await renderDialog(props, vi.fn(async () => ({
      ok: true as const,
      data: {
        ...snapshot,
        packaged: true,
        vision: { binaryPath: "/resources/bin/vision-ocr", binaryExists: true, source: "bundled", swiftToolchain: false },
      },
    })));

    expect(dialogElement().textContent).toContain("打包内置 bridge");
  });

  it("re-probes the machine when 重新检测 is pressed", async () => {
    const props = baseProps();
    const getOcrEnvironment = vi.fn(async () => ({ ok: true as const, data: snapshot }));
    await renderDialog(props, getOcrEnvironment);

    await act(async () => {
      findButton(dialogElement(), "重新检测").click();
      await Promise.resolve();
      await Promise.resolve();
    });

    expect(getOcrEnvironment).toHaveBeenCalledTimes(2);
  });

  it("keeps a retryable error visible when the environment probe rejects", async () => {
    const props = baseProps();
    await renderDialog(props, vi.fn(async () => ({
      ok: false as const,
      error: { code: "UNKNOWN", message: "OCR 环境检测不可用，请完全退出 SlateSync 后重试。", retryable: true },
    })));

    const dialog = dialogElement();
    expect(dialog.textContent).toContain("OCR 环境检测不可用");
    expect(dialog.textContent).toContain("重试");
  });

  it("explains a Preload version mismatch instead of throwing a TypeError", async () => {
    const props = baseProps();
    // HMR keeps an old Preload alive; the dialog must degrade to guidance.
    const api = { settings: {} };
    Object.defineProperty(window, "slateSync", { configurable: true, value: api });

    const host = document.createElement("div");
    document.body.append(host);
    const root = createRoot(host);
    mounted.push({ host, root });
    await act(async () => {
      root.render(<OcrEnvironmentDialog {...props} />);
      await Promise.resolve();
      await Promise.resolve();
    });
    await act(async () => {
      await Promise.resolve();
      await Promise.resolve();
    });

    expect(dialogElement().textContent).toContain("当前 Renderer 与 Preload 版本不一致");
  });

  it("switches the Paddle call to action with the installed environment", async () => {
    const props = baseProps();
    await renderDialog(props, vi.fn(async () => ({
      ok: true as const,
      data: {
        ...snapshot,
        paddle: { ...snapshot.paddle, venvExists: true },
      },
    })));

    const dialog = dialogElement();
    expect(dialog.textContent).toContain("已安装");
    expect(findButton(dialog, "重新安装 PaddleOCR")).toBeTruthy();
  });

  it("forwards the one-click install action from the dialog card", async () => {
    const props = baseProps();
    await renderDialog(props);

    const dialog = dialogElement();
    await act(async () => {
      findButton(dialog, "安装 PaddleOCR").click();
      await Promise.resolve();
    });
    expect(props.onInstallPaddleOcr).toHaveBeenCalledTimes(1);
  });

  it("offers a cancel action while the installation is running", async () => {
    const props = {
      ...baseProps(),
      paddleInstallState: "installing" as PaddleOcrInstallState,
      paddleInstallProgress: { stage: "install-dependencies", percent: 35, message: "正在安装依赖…" },
    };
    await renderDialog(props);

    const dialog = dialogElement();
    expect(dialog.textContent).toContain("正在安装依赖…");
    await act(async () => {
      findButton(dialog, "取消安装").click();
      await Promise.resolve();
    });
    expect(props.onCancelPaddleOcrInstall).toHaveBeenCalledTimes(1);
  });

  it("forwards the Vision runtime check from the dialog card", async () => {
    const props = baseProps();
    await renderDialog(props);

    await act(async () => {
      findButton(dialogElement(), "检查 Vision OCR").click();
      await Promise.resolve();
    });
    expect(props.onCheckVision).toHaveBeenCalledTimes(1);
  });

  it("keeps the machine grid two-column on desktop and single-column on narrow windows", async () => {
    const css = await readFile("src/renderer/app/app.module.css", "utf8");

    expect(css).toMatch(/\.ocrEnvironmentGrid \{[^}]*grid-template-columns: repeat\(2, minmax\(0, 1fr\)\);/s);
    expect(css).toMatch(/\n  \.ocrEnvironmentGrid \{ grid-template-columns: 1fr; \}/);
  });
});

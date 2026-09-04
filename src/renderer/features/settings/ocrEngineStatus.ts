import type { ConfigData, OcrEngineStatus } from "../../../shared/contracts/index.js";

export type StatusTone = "neutral" | "success" | "warning" | "danger";
export type PaddleOcrInstallState = "idle" | "installing" | "installed" | "canceled" | "error";

export function engineStatus(config: ConfigData | null, id: "vision" | "paddleocr"): OcrEngineStatus | null {
  return config?.ocrEngines.find((engine) => engine.id === id) || null;
}

export function engineStatusLabel(engine: OcrEngineStatus | null): string {
  if (!engine) return "未读取";
  if (engine.enabled && engine.available) return "环境可用";
  if (engine.enabled) return "已启用但不可用";
  return engine.mode === "auto" ? "未启用" : "已关闭";
}

export function engineStatusTone(engine: OcrEngineStatus | null): StatusTone {
  if (!engine) return "neutral";
  if (engine.enabled && engine.available) return "success";
  if (engine.enabled && engine.required) return "danger";
  if (engine.enabled) return "warning";
  return "neutral";
}

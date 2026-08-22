import type { AppError, Result, SlateSyncApi } from "../../shared/contracts/index.js";

/** The Renderer sees only the frozen typed gateway; no raw channel names leak into features. */
export function getSlateSync(): SlateSyncApi {
  if (!window.slateSync) throw new Error("SlateSync Preload gateway is unavailable");
  return window.slateSync;
}

export class RendererAppError extends Error {
  readonly code: string;
  readonly retryable: boolean;

  constructor(error: AppError) {
    super(error.message);
    this.name = "RendererAppError";
    this.code = error.code;
    this.retryable = error.retryable;
  }
}

export async function unwrap<T>(result: Result<T>): Promise<T> {
  if (result.ok) return result.data;
  throw new RendererAppError(result.error);
}

export function appErrorFromUnknown(value: unknown): AppError {
  if (value instanceof RendererAppError) return { code: value.code, message: value.message, retryable: value.retryable };
  if (value instanceof Error) return { code: "UNKNOWN", message: value.message, retryable: false };
  return { code: "UNKNOWN", message: "未知错误", retryable: false };
}

export async function loadConfig() {
  return unwrap(await getSlateSync().app.getConfig());
}

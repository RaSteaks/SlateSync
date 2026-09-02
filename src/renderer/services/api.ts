import type { AppError, Result, SlateSyncApi } from "../../shared/contracts/index.js";

/** The Renderer sees only the frozen typed gateway; no raw channel names leak into features. */
export function getSlateSync(): SlateSyncApi {
  if (!window.slateSync) throw new Error("SlateSync Preload gateway is unavailable");
  return window.slateSync;
}

/**
 * HMR replaces Renderer code without reloading Electron's Preload context.
 * Check the newly added settings methods at the feature boundary so an old
 * window reports an actionable restart instruction instead of a raw TypeError.
 */
export function requireGlobalSettingsApi(): SlateSyncApi {
  const api = getSlateSync();
  const settings = api.settings as Partial<SlateSyncApi["settings"]> | undefined;
  if (typeof settings?.getGlobalSettings !== "function" || typeof settings.saveGlobalSettings !== "function") {
    throw new Error("当前 Renderer 与 Preload 版本不一致，无法读取全局设置。请完全退出 SlateSync 后重新启动；开发环境请运行 npm run electron:dev:modern。不要只刷新窗口。");
  }
  return api;
}

/** Keep the log viewer's newly added folder action diagnosable across HMR. */
export function requireLocalLogDirectoryApi(): SlateSyncApi {
  const api = getSlateSync();
  const logs = api.logs as Partial<SlateSyncApi["logs"]> | undefined;
  if (typeof logs?.openDirectory !== "function") {
    throw new Error("当前 Renderer 与 Preload 版本不一致，无法打开本地日志文件夹。请完全退出 SlateSync 后重新启动；开发环境请运行 npm run electron:dev:modern。不要只刷新窗口。");
  }
  return api;
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

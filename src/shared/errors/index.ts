import type { AppError } from "../contracts/index.js";

interface ErrorLike {
  readonly code?: unknown;
  readonly message?: unknown;
  readonly retryable?: unknown;
  readonly status?: unknown;
}

const RETRYABLE_STATUSES = new Set([408, 429, 502, 503, 504]);
const TRANSPORT_PREFIX = /^Error invoking remote method '[^']+':\s*/;
const ABSOLUTE_PATH = /(?:\/Users\/|\/private\/|\/tmp\/|\/var\/|\/home\/|[A-Za-z]:\\)[^\s)]+/g;

function isErrorLike(value: unknown): value is ErrorLike {
  return typeof value === "object" && value !== null;
}

function safeStatus(value: unknown): number | null {
  return typeof value === "number" && Number.isInteger(value) ? value : null;
}

function safeCode(value: unknown): string | null {
  if (typeof value !== "string" || !/^[A-Za-z][A-Za-z0-9_.:-]{0,64}$/.test(value)) return null;
  return value;
}

function safeMessage(value: unknown): string {
  const raw = typeof value === "string" && value.trim() ? value : "未知错误";
  return raw.replace(TRANSPORT_PREFIX, "").replace(ABSOLUTE_PATH, "<path>");
}

/** Convert a rejected IPC invocation into the stable, secret-free envelope. */
export function toAppError(value: unknown): AppError {
  const details = isErrorLike(value) ? value : {};
  const status = safeStatus(details.status);
  const code = safeCode(details.code) || (status === null ? "UNKNOWN" : `HTTP_${status}`);
  return {
    code,
    message: safeMessage(details.message),
    retryable: typeof details.retryable === "boolean"
      ? details.retryable
      : status !== null && RETRYABLE_STATUSES.has(status),
  };
}

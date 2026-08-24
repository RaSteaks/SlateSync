export type ValidationResult =
  | { readonly ok: true }
  | { readonly ok: false; readonly message: string };

export type CsvInputKind = "slate" | "resolve";

export const CSV_MAX_BYTES = 10 * 1024 * 1024;

const SLATE_FALLBACK_TYPES = [
  "image/jpeg",
  "image/png",
  "image/webp",
  "application/pdf",
] as const;

function fileTypeFromName(file: File): string {
  const extension = file.name.toLowerCase().split(".").pop();
  if (extension === "pdf") return "application/pdf";
  if (extension === "jpg" || extension === "jpeg") return "image/jpeg";
  if (extension === "png") return "image/png";
  if (extension === "webp") return "image/webp";
  return "";
}

export function validateProjectName(value: string): ValidationResult {
  if (!value.trim()) return { ok: false, message: "请输入项目名称。" };
  return { ok: true };
}

export function validateSlateFile(
  file: File,
  options: {
    readonly acceptedTypes?: readonly string[];
    readonly maxBytes?: number;
  } = {},
): ValidationResult & { readonly type?: string } {
  const acceptedTypes = options.acceptedTypes || SLATE_FALLBACK_TYPES;
  const type = file.type || fileTypeFromName(file);
  if (!acceptedTypes.includes(type)) {
    return { ok: false, message: "请选择 PDF、JPEG、PNG 或 WebP 文件。" };
  }
  if (options.maxBytes && file.size > options.maxBytes) {
    return {
      ok: false,
      message: `文件不能超过 ${(options.maxBytes / 1024 / 1024).toFixed(0)} MB。`,
    };
  }
  return { ok: true, type };
}

export function validateCsvFile(
  file: File,
  kind: CsvInputKind,
  maxBytes = CSV_MAX_BYTES,
): ValidationResult {
  if (!file.name.toLowerCase().endsWith(".csv")) {
    return { ok: false, message: kind === "slate" ? "请选择场记 CSV 文件。" : "请选择 Resolve CSV 文件。" };
  }
  if (file.size > maxBytes) {
    return { ok: false, message: `CSV 不能超过 ${(maxBytes / 1024 / 1024).toFixed(0)} MB。` };
  }
  return { ok: true };
}

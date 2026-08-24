import { describe, expect, it } from "vitest";
import { CSV_MAX_BYTES, validateCsvFile, validateProjectName, validateSlateFile } from "../../../src/renderer/validation/input-validation";

describe("renderer input validation", () => {
  it("returns a visible project-name error instead of silently stopping", () => {
    expect(validateProjectName("   ")).toEqual({ ok: false, message: "请输入项目名称。" });
    expect(validateProjectName("  Demo  ")).toEqual({ ok: true });
  });

  it("uses one CSV type and size policy for picker and drop inputs", () => {
    expect(validateCsvFile(new File(["a"], "notes.txt"), "resolve")).toEqual({ ok: false, message: "请选择 Resolve CSV 文件。" });
    expect(validateCsvFile(new File(["a"], "slate.csv"), "slate")).toEqual({ ok: true });
    expect(validateCsvFile(new File([new Uint8Array(CSV_MAX_BYTES + 1)], "large.csv"), "slate").ok).toBe(false);
  });

  it("accepts a known slate extension when the browser omits MIME type", () => {
    const result = validateSlateFile(new File(["pdf"], "sheet.pdf"), { acceptedTypes: ["application/pdf"], maxBytes: 1024 });
    expect(result).toEqual({ ok: true, type: "application/pdf" });
  });
});

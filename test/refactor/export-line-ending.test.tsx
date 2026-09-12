// @vitest-environment jsdom
import { act } from "react";
import { createRoot } from "react-dom/client";
import { expect, it } from "vitest";
import { readFileSync } from "node:fs";
import { ExportOptionsPanel } from "../../src/renderer/features/export/ExportOptionsPanel";
import { DEFAULT_EXPORT_OPTIONS, type ExportOptions } from "../../src/shared/contracts/index.js";
// @ts-expect-error Shared browser module is intentionally JavaScript.
import { normalizeExportOptions, DEFAULT_EXPORT_OPTIONS as workerDefaults } from "../../public/export-options.js";

// @ts-expect-error Shared built-in registry is intentionally JavaScript.
import { RESOLVE_TEMPLATE_ID, RESOLVE_METADATA_FIELDS } from "../../public/resolve-export-template.js";

(globalThis as { IS_REACT_ACT_ENVIRONMENT?: boolean }).IS_REACT_ACT_ENVIRONMENT = true;

it("modern line ending choices survive change and controlled rerender", () => {
  const host = document.createElement("div");
  document.body.append(host);
  const root = createRoot(host);
  let options: ExportOptions = DEFAULT_EXPORT_OPTIONS;
  const render = () => root.render(<ExportOptionsPanel options={options} onChange={(next) => { options = next; render(); }} />);
  try {
    act(render);
    const select = [...host.querySelectorAll("select")].find((item) => item.textContent?.includes("CRLF"))!;
    for (const ending of ["\n", "\r", "\r\n"]) {
      act(() => { select.value = ending; select.dispatchEvent(new Event("change", { bubbles: true })); });
      expect(options.format.lineEnding).toBe(ending);
      expect(select.value).toBe(ending);
    }
  } finally { act(() => root.unmount()); host.remove(); }
});

it("legacy HTML preserves all line endings through rendering and form readback", () => {
  // Exercise the actual legacy functions without booting Electron or app startup.
  const source = readFileSync("public/app.js", "utf8");
  const functions = source.slice(source.indexOf("function renderLegacyExportOptions("), source.indexOf("function bindLegacyExportOptionEvents("));
  const { renderLegacyExportOptions, readLegacyExportOptions } = new Function("normalizeExportOptions", "DEFAULT_EXPORT_OPTIONS", "escapeHtml", "LEGACY_EXPORT_COLUMN_LABELS", "bindLegacyExportOptionEvents", "RESOLVE_TEMPLATE_ID", "RESOLVE_METADATA_FIELDS", `${functions}; return { renderLegacyExportOptions, readLegacyExportOptions };`)(normalizeExportOptions, DEFAULT_EXPORT_OPTIONS, (value: string) => value, {}, () => {}, RESOLVE_TEMPLATE_ID, RESOLVE_METADATA_FIELDS);
  const host = document.createElement("div");
  for (const ending of ["\r\n", "\n", "\r"]) {
    const options = normalizeExportOptions({ format: { lineEnding: ending } });
    renderLegacyExportOptions(host, options, "project");
    expect(readLegacyExportOptions(host, options).format.lineEnding).toBe(ending);
    const select = host.querySelector('[data-export-field="lineEnding"]') as HTMLSelectElement;
    for (const [token, bytes] of [["crlf", "\r\n"], ["lf", "\n"], ["cr", "\r"]]) {
      select.value = token!;
      expect(readLegacyExportOptions(host, options).format.lineEnding).toBe(bytes);
    }
  }
});

it("built-in selection locks identity fields, preserves optional choices and uses official headers", () => {
  const host = document.createElement("div");
  document.body.append(host);
  const root = createRoot(host);
  let options: ExportOptions = DEFAULT_EXPORT_OPTIONS;
  const render = () => root.render(<ExportOptionsPanel options={options} onChange={(next) => { options = next; render(); }} />);
  try {
    act(render);
    const select = host.querySelector("select")!;
    act(() => { select.value = RESOLVE_TEMPLATE_ID; select.dispatchEvent(new Event("change", { bubbles: true })); });
    expect(options.templateId).toBe(RESOLVE_TEMPLATE_ID);
    expect(options.columns.filter((column) => column.enabled).slice(0, 5).map((column) => column.header)).toEqual(["File Name", "Start TC", "End TC", "Reel Name", "Clip Directory"]);
    expect(host.querySelectorAll('input[type="checkbox"]:disabled')).toHaveLength(5);
    expect(host.querySelectorAll('input[readonly]')).toHaveLength(15);
    const description = [...host.querySelectorAll('input[type="checkbox"]')].find((input) => input.closest("label")?.textContent?.includes("内容描述")) as HTMLInputElement;
    act(() => description.click());
    expect(options.columns.find((column) => column.key === "description")?.enabled).toBe(true);
    expect(options.columns.find((column) => column.key === "description")?.header).toBe("Description");
  } finally { act(() => root.unmount()); host.remove(); }
});

// The compiled contract cannot import public JavaScript; guard the duplicated default boundary.
it("shared renderer and Worker defaults select the same Resolve schema", () => {
  expect(DEFAULT_EXPORT_OPTIONS).toEqual(workerDefaults);
});

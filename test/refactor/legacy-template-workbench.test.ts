// @vitest-environment jsdom
import { readFileSync } from "node:fs";
import { afterEach, expect, it, vi } from "vitest";
// @ts-expect-error Shared browser modules deliberately remain JavaScript.
import * as templates from "../../public/export-templates.js";
// @ts-expect-error Shared browser module.
import * as exports from "../../public/export-options.js";
// @ts-expect-error Shared browser module.
import * as resolve from "../../public/resolve-export-template.js";

// Execute production legacy functions with isolated state, without app startup.
function setup() {
  const state = { currentProjectId: "A", currentProject: { settings: { export: exports.normalizeExportOptions({ templateId: "custom" }) } }, projectExportTemplatesDraft: null, templateNameDraft: null };
  const dirty = vi.fn();
  const open = vi.fn();
  const worker = vi.fn(async () => ({ options: exports.normalizeExportOptions({ templateId: "custom" }), sourceEncoding: "utf-8" }));
  const source = readFileSync("public/app.js", "utf8");
  const functions = source.slice(source.indexOf("function renderLegacyExportOptions("), source.indexOf("function openTemplateDialog("));
  const dependencies = { ...templates, ...exports, ...resolve, state, markProjectSettingsDirty: dirty, openTemplateDialog: open, runCsvBackgroundTask: worker, isProjectReadOnly: () => false, defaultRendererProjectSettings: () => state.currentProject.settings, effectiveLegacyExportOptions: () => state.currentProject.settings.export, LEGACY_EXPORT_COLUMN_LABELS: {}, escapeHtml: (value: string) => String(value).replaceAll('"', '&quot;') };
  const api = new Function(...Object.keys(dependencies), `${functions}; return { renderLegacyExportOptions, readLegacyExportOptions, legacyTemplateEditorDirty, legacyImportTemplate };`)(...Object.values(dependencies));
  const host = document.createElement("div"); document.body.append(host);
  api.renderLegacyExportOptions(host, state.currentProject.settings.export, "project");
  return { api, host, state, dirty, open, worker };
}
afterEach(() => { document.body.innerHTML = ""; });

it("preserves configured provider/model for empty selects and rejects an unready provider switch", () => {
  const source = readFileSync("public/app.js", "utf8");
  const functions = source.slice(source.indexOf("function buildProjectSettingsFromForm("), source.indexOf("async function saveProjectSettings("));
  const elements = Object.fromEntries(Object.entries({ projectSceneFormat: "XXX", projectShotFormat: "XX", projectTakeFormat: "XX", projectGoodComment: "_OK", projectHoldComment: "_KP", projectProvider: "", projectModel: "", projectAccuracy: "high", projectScenario: "", projectCustomPrompt: "" }).map(([key, value]) => [key, { value }]));
  const settings = { providerId: "saved-provider", modelId: "saved-model", export: {} };
  const build = new Function("elements", "state", "readLegacyExportOptions", "legacyTemplatesDraft", `${functions}; return buildProjectSettingsFromForm;`)(elements, { currentProject: { settings } }, () => ({}), () => []);
  expect(build()).toMatchObject({ providerId: "saved-provider", modelId: "saved-model" });
  elements.projectProvider.value = "another-provider";
  expect(build).toThrow();
  elements.projectModel.value = "another-model";
  expect(build()).toMatchObject({ providerId: "another-provider", modelId: "another-model" });
});

it("binds field edits, reordering and file picking once, and switches unsaved to locked built-in", () => {
  const { api, host, state, dirty, open } = setup();
  expect(api.legacyTemplateEditorDirty(host)).toBe(false);
  const header = host.querySelector("[data-export-header]") as HTMLInputElement;
  header.value = "Edited"; header.dispatchEvent(new Event("change", { bubbles: true }));
  expect(dirty).toHaveBeenCalledTimes(1);
  expect(api.readLegacyExportOptions(host).columns[0].header).toBe("Edited");
  (host.querySelector('[data-export-move="1"]') as HTMLButtonElement).click();
  expect(api.readLegacyExportOptions(host).columns[1].header).toBe("Edited");
  expect(dirty).toHaveBeenCalledTimes(2);
  const pick = vi.spyOn(host.querySelector("[data-template-import]") as HTMLInputElement, "click");
  (host.querySelector('[data-template-action="import"]') as HTMLButtonElement).click();
  expect(pick).toHaveBeenCalledTimes(1);
  api.renderLegacyExportOptions(host, state.currentProject.settings.export, "project");
  (host.querySelector('[data-template-select=""]') as HTMLButtonElement).click();
  expect(open).not.toHaveBeenCalled();
  expect(host.dataset.exportTemplate).toBe(resolve.RESOLVE_TEMPLATE_ID);
  expect([...host.querySelectorAll("[data-export-field], [data-export-enabled], [data-export-header], [data-export-move]")].every((node) => (node as HTMLInputElement).disabled)).toBe(true);
});

it.each(["file", "worker", "dialog"])("rejects stale project imports after %s", async (phase) => {
  const { api, host, state, worker, open, dirty } = setup();
  let release!: (value: unknown) => void;
  const pending = new Promise((done) => { release = done; });
  const file = { name: "sample.csv", size: 1, arrayBuffer: () => phase === "file" ? pending : Promise.resolve(new ArrayBuffer(0)) };
  if (phase === "worker") worker.mockImplementationOnce(() => pending as ReturnType<typeof worker>);
  const running = api.legacyImportTemplate(host, file);
  await Promise.resolve();
  if (phase !== "dialog") { state.currentProjectId = "B"; release(phase === "file" ? new ArrayBuffer(0) : { options: {}, sourceEncoding: "utf-8" }); }
  await running;
  if (phase === "dialog") { state.currentProjectId = "B"; open.mock.calls[0][0].onConfirm("Imported"); }
  else expect(open).not.toHaveBeenCalled();
  expect(dirty).not.toHaveBeenCalled();
  expect(state.projectExportTemplatesDraft).toBeNull();
  if (phase === "file") expect(worker).not.toHaveBeenCalled();
});

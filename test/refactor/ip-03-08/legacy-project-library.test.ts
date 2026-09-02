import { readFileSync } from "node:fs";
import { describe, expect, it } from "vitest";

const legacyHtml = readFileSync(new URL("../../../public/index.html", import.meta.url), "utf8");
const legacyScript = readFileSync(new URL("../../../public/app.js", import.meta.url), "utf8");

function functionSource(name: string, nextName: string) {
  const start = legacyScript.indexOf(`async function ${name}`);
  const end = legacyScript.indexOf(`async function ${nextName}`, start);
  expect(start).toBeGreaterThanOrEqual(0);
  expect(end).toBeGreaterThan(start);
  return legacyScript.slice(start, end);
}

describe("Legacy project package transfer contract", () => {
  it("keeps one-click PaddleOCR installation beside the Local OCR status", () => {
    // Legacy 不是第二条安装实现；静态契约只锁住 HTML 入口、typed bridge
    // adapter 和状态渲染函数，实际安装仍由 Main 的同一套 IPC 完成。
    expect(legacyHtml).toContain('id="global-paddleocr-install"');
    expect(legacyHtml).toContain('id="global-paddleocr-install-feedback"');
    expect(legacyHtml).toContain('id="global-paddleocr-install-cancel"');
    expect(legacyScript).toContain("installPaddleOcrApi");
    expect(legacyScript).toContain("cancelPaddleOcrInstallApi");
    expect(legacyScript).toContain("onPaddleOcrInstallProgressApi");
    expect(legacyScript).toContain("function renderPaddleOcrInstall");
  });

  it("keeps project package actions in project settings instead of library cards", () => {
    // Legacy 没有 React 组件树，静态契约确保入口层级和 bridge 名称不会漂移。
    expect(legacyHtml).not.toContain('id="import-project-button"');
    expect(legacyHtml).toContain('id="project-settings-import-button"');
    expect(legacyHtml).toContain('id="project-settings-export-button"');
    expect(legacyHtml).toContain('id="project-transfer-notice"');
    expect(legacyScript).not.toContain('data-project-action="export"');
    expect(legacyScript).toContain("projectSettingsImportButton");
    expect(legacyScript).toContain("projectSettingsExportButton");
    expect(legacyScript).toContain("importProjectApi");
    expect(legacyScript).toContain("exportProjectApi");
  });

  it("keeps Legacy Paddle presets effective and version drafts reversible", () => {
    // Legacy is a recovery surface, but it must expose the same preset
    // precedence and unsaved version-switch behavior as Modern settings.
    expect(legacyScript).toContain("const PADDLE_PRESET_VALUES");
    expect(legacyScript).toContain("legacyPaddlePresetOwns");
    expect(legacyScript).toContain("presetLockAttribute");
    expect(legacyScript).toContain("paddleModelDrafts");
    expect(legacyScript).toContain("const restored = state.paddleModelDrafts[nextVersion]");
  });

  it("guards both operations with autosave, cancellation, refresh, and busy cleanup", () => {
    const importSource = functionSource("importProject", "exportProject");
    const exportSource = functionSource("exportProject", "importProjectLibrary");
    const importLibrarySource = functionSource("importProjectLibrary", "changeLibraryLocation");
    const changeLocationSource = functionSource("changeLibraryLocation", "prepareLibraryTransfer");
    for (const source of [importSource, exportSource]) {
      expect(source).toContain("prepareLibraryTransfer");
      expect(source).toContain("result?.canceled");
      expect(source).toContain("state.projectTransferBusy = null");
      expect(source).toContain("setLibraryActionBusy(false)");
      expect(source).not.toContain("confirm(");
    }
    // 导入完成必须刷新当前页面，导出成功只报告路径，不触发应用重启。
    expect(importSource).toContain("refreshLibrary()");
    expect(exportSource).toContain("result.path");
    expect(importSource).toContain("startedNavigationIntent");
    expect(importSource).toContain("showProjectTransferNotice");
    expect(exportSource).toContain("showProjectTransferNotice");
    expect(legacyScript).toContain("intent !== navigationIntent");
    expect(legacyScript).toContain("state.libraryActionBusy");
    expect(legacyScript).toContain("state.projectSettingsDirty");
    expect(legacyScript).toContain("markProjectSettingsDirty");
    expect(legacyScript).toContain("preserveDraft");
    expect(importLibrarySource).toContain("finally");
    expect(changeLocationSource).toContain("finally");
  });
});

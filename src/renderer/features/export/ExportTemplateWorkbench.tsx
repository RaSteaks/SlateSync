import { useEffect, useRef, useState } from "react";
import type { ExportOptions, ProjectSettings, SavedExportTemplate } from "../../../shared/contracts/index.js";
import { Badge, Button, Dialog, Field, InlineError, Input, Stack, Text } from "../../design-system";
import styles from "../../app/app.module.css";
import { appErrorFromUnknown } from "../../services/api";
import { getCsvWorkerService } from "../../services/csv-worker-service";

// @ts-expect-error Shared browser module intentionally has no generated declarations.
import { normalizeExportOptions } from "../../../../public/export-options.js";
import { ExportOptionsPanel } from "./ExportOptionsPanel";
// @ts-expect-error Shared template-library boundary is also consumed by the legacy renderer and Node tests.
import { BUILTIN_TEMPLATE_LABEL, DEFAULT_TEMPLATE_NAME, UNSAVED_TEMPLATE_LABEL, applyEditorContentToTemplate, canonicalTemplateSource, cleanTemplateName, copyTemplateName, createExportTemplate, exportOptionsForBuiltinTemplate, exportOptionsFromTemplate, findExportTemplate, sameTemplateContent, templateAfterDelete, uniqueTemplateName, validateTemplateName } from "../../../../public/export-templates.js";
// @ts-expect-error Shared registry is also consumed by Main and the CSV Worker.
import { RESOLVE_TEMPLATE_ID } from "../../../../public/resolve-export-template.js";

export interface ExportTemplateWorkbenchProps {
  readonly projectId: string;
  readonly settings: ProjectSettings;
  /** Last persisted export config; the dirty baseline of an unsaved selection. */
  readonly baselineExport: ExportOptions | null | undefined;
  readonly disabled?: boolean;
  /** CSV import additionally pauses while a workspace operation is running. */
  readonly importDisabled?: boolean;
  /**
   * All template operations stage page drafts only. `build` receives the
   * latest project settings so an async import can never patch a stale or
   * already-switched draft; the existing page save stays the only durable
   * write.
   */
  readonly applyPatch: (build: (latest: ProjectSettings) => Partial<ProjectSettings>) => void;
}

type WorkbenchDialog =
  | { kind: "save-as" }
  | { kind: "import"; options: ExportOptions; sourceEncoding: string }
  | { kind: "delete"; templateId: string }
  | { kind: "switch"; targetId: string | null };

type TemplateBuildResult = { ok: true; template: SavedExportTemplate } | { ok: false; message: string };

/**
 * 项目级“模板库 + 当前模板编辑器”：左侧是只读的 Resolve 内置模板和项目
 * 模板列表，右侧编辑当前模板。所有操作只写入设置草稿，由页面统一的
 * “保存项目设置”持久化；模板名称与导出文件名规则完全独立。
 */
export function ExportTemplateWorkbench({ projectId, settings, baselineExport, disabled = false, importDisabled = false, applyPatch }: ExportTemplateWorkbenchProps) {
  const templates = settings.exportTemplates ?? [];
  const exportOptions = settings.export;
  const selected = findExportTemplate(templates, exportOptions.savedTemplateId);
  const builtinSelected = !selected && exportOptions.templateId === RESOLVE_TEMPLATE_ID;
  const unsavedSelected = !selected && !builtinSelected;

  const [nameDraft, setNameDraft] = useState(() => uniqueTemplateName(DEFAULT_TEMPLATE_NAME, templates));
  const [editorError, setEditorError] = useState<string | null>(null);
  const [dialog, setDialog] = useState<WorkbenchDialog | null>(null);
  const [dialogName, setDialogName] = useState("");
  const [dialogError, setDialogError] = useState<string | null>(null);
  const [importing, setImporting] = useState(false);
  const [importStatus, setImportStatus] = useState<string | null>(null);
  const [importError, setImportError] = useState<string | null>(null);
  const importInputRef = useRef<HTMLInputElement>(null);
  const importGenerationRef = useRef(0);

  // Selection identity: switching what the editor points at re-seeds the name
  // draft, while content edits inside one selection never clobber typing.
  const selectionKey = selected?.id ?? (builtinSelected ? "::builtin" : "::unsaved");
  useEffect(() => {
    setEditorError(null);
    if (selected) setNameDraft(selected.name);
    else if (unsavedSelected) setNameDraft(uniqueTemplateName(DEFAULT_TEMPLATE_NAME, templates));
    // templates/selected are intentionally read fresh; only selection flips reseed.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [selectionKey]);

  // A project switch while an import decode is in flight must not open the
  // naming dialog for the previous project's draft.
  const activeProjectRef = useRef(projectId);
  useEffect(() => {
    if (activeProjectRef.current === projectId) return;
    activeProjectRef.current = projectId;
    importGenerationRef.current++;
    setDialog(null);
    setImportError(null);
    setImportStatus(null);
  }, [projectId]);

  const nameChanged = Boolean(selected) && cleanTemplateName(nameDraft) !== selected?.name;
  // The read-only built-in never drifts; an unsaved selection only counts as
  // dirty once it differs from the last persisted export configuration.
  const editorDirty = selected
    ? nameChanged || !sameTemplateContent(exportOptions, selected)
    : unsavedSelected && baselineExport
      ? !sameTemplateContent(exportOptions, baselineExport)
      : false;

  const patchExport = (next: ExportOptions) => {
    setEditorError(null);
    applyPatch((latest) => ({ export: normalizeExportOptions(next) as ExportOptions }));
  };
  const patchTemplates = (build: (latest: readonly SavedExportTemplate[]) => Partial<ProjectSettings>) => {
    setEditorError(null);
    applyPatch((latest) => build(latest.exportTemplates ?? []));
  };

  const selectTemplate = (template: SavedExportTemplate) => patchExport(exportOptionsFromTemplate(template) as ExportOptions);
  const selectBuiltin = () => patchExport(exportOptionsForBuiltinTemplate() as ExportOptions);

  const requestSwitch = (targetId: string | null) => {
    // A missing library link also represents unsaved custom settings.
    if (targetId ? targetId === selected?.id : builtinSelected) return;
    if (editorDirty) {
      setDialogError(null);
      setDialog({ kind: "switch", targetId });
      return;
    }
    performSwitch(targetId);
  };
  const performSwitch = (targetId: string | null) => {
    const target = targetId ? findExportTemplate(templates, targetId) : null;
    if (targetId && !target) return;
    if (target) selectTemplate(target);
    else selectBuiltin();
    setDialog(null);
  };

  /** Validate a name against the library and shape the editor into a preset. */
  const buildTemplateFromEditor = (name: string): TemplateBuildResult => {
    const validation = validateTemplateName(name, templates);
    if (!validation.ok) return validation;
    // New presets copy the current editor content; canonicalTemplateSource
    // expands a built-in copy to the full custom column set so reselecting
    // never shows phantom drift.
    return {
      ok: true,
      template: createExportTemplate({
        name: validation.name,
        options: canonicalTemplateSource(exportOptions),
        templateId: exportOptions.templateId === "imported-csv-v1" ? "imported-csv-v1" : "custom",
      }),
    };
  };
  const commitTemplate = (template: SavedExportTemplate) => {
    patchTemplates((latest) => ({
      exportTemplates: [...latest, template],
      export: exportOptionsFromTemplate(template) as ExportOptions,
    }));
    setNameDraft(template.name);
  };
  const createFromEditor = (name: string): boolean => {
    const result = buildTemplateFromEditor(name);
    if (!result.ok) {
      setEditorError(result.message);
      return false;
    }
    commitTemplate(result.template);
    return true;
  };

  /** Write the editor content (and possibly a renamed display name) back. */
  const saveSelectedTemplate = (templateId: string, name: string): string | null => {
    const validation = validateTemplateName(name, templates, templateId);
    if (!validation.ok) return validation.message;
    patchTemplates((latest) => ({
      exportTemplates: latest.map((template) => template.id === templateId
        ? applyEditorContentToTemplate({ ...template, name: validation.name }, exportOptions)
        : template),
    }));
    return null;
  };
  const saveTemplate = () => {
    if (!selected) return;
    const message = saveSelectedTemplate(selected.id, nameDraft);
    if (message) setEditorError(message);
  };

  const openSaveAs = () => {
    setDialogError(null);
    setDialogName(copyTemplateName(selected?.name ?? cleanTemplateName(nameDraft) ?? DEFAULT_TEMPLATE_NAME, templates));
    setDialog({ kind: "save-as" });
  };
  const confirmSaveAs = () => {
    const result = buildTemplateFromEditor(dialogName);
    if (!result.ok) {
      setDialogError(result.message);
      return;
    }
    commitTemplate(result.template);
    setDialog(null);
  };

  const requestDelete = (template: SavedExportTemplate) => {
    setDialogError(null);
    setDialog({ kind: "delete", templateId: template.id });
  };
  const confirmDelete = () => {
    if (dialog?.kind !== "delete") return;
    const deletedId = dialog.templateId;
    patchTemplates((latest) => {
      if (!latest.some((template) => template.id === deletedId)) return {};
      const remaining = latest.filter((template) => template.id !== deletedId);
      if (exportOptions.savedTemplateId !== deletedId) return { exportTemplates: remaining };
      // 删除当前模板后自动切换：next entry, else previous, else built-in.
      const fallback = templateAfterDelete(latest, deletedId);
      return {
        exportTemplates: remaining,
        export: fallback
          ? exportOptionsFromTemplate(fallback) as ExportOptions
          : exportOptionsForBuiltinTemplate() as ExportOptions,
      };
    });
    setDialog(null);
  };

  const copyBuiltinAsCustom = () => {
    commitTemplate(createExportTemplate({
      name: copyTemplateName("Resolve 21.1", templates),
      options: canonicalTemplateSource(exportOptions),
      templateId: "custom",
    }));
  };

  const importTemplate = async (file: File) => {
    if (disabled || importDisabled || importing) return;
    const generation = ++importGenerationRef.current;
    setImporting(true);
    setImportError(null);
    setImportStatus(null);
    try {
      if (!/\.csv$/i.test(file.name)) throw new Error("请选择 CSV 模板文件。");
      if (file.size > 5 * 1024 * 1024) throw new Error("CSV 模板不能超过 5 MB。");
      const data = await file.arrayBuffer();
      const result = await getCsvWorkerService().request<{ options: ExportOptions; sourceEncoding: string }>({ type: "import-export-template", data, filename: file.name }, [data]);
      // A late decode must never open the naming dialog for another template.
      if (generation !== importGenerationRef.current) return;
      setDialogError(null);
      // 建议名称取自样表文件名（去扩展名），并避免与现有模板重名。
      setDialogName(uniqueTemplateName(file.name.replace(/\.[^.]+$/, ""), templates));
      setDialog({ kind: "import", options: result.options, sourceEncoding: result.sourceEncoding });
    } catch (cause) {
      if (generation === importGenerationRef.current) setImportError(appErrorFromUnknown(cause).message);
    } finally {
      if (generation === importGenerationRef.current) setImporting(false);
    }
  };
  const confirmImport = () => {
    if (dialog?.kind !== "import") return;
    const validation = validateTemplateName(dialogName, templates);
    if (!validation.ok) {
      setDialogError(validation.message);
      return;
    }
    // Templates store schema only: the decoded options never carry rows.
    const template = createExportTemplate({ name: validation.name, options: dialog.options, templateId: "imported-csv-v1" });
    commitTemplate(template);
    setImportStatus(`已导入样表「${validation.name}」（${template.columns.length} 列）。保存项目设置后，该项目后续任务默认使用此模板。${dialog.sourceEncoding.startsWith("gb") ? "源样表为 GBK/GB18030，输出采用 UTF-8。" : ""}`);
    setDialog(null);
  };

  const dialogTitle = dialog?.kind === "delete"
    ? "删除模板？"
    : dialog?.kind === "switch"
      ? "切换模板？"
      : dialog?.kind === "import"
        ? "保存导入的 CSV 模板"
        : "另存为模板";
  const dialogDescription = dialog?.kind === "delete"
    ? "模板将从当前项目的模板库中移除。"
    : dialog?.kind === "switch"
      ? "当前模板编辑器有未保存的修改。"
      : dialog?.kind === "import"
        ? "只保留样表的列结构、顺序和格式，不保存样表数据行。"
        : "以新名称保存当前模板内容，原模板保持不变。";

  const switchTargetName = dialog?.kind === "switch"
    ? dialog.targetId ? findExportTemplate(templates, dialog.targetId)?.name ?? "" : BUILTIN_TEMPLATE_LABEL
    : "";
  const deleteTarget = dialog?.kind === "delete" ? findExportTemplate(templates, dialog.templateId) : null;
  const confirmSaveDialog = dialog?.kind === "import" ? confirmImport : confirmSaveAs;

  return <div className={styles.templateWorkbench}>
    <div className={styles.templateLibrary} aria-label="导出模板库">
      <div className={styles.templateLibraryActions}>
        <Button type="button" size="sm" disabled={disabled} onClick={() => createFromEditor(uniqueTemplateName(DEFAULT_TEMPLATE_NAME, templates))}>新建自定义模板</Button>
        <Button type="button" size="sm" variant="secondary" loading={importing} disabled={disabled || importDisabled} onClick={() => importInputRef.current?.click()}>导入 CSV</Button>
        <input ref={importInputRef} type="file" accept=".csv,text/csv" aria-label="导入 CSV 模板文件" hidden onChange={(event) => { const file = event.target.files?.[0]; event.target.value = ""; if (file) void importTemplate(file); }} />
      </div>
      <div className={styles.templateList} role="list">
        <div role="listitem">
          <button type="button" className={styles.templateEntry} data-active={builtinSelected || undefined} aria-current={builtinSelected || undefined} disabled={disabled} onClick={() => requestSwitch(null)}>
            <span className={styles.templateEntryName}>{BUILTIN_TEMPLATE_LABEL}</span>
            <Badge tone="neutral">只读</Badge>
          </button>
        </div>
        {unsavedSelected && <div role="listitem">
          <button type="button" className={styles.templateEntry} data-active="true" aria-current="true" disabled={true}>
            <span className={styles.templateEntryName}>{UNSAVED_TEMPLATE_LABEL}</span>
          </button>
        </div>}
        {templates.map((template) => <div role="listitem" key={template.id}>
          <button type="button" className={styles.templateEntry} data-active={selected?.id === template.id || undefined} aria-current={selected?.id === template.id || undefined} disabled={disabled} onClick={() => requestSwitch(template.id)}>
            <span className={styles.templateEntryName}>{template.name}</span>
            <span className={styles.templateEntryMeta}>{template.columns.filter((column) => column.enabled).length}/{template.columns.length} 列</span>
          </button>
        </div>)}
      </div>
      {importStatus && <p role="status" className={styles.templateLibraryStatus}>{importStatus}</p>}
      {importError && <InlineError message={importError} />}
    </div>
    <div className={styles.templateEditor}>
      <Stack direction="row" gap={2} align="center" justify="between" wrap>
        <Text as="h3" size="sm" weight="bold">
          {selected ? `当前模板 · ${selected.name}` : builtinSelected ? `当前模板 · ${BUILTIN_TEMPLATE_LABEL}` : `当前模板 · ${UNSAVED_TEMPLATE_LABEL}`}
        </Text>
        {selected && editorDirty && <Badge tone="warning">未保存修改</Badge>}
        {builtinSelected && <Badge tone="neutral">只读</Badge>}
      </Stack>
      {!builtinSelected && <Field label="模板名称" hint="只作为模板库中的显示名称，与导出文件名规则无关。" error={editorError ?? undefined}>
        <Input value={nameDraft} maxLength={80} disabled={disabled} onChange={(event) => { setNameDraft(event.target.value); setEditorError(null); }} />
      </Field>}
      {unsavedSelected && <Text size="sm" tone="muted">当前导出配置尚未保存为模板。填写名称后点击“保存为模板”；不保存也不会影响导出行为。</Text>}
      {selected && <Text size="sm" tone="muted">“保存模板”把编辑器当前内容写回「{selected.name}」；“另存为”创建副本；点击“保存项目设置”后所有修改才真正生效。</Text>}
      <ExportOptionsPanel
        options={exportOptions}
        onChange={patchExport}
        // The built-in must be copied before any editor field can change.
        disabled={disabled || builtinSelected}
        hideHeader
        hideTemplateSelect
      />
      <Stack direction="row" gap={2} wrap align="center">
        {builtinSelected && <Button type="button" size="sm" disabled={disabled} onClick={copyBuiltinAsCustom}>复制为自定义</Button>}
        {unsavedSelected && <Button type="button" size="sm" disabled={disabled} onClick={() => createFromEditor(nameDraft)}>保存为模板</Button>}
        {selected && <>
          <Button type="button" size="sm" disabled={disabled} onClick={saveTemplate}>保存模板</Button>
          <Button type="button" size="sm" variant="secondary" disabled={disabled} onClick={openSaveAs}>另存为</Button>
          <Button type="button" size="sm" variant="ghost" disabled={disabled} onClick={() => requestDelete(selected)}>删除模板</Button>
        </>}
      </Stack>
    </div>
    <Dialog open={dialog !== null} title={dialogTitle} description={dialogDescription} onClose={() => setDialog(null)} footer={<Stack direction="row" gap={2} justify="end">
      <Button type="button" variant="ghost" onClick={() => setDialog(null)}>取消</Button>
      {dialog?.kind === "switch" && <Button type="button" variant="secondary" onClick={() => performSwitch(dialog.targetId)}>放弃并切换</Button>}
      {dialog?.kind === "switch" && <Button type="button" onClick={() => {
        // 保存并切换：commit the source editor first, then load the target.
        // applyPatch always reads the freshest store state, so both writes land.
        if (selected) {
          const message = saveSelectedTemplate(selected.id, nameDraft);
          if (message) { setDialogError(message); return; }
          performSwitch(dialog.targetId);
          return;
        }
        // Unsaved source: preserve it as a new template before switching.
        if (createFromEditor(nameDraft)) {
          performSwitch(dialog.targetId);
          return;
        }
        setDialogError(validateTemplateName(nameDraft, templates).message || "模板名称无效。");
      }}>保存并切换</Button>}
      {dialog?.kind === "delete" && <Button type="button" variant="danger" onClick={confirmDelete}>删除模板</Button>}
      {(dialog?.kind === "save-as" || dialog?.kind === "import") && <Button type="button" onClick={() => confirmSaveDialog()}>保存模板</Button>}
    </Stack>}>
      {dialog?.kind === "switch" && <Stack direction="column" gap={3}>
        <Text size="sm">切换到「{switchTargetName}」后，编辑器将载入该模板已保存的内容。</Text>
        {dialogError && <InlineError message={dialogError} />}
      </Stack>}
      {dialog?.kind === "delete" && <Stack direction="column" gap={3}>
        <Text size="sm">删除「{deleteTarget?.name}」？</Text>
        {deleteTarget && exportOptions.savedTemplateId === deleteTarget.id && editorDirty && <Text size="sm" tone="warning">该模板是当前模板且有未保存的修改，删除后将一并丢弃。</Text>}
      </Stack>}
      {(dialog?.kind === "save-as" || dialog?.kind === "import") && <Field label="模板名称" error={dialogError ?? undefined}>
        <Input autoFocus value={dialogName} maxLength={80} onChange={(event) => { setDialogName(event.target.value); setDialogError(null); }} />
      </Field>}
    </Dialog>
  </div>;
}

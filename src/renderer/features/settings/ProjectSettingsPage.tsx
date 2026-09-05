import { AlertTriangle, ArrowLeft, Check, Import, PackageOpen, RotateCcw, Save, SlidersHorizontal, Trash2 } from "lucide-react";
import { useEffect, useMemo, useState } from "react";
import type { ProjectSettings } from "../../../shared/contracts/index.js";
import { Button, Dialog, Field, InlineError, Input, Select, Separator, Stack, Surface, Text, Textarea } from "../../design-system";
import { appErrorFromUnknown, getSlateSync, unwrap } from "../../services/api";
import { useProjectStore, useRecognitionStore, useSettingsStore, useTaskStore, useUiStore } from "../../state";
import { saveProjectSettingsChanges } from "./projectSettingsActions";
import { useProviderModels } from "../recognition/useProviderModels";
import { acquireWorkspaceOperation, isWorkspaceBusy } from "../../services/workspace-operation";
import { ModelSelect } from "../recognition/ModelSelect";
import { groupModelOptions } from "../recognition/model-options";
import styles from "../../app/app.module.css";
import { validateProjectName } from "../../validation/input-validation";

function settingsDefaults(config: ReturnType<typeof useProjectStore.getState>["config"]): ProjectSettings {
  return { version: 1, providerId: null, modelId: null, accuracyMode: "high", scenarioId: null, customPrompt: "", resolve: { fieldFormats: config?.workflow.resolve.fieldFormats || { scene: "XXX", shot: "XX", take: "XX" }, comments: config?.workflow.resolve.comments || { goodTake: "_OK", holdTake: "_KP" } } };
}

export function ProjectSettingsPage({ onBack, onDeleted, onPrepareTransfer, onProjectImported }: { onBack: () => void; onDeleted: (projectId: string) => void; onPrepareTransfer?: () => Promise<boolean>; onProjectImported?: (projectId: string) => void | boolean | Promise<void | boolean> }) {
  const project = useProjectStore((state) => state.current);
  const config = useProjectStore((state) => state.config);
  const scenarios = useProjectStore((state) => state.scenarios);
  const setProjects = useProjectStore((state) => state.setProjects);
  const setScenarios = useProjectStore((state) => state.setScenarios);
  const setToast = useUiStore((state) => state.setToast);
  const projectDraft = useSettingsStore((state) => state.draft);
  const draftProjectId = useSettingsStore((state) => state.projectId);
  const settingsDirty = useSettingsStore((state) => state.dirty);
  const saving = useSettingsStore((state) => state.saving);
  const saveError = useSettingsStore((state) => state.saveError);
  const patchProject = useSettingsStore((state) => state.patchProject);
  const currentDraft = draftProjectId === project?.id ? projectDraft : null;
  const name = currentDraft?.name ?? project?.name ?? "";
  const description = currentDraft?.description ?? project?.description ?? "";
  const settings = currentDraft?.settings ?? project?.settings ?? settingsDefaults(config);
  const { models } = useProviderModels(settings.providerId || "");
  const [deleting, setDeleting] = useState(false);
  const [deleteStep, setDeleteStep] = useState<0 | 1 | 2>(0);
  const [deleteConfirmation, setDeleteConfirmation] = useState("");
  const [error, setError] = useState<string | null>(null);
  const [transferBusy, setTransferBusy] = useState<"import" | "export" | null>(null);
  const [deleteError, setDeleteError] = useState<string | null>(null);
  const workspaceOperation = useTaskStore((state) => state.operation);
  const running = useRecognitionStore((state) => state.running);
  // Mirror the global operation lease in the visible controls; the handler
  // still rechecks synchronously to cover an operation starting between frames.
  const workspaceBusy = running || Boolean(workspaceOperation);
  const recognitionRunning = running || workspaceOperation?.kind === "recognition";
  const workspaceBusyMessage = recognitionRunning
    ? "识别完成或停止后，才能导入或导出项目。"
    : "当前任务处理完成后，才能导入或导出项目。";

  useEffect(() => {
    if (!project) return;
    useSettingsStore.getState().hydrateProject(project.id, {
      name: project.name, description: project.description, settings: project.settings || settingsDefaults(config),
    });
    let active = true;
    void (async () => {
      try {
        const nextScenarios = await unwrap(await getSlateSync().projects.listScenarios({ projectId: project.id }));
        if (active) setScenarios(nextScenarios);
      } catch {
        if (active) setScenarios([]);
      }
    })();
    return () => { active = false; };
  }, [config, project, setScenarios]);

  const availableProviders = config?.providers || [];
  const selectedProvider = availableProviders.find((item) => item.id === settings.providerId);
  const modelOptions = useMemo(() => {
    const candidates = models;
    return candidates.filter((model) => !model.capabilityStatus || ["declared", "inferred", "verified"].includes(model.capabilityStatus));
  }, [config?.models, models, settings.providerId]);
  const modelGroups = useMemo(() => groupModelOptions(settings.providerId || "", modelOptions), [modelOptions, settings.providerId]);

  useEffect(() => {
    const onBeforeUnload = (event: BeforeUnloadEvent) => {
      const state = useSettingsStore.getState();
      if (!state.dirty && !state.saving) return;
      event.preventDefault();
      event.returnValue = "";
    };
    window.addEventListener("beforeunload", onBeforeUnload);
    return () => window.removeEventListener("beforeunload", onBeforeUnload);
  }, []);

  if (!project) return <div className={styles.page}><InlineError message="尚未选择项目。" onRetry={onBack} /></div>;

  const updateSettings = (patch: Partial<ProjectSettings>) => patchProject({ settings: { ...settings, ...patch } });
  const updateResolveField = (field: keyof ProjectSettings["resolve"]["fieldFormats"], value: string) =>
    updateSettings({ resolve: { ...settings.resolve, fieldFormats: { ...settings.resolve.fieldFormats, [field]: value } } });
  const updateResolveComment = (field: keyof ProjectSettings["resolve"]["comments"], value: string) =>
    updateSettings({ resolve: { ...settings.resolve, comments: { ...settings.resolve.comments, [field]: value } } });
  const save = async (event: React.FormEvent<HTMLFormElement>) => {
    event.preventDefault();
    if (!(await saveProjectSettingsChanges()) && !validateProjectName(useSettingsStore.getState().draft?.name || "").ok) {
      document.getElementById("project-settings-name")?.focus();
    }
  };
  const resetOutput = () => updateSettings({ resolve: settingsDefaults(config).resolve });
  const closeDeleteDialogs = () => {
    if (deleting) return;
    setDeleteStep(0);
    setDeleteConfirmation("");
    setDeleteError(null);
  };
  const deleteProject = async () => {
    if (deleteConfirmation !== project.name || deleting || saving) return;
    const lease = acquireWorkspaceOperation("delete", project.id);
    if (!lease) return;
    setDeleting(true);
    setDeleteError(null);
    try {
      const result = await unwrap(await getSlateSync().projects.delete({ id: project.id }));
      setToast({ tone: "success", message: "项目已删除" });
      onDeleted(result.deleted);
    } catch (nextError) {
      setDeleteError(appErrorFromUnknown(nextError).message);
    } finally {
      lease.release();
      setDeleting(false);
    }
  };
  const readOnly = Boolean(project.archivedAt);
  const packageBusy = Boolean(transferBusy) || saving || deleting;
  const settingsDisabled = readOnly || packageBusy;
  const transferProject = async (operation: "import" | "export") => {
    if (packageBusy || transferBusy) return;
    if (isWorkspaceBusy()) {
      setError(workspaceBusyMessage);
      return;
    }
    if (settingsDirty) {
      setError("请先保存项目设置，再进行项目包导入或导出。");
      return;
    }
    setTransferBusy(operation);
    setError(null);
    let shouldReturnToLibrary = false;
    try {
      // 项目设置是项目包操作的唯一入口；开始文件选择前仍沿用工作台自动保存闸门。
      if (onPrepareTransfer && !(await onPrepareTransfer())) return;
      const api = getSlateSync();
      if (operation === "import") {
        const result = await unwrap(await api.projects.importProject());
        if (result.canceled) return;
        // The package commit is already complete at this point. Keep the new
        // row locally when a follow-up list refresh is unavailable so retrying
        // the same package cannot create a duplicate project.
        shouldReturnToLibrary = true;
        try {
          setProjects(await unwrap(await api.projects.list()));
          setToast({ tone: "success", message: `项目已导入：${result.project.name}` });
        } catch {
          const currentProjects = useProjectStore.getState().projects.filter((item) => item.id !== result.project.id);
          setProjects([...currentProjects, result.project]);
          setToast({ tone: "warning", message: `项目已导入：${result.project.name}；列表刷新失败，请稍后刷新项目库。` });
        }
      } else {
        const result = await unwrap(await api.projects.exportProject({ id: project.id }));
        if (result.canceled) return;
        setToast({ tone: "success", message: `项目已导出：${result.path}` });
      }
    } catch (nextError) {
      setError(appErrorFromUnknown(nextError).message);
    } finally {
      setTransferBusy(null);
    }
    if (shouldReturnToLibrary) {
      // 等待本页忙碌态恢复后再切路由，避免在卸载中的设置页继续写本地状态。
      try { await onProjectImported?.(project.id); } catch (nextError) { setError(appErrorFromUnknown(nextError).message); }
    }
  };
  const formError = saveError || error;
  const nameError = formError === "请输入项目名称。" ? formError : undefined;
  const staleProvider = Boolean(settings.providerId && !availableProviders.some((provider) => provider.id === settings.providerId));
  // A remembered model is stale even when discovery returned no selectable
  // entries; pending/failed custom models must not be submitted silently.
  const staleModel = Boolean(settings.modelId && !modelOptions.some((model) => model.id === settings.modelId));

  return <div className={styles.page}><div className={styles.pageHeader}><div><Button variant="ghost" size="sm" onClick={onBack} startIcon={<ArrowLeft size={15} />}>返回工作台</Button><p className={styles.eyebrow} style={{ marginTop: 18 }}>项目设置</p><h1 className={styles.heading}>{project.name}</h1><p className={styles.subtitle}>设置默认识别方式和输出格式。</p></div><div className={styles.pageActions}>{readOnly && <Text tone="warning" size="sm">已归档 · 只读</Text>}<Button type="submit" form="project-settings-form" disabled={settingsDisabled} loading={saving} startIcon={<Save size={15} />}>保存设置</Button></div></div>
    {formError && !nameError && <div style={{ marginBottom: 16 }}><InlineError message={formError} /></div>}
    {staleProvider && <div style={{ marginBottom: 16 }}><InlineError message="已保存的 Provider 已被删除，请重新选择接口。" /></div>}
    {staleModel && <div style={{ marginBottom: 16 }}><InlineError message="已保存的模型当前不可用或探针已失效，请重新选择。" /></div>}
    <form id="project-settings-form" noValidate onSubmit={save} className={styles.grid}>
      <Surface className={styles.panel}><div className={styles.sectionHeader}><div><p className={styles.kicker}>项目资料</p><h2 className={styles.sectionTitle}>名称与描述</h2></div><SlidersHorizontal size={18} /></div><div className={styles.formGrid}><div className={styles.formField}><Field label="项目名称" htmlFor="project-settings-name" error={nameError}><Input id="project-settings-name" value={name} onChange={(event) => { patchProject({ name: event.target.value }); if (nameError) setError(null); }} onBlur={() => { const result = validateProjectName(name); if (!result.ok) setError(result.message); }} disabled={settingsDisabled} /></Field></div><div className={styles.formField}><Field label="描述"><Input value={description} onChange={(event) => { patchProject({ description: event.target.value }); }} disabled={settingsDisabled} /></Field></div></div></Surface>
      <Surface className={styles.panel}><div className={styles.sectionHeader}><div><p className={styles.kicker}>识别默认值</p><h2 className={styles.sectionTitle}>识别设置</h2></div></div><div className={styles.formGrid}><div className={styles.formField}><Field label="Provider"><Select value={settings.providerId || ""} onChange={(event) => { updateSettings({ providerId: event.target.value || null, modelId: null }); }} disabled={settingsDisabled}><option value="">跟随当前设备</option>{staleProvider && <option value={settings.providerId || ""}>{settings.providerId} · 接口已移除</option>}{availableProviders.map((provider) => <option key={provider.id} value={provider.id}>{provider.label}{provider.configured ? " · 已配置" : " · 未配置"}</option>)}</Select></Field></div><div className={styles.formField}><Field label="模型" hint={selectedProvider?.configured ? undefined : "Provider 未配置时会在识别前提示。"}><ModelSelect key={settings.providerId} value={settings.modelId || ""} groups={modelGroups} onChange={(modelId) => updateSettings({ modelId: modelId || null })} disabled={settingsDisabled} placeholder="自动选择" /></Field></div><div className={styles.formField}><Field label="准确度"><Select value={settings.accuracyMode} onChange={(event) => updateSettings({ accuracyMode: event.target.value as ProjectSettings["accuracyMode"] })} disabled={settingsDisabled}><option value="high">精确 · 主识别 + 查漏</option><option value="standard">快速 · 单次主识别</option></Select></Field></div><div className={styles.formField}><Field label="场记结构"><Select value={settings.scenarioId || ""} onChange={(event) => updateSettings({ scenarioId: event.target.value || null })} disabled={settingsDisabled}><option value="">自动识别并学习</option>{scenarios.map((scenario) => <option key={scenario.id} value={scenario.id}>{scenario.label} · {scenario.sampleCount} 次</option>)}</Select></Field></div><div className={`${styles.formField} ${styles.formFieldFull}`}><Field label="识别提示" hint="可选，用于补充项目约定。"><Textarea className="resize-none" value={settings.customPrompt} onChange={(event) => updateSettings({ customPrompt: event.target.value })} maxLength={2000} showCount disabled={settingsDisabled} placeholder="例如：本片使用繁体字；A 机为主机。" /></Field></div></div></Surface>
      <Surface className={styles.panel}><div className={styles.sectionHeader}><div><p className={styles.kicker}>Resolve 输出</p><h2 className={styles.sectionTitle}>字段格式与条次标记</h2></div><Button type="button" variant="ghost" size="sm" onClick={resetOutput} disabled={settingsDisabled} startIcon={<RotateCcw size={14} />}>恢复默认</Button></div><Text tone="muted" size="sm">X 表示最小位数，更多位数会保留。</Text><Separator style={{ margin: "16px 0" }} /><div className={styles.formGrid}><Field label="Scene"><Input value={settings.resolve.fieldFormats.scene} onChange={(event) => updateResolveField("scene", event.target.value)} disabled={settingsDisabled} /></Field><Field label="Shot"><Input value={settings.resolve.fieldFormats.shot} onChange={(event) => updateResolveField("shot", event.target.value)} disabled={settingsDisabled} /></Field><Field label="Take"><Input value={settings.resolve.fieldFormats.take} onChange={(event) => updateResolveField("take", event.target.value)} disabled={settingsDisabled} /></Field><Field label="过条标记"><Input value={settings.resolve.comments.goodTake} onChange={(event) => updateResolveComment("goodTake", event.target.value)} disabled={settingsDisabled} /></Field><Field label="保条标记"><Input value={settings.resolve.comments.holdTake} onChange={(event) => updateResolveComment("holdTake", event.target.value)} disabled={settingsDisabled} /></Field></div></Surface>
      <div className={styles.formActions}><Button type="submit" disabled={settingsDisabled} loading={saving} startIcon={<Check size={16} />}>保存项目设置</Button></div>
    </form>
    <Surface className={styles.panel} style={{ marginTop: 20 }}>
      <div className={styles.sectionHeader}><div><p className={styles.kicker}>项目包</p><h2 className={styles.sectionTitle}>导入与导出</h2></div><PackageOpen size={18} aria-hidden="true" /></div>
      <Text tone="muted" size="sm">将当前项目保存为目录包，或从目录包创建新的项目副本。导入不会覆盖当前项目。</Text>
      {settingsDirty && <Text tone="warning" size="xs" style={{ marginTop: 8 }}>请先保存项目设置；未保存的修改不会随项目包传输。</Text>}
      {workspaceBusy && <Text tone="warning" size="xs" style={{ marginTop: 8 }}>{workspaceBusyMessage}</Text>}
      <Stack direction="row" gap={2} wrap align="center" style={{ marginTop: 16 }}>
        <Button type="button" variant="secondary" onClick={() => void transferProject("import")} loading={transferBusy === "import"} disabled={packageBusy || settingsDirty || workspaceBusy} startIcon={<Import size={15} />}>导入项目</Button>
        <Button type="button" variant="secondary" onClick={() => void transferProject("export")} loading={transferBusy === "export"} disabled={packageBusy || settingsDirty || workspaceBusy} startIcon={<PackageOpen size={15} />}>导出项目</Button>
      </Stack>
    </Surface>
    <Surface className={`${styles.panel} ${styles.dangerZone}`} style={{ marginTop: 20 }}>
      <div><p className={styles.kicker}>危险操作</p><h2 className={styles.sectionTitle}>删除项目</h2><Text tone="muted" size="sm">永久删除项目及其中的任务和识别结果。</Text></div>
      <Button variant="danger" onClick={() => { setDeleteError(null); setDeleteStep(1); }} disabled={!project.canArchive || Boolean(workspaceOperation) || recognitionRunning || packageBusy} startIcon={<Trash2 size={15} />}>删除项目</Button>
      {!project.canArchive && <Text tone="subtle" size="xs">默认项目不能删除。</Text>}
      {recognitionRunning && <Text tone="warning" size="xs">识别完成或停止后才能删除。</Text>}
    </Surface>
    <Dialog open={deleteStep === 1} title="删除项目？" description="项目中的任务、场记和识别结果都会永久删除。" onClose={closeDeleteDialogs} footer={<Stack direction="row" gap={2} justify="end"><Button variant="ghost" onClick={closeDeleteDialogs}>取消</Button><Button variant="danger" onClick={() => setDeleteStep(2)}>继续确认</Button></Stack>}>
      <Stack direction="row" gap={2} align="center"><AlertTriangle size={18} aria-hidden="true" /><Text tone="danger" size="sm">此操作不可撤销。</Text></Stack>
    </Dialog>
    <Dialog dismissible={!deleting} open={deleteStep === 2} title="再次确认删除" description={`输入“${project.name}”以确认。`} onClose={closeDeleteDialogs} footer={<Stack direction="row" gap={2} justify="end"><Button variant="ghost" onClick={closeDeleteDialogs} disabled={deleting}>取消</Button><Button variant="danger" onClick={() => void deleteProject()} disabled={deleteConfirmation !== project.name} loading={deleting}>永久删除</Button></Stack>}>
      {deleteError && <InlineError message={deleteError} />}
      <Field label="项目名称"><Input disabled={deleting} autoFocus value={deleteConfirmation} onChange={(event) => setDeleteConfirmation(event.target.value)} autoComplete="off" /></Field>
    </Dialog>
  </div>;
}

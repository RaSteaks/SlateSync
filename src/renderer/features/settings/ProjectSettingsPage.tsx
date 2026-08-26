import { AlertTriangle, ArrowLeft, Check, RotateCcw, Save, SlidersHorizontal, Trash2 } from "lucide-react";
import { useCallback, useEffect, useMemo, useState } from "react";
import type { ProjectSettings } from "../../../shared/contracts/index.js";
import { Button, Dialog, Field, InlineError, Input, Select, Separator, Stack, Surface, Text, Textarea } from "../../design-system";
import { appErrorFromUnknown, getSlateSync, unwrap } from "../../services/api";
import { useProjectStore, useRecognitionStore, useUiStore } from "../../state";
import { ModelSelect } from "../recognition/ModelSelect";
import { groupModelOptions } from "../recognition/model-options";
import styles from "../../app/app.module.css";
import { validateProjectName } from "../../validation/input-validation";

function settingsDefaults(config: ReturnType<typeof useProjectStore.getState>["config"]): ProjectSettings {
  return { version: 1, providerId: null, modelId: null, accuracyMode: "high", scenarioId: null, customPrompt: "", resolve: { fieldFormats: config?.workflow.resolve.fieldFormats || { scene: "XXX", shot: "XX", take: "XX" }, comments: config?.workflow.resolve.comments || { goodTake: "_OK", holdTake: "_KP" } } };
}

export function ProjectSettingsPage({ onBack, onDeleted }: { onBack: () => void; onDeleted: (projectId: string) => void }) {
  const project = useProjectStore((state) => state.current);
  const config = useProjectStore((state) => state.config);
  const scenarios = useProjectStore((state) => state.scenarios);
  const setCurrent = useProjectStore((state) => state.setCurrent);
  const setProjects = useProjectStore((state) => state.setProjects);
  const projects = useProjectStore((state) => state.projects);
  const setScenarios = useProjectStore((state) => state.setScenarios);
  const setToast = useUiStore((state) => state.setToast);
  const [name, setName] = useState("");
  const [description, setDescription] = useState("");
  const [settings, setSettings] = useState<ProjectSettings>(() => settingsDefaults(config));
  const [models, setModels] = useState<readonly import("../../../shared/contracts/index.js").ModelData[]>([]);
  const [saving, setSaving] = useState(false);
  const [deleting, setDeleting] = useState(false);
  const [deleteStep, setDeleteStep] = useState<0 | 1 | 2>(0);
  const [deleteConfirmation, setDeleteConfirmation] = useState("");
  const [error, setError] = useState<string | null>(null);
  const recognitionRunning = useRecognitionStore((state) => state.running);

  useEffect(() => {
    if (!project) return;
    setName(project.name);
    setDescription(project.description);
    setSettings(project.settings || settingsDefaults(config));
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
  const modelOptions = useMemo(() => models.length ? models : config?.models.filter((model) => model.providers.includes(settings.providerId || "")) || [], [config?.models, models, settings.providerId]);
  const modelGroups = useMemo(() => groupModelOptions(settings.providerId || "", modelOptions), [modelOptions, settings.providerId]);

  // Keep these hooks before the no-project branch so project restoration never
  // changes the Hook order between renders.
  const loadModels = useCallback(async (providerId: string) => {
    setModels([]);
    if (!providerId) return;
    try { setModels((await unwrap(await getSlateSync().recognition.getModels({ providerId, forceRefresh: false }))).models); } catch { /* static config remains available */ }
  }, []);
  useEffect(() => {
    // Load the initially saved provider as well as providers selected manually;
    // otherwise an OpenRouter project would only show its static fallback until
    // the user toggled the Provider field.
    void loadModels(settings.providerId || "");
  }, [loadModels, settings.providerId]);

  if (!project) return <div className={styles.page}><InlineError message="尚未选择项目。" onRetry={onBack} /></div>;

  const updateSettings = (patch: Partial<ProjectSettings>) => setSettings((current) => ({ ...current, ...patch }));
  const save = async (event: React.FormEvent<HTMLFormElement>) => {
    event.preventDefault();
    const validation = validateProjectName(name);
    if (!validation.ok) { setError(validation.message); return; }
    setSaving(true); setError(null);
    try {
      const updated = await unwrap(await getSlateSync().projects.update({ id: project.id, name: name.trim(), description: description.trim(), settings }));
      setCurrent(updated);
      setProjects(useProjectStore.getState().projects.map((item) => item.id === updated.id ? updated : item));
      setToast({ tone: "success", message: "项目设置已保存" });
    } catch (nextError) { setError(appErrorFromUnknown(nextError).message); }
    finally { setSaving(false); }
  };
  const resetOutput = () => setSettings((current) => ({ ...current, resolve: settingsDefaults(config).resolve }));
  const closeDeleteDialogs = () => {
    if (deleting) return;
    setDeleteStep(0);
    setDeleteConfirmation("");
  };
  const deleteProject = async () => {
    if (deleteConfirmation !== project.name || deleting || recognitionRunning) return;
    setDeleting(true);
    setError(null);
    try {
      const result = await unwrap(await getSlateSync().projects.delete({ id: project.id }));
      setToast({ tone: "success", message: "项目已删除" });
      onDeleted(result.deleted);
    } catch (nextError) {
      setError(appErrorFromUnknown(nextError).message);
      setDeleteStep(0);
    } finally {
      setDeleting(false);
    }
  };
  const readOnly = Boolean(project.archivedAt);
  const nameError = error === "请输入项目名称。" ? error : undefined;

  return <div className={styles.page}><div className={styles.pageHeader}><div><Button variant="ghost" size="sm" onClick={onBack} startIcon={<ArrowLeft size={15} />}>返回工作台</Button><p className={styles.eyebrow} style={{ marginTop: 18 }}>项目设置</p><h1 className={styles.heading}>{project.name}</h1><p className={styles.subtitle}>设置默认识别方式和输出格式。</p></div><div className={styles.pageActions}>{readOnly && <Text tone="warning" size="sm">已归档 · 只读</Text>}<Button type="submit" form="project-settings-form" disabled={readOnly} loading={saving} startIcon={<Save size={15} />}>保存设置</Button></div></div>
    {error && !nameError && <div style={{ marginBottom: 16 }}><InlineError message={error} /></div>}
    <form id="project-settings-form" noValidate onSubmit={save} className={styles.grid}>
      <Surface className={styles.panel}><div className={styles.sectionHeader}><div><p className={styles.kicker}>项目资料</p><h2 className={styles.sectionTitle}>名称与描述</h2></div><SlidersHorizontal size={18} /></div><div className={styles.formGrid}><div className={styles.formField}><Field label="项目名称" error={nameError}><Input value={name} onChange={(event) => { setName(event.target.value); if (nameError) setError(null); }} onBlur={() => { const result = validateProjectName(name); if (!result.ok) setError(result.message); }} disabled={readOnly} /></Field></div><div className={styles.formField}><Field label="描述"><Input value={description} onChange={(event) => setDescription(event.target.value)} disabled={readOnly} /></Field></div></div></Surface>
      <Surface className={styles.panel}><div className={styles.sectionHeader}><div><p className={styles.kicker}>识别默认值</p><h2 className={styles.sectionTitle}>识别设置</h2></div></div><div className={styles.formGrid}><div className={styles.formField}><Field label="Provider"><Select value={settings.providerId || ""} onChange={(event) => { updateSettings({ providerId: event.target.value || null, modelId: null }); }} disabled={readOnly}><option value="">跟随当前设备</option>{availableProviders.map((provider) => <option key={provider.id} value={provider.id}>{provider.label}{provider.configured ? " · 已配置" : " · 未配置"}</option>)}</Select></Field></div><div className={styles.formField}><Field label="模型" hint={selectedProvider?.configured ? undefined : "Provider 未配置时会在识别前提示。"}><ModelSelect value={settings.modelId || ""} groups={modelGroups} onChange={(modelId) => updateSettings({ modelId: modelId || null })} disabled={readOnly} placeholder="自动选择" /></Field></div><div className={styles.formField}><Field label="准确度"><Select value={settings.accuracyMode} onChange={(event) => updateSettings({ accuracyMode: event.target.value as ProjectSettings["accuracyMode"] })} disabled={readOnly}><option value="high">精确 · 主识别 + 查漏</option><option value="standard">快速 · 单次主识别</option></Select></Field></div><div className={styles.formField}><Field label="场记结构"><Select value={settings.scenarioId || ""} onChange={(event) => updateSettings({ scenarioId: event.target.value || null })} disabled={readOnly}><option value="">自动识别并学习</option>{scenarios.map((scenario) => <option key={scenario.id} value={scenario.id}>{scenario.label} · {scenario.sampleCount} 次</option>)}</Select></Field></div><div className={`${styles.formField} ${styles.formFieldFull}`}><Field label="识别提示" hint="可选，用于补充项目约定。"><Textarea className="resize-none" value={settings.customPrompt} onChange={(event) => updateSettings({ customPrompt: event.target.value })} maxLength={2000} showCount disabled={readOnly} placeholder="例如：本片使用繁体字；A 机为主机。" /></Field></div></div></Surface>
      <Surface className={styles.panel}><div className={styles.sectionHeader}><div><p className={styles.kicker}>Resolve 输出</p><h2 className={styles.sectionTitle}>字段格式与条次标记</h2></div><Button type="button" variant="ghost" size="sm" onClick={resetOutput} disabled={readOnly} startIcon={<RotateCcw size={14} />}>恢复默认</Button></div><Text tone="muted" size="sm">X 表示最小位数，更多位数会保留。</Text><Separator style={{ margin: "16px 0" }} /><div className={styles.formGrid}><Field label="Scene"><Input value={settings.resolve.fieldFormats.scene} onChange={(event) => setSettings((current) => ({ ...current, resolve: { ...current.resolve, fieldFormats: { ...current.resolve.fieldFormats, scene: event.target.value } } }))} disabled={readOnly} /></Field><Field label="Shot"><Input value={settings.resolve.fieldFormats.shot} onChange={(event) => setSettings((current) => ({ ...current, resolve: { ...current.resolve, fieldFormats: { ...current.resolve.fieldFormats, shot: event.target.value } } }))} disabled={readOnly} /></Field><Field label="Take"><Input value={settings.resolve.fieldFormats.take} onChange={(event) => setSettings((current) => ({ ...current, resolve: { ...current.resolve, fieldFormats: { ...current.resolve.fieldFormats, take: event.target.value } } }))} disabled={readOnly} /></Field><Field label="过条标记"><Input value={settings.resolve.comments.goodTake} onChange={(event) => setSettings((current) => ({ ...current, resolve: { ...current.resolve, comments: { ...current.resolve.comments, goodTake: event.target.value } } }))} disabled={readOnly} /></Field><Field label="保条标记"><Input value={settings.resolve.comments.holdTake} onChange={(event) => setSettings((current) => ({ ...current, resolve: { ...current.resolve, comments: { ...current.resolve.comments, holdTake: event.target.value } } }))} disabled={readOnly} /></Field></div></Surface>
      <div className={styles.formActions}><Button type="submit" disabled={readOnly} loading={saving} startIcon={<Check size={16} />}>保存项目设置</Button></div>
    </form>
    <Surface className={`${styles.panel} ${styles.dangerZone}`} style={{ marginTop: 20 }}>
      <div><p className={styles.kicker}>危险操作</p><h2 className={styles.sectionTitle}>删除项目</h2><Text tone="muted" size="sm">永久删除项目及其中的任务和识别结果。</Text></div>
      <Button variant="danger" onClick={() => setDeleteStep(1)} disabled={!project.canArchive || recognitionRunning} startIcon={<Trash2 size={15} />}>删除项目</Button>
      {!project.canArchive && <Text tone="subtle" size="xs">默认项目不能删除。</Text>}
      {recognitionRunning && <Text tone="warning" size="xs">识别完成或停止后才能删除。</Text>}
    </Surface>
    <Dialog open={deleteStep === 1} title="删除项目？" description="项目中的任务、场记和识别结果都会永久删除。" onClose={closeDeleteDialogs} footer={<Stack direction="row" gap={2} justify="end"><Button variant="ghost" onClick={closeDeleteDialogs}>取消</Button><Button variant="danger" onClick={() => setDeleteStep(2)}>继续确认</Button></Stack>}>
      <Stack direction="row" gap={2} align="center"><AlertTriangle size={18} aria-hidden="true" /><Text tone="danger" size="sm">此操作不可撤销。</Text></Stack>
    </Dialog>
    <Dialog open={deleteStep === 2} title="再次确认删除" description={`输入“${project.name}”以确认。`} onClose={closeDeleteDialogs} footer={<Stack direction="row" gap={2} justify="end"><Button variant="ghost" onClick={closeDeleteDialogs} disabled={deleting}>取消</Button><Button variant="danger" onClick={() => void deleteProject()} disabled={deleteConfirmation !== project.name} loading={deleting}>永久删除</Button></Stack>}>
      <Field label="项目名称"><Input autoFocus value={deleteConfirmation} onChange={(event) => setDeleteConfirmation(event.target.value)} autoComplete="off" /></Field>
    </Dialog>
  </div>;
}

import { Archive, ArchiveRestore, FolderKanban, Plus, RefreshCw, Settings2 } from "lucide-react";
import { useEffect, useMemo, useState } from "react";
import { Button, Dialog, EmptyState, Field, Icon, IconButton, InlineError, Input, Stack, Surface, Text } from "../../design-system";
import { appErrorFromUnknown, getSlateSync, unwrap } from "../../services/api";
import { createOperationGuard } from "../../services/operation-guard";
import { useProjectStore, useUiStore } from "../../state";
import styles from "../../app/app.module.css";
import { validateProjectName } from "../../validation/input-validation";

function formatDate(value: string | null) {
  if (!value) return "暂无任务";
  return new Intl.DateTimeFormat("zh-CN", { month: "short", day: "numeric", hour: "2-digit", minute: "2-digit" }).format(new Date(value));
}

export function ProjectLibraryPage({ onOpenProject, onOpenLibrarySettings }: { onOpenProject: (id: string, route?: "workspace" | "project-settings") => void; onOpenLibrarySettings: () => void }) {
  const projects = useProjectStore((state) => state.projects);
  const current = useProjectStore((state) => state.current);
  const loading = useProjectStore((state) => state.loading);
  const error = useProjectStore((state) => state.error);
  const setLoading = useProjectStore((state) => state.setLoading);
  const setError = useProjectStore((state) => state.setError);
  const setLibrary = useProjectStore((state) => state.setLibrary);
  const setProjects = useProjectStore((state) => state.setProjects);
  const setDialog = useUiStore((state) => state.setDialog);
  const setToast = useUiStore((state) => state.setToast);
  const dialog = useUiStore((state) => state.dialog);
  const [name, setName] = useState("");
  const [description, setDescription] = useState("");
  const [nameError, setNameError] = useState<string | null>(null);
  const [actionBusy, setActionBusy] = useState<string | null>(null);
  const refreshGuard = useMemo(() => createOperationGuard(), []);

  const refresh = async () => {
    const operationId = refreshGuard.start();
    setLoading(true);
    setError(null);
    try {
      const api = getSlateSync();
      const [libraryInfo, projectList] = await Promise.all([unwrap(await api.projects.getLibraryInfo()), unwrap(await api.projects.list())]);
      if (!refreshGuard.isCurrent(operationId)) return false;
      setLibrary(libraryInfo);
      setProjects(projectList);
      return true;
    } catch (nextError) {
      if (refreshGuard.isCurrent(operationId)) setError(appErrorFromUnknown(nextError));
      return false;
    } finally {
      if (refreshGuard.isCurrent(operationId)) setLoading(false);
    }
  };

  useEffect(() => {
    void refresh();
    return () => refreshGuard.invalidate();
  }, [refreshGuard]);

  const createProject = async (event: React.FormEvent<HTMLFormElement>) => {
    event.preventDefault();
    const validation = validateProjectName(name);
    if (!validation.ok) { setNameError(validation.message); return; }
    setActionBusy("create");
    try {
      const project = await unwrap(await getSlateSync().projects.create({ name: name.trim(), description: description.trim() }));
      setProjects([...useProjectStore.getState().projects, project]);
      setDialog(null);
      setName("");
      setDescription("");
      setNameError(null);
      onOpenProject(project.id, "workspace");
    } catch (nextError) {
      setError(appErrorFromUnknown(nextError));
    } finally {
      setActionBusy(null);
    }
  };

  const archive = async (projectId: string, archived: boolean) => {
    if (actionBusy) return;
    setActionBusy(`archive:${projectId}`);
    try {
      const result = archived
        ? await unwrap(await getSlateSync().projects.restore({ id: projectId }))
        : await unwrap(await getSlateSync().projects.archive({ id: projectId }));
      setProjects(useProjectStore.getState().projects.map((project) => project.id === result.id ? result : project));
      setToast({ tone: "success", message: archived ? "项目已恢复" : "项目已归档" });
    } catch (nextError) {
      setError(appErrorFromUnknown(nextError));
    } finally {
      setActionBusy(null);
    }
  };

  const active = projects.filter((project) => !project.archivedAt);
  const archived = projects.filter((project) => project.archivedAt);

  return <div className={styles.page}>
    <div className={styles.pageHeader}>
      <div><p className={styles.eyebrow}>本地项目</p><h1 className={styles.heading}>项目库</h1><p className={styles.subtitle}>管理本地项目和项目库；项目包操作位于项目设置。</p></div>
      <div className={styles.pageActions}><Button variant="ghost" size="sm" onClick={onOpenLibrarySettings} disabled={Boolean(actionBusy)} startIcon={<Settings2 size={15} />}>项目库设置</Button><Button variant="ghost" size="sm" onClick={() => void refresh()} loading={loading} disabled={Boolean(actionBusy)} startIcon={<RefreshCw size={15} />}>刷新</Button><Button size="lg" onClick={() => setDialog("new-project")} disabled={Boolean(actionBusy)} startIcon={<Plus size={17} />}>新建项目</Button></div>
    </div>
    {error && <div style={{ marginBottom: 16 }}><InlineError message={error.message} onRetry={() => void refresh()} /></div>}
    <div className={`${styles.grid} ${styles.gridTwo}`} style={{ marginBottom: 20 }}>
      <Surface tone="accent" compact className={styles.metric}><span className={styles.kicker}>在线项目</span><strong className={styles.metricValue}>{active.length}</strong><span className={styles.metricNote}>可继续工作</span></Surface>
      <Surface compact className={styles.metric}><span className={styles.kicker}>已归档</span><strong className={styles.metricValue}>{archived.length}</strong><span className={styles.metricNote}>可随时恢复</span></Surface>
    </div>
    <Surface className={styles.panel}>
      <div className={styles.sectionHeader}><div><p className={styles.kicker}>项目</p><h2 className={styles.sectionTitle}>项目列表</h2></div></div>
      {active.length === 0 ? <EmptyState icon={FolderKanban} title="还没有项目" description="创建项目后即可开始识别场记。" action={<Button onClick={() => setDialog("new-project")} disabled={Boolean(actionBusy)} startIcon={<Plus size={16} />}>创建第一个项目</Button>} /> : <div className={styles.cardGrid}>{active.map((project) => <ProjectCard key={project.id} project={project} current={project.id === current?.id} busy={actionBusy === `archive:${project.id}`} disabled={Boolean(actionBusy)} onOpen={() => onOpenProject(project.id, "workspace")} onSettings={() => onOpenProject(project.id, "project-settings")} onArchive={() => void archive(project.id, false)} />)}</div>}
    </Surface>
    {archived.length > 0 && <Surface className={styles.panel} style={{ marginTop: 16 }}><div className={styles.sectionHeader}><div><p className={styles.kicker}>归档</p><h2 className={styles.sectionTitle}>已归档项目</h2></div><Text tone="muted" size="sm">恢复后可继续编辑。</Text></div><div className={styles.cardGrid}>{archived.map((project) => <ProjectCard key={project.id} project={project} current={false} busy={actionBusy === `archive:${project.id}`} disabled={Boolean(actionBusy)} onOpen={() => onOpenProject(project.id, "project-settings")} onSettings={() => onOpenProject(project.id, "project-settings")} onArchive={() => void archive(project.id, true)} />)}</div></Surface>}
    <Dialog open={dialog === "new-project"} title="新建项目" description="输入名称即可创建。" onClose={() => { setDialog(null); setNameError(null); }} footer={<Stack direction="row" gap={2} justify="end"><Button variant="ghost" onClick={() => { setDialog(null); setNameError(null); }}>取消</Button><Button type="submit" form="new-project-form" loading={actionBusy === "create"}>创建项目</Button></Stack>}>
      <form id="new-project-form" noValidate onSubmit={createProject} className={styles.grid}>
        <div className={styles.formField}><Field label="项目名称" error={nameError || undefined}><Input autoFocus required value={name} onChange={(event) => { setName(event.target.value); if (nameError) setNameError(null); }} onBlur={() => { if (name) { const validation = validateProjectName(name); setNameError(validation.ok ? null : validation.message); } }} placeholder="例如：纪录片 · 第 01 集" /></Field></div>
        <div className={styles.formField}><Field label="描述"><Input value={description} onChange={(event) => setDescription(event.target.value)} placeholder="可选" /></Field></div>
      </form>
    </Dialog>
  </div>;
}

function ProjectCard({ project, current, busy, disabled, onOpen, onSettings, onArchive }: { project: import("../../../shared/contracts/index.js").ProjectSummary; current: boolean; busy: boolean; disabled: boolean; onOpen: () => void; onSettings: () => void; onArchive: () => void }) {
  const archived = Boolean(project.archivedAt);
  return <Surface compact className={styles.projectCard} data-current={current || undefined} data-archived={archived || undefined}>
    {/* 原生按钮负责整卡点击区域，项目包操作统一收纳到项目设置。 */}
    <button type="button" className={styles.projectCardOpen} onClick={onOpen} disabled={disabled} aria-label={`打开项目 ${project.name}`} />
    <div className={styles.projectCardContent}>
      <div className={styles.projectTop}><span className={styles.projectMark}><FolderKanban size={19} /></span><div style={{ flex: 1, minWidth: 0 }}><h3 className={styles.projectName}>{project.name}</h3>{project.description && <p className={styles.projectDescription}>{project.description}</p>}</div></div>
      <p className={styles.projectMeta}>{project.taskCount || 0} 个任务 · 最近 {formatDate(project.latestTaskAt)}</p>
    </div>
    <div className={styles.projectCardActions}><span /><Stack direction="row" gap={1} align="center"><IconButton label="项目设置" size="sm" onClick={onSettings} disabled={disabled}><Settings2 size={15} /></IconButton>{project.canArchive && <Button variant="ghost" size="sm" onClick={onArchive} loading={busy} disabled={disabled} startIcon={archived ? <ArchiveRestore size={14} /> : <Archive size={14} />}>{archived ? "恢复" : "归档"}</Button>}</Stack></div>
  </Surface>;
}

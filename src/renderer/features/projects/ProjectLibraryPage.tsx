import { Archive, ArchiveRestore, FolderKanban, Import, MapPin, PackageOpen, Plus, RefreshCw, Settings2 } from "lucide-react";
import { useEffect, useMemo, useState } from "react";
import { Button, Dialog, EmptyState, Icon, IconButton, InlineError, Input, Stack, Surface, Text } from "../../design-system";
import { appErrorFromUnknown, getSlateSync, unwrap } from "../../services/api";
import { createOperationGuard } from "../../services/operation-guard";
import { useProjectStore, useUiStore } from "../../state";
import styles from "../../app/app.module.css";

function formatDate(value: string | null) {
  if (!value) return "暂无任务";
  return new Intl.DateTimeFormat("zh-CN", { month: "short", day: "numeric", hour: "2-digit", minute: "2-digit" }).format(new Date(value));
}

export function ProjectLibraryPage({ onOpenProject }: { onOpenProject: (id: string, route?: "workspace" | "project-settings") => void }) {
  const projects = useProjectStore((state) => state.projects);
  const current = useProjectStore((state) => state.current);
  const library = useProjectStore((state) => state.library);
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
  const [actionBusy, setActionBusy] = useState<string | null>(null);
  const refreshGuard = useMemo(() => createOperationGuard(), []);

  const refresh = async () => {
    const operationId = refreshGuard.start();
    setLoading(true);
    setError(null);
    try {
      const api = getSlateSync();
      const [libraryInfo, projectList] = await Promise.all([unwrap(await api.projects.getLibraryInfo()), unwrap(await api.projects.list())]);
      if (!refreshGuard.isCurrent(operationId)) return;
      setLibrary(libraryInfo);
      setProjects(projectList);
    } catch (nextError) {
      if (refreshGuard.isCurrent(operationId)) setError(appErrorFromUnknown(nextError));
    } finally {
      if (refreshGuard.isCurrent(operationId)) setLoading(false);
    }
  };

  useEffect(() => {
    void refresh();
    return () => refreshGuard.invalidate();
  }, [refreshGuard]);

  const runLibraryAction = async (action: "import" | "export" | "change") => {
    setActionBusy(action);
    try {
      const api = getSlateSync();
      const result = action === "import"
        ? await unwrap(await api.projects.importLibrary())
        : action === "export"
          ? await unwrap(await api.projects.exportLibrary())
          : await unwrap(await api.projects.changeLibraryLocation());
      if (result.canceled) return;
      setToast({ tone: "success", message: action === "export" ? "Project Library 已导出" : "Project Library 已更新，应用将重新启动" });
    } catch (nextError) {
      setError(appErrorFromUnknown(nextError));
    } finally {
      setActionBusy(null);
    }
  };

  const createProject = async (event: React.FormEvent<HTMLFormElement>) => {
    event.preventDefault();
    if (!name.trim()) return;
    setActionBusy("create");
    try {
      const project = await unwrap(await getSlateSync().projects.create({ name: name.trim(), description: description.trim() }));
      setProjects([...useProjectStore.getState().projects, project]);
      setDialog(null);
      setName("");
      setDescription("");
      onOpenProject(project.id, "workspace");
    } catch (nextError) {
      setError(appErrorFromUnknown(nextError));
    } finally {
      setActionBusy(null);
    }
  };

  const archive = async (projectId: string, archived: boolean) => {
    setActionBusy(projectId);
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
      <div><p className={styles.eyebrow}>PROJECT LIBRARY / LOCAL</p><h1 className={styles.heading}>项目库</h1><p className={styles.subtitle}>{library ? `${library.name} · ${library.path}` : "正在读取本地 Project Library…"}</p></div>
      <div className={styles.pageActions}><Button variant="ghost" size="sm" onClick={() => void refresh()} loading={loading} startIcon={<RefreshCw size={15} />}>刷新</Button><Button size="lg" onClick={() => setDialog("new-project")} startIcon={<Plus size={17} />}>新建项目</Button></div>
    </div>
    {error && <div style={{ marginBottom: 16 }}><InlineError message={error.message} onRetry={() => void refresh()} /></div>}
    <div className={`${styles.grid} ${styles.gridThree}`} style={{ marginBottom: 20 }}>
      <Surface tone="accent" compact className={styles.metric}><span className={styles.kicker}>ACTIVE PROJECTS</span><strong className={styles.metricValue}>{active.length}</strong><span className={styles.metricNote}>可继续工作的项目</span></Surface>
      <Surface compact className={styles.metric}><span className={styles.kicker}>ARCHIVED</span><strong className={styles.metricValue}>{archived.length}</strong><span className={styles.metricNote}>只读，可随时恢复</span></Surface>
      <Surface compact className={styles.metric}><span className={styles.kicker}>LIBRARY FORMAT</span><strong className={styles.metricValue}>v{library?.formatVersion || 1}</strong><span className={styles.metricNote}>SQLite / portable package</span></Surface>
    </div>
    <Surface className={styles.panel}>
      <div className={styles.sectionHeader}><div><p className={styles.kicker}>WORKSPACES</p><h2 className={styles.sectionTitle}>当前项目</h2></div><Stack direction="row" gap={2} align="center"><Button variant="ghost" size="sm" startIcon={<Import size={15} />} onClick={() => void runLibraryAction("import")} loading={actionBusy === "import"}>导入</Button><Button variant="ghost" size="sm" startIcon={<PackageOpen size={15} />} onClick={() => void runLibraryAction("export")} loading={actionBusy === "export"}>导出</Button><Button variant="ghost" size="sm" startIcon={<MapPin size={15} />} onClick={() => void runLibraryAction("change")} loading={actionBusy === "change"}>更换位置</Button></Stack></div>
      {active.length === 0 ? <EmptyState icon={FolderKanban} title="还没有项目" description="创建一个项目，把识别、任务和 Resolve 输出放在同一个可迁移的 Library 中。" action={<Button onClick={() => setDialog("new-project")} startIcon={<Plus size={16} />}>创建第一个项目</Button>} /> : <div className={styles.cardGrid}>{active.map((project) => <ProjectCard key={project.id} project={project} current={project.id === current?.id} busy={actionBusy === project.id} onOpen={() => onOpenProject(project.id, "workspace")} onSettings={() => onOpenProject(project.id, "project-settings")} onArchive={() => void archive(project.id, false)} />)}</div>}
    </Surface>
    {archived.length > 0 && <Surface className={styles.panel} style={{ marginTop: 16 }}><div className={styles.sectionHeader}><div><p className={styles.kicker}>ARCHIVE</p><h2 className={styles.sectionTitle}>已归档项目</h2></div><Text tone="muted" size="sm">项目内容保持可读，恢复后才能写入。</Text></div><div className={styles.cardGrid}>{archived.map((project) => <ProjectCard key={project.id} project={project} current={false} busy={actionBusy === project.id} onOpen={() => onOpenProject(project.id, "project-settings")} onSettings={() => onOpenProject(project.id, "project-settings")} onArchive={() => void archive(project.id, true)} />)}</div></Surface>}
    <Dialog open={dialog === "new-project"} title="新建项目" description="项目设置会保存到当前 Project Library 的独立数据库中。" onClose={() => setDialog(null)} footer={<Stack direction="row" gap={2} justify="end"><Button variant="ghost" onClick={() => setDialog(null)}>取消</Button><Button type="submit" form="new-project-form" loading={actionBusy === "create"}>创建项目</Button></Stack>}>
      <form id="new-project-form" onSubmit={createProject} className={styles.grid}>
        <label className={styles.formField}><span className={styles.kicker}>PROJECT NAME</span><Input autoFocus required value={name} onChange={(event) => setName(event.target.value)} placeholder="例如：纪录片 · 第 01 集" /></label>
        <label className={styles.formField}><span className={styles.kicker}>DESCRIPTION</span><Input value={description} onChange={(event) => setDescription(event.target.value)} placeholder="可选，用一句话标记项目用途" /></label>
      </form>
    </Dialog>
  </div>;
}

function ProjectCard({ project, current, busy, onOpen, onSettings, onArchive }: { project: import("../../../shared/contracts/index.js").ProjectSummary; current: boolean; busy: boolean; onOpen: () => void; onSettings: () => void; onArchive: () => void }) {
  const archived = Boolean(project.archivedAt);
  return <Surface compact className={styles.projectCard} data-current={current || undefined} data-archived={archived || undefined}>
    <div className={styles.projectTop}><button type="button" onClick={onOpen} style={{ display: "contents" }} aria-label={`打开项目 ${project.name}`}><span className={styles.projectMark}><FolderKanban size={19} /></span><div style={{ flex: 1, minWidth: 0 }}><h3 className={styles.projectName}>{project.name}</h3><p className={styles.projectDescription}>{project.description || "SlateSync Project"}</p></div></button></div>
    <p className={styles.projectMeta}>{project.taskCount || 0} 个任务 · 最近 {formatDate(project.latestTaskAt)}</p>
    <div className={styles.projectCardActions}><Text tone="subtle" size="xs" mono>{project.canArchive ? "PROJECT-READY" : "DEFAULT-PROJECT"}</Text><Stack direction="row" gap={1} align="center"><IconButton label="项目设置" size="sm" onClick={onSettings}><Settings2 size={15} /></IconButton>{project.canArchive && <Button variant="ghost" size="sm" onClick={onArchive} loading={busy} startIcon={archived ? <ArchiveRestore size={14} /> : <Archive size={14} />}>{archived ? "恢复" : "归档"}</Button>}</Stack></div>
  </Surface>;
}

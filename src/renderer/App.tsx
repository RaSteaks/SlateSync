import { FolderKanban, Import, LayoutDashboard, MapPin, Moon, PackageOpen, PanelLeftClose, PanelLeftOpen, PencilLine, Settings, Sun, SlidersHorizontal } from "lucide-react";
import { useEffect, useMemo, useRef, useState } from "react";
import { flushSync } from "react-dom";
import appIconUrl from "../../build/icon.png";
import { AppShell, Button, ContextMenu, Dialog, Field, Icon, IconButton, Input, Separator, Sidebar, Stack, Text, Toast, Toolbar } from "./design-system";
import { appErrorFromUnknown, getSlateSync, unwrap } from "./services/api";
import { createOperationGuard } from "./services/operation-guard";
import { isEditableShortcutTarget, RECOGNITION_SHORTCUT_EVENT } from "./services/keyboard-shortcuts";
import { APPEARANCE_PREFERENCE_KEY, parseAppearancePreference, resolveTheme, watchSystemTheme } from "./services/appearance-preference";
import { useExportStore, useMetadataStore, useProjectStore, useRecognitionStore, useSlateStore, useTaskStore, useUiStore } from "./state";
import { validateLibraryName } from "./validation/input-validation";
import { ProjectLibraryPage } from "./features/projects/ProjectLibraryPage";
import { GlobalSettingsPage } from "./features/settings/GlobalSettingsPage";
import { ProjectSettingsPage } from "./features/settings/ProjectSettingsPage";
import { WorkspacePage } from "./features/workspace/WorkspacePage";
import styles from "./app/app.module.css";

function routeTitle(route: ReturnType<typeof useUiStore.getState>["route"]) {
  return route === "projects" ? "项目库" : route === "workspace" ? "工作台" : route === "project-settings" ? "项目设置" : "全局设置";
}

// 项目库路径展示简化：去掉末尾的项目库目录（默认名称或便携包名称），只显示
// 所在位置，并把 macOS 用户主目录缩写为 ~，便于右键菜单内阅读。
function formatLibraryLocation(path: string): string {
  const lastSlash = path.lastIndexOf("/");
  const parent = lastSlash > 0 ? path.slice(0, lastSlash) : path;
  const match = /^\/Users\/([^/]+)\//.exec(parent);
  return match ? `~/${parent.slice(match[0].length)}` : parent;
}

export function App() {
  const route = useUiStore((state) => state.route);
  const theme = useUiStore((state) => state.theme);
  const density = useUiStore((state) => state.density);
  const sidebarCollapsed = useUiStore((state) => state.sidebarCollapsed);
  const toast = useUiStore((state) => state.toast);
  const setTheme = useUiStore((state) => state.setTheme);
  const setDensity = useUiStore((state) => state.setDensity);
  const setRoute = useUiStore((state) => state.setRoute);
  const setToast = useUiStore((state) => state.setToast);
  const toggleSidebar = useUiStore((state) => state.toggleSidebar);
  const project = useProjectStore((state) => state.current);
  const library = useProjectStore((state) => state.library);
  const setError = useProjectStore((state) => state.setError);
  const [booting, setBooting] = useState(true);
  const [appearanceHydrated, setAppearanceHydrated] = useState(false);
  const [systemPrefersDark, setSystemPrefersDark] = useState(() => typeof window.matchMedia === "function" && window.matchMedia("(prefers-color-scheme: dark)").matches);
  const [libraryMenu, setLibraryMenu] = useState<{ open: boolean; x: number; y: number }>({ open: false, x: 0, y: 0 });
  const [libraryBusy, setLibraryBusy] = useState<"import" | "export" | "change" | null>(null);
  const [libraryDialog, setLibraryDialog] = useState<"settings" | "rename" | null>(null);
  const [renameName, setRenameName] = useState("");
  const [renameBusy, setRenameBusy] = useState(false);
  const [renameError, setRenameError] = useState<string | null>(null);
  const mainRef = useRef<HTMLElement>(null);
  const appliedThemeRef = useRef<"dark" | "light" | null>(null);
  const themeHydratedRef = useRef(false);
  const projectLoadGuard = useMemo(() => createOperationGuard(), []);

  const resolvedTheme = resolveTheme(theme, systemPrefersDark);

  useEffect(() => {
    document.documentElement.dataset.density = density;
  }, [density]);

  useEffect(() => {
    const root = document.documentElement;
    const previousTheme = appliedThemeRef.current;
    const themeChanged = themeHydratedRef.current && previousTheme !== null && previousTheme !== resolvedTheme;
    // Skip motion on first paint, then expose a short-lived hook so every
    // semantic color surface cross-fades together on later theme changes.
    if (themeChanged) root.dataset.themeTransition = "true";
    root.dataset.theme = resolvedTheme;
    appliedThemeRef.current = resolvedTheme;
    if (appearanceHydrated) themeHydratedRef.current = true;
    if (!themeChanged) return undefined;
    const timer = window.setTimeout(() => { delete root.dataset.themeTransition; }, 240);
    return () => {
      window.clearTimeout(timer);
      delete root.dataset.themeTransition;
    };
  }, [appearanceHydrated, resolvedTheme]);

  useEffect(() => {
    if (typeof window.matchMedia !== "function") return undefined;
    return watchSystemTheme(window.matchMedia("(prefers-color-scheme: dark)"), setSystemPrefersDark);
  }, []);

  useEffect(() => {
    mainRef.current?.focus({ preventScroll: true });
    // Route content replaces the document's scroll owner. Resetting the
    // viewport keeps keyboard focus and the new page heading visible instead
    // of carrying a prior form/table scroll position across routes.
    window.scrollTo(0, 0);
    document.scrollingElement?.scrollTo({ top: 0, left: 0, behavior: "auto" });
    document.documentElement.scrollTop = 0;
    document.body.scrollTop = 0;
  }, [route]);

  useEffect(() => {
    let active = true;
    void (async () => {
      try {
        const api = getSlateSync();
        const [config, library] = await Promise.all([
          unwrap(await api.app.getConfig()),
          unwrap(await api.projects.getLibraryInfo()),
        ]);
        if (!active) return;
        useProjectStore.getState().setConfig(config);
        useProjectStore.getState().setLibrary(library);
        useUiStore.getState().hydrateAppearance(parseAppearancePreference(localStorage.getItem(APPEARANCE_PREFERENCE_KEY)));
        setAppearanceHydrated(true);
      } catch (error) {
        if (active) setError(appErrorFromUnknown(error));
      } finally { if (active) setBooting(false); }
    })();
    return () => { active = false; };
  }, [setError]);

  useEffect(() => {
    if (!appearanceHydrated) return;
    // Appearance is renderer-only UI state. A versioned key persists it without
    // expanding Shared Contract v1 or mixing it into project data.
    try {
      localStorage.setItem(APPEARANCE_PREFERENCE_KEY, JSON.stringify({ theme, density }));
    } catch {
      // Appearance remains usable for this session when storage is unavailable.
    }
  }, [appearanceHydrated, density, theme]);

  useEffect(() => {
    const onKeyDown = (event: KeyboardEvent) => {
      if (!event.metaKey && !event.ctrlKey) return;
      if (event.key === ",") {
        event.preventDefault();
        useUiStore.getState().setDialog(null);
        setRoute("global-settings");
        return;
      }
      if (event.key !== "Enter" || route !== "workspace" || isEditableShortcutTarget(event.target) || document.querySelector('[role="dialog"]')) return;
      event.preventDefault();
      window.dispatchEvent(new Event(RECOGNITION_SHORTCUT_EVENT));
    };
    document.addEventListener("keydown", onKeyDown);
    return () => document.removeEventListener("keydown", onKeyDown);
  }, [route, setRoute]);

  useEffect(() => {
    if (!toast) return undefined;
    const timer = window.setTimeout(() => setToast(null), 4200);
    return () => window.clearTimeout(timer);
  }, [setToast, toast]);

  // 项目库右键菜单：点击任意处、右键其他地方、Escape 或滚动时关闭。
  useEffect(() => {
    if (!libraryMenu.open) return undefined;
    const close = () => setLibraryMenu((current) => ({ ...current, open: false }));
    const onKeyDown = (event: KeyboardEvent) => { if (event.key === "Escape") close(); };
    window.addEventListener("click", close);
    window.addEventListener("contextmenu", close);
    window.addEventListener("keydown", onKeyDown);
    window.addEventListener("scroll", close, true);
    window.addEventListener("resize", close);
    return () => {
      window.removeEventListener("click", close);
      window.removeEventListener("contextmenu", close);
      window.removeEventListener("keydown", onKeyDown);
      window.removeEventListener("scroll", close, true);
      window.removeEventListener("resize", close);
    };
  }, [libraryMenu.open]);

  // 项目库设置动作：导入 / 导出 / 更换位置，结果统一经 Toast 反馈。
  const runLibraryAction = async (action: "import" | "export" | "change") => {
    setLibraryBusy(action);
    try {
      const api = getSlateSync();
      const result = action === "import"
        ? await unwrap(await api.projects.importLibrary())
        : action === "export"
          ? await unwrap(await api.projects.exportLibrary())
          : await unwrap(await api.projects.changeLibraryLocation());
      if (result.canceled) return;
      setToast({ tone: "success", message: action === "export" ? "项目库已导出" : "项目库已更新，应用将重新启动" });
      setLibraryDialog(null);
    } catch (nextError) {
      setToast({ tone: "danger", message: appErrorFromUnknown(nextError).message });
    } finally {
      setLibraryBusy(null);
      setLibraryMenu((current) => ({ ...current, open: false }));
    }
  };

  // 点击菜单中的路径行时复制完整路径到剪贴板。
  const copyLibraryPath = async () => {
    if (!library?.path) return;
    try {
      await navigator.clipboard.writeText(library.path);
      setToast({ tone: "success", message: "项目库路径已复制" });
    } catch {
      setToast({ tone: "danger", message: "复制失败，请手动选择路径复制" });
    }
  };

  // 打开改名对话框时预填当前名称并清空上一次的错误。
  const openRenameDialog = () => {
    setRenameName(library?.name || "");
    setRenameError(null);
    setLibraryMenu((current) => ({ ...current, open: false }));
    setLibraryDialog("rename");
  };

  // 提交改名：主进程会同步重命名磁盘目录并重启应用。
  const renameLibrary = async () => {
    const validation = validateLibraryName(renameName);
    if (!validation.ok) { setRenameError(validation.message); return; }
    setRenameBusy(true);
    setRenameError(null);
    try {
      const result = await unwrap(await getSlateSync().projects.renameLibrary({ name: renameName.trim() }));
      if (result.canceled) return;
      setToast({ tone: "success", message: "项目库已改名，应用将重新启动" });
    } catch (nextError) {
      setRenameError(appErrorFromUnknown(nextError).message);
    } finally {
      setRenameBusy(false);
    }
  };

  const openProject = async (id: string, nextRoute: "workspace" | "project-settings" = "workspace") => {
    const operationId = projectLoadGuard.start();
    useProjectStore.getState().setError(null);
    try {
      const api = getSlateSync();
      // Match the compatibility composition root: one parallel authority read
      // supplies the complete first-usable project projection before routing.
      const [loaded, scenarios, tasks] = await Promise.all([
        unwrap(await api.projects.load({ id })),
        unwrap(await api.projects.listScenarios({ projectId: id })),
        unwrap(await api.tasks.list({ projectId: id })),
      ]);
      if (!projectLoadGuard.isCurrent(operationId)) return;
      // Project identity and its route are one visible projection boundary;
      // publish both subscriptions in one commit so no intermediate frame can
      // show the new project on the old Library route (or vice versa).
      flushSync(() => {
        useProjectStore.getState().setCurrent(loaded);
        useProjectStore.getState().setScenarios(scenarios);
        useTaskStore.getState().setItems(tasks);
        useUiStore.getState().setRoute(nextRoute);
      });
    } catch (error) { if (projectLoadGuard.isCurrent(operationId)) useProjectStore.getState().setError(appErrorFromUnknown(error)); }
  };

  const leaveProject = () => {
    if (useRecognitionStore.getState().running) { setToast({ tone: "warning", message: "识别进行中，完成后才能切换项目" }); return; }
    projectLoadGuard.invalidate();
    useRecognitionStore.getState().reset();
    useSlateStore.getState().clearInput();
    useExportStore.getState().clear();
    useMetadataStore.getState().clear();
    useTaskStore.getState().clear();
    // Match the retained compatibility route: the Library may show which
    // project was current, while workspace-owned data is already released.
    // Reopening still reloads full project authority from Main.
    setRoute("projects");
  };

  const leaveDeletedProject = (projectId: string) => {
    projectLoadGuard.invalidate();
    const projectState = useProjectStore.getState();
    projectState.setProjects(projectState.projects.filter((item) => item.id !== projectId));
    projectState.setCurrent(null);
    projectState.setScenarios([]);
    useRecognitionStore.getState().reset();
    useSlateStore.getState().clearInput();
    useExportStore.getState().clear();
    useMetadataStore.getState().clear();
    useTaskStore.getState().clear();
    setRoute("projects");
  };

  const navigation = <>
    <div className={styles.navSection} data-collapsed={sidebarCollapsed || undefined}>项目</div>
    <button type="button" className={styles.navItem} data-active={route === "projects"} data-collapsed={sidebarCollapsed || undefined} title="项目库" onClick={leaveProject} onContextMenu={(event) => { event.preventDefault(); event.stopPropagation(); setLibraryMenu({ open: true, x: event.clientX, y: event.clientY }); }}><Icon icon={FolderKanban} size={17} /><span>项目库</span></button>
    {project && <><div className={`${styles.navSection} ${styles.navSectionCurrent}`} data-collapsed={sidebarCollapsed || undefined}><span>当前项目</span><span className={styles.navSectionProject} title={project.name}>{project.name}</span></div><button type="button" className={styles.navItem} data-active={route === "workspace"} data-collapsed={sidebarCollapsed || undefined} title="工作台" onClick={() => setRoute("workspace")}><Icon icon={LayoutDashboard} size={17} /><span>工作台</span></button><button type="button" className={styles.navItem} data-active={route === "project-settings"} data-collapsed={sidebarCollapsed || undefined} title="项目设置" onClick={() => setRoute("project-settings")}><Icon icon={SlidersHorizontal} size={17} /><span>项目设置</span></button></>}
    <div style={{ flex: 1 }} />
    <div className={styles.navSection} data-collapsed={sidebarCollapsed || undefined}>系统</div><button type="button" className={styles.navItem} data-active={route === "global-settings"} data-collapsed={sidebarCollapsed || undefined} title="全局设置" onClick={() => setRoute("global-settings")}><Icon icon={Settings} size={17} /><span>全局设置</span></button>
  </>;

  const sidebar = <Sidebar brand={<><img className={styles.brandIcon} src={appIconUrl} alt="" aria-hidden="true" draggable={false} /><span className={styles.brandCopy} data-collapsed={sidebarCollapsed || undefined}><strong>SlateSync</strong></span></>} navigation={navigation} footer={<><IconButton label={sidebarCollapsed ? "展开侧栏" : "收起侧栏"} size="sm" onClick={toggleSidebar}>{sidebarCollapsed ? <PanelLeftOpen size={16} /> : <PanelLeftClose size={16} />}</IconButton><IconButton label={resolvedTheme === "dark" ? "切换浅色主题" : "切换深色主题"} size="sm" onClick={() => setTheme(resolvedTheme === "dark" ? "light" : "dark")}>{resolvedTheme === "dark" ? <Sun size={16} /> : <Moon size={16} />}</IconButton></>} />;
  // 顶部栏副标题仅在工作台 / 项目设置 / 全局设置展示当前项目名；项目库页只显示“项目库”，当前项目名仅由左侧导航栏维护。
  const toolbar = <Toolbar title={routeTitle(route)} {...(project?.name && route !== "projects" ? { subtitle: project.name } : {})} actions={<Button variant="ghost" size="sm" onClick={() => setDensity(density === "compact" ? "comfortable" : "compact")}>{density === "compact" ? "标准密度" : "紧凑密度"}</Button>} />;
  // The same visible actions serve the expert context menu and the accessible
  // settings dialog, keeping labels, pending states, and outcomes identical.
  const renderLibraryActions = () => <>
    <Button variant="ghost" size="sm" onClick={() => void runLibraryAction("import")} loading={libraryBusy === "import"} startIcon={<Import size={14} />}>导入项目库</Button>
    <Button variant="ghost" size="sm" onClick={() => void runLibraryAction("export")} loading={libraryBusy === "export"} startIcon={<PackageOpen size={14} />}>导出项目库</Button>
    <Button variant="ghost" size="sm" onClick={() => void runLibraryAction("change")} loading={libraryBusy === "change"} startIcon={<MapPin size={14} />}>更换位置</Button>
    <Button variant="ghost" size="sm" onClick={openRenameDialog} startIcon={<PencilLine size={14} />}>改名项目库</Button>
  </>;
  // 项目库右键菜单：展示项目库名称与路径，并提供导入 / 导出 / 更换位置入口。
  const libraryMenuNode = libraryMenu.open && <ContextMenu open={libraryMenu.open} style={{ left: libraryMenu.x, top: libraryMenu.y }}>
    <div className={styles.libraryMenuHeader}><span className={styles.kicker}>项目库设置</span>{library && <strong className={styles.libraryMenuName}>{library.name}</strong>}{library?.path && <button type="button" className={styles.libraryMenuPath} title="点击复制完整路径" onClick={() => void copyLibraryPath()}>{formatLibraryLocation(library.path)}</button>}</div>
    <Separator style={{ margin: "8px 0" }} />
    <Stack direction="column" gap={1}>
      {renderLibraryActions()}
    </Stack>
  </ContextMenu>;

  // A visible Dialog is the keyboard/touch path; right-click remains an expert
  // shortcut. Switching to rename keeps one modal owner and restores focus to
  // the original settings trigger when the complete flow closes.
  const libraryDialogNode = libraryDialog === "settings"
    ? <Dialog open title="项目库设置" description="导入、导出或调整当前项目库。" onClose={() => { if (!libraryBusy) setLibraryDialog(null); }}>
        <div className={styles.libraryMenuHeader}>{library && <strong className={styles.libraryMenuName}>{library.name}</strong>}{library?.path && <button type="button" className={styles.libraryMenuPath} title="点击复制完整路径" onClick={() => void copyLibraryPath()}>{formatLibraryLocation(library.path)}</button>}</div>
        <Separator style={{ margin: "8px 0" }} />
        <Stack direction="column" gap={1}>{renderLibraryActions()}</Stack>
      </Dialog>
    : <Dialog open={libraryDialog === "rename"} title="项目库改名" description="名称将同步应用到项目库目录与导出文件。" onClose={() => { if (!renameBusy) { setLibraryDialog(null); setRenameError(null); } }} footer={<Stack direction="row" gap={2} justify="end"><Button variant="ghost" onClick={() => { setLibraryDialog(null); setRenameError(null); }} disabled={renameBusy}>取消</Button><Button onClick={() => void renameLibrary()} loading={renameBusy} startIcon={<PencilLine size={15} />}>保存</Button></Stack>}>
        <form noValidate onSubmit={(event) => { event.preventDefault(); void renameLibrary(); }} className={styles.grid}>
          <div className={styles.formField}><Field label="项目库名称" hint="只允许常规字符，不能包含路径分隔符。" error={renameError || undefined}><Input autoFocus required value={renameName} onChange={(event) => { setRenameName(event.target.value); if (renameError) setRenameError(null); }} placeholder={library?.name || "项目库名称"} /></Field></div>
        </form>
      </Dialog>;

  if (booting) return <div data-testid="modern-shell" className={styles.bootScreen}><div><Text as="p" size="lg" weight="bold">正在准备 SlateSync</Text><Text tone="subtle" size="sm">正在读取项目…</Text></div></div>;
  return <div data-testid="modern-shell"><AppShell collapsed={sidebarCollapsed} sidebar={sidebar} toolbar={toolbar}><main ref={mainRef} id="main-content" className={styles.appMain} tabIndex={-1} aria-label={routeTitle(route)}>{route === "projects" && <ProjectLibraryPage onOpenProject={(id, nextRoute) => void openProject(id, nextRoute)} onOpenLibrarySettings={() => setLibraryDialog("settings")} />}{route === "workspace" && <WorkspacePage />}{route === "project-settings" && <ProjectSettingsPage onBack={() => setRoute("workspace")} onDeleted={leaveDeletedProject} />}{route === "global-settings" && <GlobalSettingsPage />}</main></AppShell>{libraryMenuNode}{libraryDialogNode}{toast && <Toast message={toast.message} tone={toast.tone} onDismiss={() => setToast(null)} />}</div>;
}

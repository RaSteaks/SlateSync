import { FolderKanban, LayoutDashboard, Moon, PanelLeftClose, PanelLeftOpen, Settings, Sun, SlidersHorizontal } from "lucide-react";
import { useEffect, useMemo, useRef, useState } from "react";
import { flushSync } from "react-dom";
import { AppShell, Button, Icon, IconButton, Sidebar, Text, Toast, Toolbar } from "./design-system";
import { appErrorFromUnknown, getSlateSync, unwrap } from "./services/api";
import { createOperationGuard } from "./services/operation-guard";
import { useExportStore, useMetadataStore, useProjectStore, useRecognitionStore, useSlateStore, useTaskStore, useUiStore } from "./state";
import { ProjectLibraryPage } from "./features/projects/ProjectLibraryPage";
import { GlobalSettingsPage } from "./features/settings/GlobalSettingsPage";
import { ProjectSettingsPage } from "./features/settings/ProjectSettingsPage";
import { WorkspacePage } from "./features/workspace/WorkspacePage";
import styles from "./app/app.module.css";

function routeTitle(route: ReturnType<typeof useUiStore.getState>["route"]) {
  return route === "projects" ? "项目库" : route === "workspace" ? "工作台" : route === "project-settings" ? "项目设置" : "全局设置";
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
  const setError = useProjectStore((state) => state.setError);
  const [booting, setBooting] = useState(true);
  const mainRef = useRef<HTMLElement>(null);
  const projectLoadGuard = useMemo(() => createOperationGuard(), []);

  useEffect(() => {
    document.documentElement.dataset.theme = theme;
    document.documentElement.dataset.density = density;
  }, [density, theme]);

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
        const config = await unwrap(await getSlateSync().app.getConfig());
        useProjectStore.getState().setConfig(config);
        const library = await unwrap(await getSlateSync().projects.getLibraryInfo());
        if (active) useProjectStore.getState().setLibrary(library);
      } catch (error) {
        if (active) setError(appErrorFromUnknown(error));
      } finally { if (active) setBooting(false); }
    })();
    return () => { active = false; };
  }, [setError]);

  useEffect(() => {
    if (!toast) return undefined;
    const timer = window.setTimeout(() => setToast(null), 4200);
    return () => window.clearTimeout(timer);
  }, [setToast, toast]);

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

  const navigation = <>
    <div className={styles.navSection} data-collapsed={sidebarCollapsed || undefined}>LIBRARY</div>
    <button type="button" className={styles.navItem} data-active={route === "projects"} data-collapsed={sidebarCollapsed || undefined} title="项目库" onClick={leaveProject}><Icon icon={FolderKanban} size={17} /><span>项目库</span></button>
    {project && <><div className={styles.navSection} data-collapsed={sidebarCollapsed || undefined}>CURRENT PROJECT</div><button type="button" className={styles.navItem} data-active={route === "workspace"} data-collapsed={sidebarCollapsed || undefined} title="工作台" onClick={() => setRoute("workspace")}><Icon icon={LayoutDashboard} size={17} /><span>工作台</span></button><button type="button" className={styles.navItem} data-active={route === "project-settings"} data-collapsed={sidebarCollapsed || undefined} title="项目设置" onClick={() => setRoute("project-settings")}><Icon icon={SlidersHorizontal} size={17} /><span>项目设置</span></button></>}
    <div style={{ flex: 1 }} />
    <div className={styles.navSection} data-collapsed={sidebarCollapsed || undefined}>SYSTEM</div><button type="button" className={styles.navItem} data-active={route === "global-settings"} data-collapsed={sidebarCollapsed || undefined} title="全局设置" onClick={() => setRoute("global-settings")}><Icon icon={Settings} size={17} /><span>全局设置</span></button>
  </>;

  const sidebar = <Sidebar brand={<><span className={styles.brandMark} aria-hidden="true">S</span><span className={styles.brandCopy}><strong>SlateSync</strong><small>Slate to Resolve</small></span></>} navigation={navigation} footer={<><IconButton label={sidebarCollapsed ? "展开侧栏" : "收起侧栏"} size="sm" onClick={toggleSidebar}>{sidebarCollapsed ? <PanelLeftOpen size={16} /> : <PanelLeftClose size={16} />}</IconButton><IconButton label={theme === "dark" ? "切换浅色主题" : "切换深色主题"} size="sm" onClick={() => setTheme(theme === "dark" ? "light" : "dark")}>{theme === "dark" ? <Sun size={16} /> : <Moon size={16} />}</IconButton></>} />;
  const toolbar = <Toolbar title={project ? `${routeTitle(route)} · ${project.name}` : routeTitle(route)} subtitle={project ? `PROJECT / ${project.id}` : "LOCAL PROJECT LIBRARY"} actions={<><Text tone="subtle" size="xs" mono>{density === "compact" ? "DENSE" : "FOCUS"}</Text><Button variant="ghost" size="sm" onClick={() => setDensity(density === "compact" ? "comfortable" : "compact")}>{density === "compact" ? "标准密度" : "紧凑密度"}</Button></>} />;

  if (booting) return <div data-testid="modern-shell" className={styles.bootScreen}><div><Text as="p" size="lg" weight="bold">正在准备 SlateSync</Text><Text tone="subtle" size="sm">连接本地 Project Library…</Text></div></div>;
  return <div data-testid="modern-shell"><AppShell collapsed={sidebarCollapsed} sidebar={sidebar} toolbar={toolbar}><main ref={mainRef} id="main-content" className={styles.appMain} tabIndex={-1} aria-label={routeTitle(route)}>{route === "projects" && <ProjectLibraryPage onOpenProject={(id, nextRoute) => void openProject(id, nextRoute)} />}{route === "workspace" && <WorkspacePage />}{route === "project-settings" && <ProjectSettingsPage onBack={() => setRoute("workspace")} />}{route === "global-settings" && <GlobalSettingsPage />}</main></AppShell>{toast && <Toast message={toast.message} tone={toast.tone} onDismiss={() => setToast(null)} />}</div>;
}

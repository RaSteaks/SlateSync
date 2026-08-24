import { FolderKanban, LayoutDashboard, Moon, PanelLeftClose, PanelLeftOpen, Settings, Sun, SlidersHorizontal } from "lucide-react";
import { useEffect, useMemo, useRef, useState } from "react";
import { flushSync } from "react-dom";
import appIconUrl from "../../build/icon.png";
import { AppShell, Button, Icon, IconButton, Sidebar, Text, Toast, Toolbar } from "./design-system";
import { appErrorFromUnknown, getSlateSync, unwrap } from "./services/api";
import { createOperationGuard } from "./services/operation-guard";
import { isEditableShortcutTarget, RECOGNITION_SHORTCUT_EVENT } from "./services/keyboard-shortcuts";
import { APPEARANCE_PREFERENCE_KEY, parseAppearancePreference, resolveTheme, watchSystemTheme } from "./services/appearance-preference";
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
  const [appearanceHydrated, setAppearanceHydrated] = useState(false);
  const [systemPrefersDark, setSystemPrefersDark] = useState(() => typeof window.matchMedia === "function" && window.matchMedia("(prefers-color-scheme: dark)").matches);
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
    <button type="button" className={styles.navItem} data-active={route === "projects"} data-collapsed={sidebarCollapsed || undefined} title="项目库" onClick={leaveProject}><Icon icon={FolderKanban} size={17} /><span>项目库</span></button>
    {project && <><div className={styles.navSection} data-collapsed={sidebarCollapsed || undefined}>当前项目</div><button type="button" className={styles.navItem} data-active={route === "workspace"} data-collapsed={sidebarCollapsed || undefined} title="工作台" onClick={() => setRoute("workspace")}><Icon icon={LayoutDashboard} size={17} /><span>工作台</span></button><button type="button" className={styles.navItem} data-active={route === "project-settings"} data-collapsed={sidebarCollapsed || undefined} title="项目设置" onClick={() => setRoute("project-settings")}><Icon icon={SlidersHorizontal} size={17} /><span>项目设置</span></button></>}
    <div style={{ flex: 1 }} />
    <div className={styles.navSection} data-collapsed={sidebarCollapsed || undefined}>系统</div><button type="button" className={styles.navItem} data-active={route === "global-settings"} data-collapsed={sidebarCollapsed || undefined} title="全局设置" onClick={() => setRoute("global-settings")}><Icon icon={Settings} size={17} /><span>全局设置</span></button>
  </>;

  const sidebar = <Sidebar brand={<><img className={styles.brandIcon} src={appIconUrl} alt="" aria-hidden="true" draggable={false} /><span className={styles.brandCopy} data-collapsed={sidebarCollapsed || undefined}><strong>SlateSync</strong></span></>} navigation={navigation} footer={<><IconButton label={sidebarCollapsed ? "展开侧栏" : "收起侧栏"} size="sm" onClick={toggleSidebar}>{sidebarCollapsed ? <PanelLeftOpen size={16} /> : <PanelLeftClose size={16} />}</IconButton><IconButton label={resolvedTheme === "dark" ? "切换浅色主题" : "切换深色主题"} size="sm" onClick={() => setTheme(resolvedTheme === "dark" ? "light" : "dark")}>{resolvedTheme === "dark" ? <Sun size={16} /> : <Moon size={16} />}</IconButton></>} />;
  const toolbar = <Toolbar title={routeTitle(route)} {...(project?.name ? { subtitle: project.name } : {})} actions={<Button variant="ghost" size="sm" onClick={() => setDensity(density === "compact" ? "comfortable" : "compact")}>{density === "compact" ? "标准密度" : "紧凑密度"}</Button>} />;

  if (booting) return <div data-testid="modern-shell" className={styles.bootScreen}><div><Text as="p" size="lg" weight="bold">正在准备 SlateSync</Text><Text tone="subtle" size="sm">正在读取项目…</Text></div></div>;
  return <div data-testid="modern-shell"><AppShell collapsed={sidebarCollapsed} sidebar={sidebar} toolbar={toolbar}><main ref={mainRef} id="main-content" className={styles.appMain} tabIndex={-1} aria-label={routeTitle(route)}>{route === "projects" && <ProjectLibraryPage onOpenProject={(id, nextRoute) => void openProject(id, nextRoute)} />}{route === "workspace" && <WorkspacePage />}{route === "project-settings" && <ProjectSettingsPage onBack={() => setRoute("workspace")} onDeleted={leaveDeletedProject} />}{route === "global-settings" && <GlobalSettingsPage />}</main></AppShell>{toast && <Toast message={toast.message} tone={toast.tone} onDismiss={() => setToast(null)} />}</div>;
}

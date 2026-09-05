import { BookOpen, Download, FolderKanban, Import, LayoutDashboard, MapPin, Monitor, Moon, PackageOpen, PanelLeftClose, PanelLeftOpen, PencilLine, ScrollText, Settings, Sun, SlidersHorizontal } from "lucide-react";
import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import { flushSync } from "react-dom";
import appIconUrl from "../../build/icon.png";
import { AppShell, Button, ContextMenu, Dialog, Field, Icon, IconButton, InlineError, Input, Separator, Sidebar, Stack, Text, Toast, Toolbar } from "./design-system";
import { appErrorFromUnknown, getSlateSync, unwrap } from "./services/api";
import { createOperationGuard } from "./services/operation-guard";
import { GLOBAL_SETTINGS_SAVE_EVENT, isEditableShortcutTarget, RECOGNITION_SHORTCUT_EVENT } from "./services/keyboard-shortcuts";
import { saveProjectSettingsChanges } from "./features/settings/projectSettingsActions";
import { acquireWorkspaceOperation, isWorkspaceBusy } from "./services/workspace-operation";
import { isRouteChangeBlocked, saveGlobalSettingsChanges } from "./features/settings/globalSettingsActions";
import { APPEARANCE_PREFERENCE_KEY, cycleTheme, parseAppearancePreference, resolveTheme, themePreferenceLabel, watchSystemTheme } from "./services/appearance-preference";
import { useExportStore, useGlobalSettingsStore, useMetadataStore, useProjectStore, useRecognitionStore, useSettingsStore, useSlateStore, useTaskStore, useUiStore } from "./state";
import { validateLibraryName } from "./validation/input-validation";
import { documentTitle, routeTitle } from "./app/route-title";
import { ProjectLibraryPage } from "./features/projects/ProjectLibraryPage";
import { HelpPage } from "./features/help/HelpPage";
import { GlobalSettingsPage } from "./features/settings/GlobalSettingsPage";
import { GlobalSettingsSidebarNav } from "./features/settings/GlobalSettingsSidebarNav";
import { LogViewerPage } from "./features/logs/LogViewerPage";
import { ProjectSettingsPage } from "./features/settings/ProjectSettingsPage";
import { WorkspacePage, type RegisterWorkspaceToolbarExport, type RegisterWorkspaceTransferPreparation } from "./features/workspace/WorkspacePage";
import styles from "./app/app.module.css";

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
  const settingsSectionRequest = useUiStore((state) => state.settingsSectionRequest);
  const settingsSection = useUiStore((state) => state.settingsSection);
  const setSettingsSection = useUiStore((state) => state.setSettingsSection);
  const project = useProjectStore((state) => state.current);
  const library = useProjectStore((state) => state.library);
  const setError = useProjectStore((state) => state.setError);
  const [booting, setBooting] = useState(true);
  const [appearanceHydrated, setAppearanceHydrated] = useState(false);
  const [systemPrefersDark, setSystemPrefersDark] = useState(() => typeof window.matchMedia === "function" && window.matchMedia("(prefers-color-scheme: dark)").matches);
  const [libraryMenu, setLibraryMenu] = useState<{ open: boolean; x: number; y: number }>({ open: false, x: 0, y: 0 });
  const [libraryBusy, setLibraryBusy] = useState<"import" | "export" | "change" | "rename" | null>(null);
  const [libraryDialog, setLibraryDialog] = useState<"settings" | "rename" | null>(null);
  const [renameName, setRenameName] = useState("");
  const [renameBusy, setRenameBusy] = useState(false);
  const [renameError, setRenameError] = useState<string | null>(null);
  const mainRef = useRef<HTMLElement>(null);
  // A hidden settings sub-navigation returns focus to its own parent without
  // invoking the parent's page-top action or changing the current section.
  const globalSettingsTriggerRef = useRef<HTMLButtonElement>(null);
  const appliedThemeRef = useRef<"dark" | "light" | null>(null);
  const themeHydratedRef = useRef(false);
  const projectLoadGuard = useMemo(() => createOperationGuard(), []);
  const navigationIntentRef = useRef(0);
  const libraryActionRef = useRef<"import" | "export" | "change" | "rename" | null>(null);
  const workspaceExportRef = useRef<(() => void) | null>(null);
  const workspaceTransferRef = useRef<(() => Promise<boolean>) | null>(null);
  const [workspaceExportState, setWorkspaceExportState] = useState({ canExport: false, processing: false });
  // 全局设置的未保存草稿会拦截路由切换；该状态记录被拦截的目标路由，由
  // 守卫对话框提供“取消 / 放弃 / 保存”三条出路。
  const [pendingRoute, setPendingRoute] = useState<Parameters<typeof setRoute>[0] | null>(null);
  const globalSaveState = useGlobalSettingsStore((state) => state.saveState);
  const globalMutationOwner = useGlobalSettingsStore((state) => state.mutationOwner);
  const globalSaveError = useGlobalSettingsStore((state) => state.saveError);
  const projectSaving = useSettingsStore((state) => state.saving);
  const projectSaveError = useSettingsStore((state) => state.saveError);
  const guardSaving = route === "project-settings" ? projectSaving : globalSaveState === "saving";
  const guardWriteBusy = guardSaving || (route === "global-settings" && globalMutationOwner !== null);
  const guardError = route === "project-settings" ? projectSaveError : globalSaveError;
  const isGuardSaving = () => useUiStore.getState().route === "project-settings"
    ? useSettingsStore.getState().saving : useGlobalSettingsStore.getState().saveState === "saving";

  const navigateTo = useCallback((nextRoute: Parameters<typeof setRoute>[0]) => {
    // 未保存的项目/全局设置草稿先经守卫确认；留在当前页不消耗导航意图标记。
    if (isRouteChangeBlocked(useUiStore.getState().route, nextRoute)) {
      setPendingRoute(nextRoute);
      return;
    }
    // An intent token prevents a slower autosave continuation from replacing a
    // route the user selected while the previous navigation was still flushing.
    navigationIntentRef.current += 1;
    setRoute(nextRoute);
  }, [setRoute]);

  const openGlobalSettings = useCallback(() => {
    // `null` is the explicit parent destination: every activation requests
    // page-top focus even when Global Settings is already the current route.
    setSettingsSection(null);
    navigateTo("global-settings");
  }, [navigateTo, setSettingsSection]);

  // The workspace owns export semantics; the shell only hosts its stable
  // trigger in the sticky toolbar and mirrors the current busy/disabled state.
  const registerWorkspaceToolbarExport = useCallback<RegisterWorkspaceToolbarExport>((handler, nextState) => {
    workspaceExportRef.current = handler;
    setWorkspaceExportState((current) => {
      const next = nextState || { canExport: false, processing: false };
      return current.canExport === next.canExport && current.processing === next.processing ? current : next;
    });
  }, []);

  const registerWorkspaceTransferPreparation = useCallback<RegisterWorkspaceTransferPreparation>((handler) => {
    workspaceTransferRef.current = handler;
  }, []);

  const resolvedTheme = resolveTheme(theme, systemPrefersDark);
  const nextTheme = cycleTheme(theme);
  const themeButtonLabel = `当前主题：${themePreferenceLabel(theme)}，切换为${themePreferenceLabel(nextTheme)}`;
  // The sidebar mirrors the saved preference, while resolvedTheme remains the
  // separate paint value that follows macOS only when the preference is system.
  const themeIcon = theme === "system"
    ? <Monitor size={16} aria-hidden="true" />
    : theme === "dark"
      ? <Moon size={16} aria-hidden="true" />
      : <Sun size={16} aria-hidden="true" />;

  useEffect(() => {
    document.documentElement.dataset.density = density;
  }, [density]);

  useEffect(() => {
    document.title = documentTitle(route);
  }, [route]);

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
    if (route !== "global-settings") return;
    const target = settingsSection
      ? document.getElementById(settingsSection)
      : document.getElementById("global-settings-heading");
    if (!target) return;
    // A repeated click is a fresh request. Ordinary draft renders never move
    // focus; the null parent request deliberately targets the page heading.
    const heading = settingsSection ? target.querySelector<HTMLElement>("h2") || target : target;
    heading.tabIndex = -1;
    heading.focus({ preventScroll: true });
    target.scrollIntoView?.();
  }, [route, settingsSection, settingsSectionRequest]);

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
    let unsubscribe: (() => void) | undefined;
    try {
      // Recognition belongs to the app session rather than the Workspace
      // route. Keeping one listener here means Logs and Workspace observe the
      // same operation without competing subscriptions during route changes.
      unsubscribe = getSlateSync().recognition.onProgress((event) => {
        const recognition = useRecognitionStore.getState();
        if (recognition.running) recognition.progress(recognition.operationId, event);
      });
    } catch {
      // Renderer-only tests can mount without the Electron preload bridge;
      // the real desktop window always installs the bridge before this effect.
    }
    return () => unsubscribe?.();
  }, []);

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
      if ((!event.metaKey && !event.ctrlKey) || event.isComposing || event.defaultPrevented) return;
      if (event.key === ",") {
        event.preventDefault();
        if (document.querySelector('[role="dialog"]')) return;
        openGlobalSettings();
        return;
      }
      if (event.key === "s") {
        // 不经 isEditableShortcutTarget：输入框聚焦时同样保存，并抑制浏览器
        // 自带的“存储页面”。对话框打开时让位给对话框动作；两类设置共用保存入口。
        event.preventDefault();
        if (document.querySelector('[role="dialog"]')) return;
        if (useUiStore.getState().route === "project-settings") {
          void saveProjectSettingsChanges();
        } else if (useUiStore.getState().route === "global-settings") {
          window.dispatchEvent(new Event(GLOBAL_SETTINGS_SAVE_EVENT));
        }
        return;
      }
      if (event.key !== "Enter" || route !== "workspace" || isEditableShortcutTarget(event.target) || document.querySelector('[role="dialog"]')) return;
      event.preventDefault();
      window.dispatchEvent(new Event(RECOGNITION_SHORTCUT_EVENT));
    };
    document.addEventListener("keydown", onKeyDown);
    return () => document.removeEventListener("keydown", onKeyDown);
  }, [openGlobalSettings, route]);

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
    if (libraryActionRef.current) return;
    // Reserve the action before the async save gate so repeated clicks cannot
    // open multiple pickers while the current workspace is being flushed.
    libraryActionRef.current = action;
    setLibraryBusy(action);
    try {
      if (!(await prepareWorkspaceForTransfer())) return;
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
      if (libraryActionRef.current === action) {
        libraryActionRef.current = null;
        setLibraryBusy(null);
        setLibraryMenu((current) => ({ ...current, open: false }));
      }
    }
  };

  const prepareWorkspaceForTransfer = async (owner?: ReturnType<typeof acquireWorkspaceOperation>) => {
    // 所有项目库传输都先经过同一条识别/自动保存闸门，避免导出旧草稿。
    if (isWorkspaceBusy() && !owner?.isCurrent()) {
      setToast({ tone: "warning", message: "识别进行中，完成后才能操作项目库" });
      return false;
    }
    const prepare = workspaceTransferRef.current;
    if (!prepare) return true;
    const saved = await prepare();
    if (!saved) {
      setToast({ tone: "danger", message: "当前任务保存失败，请重试保存后再操作项目库" });
    }
    return saved && (!isWorkspaceBusy() || Boolean(owner?.isCurrent()));
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
    // Renaming closes the active library just like transfer actions, so it
    // must reserve the shared action slot before flushing the workspace.
    if (libraryActionRef.current) return;
    libraryActionRef.current = "rename";
    setLibraryBusy("rename");
    setRenameBusy(true);
    setRenameError(null);
    try {
      if (!(await prepareWorkspaceForTransfer())) return;
      const result = await unwrap(await getSlateSync().projects.renameLibrary({ name: renameName.trim() }));
      if (result.canceled) return;
      setToast({ tone: "success", message: "项目库已改名，应用将重新启动" });
    } catch (nextError) {
      setRenameError(appErrorFromUnknown(nextError).message);
    } finally {
      setRenameBusy(false);
      if (libraryActionRef.current === "rename") {
        libraryActionRef.current = null;
        setLibraryBusy(null);
      }
    }
  };

  const openProject = async (id: string, nextRoute: "workspace" | "project-settings" = "workspace") => {
    // openProject 直接写路由而非 navigateTo：它只能从项目库触发，而脏草稿
    // 守卫恰好把“离开全局设置”作为唯一入口，两者不会重叠。
    const navigationIntent = ++navigationIntentRef.current;
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
      if (!projectLoadGuard.isCurrent(operationId) || navigationIntentRef.current !== navigationIntent) return;
      // Project identity and its route are one visible projection boundary;
      // publish both subscriptions in one commit so no intermediate frame can
      // show the new project on the old Library route (or vice versa).
      flushSync(() => {
        useSettingsStore.getState().clearProject();
        useProjectStore.getState().setCurrent(loaded);
        useProjectStore.getState().setScenarios(scenarios);
        // Mark the project represented by the opening read so Workspace does
        // not immediately issue the same history request again on mount.
        useTaskStore.getState().setItems(tasks, id);
        useUiStore.getState().setRoute(nextRoute);
      });
    } catch (error) {
      if (projectLoadGuard.isCurrent(operationId) && navigationIntentRef.current === navigationIntent) {
        useProjectStore.getState().setError(appErrorFromUnknown(error));
      }
    }
  };

  const releaseWorkspaceForLibrary = (sourceProjectId?: string) => {
    const currentProject = useProjectStore.getState().current;
    const currentRoute = useUiStore.getState().route;
    // Import completion is allowed to release the workspace only if the user
    // is still on the importing project's settings route. Returning to the
    // workspace (or another project) must win over the late completion.
    if (
      sourceProjectId !== undefined
      && (currentRoute !== "project-settings" || currentProject?.id !== sourceProjectId)
    ) return false;
    projectLoadGuard.invalidate();
    useRecognitionStore.getState().reset();
    useSlateStore.getState().clearInput();
    useExportStore.getState().clear();
    useMetadataStore.getState().clear();
    useTaskStore.getState().clear();
    useSettingsStore.getState().clearProject();
    // Match the retained compatibility route: the Library may show which
    // project was current, while workspace-owned data is already released.
    // Reopening still reloads full project authority from Main.
    navigateTo("projects");
    return true;
  };

  const performLeaveProject = async () => {
    const navigationIntent = ++navigationIntentRef.current;
    if (useUiStore.getState().route === "projects") return;
    const owner = acquireWorkspaceOperation("transfer", useProjectStore.getState().current?.id || "library");
    if (!owner) {
      setToast({ tone: "warning", message: "任务处理中，请等待完成或先停止识别。" });
      return;
    }
    try {
      if (!(await prepareWorkspaceForTransfer(owner))) return;
      if (navigationIntentRef.current !== navigationIntent) return;
      releaseWorkspaceForLibrary();
    } finally { owner.release(); }

  };

  const leaveProject = async () => {
    // 全局设置脏草稿同样保护项目库入口：先确认再走后续清理，否则用户取消时
    // 工作区 store 已被释放。
    if (isRouteChangeBlocked(useUiStore.getState().route, "projects")) {
      setPendingRoute("projects");
      return;
    }
    await performLeaveProject();
  };

  const leaveDeletedProject = (projectId: string) => {
    useSettingsStore.getState().clearProject();
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
    navigateTo("projects");
  };

  // 守卫恢复的是原始导航语义：项目库入口仍需经过自动保存与 workspace 清理，
  // 其他目标才是普通路由切换。
  const continuePendingNavigation = async (target: Parameters<typeof setRoute>[0]) => {
    if (target === "projects") {
      await performLeaveProject();
      return;
    }
    navigateTo(target);
  };

  // 两类设置离开守卫对话框的三条出路：取消留在设置页；放弃清除草稿后继续；
  // 保存成功后继续，失败留在对话框并展示保存错误。保存中的对话框不可取消，
  // 避免已发出的持久化请求在用户选择放弃后仍完成并跳转。
  const cancelPendingNavigation = () => {
    if (isGuardSaving()) return;
    setPendingRoute(null);
  };

  const discardChangesAndLeave = () => {
    if (isGuardSaving()) return;
    if (useUiStore.getState().route === "global-settings" && useGlobalSettingsStore.getState().mutationOwner) return;
    const target = pendingRoute;
    if (!target) return;
    if (useUiStore.getState().route === "project-settings") useSettingsStore.getState().discardProject();
    else useGlobalSettingsStore.getState().discardDraft();
    setPendingRoute(null);
    void continuePendingNavigation(target);
  };

  const saveChangesAndLeave = async () => {
    if (isGuardSaving()) return;
    if (useUiStore.getState().route === "global-settings" && useGlobalSettingsStore.getState().mutationOwner) return;
    const target = pendingRoute;
    if (!target) return;
    const origin = useUiStore.getState().route;
    const sourceProjectId = useProjectStore.getState().current?.id;
    const saved = origin === "project-settings" ? await saveProjectSettingsChanges() : await saveGlobalSettingsChanges();
    if (!saved || useUiStore.getState().route !== origin || useProjectStore.getState().current?.id !== sourceProjectId) return;
    setPendingRoute(null);
    await continuePendingNavigation(target);
  };

  const navigation = <>
    <div className={styles.navSection} data-collapsed={sidebarCollapsed || undefined}>项目</div>
    <button type="button" className={styles.navItem} data-active={route === "projects"} data-collapsed={sidebarCollapsed || undefined} title="项目库" onClick={leaveProject} onContextMenu={(event) => { event.preventDefault(); event.stopPropagation(); setLibraryMenu({ open: true, x: event.clientX, y: event.clientY }); }}><Icon icon={FolderKanban} size={18} /><span>项目库</span></button>
    {project && <><div className={`${styles.navSection} ${styles.navSectionCurrent}`} data-collapsed={sidebarCollapsed || undefined}><span>当前项目</span><span className={styles.navSectionProject} title={project.name}>{project.name}</span></div><button type="button" className={styles.navItem} data-active={route === "workspace"} data-collapsed={sidebarCollapsed || undefined} title="工作台" onClick={() => navigateTo("workspace")}><Icon icon={LayoutDashboard} size={18} /><span>工作台</span></button><button type="button" className={styles.navItem} data-active={route === "project-settings"} data-collapsed={sidebarCollapsed || undefined} title="项目设置" onClick={() => navigateTo("project-settings")}><Icon icon={SlidersHorizontal} size={18} /><span>项目设置</span></button></>}
    <div style={{ flex: 1 }} />
    <div className={styles.navSection} data-collapsed={sidebarCollapsed || undefined}>系统</div><button type="button" className={styles.navItem} data-active={route === "logs"} data-collapsed={sidebarCollapsed || undefined} title="日志" onClick={() => navigateTo("logs")}><Icon icon={ScrollText} size={18} /><span>日志</span></button><button type="button" className={styles.navItem} data-active={route === "global-settings"} data-collapsed={sidebarCollapsed || undefined} title="全局设置" ref={globalSettingsTriggerRef} onClick={openGlobalSettings}><Icon icon={Settings} size={18} /><span>全局设置</span></button>{route === "global-settings" && <GlobalSettingsSidebarNav activeSection={settingsSection} onSelect={setSettingsSection} collapsed={sidebarCollapsed} parentTriggerRef={globalSettingsTriggerRef} />}<button type="button" className={styles.navItem} data-active={route === "help"} data-collapsed={sidebarCollapsed || undefined} title="说明" onClick={() => navigateTo("help")}><Icon icon={BookOpen} size={18} /><span>说明</span></button>
  </>;

  // The App Icon is the shell-level home action. Reusing leaveProject keeps
  // recognition guards and workspace cleanup identical to the Library item.
  const sidebar = <Sidebar brand={<><button type="button" className={styles.brandHomeButton} aria-label="返回项目库" title="返回项目库" onClick={leaveProject}><img className={styles.brandIcon} src={appIconUrl} alt="" aria-hidden="true" draggable={false} /></button><span className={styles.brandCopy} data-collapsed={sidebarCollapsed || undefined}><strong>SlateSync</strong></span></>} navigation={navigation} footer={<><IconButton label={sidebarCollapsed ? "展开侧栏" : "收起侧栏"} size="sm" onClick={toggleSidebar}>{sidebarCollapsed ? <PanelLeftOpen size={16} /> : <PanelLeftClose size={16} />}</IconButton><Button className={styles.sidebarThemeButton} data-collapsed={sidebarCollapsed || undefined} aria-label={themeButtonLabel} title={themeButtonLabel} variant="ghost" size="sm" startIcon={themeIcon} onClick={() => setTheme(nextTheme)}>{themePreferenceLabel(theme)}</Button></>} />;
  // 顶部栏副标题仅在工作台 / 项目设置 / 全局设置展示当前项目名；项目库页只显示“项目库”，当前项目名仅由左侧导航栏维护。
  const showsProjectSubtitle = route === "workspace" || route === "project-settings" || route === "global-settings";
  const toolbarActions = <>
    {route === "workspace" && project && <Button size="sm" onClick={() => workspaceExportRef.current?.()} disabled={!workspaceExportState.canExport} loading={workspaceExportState.processing} startIcon={<Download size={15} />}>导出 Resolve CSV</Button>}
    <Button variant="ghost" size="sm" onClick={() => setDensity(density === "compact" ? "comfortable" : "compact")}>{density === "compact" ? "标准密度" : "紧凑密度"}</Button>
  </>;
  const toolbar = <Toolbar title={routeTitle(route)} {...(project?.name && showsProjectSubtitle ? { subtitle: project.name } : {})} actions={toolbarActions} />;
  // The same visible actions serve the expert context menu and the accessible
  // settings dialog, keeping labels, pending states, and outcomes identical.
  const renderLibraryActions = () => <>
    <Button variant="ghost" size="sm" onClick={() => void runLibraryAction("import")} disabled={libraryBusy !== null} loading={libraryBusy === "import"} startIcon={<Import size={14} />}>导入项目库</Button>
    <Button variant="ghost" size="sm" onClick={() => void runLibraryAction("export")} disabled={libraryBusy !== null} loading={libraryBusy === "export"} startIcon={<PackageOpen size={14} />}>导出项目库</Button>
    <Button variant="ghost" size="sm" onClick={() => void runLibraryAction("change")} disabled={libraryBusy !== null} loading={libraryBusy === "change"} startIcon={<MapPin size={14} />}>更换位置</Button>
    <Button variant="ghost" size="sm" onClick={openRenameDialog} disabled={libraryBusy !== null} loading={libraryBusy === "rename"} startIcon={<PencilLine size={14} />}>改名项目库</Button>
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

  // 被拦截的路由切换以对话框收口；草稿在 store 中保留，取消或失败都不丢编辑。
  const pendingRouteDialog = pendingRoute && <Dialog
    open
    title="有未保存的修改"
    description={route === "project-settings" ? "项目设置还有未保存的修改，请保存或放弃后离开。" : "全局设置还有未保存的修改；草稿会保留，请保存或放弃后离开。"}
    onClose={cancelPendingNavigation}
    dismissible={!guardSaving}
    footer={<Stack direction="row" gap={2} justify="end">
      <Button variant="ghost" onClick={cancelPendingNavigation} disabled={guardSaving}>取消</Button>
      <Button variant="danger" onClick={discardChangesAndLeave} disabled={guardWriteBusy}>放弃修改并离开</Button>
      <Button loading={guardSaving} disabled={guardWriteBusy} onClick={() => void saveChangesAndLeave()}>保存并离开</Button>
    </Stack>}
  >
    {guardError && <InlineError message={guardError} />}
    {guardWriteBusy && !guardSaving && <Text tone="muted" size="sm">请等待当前配置写入完成后再保存或放弃修改。</Text>}
  </Dialog>;

  if (booting) return <div data-testid="modern-shell" className={styles.bootScreen}><div><Text as="p" size="lg" weight="bold">正在准备 SlateSync</Text><Text tone="subtle" size="sm">正在读取项目…</Text></div></div>;
  // Keep one Workspace instance mounted while Logs, Help, or either settings page is
  // visible. Its draft, image inputs, CSV Worker and in-flight recognition
  // stay intact; the hidden page is excluded from the accessibility tree.
  return <div data-testid="modern-shell"><AppShell collapsed={sidebarCollapsed} sidebar={sidebar} toolbar={toolbar}><main ref={mainRef} id="main-content" className={styles.appMain} tabIndex={-1} aria-label={routeTitle(route)}>{project && route !== "projects" && <WorkspacePage registerToolbarExport={registerWorkspaceToolbarExport} registerTransferPreparation={registerWorkspaceTransferPreparation} hidden={route !== "workspace"} />}{route === "projects" && <ProjectLibraryPage onOpenProject={(id, nextRoute) => void openProject(id, nextRoute)} onOpenLibrarySettings={() => setLibraryDialog("settings")} />}{route === "project-settings" && <ProjectSettingsPage onBack={() => navigateTo("workspace")} onDeleted={leaveDeletedProject} onPrepareTransfer={prepareWorkspaceForTransfer} onProjectImported={releaseWorkspaceForLibrary} />}{route === "global-settings" && <GlobalSettingsPage />}{route === "logs" && <LogViewerPage />}{route === "help" && <HelpPage />}</main></AppShell>{libraryMenuNode}{libraryDialogNode}{pendingRouteDialog}{toast && <Toast message={toast.message} tone={toast.tone} onDismiss={() => setToast(null)} />}</div>;
}

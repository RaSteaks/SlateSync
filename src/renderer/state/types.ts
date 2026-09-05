import type {
  AppError,
  ConfigData,
  DirectorySelection,
  GlobalSettingKey,
  GlobalSettingsData,
  GlobalSettingValues,
  LibraryInfo,
  ModelDiscoveryResult,
  OcrSettings,
  ProjectData,
  ProjectSettings,
  ProjectSummary,
  ProgressData,
  RecognitionData,
  RecognitionRecord,
  ResolveCsvEdits,
  ResolveCsvTable,
  ScanResult,
  ScenarioSummary,
  SlateCsvRecord,
  TaskData,
  TaskListItem,
} from "../../shared/contracts/index.js";

export type Route = "projects" | "workspace" | "project-settings" | "global-settings" | "logs" | "help";
export type Theme = "system" | "dark" | "light";
export type Density = "comfortable" | "compact";
/** Anchor sections of the Global Settings page, addressed by the sidebar sub-nav. */
export type SettingsSectionId = "settings-general" | "settings-custom-providers" | "settings-ocr" | "settings-runtime";

export interface ProjectSlice {
  config: ConfigData | null;
  library: LibraryInfo | null;
  projects: readonly ProjectSummary[];
  current: ProjectData | null;
  scenarios: readonly ScenarioSummary[];
  modelDiscovery: Readonly<Record<string, ModelDiscoveryResult>>;
  loading: boolean;
  error: AppError | null;
  setConfig(config: ConfigData): void;
  setLibrary(library: LibraryInfo | null): void;
  setProjects(projects: readonly ProjectSummary[]): void;
  setCurrent(project: ProjectData | null): void;
  setScenarios(scenarios: readonly ScenarioSummary[]): void;
  setModelDiscovery(providerId: string, result: ModelDiscoveryResult): void;
  setLoading(loading: boolean): void;
  setError(error: AppError | null): void;
}

export interface UiSlice {
  route: Route;
  theme: Theme;
  density: Density;
  sidebarCollapsed: boolean;
  toast: { message: string; tone: "neutral" | "accent" | "success" | "warning" | "danger" } | null;
  dialog: "new-project" | "ocr" | null;
  /** Global-settings section the sidebar sub-nav scrolled to; null = page top. */
  settingsSection: SettingsSectionId | null;
  settingsSectionRequest: number;
  setRoute(route: Route): void;
  setTheme(theme: Theme): void;
  setDensity(density: Density): void;
  setSettingsSection(section: SettingsSectionId | null): void;
  hydrateAppearance(appearance: { readonly theme: Theme; readonly density: Density }): void;
  toggleSidebar(): void;
  setToast(toast: UiSlice["toast"]): void;
  setDialog(dialog: UiSlice["dialog"]): void;
}

export interface SlateSlice {
  filename: string | null;
  fileType: string | null;
  fileSize: number;
  pageCount: number;
  imageDataGroups: readonly (readonly string[])[];
  preparing: boolean;
  preparationProgress: number;
  preparationMessage: string;
  error: AppError | null;
  setInput(input: { filename: string; fileType: string; fileSize: number; pageCount: number; imageDataGroups: readonly (readonly string[])[] }): void;
  clearInput(): void;
  setPreparing(preparing: boolean, progress?: number, message?: string): void;
  setError(error: AppError | null): void;
}

export interface RecognitionSlice {
  operationId: number;
  projectId: string | null;
  taskId: string | null;
  /** Whether the workspace should rehydrate this global run after a log detour. */
  resumeOnWorkspace: boolean;
  running: boolean;
  phase: string;
  percent: number;
  completedPages: number;
  totalPages: number;
  message: string;
  warning: string | null;
  data: RecognitionData | null;
  records: readonly RecognitionRecord[];
  error: AppError | null;
  start(operationId: number, projectId: string | null, totalPages: number, taskId?: string | null): void;
  setTaskId(taskId: string | null): void;
  markWorkspaceHandoff(projectId?: string | null, taskId?: string | null): void;
  clearWorkspaceHandoff(): void;
  progress(operationId: number, event: ProgressData): void;
  complete(operationId: number, data: RecognitionData): void;
  requestCancel(operationId: number): void;
  cancel(operationId: number): void;
  cancelRequestFailed(operationId: number): void;
  updateRecord(index: number, patch: Partial<RecognitionRecord>): void;
  addRecord(record: RecognitionRecord): void;
  removeRecord(index: number): void;
  fail(operationId: number, error: AppError): void;
  reset(): void;
}

export interface MetadataSlice {
  directory: DirectorySelection | null;
  result: ScanResult | null;
  scanning: boolean;
  error: AppError | null;
  setDirectory(directory: DirectorySelection | null): void;
  setScanning(scanning: boolean): void;
  setResult(result: ScanResult | null): void;
  setError(error: AppError | null): void;
  clear(): void;
}

export interface TaskSlice {
  /** A synchronous lease covers preparation, requests and their final cleanup. */
  operation: { id: number; kind: WorkspaceOperationKind; projectId: string } | null;
  beginOperation(kind: WorkspaceOperationKind, projectId: string): number | null;
  endOperation(id: number): void;
  items: readonly TaskListItem[];
  /** Project ID represented by items; null means no project list has been loaded. */
  loadedProjectId: string | null;
  activeId: string | null;
  active: TaskData | null;
  loading: boolean;
  saveState: "idle" | "dirty" | "saving" | "saved" | "error";
  error: AppError | null;
  setItems(items: readonly TaskListItem[], projectId?: string | null): void;
  setActive(id: string | null, task: TaskData | null): void;
  setLoading(loading: boolean): void;
  setSaveState(saveState: TaskSlice["saveState"]): void;
  setError(error: AppError | null): void;
  clear(): void;
}

export interface ExportSlice {
  table: ResolveCsvTable | null;
  /** Worker-derived table shown in the preview; the raw table remains the export source. */
  previewTable: ResolveCsvTable | null;
  filename: string | null;
  edits: ResolveCsvEdits;
  slateCsvRecords: readonly SlateCsvRecord[] | null;
  slateCsvFilename: string | null;
  processing: boolean;
  error: AppError | null;
  setTable(table: ResolveCsvTable | null, filename?: string | null): void;
  setPreviewTable(table: ResolveCsvTable | null): void;
  setEdit(key: `${number}:${number}`, value: string): void;
  setEdits(edits: ResolveCsvEdits): void;
  setSlateCsvRecords(records: readonly SlateCsvRecord[] | null, filename?: string | null): void;
  setProcessing(processing: boolean): void;
  setError(error: AppError | null): void;
  clear(): void;
}

export type WorkspaceOperationKind = "recognition" | "merge" | "input" | "new" | "switch" | "delete" | "transfer";

export type ProjectSettingsDraft = { name: string; description: string; settings: ProjectSettings };

export interface SettingsSlice {
  ocr: OcrSettings | null;
  setOcr(ocr: OcrSettings | null): void;
  projectId: string | null;
  baseline: ProjectSettingsDraft | null;
  draft: ProjectSettingsDraft | null;
  dirty: boolean;
  saving: boolean;
  saveError: string | null;
  hydrateProject(projectId: string, draft: ProjectSettingsDraft): void;
  patchProject(patch: Partial<ProjectSettingsDraft>): void;
  discardProject(): void;
  clearProject(): void;
}

export type GlobalSaveState = "idle" | "saving" | "saved" | "error";

/**
 * Device-level settings draft that outlives the GlobalSettingsPage mount.
 * `saved` mirrors the last server snapshot while `draftValues` only stores
 * keys the user actually moved away from it, so a navigation detour keeps the
 * edit session and the dirty count stays honest (reverting a field removes it
 * again instead of storing an inherited default as an override).
 */
export interface GlobalSettingsSlice {
  /** Independent endpoints that write the same settings snapshot serialize here. */
  mutationOwner: "global" | "key" | "ocr" | "install" | null;
  beginMutation(owner: NonNullable<GlobalSettingsSlice["mutationOwner"]>): boolean;
  endMutation(owner: NonNullable<GlobalSettingsSlice["mutationOwner"]>): void;
  saved: GlobalSettingsData | null;
  draftValues: Partial<GlobalSettingValues>;
  dirtyKeys: ReadonlySet<GlobalSettingKey>;
  fieldErrors: Partial<Record<GlobalSettingKey, string>>;
  saveState: GlobalSaveState;
  saveError: string | null;
  setDraftValue(key: GlobalSettingKey, value: string): void;
  setDraftValues(patch: Partial<Record<GlobalSettingKey, string>>): void;
  clearDirtyKey(key: GlobalSettingKey): void;
  adoptServerSnapshot(saved: GlobalSettingsData): void;
  mergeSaved(values: Partial<GlobalSettingValues>, overridesAdd?: readonly GlobalSettingKey[]): void;
  setKeyConfigured(providerId: string, configured: boolean): void;
  discardDraft(): void;
  setFieldError(key: GlobalSettingKey, message: string | null): void;
  setSaveState(saveState: GlobalSettingsSlice["saveState"]): void;
  setSaveError(message: string | null): void;
  /** Test-only full reset; production code uses adopt/discard instead. */
  clear(): void;
}

// Renderer UI — the SlateSync single-page application.
//
// Owns the page state machine, DOM wiring, and all user interactions: the
// Electron Project Library, project-scoped settings/tasks/Profiles, slate
// recognition, material metadata scanning, CSV backfill editing, and OCR
// setup. All backend operations cross the context-isolated Electron preload
// bridge in public/electron-bridge.js.
import {
  buildSlateMetadataIndex,
  canonicalMaterialKey,
  canonicalResolveComment,
  collectResolveMaterialKeys,
  detectSlateSequenceAnomalies,
  materialPrefix,
  mergeSlateIntoResolveTable,
  normalizeSceneValue,
  normalizeShotValue,
  normalizeTakeValue,
  resolveColumnIndexes,
} from "./resolve-csv.js";
import {
  restoreCsvPreviewState,
  serializeCsvPreviewState,
} from "./task-persistence.js";
import { createCsvTaskProcessor } from "./csv-background-tasks.js";
import { createCsvWorkerClient } from "./csv-worker-client.js";
import {
  calculateCoreColumnWidth,
  calculateDetailSegments,
  findDenseRowBand,
} from "./image-preprocess.js";
import {
  canExportResolveCsv,
  canLoadResolveCsv,
  canLoadSlateCsv,
  canSelectSlateDirectory,
  canStartRecognition,
  canMergeSlateCsv,
  shouldResetSlateCsvResults,
} from "./workflow-state.js";
import {
  fetchConfig,
  listProjectsApi,
  getLibraryInfoApi,
  importProjectLibraryApi,
  exportProjectLibraryApi,
  changeLibraryLocationApi,
  createProjectApi,
  loadProjectApi,
  updateProjectApi,
  archiveProjectApi,
  restoreProjectApi,
  listScenariosApi,
  saveProviderKeyApi,
  fetchModelsApi,
  recognizeApi,
  downloadFileApi,
  pickDirectoryApi,
  scanSlateDirectoryApi,
  listTasksApi,
  loadTaskApi,
  saveTaskApi,
  deleteTaskApi,
  getGlobalSettingsApi,
  getOcrSettingsApi,
  saveGlobalSettingsApi,
  saveOcrSettingsApi,
  checkOcrApi,
} from "./electron-bridge.js";
import {
  REQUEST_COMPRESSION_PROFILES,
  requestBodyBytes,
  requestBodyFits,
  selectRecognitionImageGroups,
  serializeRecognitionRequest as serializeRecognitionPayload,
} from "./recognition-request.js";
import { createLatestOperation } from "./operation-token.js";
import { createTaskAutosave } from "./task-autosave.js";
import * as pdfjsLib from "./vendor/pdfjs/pdf.mjs";

pdfjsLib.GlobalWorkerOptions.workerSrc = "./vendor/pdfjs/pdf.worker.mjs";
const PDF_PREPARE_CONCURRENCY = 1;
const MAX_DISCOVERED_MODELS = 24;
const OPENROUTER_PRIMARY_MODELS = 10;

const csvWorker = createCsvWorkerClient();
const fallbackCsvProcessor = createCsvTaskProcessor();

const state = {
  config: null,
  providerModels: {},
  modelDiscovery: {},
  modelRequestId: 0,
  reportFile: null,
  metadataFile: null,
  metadataTable: null,
  slateMetadata: [],
  slateWarnings: [],
  slateScanning: false,
  recognizing: false,
  exporting: false,
  exportButtonEnabledBeforeBusy: false,
  imageDataGroups: [],
  pageCount: 0,
  records: [],
  latestResponse: null,
  scenarioProfiles: [],
  progressPercent: 0,
  currentTaskId: null,
  tasks: [],
  slateCsvRecords: null,
  slateCsvFileName: null,
  ocrSettings: null,
  globalSettings: null,
  globalSettingsDraft: {},
  globalSettingsDirty: new Set(),
  globalSettingsLoading: false,
  csvEdits: new Map(),
  detailSort: { field: null, direction: 1 },
  detailSearch: "",
  missingMetadataKeys: new Set(),
  currentProjectId: null,
  currentProject: null,
  projects: [],
  libraryInfo: null,
  route: "projects",
  activeTaskSettings: null,
};

const elements = {
  apiStatus: document.querySelector("#api-status"),
  provider: document.querySelector("#provider-select"),
  model: document.querySelector("#model-select"),
  accuracyMode: document.querySelector("#accuracy-mode-select"),
  accuracyModeNote: document.querySelector("#accuracy-mode-note"),
  scenario: document.querySelector("#scenario-select"),
  modelRefresh: document.querySelector("#model-refresh"),
  modelNote: document.querySelector("#model-note"),
  metadataDropzone: document.querySelector("#metadata-dropzone"),
  metadataInput: document.querySelector("#metadata-input"),
  metadataHelp: document.querySelector("#metadata-help"),
  metadataCard: document.querySelector("#metadata-card"),
  metadataFileName: document.querySelector("#metadata-file-name"),
  metadataFileMeta: document.querySelector("#metadata-file-meta"),
  removeMetadata: document.querySelector("#remove-metadata"),
  slateDirectoryButton: document.querySelector("#slate-directory-button"),
  slateHelp: document.querySelector("#slate-help"),
  slateDropzone: document.querySelector("#slate-directory-button"),
  slateCard: document.querySelector("#slate-card"),
  slateDirectoryName: document.querySelector("#slate-directory-name"),
  slateFileMeta: document.querySelector("#slate-file-meta"),
  slateStatus: document.querySelector("#slate-status"),
  removeSlates: document.querySelector("#remove-slates"),
  dropzone: document.querySelector("#dropzone"),
  imageInput: document.querySelector("#image-input"),
  fileCard: document.querySelector("#file-card"),
  fileThumb: document.querySelector("#file-thumb"),
  fileName: document.querySelector("#file-name"),
  fileMeta: document.querySelector("#file-meta"),
  removeFile: document.querySelector("#remove-file"),
  recognizeButton: document.querySelector("#recognize-button"),
  error: document.querySelector("#error-message"),
  emptyPreview: document.querySelector("#empty-preview"),
  previewScroll: document.querySelector("#preview-scroll"),
  processing: document.querySelector("#processing-overlay"),
  progress: document.querySelector("#recognition-progress"),
  progressBar: document.querySelector("#recognition-progress-bar"),
  progressStage: document.querySelector("#recognition-progress-stage"),
  progressPercent: document.querySelector("#recognition-progress-percent"),
  results: document.querySelector("#results-section"),
  resultSummary: document.querySelector("#result-summary"),
  warningList: document.querySelector("#warning-list"),
  metrics: document.querySelector("#metrics"),
  csvPreviewSummary: document.querySelector("#csv-preview-summary"),
  csvResultHead: document.querySelector("#csv-result-head"),
  csvResultBody: document.querySelector("#csv-result-body"),
  csvResultEmpty: document.querySelector("#csv-result-empty"),
  resultBody: document.querySelector("#result-body"),
  addRow: document.querySelector("#add-row"),
  detailSearch: document.querySelector("#detail-search"),
  exportButton: document.querySelector("#export-button"),
  tabCsv: document.querySelector("#tab-csv"),
  tabDetail: document.querySelector("#tab-detail"),
  tabCsvBadge: document.querySelector("#tab-csv-badge"),
  tabDetailBadge: document.querySelector("#tab-detail-badge"),
  tabWarningDot: document.querySelector("#tab-warning-dot"),
  panelCsv: document.querySelector("#panel-csv"),
  panelDetail: document.querySelector("#panel-detail"),
  providerKeyField: document.querySelector("#provider-key-field"),
  apiKeyInput: document.querySelector("#api-key-input"),
  saveKeyButton: document.querySelector("#save-key-button"),
  apiKeyNote: document.querySelector("#api-key-note"),
  customPromptInput: document.querySelector("#custom-prompt-input"),
  taskSwitcher: document.querySelector("#task-switcher"),
  taskSelect: document.querySelector("#task-select"),
  taskDelete: document.querySelector("#task-delete"),
  taskSaveStatus: document.querySelector("#task-save-status"),
  taskSaveRetry: document.querySelector("#task-save-retry"),
  slateCsvDropzone: document.querySelector("#slate-csv-dropzone"),
  slateCsvInput: document.querySelector("#slate-csv-input"),
  slateCsvHelp: document.querySelector("#slate-csv-help"),
  slateCsvCard: document.querySelector("#slate-csv-card"),
  slateCsvFileName: document.querySelector("#slate-csv-file-name"),
  slateCsvFileMeta: document.querySelector("#slate-csv-file-meta"),
  removeSlateCsv: document.querySelector("#remove-slate-csv"),
  optionalInputs: document.querySelector("#optional-inputs"),
  supportDataState: document.querySelector("#support-data-state"),
  recognizeHint: document.querySelector("#recognize-hint"),
  previewPanel: document.querySelector(".preview-panel"),
  previewStatus: document.querySelector("#preview-status"),
  ocrSetupLink: document.querySelector("#ocr-setup-link"),
  ocrSetupOverlay: document.querySelector("#ocr-setup-overlay"),
  ocrSetupClose: document.querySelector("#ocr-setup-close"),
  ocrPythonPath: document.querySelector("#ocr-python-path"),
  ocrCheckResult: document.querySelector("#ocr-check-result"),
  ocrCheckButton: document.querySelector("#ocr-check-button"),
  ocrSaveButton: document.querySelector("#ocr-save-button"),
  ocrSkipButton: document.querySelector("#ocr-skip-button"),
  appNav: document.querySelector("#app-nav"),
  currentProjectNav: document.querySelector("#current-project-nav"),
  navProjects: document.querySelector("#nav-projects"),
  navWorkspace: document.querySelector("#nav-workspace"),
  navProjectSettings: document.querySelector("#nav-project-settings"),
  navGlobalSettings: document.querySelector("#nav-global-settings"),
  workspacePage: document.querySelector("#workspace-page"),
  projectHomePage: document.querySelector("#project-home-page"),
  projectSettingsPage: document.querySelector("#project-settings-page"),
  globalSettingsPage: document.querySelector("#global-settings-page"),
  libraryLocation: document.querySelector("#library-location"),
  projectGrid: document.querySelector("#project-grid"),
  archivedProjectGrid: document.querySelector("#archived-project-grid"),
  projectEmpty: document.querySelector("#project-empty"),
  activeProjectCount: document.querySelector("#active-project-count"),
  archivedProjectCount: document.querySelector("#archived-project-count"),
  projectHomeError: document.querySelector("#project-home-error"),
  libraryActionStatus: document.querySelector("#library-action-status"),
  importLibraryButton: document.querySelector("#import-library-button"),
  exportLibraryButton: document.querySelector("#export-library-button"),
  changeLibraryLocationButton: document.querySelector("#change-library-location-button"),
  newProjectButton: document.querySelector("#new-project-button"),
  projectEmptyCreate: document.querySelector("#project-empty-create"),
  projectSettingsBack: document.querySelector("#project-settings-back"),
  projectSettingsForm: document.querySelector("#project-settings-form"),
  projectSettingsHeading: document.querySelector("#project-settings-heading"),
  projectNameInput: document.querySelector("#project-name-input"),
  projectDescriptionInput: document.querySelector("#project-description-input"),
  projectProvider: document.querySelector("#project-provider-select"),
  projectModel: document.querySelector("#project-model-select"),
  projectAccuracy: document.querySelector("#project-accuracy-mode-select"),
  projectScenario: document.querySelector("#project-scenario-select"),
  projectCustomPrompt: document.querySelector("#project-custom-prompt-input"),
  projectSceneFormat: document.querySelector("#project-scene-format"),
  projectShotFormat: document.querySelector("#project-shot-format"),
  projectTakeFormat: document.querySelector("#project-take-format"),
  projectGoodComment: document.querySelector("#project-good-comment"),
  projectHoldComment: document.querySelector("#project-hold-comment"),
  projectSettingsReset: document.querySelector("#project-settings-reset"),
  projectSettingsStatus: document.querySelector("#project-settings-status"),
  globalProvider: document.querySelector("#global-provider-select"),
  globalApiKeyInput: document.querySelector("#global-api-key-input"),
  globalSaveKeyButton: document.querySelector("#global-save-key-button"),
  globalApiKeyNote: document.querySelector("#global-api-key-note"),
  globalSettingsFields: document.querySelector("#global-settings-fields"),
  globalSettingsCount: document.querySelector("#global-settings-count"),
  globalSettingsStatus: document.querySelector("#global-settings-status"),
  globalSettingsSave: document.querySelector("#global-settings-save"),
  globalSettingsReset: document.querySelector("#global-settings-reset"),
  globalOcrOpen: document.querySelector("#global-ocr-open"),
  globalOcrStatus: document.querySelector("#global-ocr-status"),
  projectContext: document.querySelector("#project-context"),
  projectDialog: document.querySelector("#project-dialog"),
  projectDialogForm: document.querySelector("#project-dialog-form"),
  projectDialogClose: document.querySelector("#project-dialog-close"),
  projectDialogCancel: document.querySelector("#project-dialog-cancel"),
  newProjectName: document.querySelector("#new-project-name"),
  newProjectDescription: document.querySelector("#new-project-description"),
};

const libraryOperations = createLatestOperation();
const projectOperations = createLatestOperation();
const projectModelOperations = createLatestOperation();
const taskOperations = createLatestOperation();
const taskListOperations = createLatestOperation();
const legacyModelPickers = new Map();
let allowWindowClose = false;

const taskAutosave = createTaskAutosave({
  delayMs: 500,
  capture: captureCurrentTaskSave,
  save: ({ projectId, task }) => saveTaskApi(task, projectId),
  onStatus: renderTaskSaveStatus,
});

init();

async function init() {
  bindEvents();
  try {
    await loadConfig();
    renderSlateDirectoryConfig();
    renderProviderOptions();
    renderModelOptions();
    renderApiStatus();
    renderOcrSetupLink();
    await maybeShowOcrSetup();
    updateExportState();
    updateMetadataInputState();
    updateSlateDirectoryState();
    await loadProviderModels();
    renderGlobalProviderOptions();
    await loadGlobalSettings();
    await refreshLibrary();
    renderRoute();
  } catch {
    showError("无法读取应用配置，请重启 SlateSync。");
  }
}

async function loadConfig() {
  state.config = await fetchConfig();
  renderScenarioOptions();
}

async function refreshScenarioProfiles(projectId = state.currentProjectId) {
  try {
    state.scenarioProfiles = await listScenariosApi(projectId);
    renderScenarioOptions();
  } catch {
    // Profile listing is advisory; recognition remains usable if it is unavailable.
    state.scenarioProfiles = [];
    renderScenarioOptions();
  }
}

function renderScenarioOptions(
  selectedId = elements.projectScenario?.value
    || elements.scenario?.value
    || state.currentProject?.settings?.scenarioId
    || "",
  includeProjectSelect = true,
  includeWorkspaceSelect = true,
) {
  const options = [
    '<option value="">自动识别并学习版式</option>',
    ...state.scenarioProfiles.map((profile) => {
      const sampleCount = Number(profile.sampleCount) || 0;
      const label = `${profile.label || "未命名结构"}${sampleCount ? ` · 已用 ${sampleCount} 次` : ""}`;
      return `<option value="${escapeHtml(profile.id)}">${escapeHtml(label)}</option>`;
    }),
  ];
  const selected = state.scenarioProfiles.some(
    (profile) => profile.id === selectedId,
  ) ? selectedId : "";
  for (const select of [
    includeWorkspaceSelect ? elements.scenario : null,
    includeProjectSelect ? elements.projectScenario : null,
  ]) {
    if (!select) continue;
    select.innerHTML = options.join("");
    select.value = selected;
  }
}

async function refreshRuntimeConfig() {
  try {
    await loadConfig();
  } catch {
    // keep the last known config when a refresh fails
  }
}

function navigate(route) {
  state.route = route;
  renderRoute();
  if (route === "projects") void refreshLibrary();
}

async function refreshLibrary() {
  const token = libraryOperations.start();
  try {
    const [libraryInfo, projects] = await Promise.all([
      getLibraryInfoApi(),
      listProjectsApi(),
    ]);
    if (!libraryOperations.isCurrent(token)) return false;
    state.libraryInfo = libraryInfo;
    state.projects = projects;
    renderProjectLibrary();
    return true;
  } catch (error) {
    if (libraryOperations.isCurrent(token)) {
      showProjectHomeError(error.message || "无法刷新项目库。");
    }
    return false;
  }
}

function renderRoute() {
  elements.appNav.hidden = false;
  elements.workspacePage.hidden = state.route !== "workspace";
  elements.projectHomePage.hidden = state.route !== "projects";
  elements.projectSettingsPage.hidden = state.route !== "project-settings";
  elements.globalSettingsPage.hidden = state.route !== "global-settings";
  elements.currentProjectNav.hidden = !state.currentProject;

  for (const [button, active] of [
    [elements.navProjects, state.route === "projects"],
    [elements.navWorkspace, state.route === "workspace"],
    [elements.navProjectSettings, state.route === "project-settings"],
    [elements.navGlobalSettings, state.route === "global-settings"],
  ]) {
    button?.classList.toggle("is-active", active);
  }

  if (state.route === "project-settings") renderProjectSettingsForm();
  if (state.route === "global-settings" && !state.globalSettings) void loadGlobalSettings();
  if (state.route === "global-settings") renderGlobalSettingsForm();
  updateProjectContextLabel();
}

async function openProject(projectId, nextRoute = "workspace") {
  const token = projectOperations.start();
  projectModelOperations.invalidate();
  taskOperations.invalidate();
  taskListOperations.invalidate();
  hideProjectHomeError();
  if (state.recognizing && projectId !== state.currentProjectId) {
    showProjectHomeError("识别进行中，完成后才能切换项目。");
    return;
  }
  try {
    if (projectId !== state.currentProjectId) {
      const saved = await flushPendingTaskSave();
      if (!projectOperations.isCurrent(token) || !saved) return;
    }
    const project = await loadProjectApi(projectId);
    if (!projectOperations.isCurrent(token)) return;
    const [scenarioProfiles, taskData] = await Promise.all([
      listScenariosApi(project.id),
      listTasksApi(project.id),
    ]);
    if (!projectOperations.isCurrent(token)) return;
    const switched = state.currentProjectId !== project.id;
    if (switched) resetProjectWorkspace();
    state.currentProjectId = project.id;
    state.currentProject = project;
    state.scenarioProfiles = Array.isArray(scenarioProfiles) ? scenarioProfiles : [];
    state.tasks = taskListFromResponse(taskData);
    // Reopening settings for the current project must not replace the output
    // snapshot or recognition controls belonging to a loaded historical task.
    if (!state.currentTaskId) applyNewTaskRecognitionDefaults(project);
    renderTaskSwitcher();
    state.route = nextRoute;
    renderRoute();
  } catch (error) {
    if (!projectOperations.isCurrent(token)) return;
    showProjectHomeError(error.message || "无法打开项目。");
    state.route = "projects";
    renderRoute();
  }
}

function resetProjectWorkspace() {
  if (state.recognizing) return;
  state.currentTaskId = null;
  clearReportFile();
  clearResolveCsv();
  resetRecognitionResults();
  state.activeTaskSettings = null;
  taskAutosave.reset();
}

function updateProjectContextLabel() {
  const label = elements.projectContext;
  if (!label) return;
  label.textContent = state.currentProject
    ? `${state.currentProject.name}${isProjectReadOnly() ? " · 只读" : ""}`
    : "未选择项目";
  label.hidden = !state.currentProject;
}

function isProjectReadOnly() {
  // The renderer mirrors the IPC archive guard for immediate feedback; the
  // main process remains authoritative and rechecks the archive flag per call.
  return Boolean(state.currentProject?.archivedAt);
}

function renderProjectLibrary() {
  const active = state.projects.filter((project) => !project.archivedAt);
  const archived = state.projects.filter((project) => project.archivedAt);
  elements.libraryLocation.textContent = state.libraryInfo?.path
    ? `${state.libraryInfo.name} · ${state.libraryInfo.path}`
    : "本地 Project Library";
  elements.activeProjectCount.textContent = `${active.length} 个项目`;
  elements.archivedProjectCount.textContent = `${archived.length} 个项目`;
  elements.projectEmpty.hidden = active.length > 0;
  elements.projectGrid.innerHTML = active.map(projectCard).join("");
  elements.archivedProjectGrid.innerHTML = archived.map(projectCard).join("");
}

function projectCard(project) {
  const archived = Boolean(project.archivedAt);
  const current = project.id === state.currentProjectId;
  const latest = project.latestTaskAt ? formatTaskDate(project.latestTaskAt) : "暂无任务";
  return `
    <article class="project-card${current ? " is-current" : ""}${archived ? " is-archived" : ""}" data-project-id="${escapeHtml(project.id)}">
      <button class="project-card-main" type="button" data-project-action="open" data-project-id="${escapeHtml(project.id)}">
        <span class="project-card-mark" aria-hidden="true">${archived ? "□" : "S"}</span>
        <span class="project-card-copy">
          <strong>${escapeHtml(project.name)}</strong>
          <small>${escapeHtml(project.description || "SlateSync Project")}</small>
          <small>${project.taskCount || 0} 个任务 · ${escapeHtml(latest)}</small>
        </span>
      </button>
      <div class="project-card-actions">
        <button class="icon-button" type="button" title="${archived ? "查看项目设置" : "项目设置"}" aria-label="${archived ? "查看项目设置" : "项目设置"}" data-project-action="settings" data-project-id="${escapeHtml(project.id)}">⚙</button>
        ${archived
          ? `<button class="secondary-button compact" type="button" data-project-action="restore" data-project-id="${escapeHtml(project.id)}">恢复</button>`
          : project.canArchive
            ? `<button class="secondary-button compact" type="button" data-project-action="archive" data-project-id="${escapeHtml(project.id)}">归档</button>`
            : ""}
      </div>
    </article>
  `;
}

async function handleProjectCardClick(event) {
  const button = event.target.closest("[data-project-action]");
  if (!button) return;
  const projectId = button.dataset.projectId;
  const action = button.dataset.projectAction;
  if (action === "open" || action === "settings") {
    await openProject(projectId, action === "settings" ? "project-settings" : "workspace");
    return;
  }
  if (action === "archive") {
    if (state.recognizing && state.currentProjectId === projectId) {
      showProjectHomeError("项目正在识别，完成后才能归档。");
      return;
    }
    if (!confirm("归档后项目将变为只读，确定继续吗？")) return;
    try {
      if (state.currentProjectId === projectId && !(await flushPendingTaskSave())) {
        return;
      }
      await archiveProjectApi(projectId);
      if (state.currentProjectId === projectId) {
        state.currentProject = null;
        resetProjectWorkspace();
        state.currentProjectId = null;
      }
      await refreshLibrary();
      state.route = "projects";
      renderRoute();
    } catch (error) {
      showProjectHomeError(error.message || "项目归档失败。");
    }
    return;
  }
  if (action === "restore") {
    try {
      await restoreProjectApi(projectId);
      await refreshLibrary();
      await openProject(projectId, "workspace");
    } catch (error) {
      showProjectHomeError(error.message || "项目恢复失败。");
    }
  }
}

function openProjectDialog() {
  elements.projectDialog.hidden = false;
  elements.newProjectName.value = "";
  elements.newProjectDescription.value = "";
  elements.newProjectName.focus();
}

function closeProjectDialog() {
  elements.projectDialog.hidden = true;
}

async function createProjectFromDialog(event) {
  event.preventDefault();
  try {
    const project = await createProjectApi({
      name: elements.newProjectName.value,
      description: elements.newProjectDescription.value,
    });
    closeProjectDialog();
    await refreshLibrary();
    await openProject(project.id, "workspace");
  } catch (error) {
    showProjectHomeError(error.message || "项目创建失败。");
  }
}

async function exportCurrentLibrary() {
  if (!(await prepareLibraryTransfer())) return;
  setLibraryActionBusy(true);
  try {
    const result = await exportProjectLibraryApi();
    if (!result?.canceled) {
      showLibraryActionStatus(`项目库已导出到 ${result.library.path}`);
    }
  } catch (error) {
    showProjectHomeError(error.message || "项目库导出失败。");
  } finally {
    setLibraryActionBusy(false);
  }
}

async function importProjectLibrary() {
  if (!confirm("导入后将切换到所选 Project Library，并自动重启 SlateSync。是否继续？")) {
    return;
  }
  if (!(await prepareLibraryTransfer())) return;
  setLibraryActionBusy(true);
  try {
    const result = await importProjectLibraryApi();
    if (result?.canceled) setLibraryActionBusy(false);
    else showLibraryActionStatus("正在切换项目库并重启…");
  } catch (error) {
    showProjectHomeError(error.message || "项目库导入失败。");
    setLibraryActionBusy(false);
  }
}

async function changeLibraryLocation() {
  if (!confirm("当前 Project Library 将复制到新位置，原位置会保留。切换后 SlateSync 将自动重启。是否继续？")) {
    return;
  }
  if (!(await prepareLibraryTransfer())) return;
  setLibraryActionBusy(true);
  try {
    const result = await changeLibraryLocationApi();
    if (result?.canceled) setLibraryActionBusy(false);
    else showLibraryActionStatus("正在切换存储位置并重启…");
  } catch (error) {
    showProjectHomeError(error.message || "项目库存储位置修改失败。");
    setLibraryActionBusy(false);
  }
}

async function prepareLibraryTransfer() {
  hideProjectHomeError();
  showLibraryActionStatus("");
  if (state.recognizing) {
    showProjectHomeError("识别进行中，完成后才能操作项目库。");
    return false;
  }
  // Library copies must include the newest manual edits. The autosave flush
  // also keeps a failed local edit visible instead of silently switching away.
  return flushPendingTaskSave();
}

function setLibraryActionBusy(busy) {
  for (const button of [
    elements.importLibraryButton,
    elements.exportLibraryButton,
    elements.changeLibraryLocationButton,
    elements.newProjectButton,
  ]) {
    if (button) button.disabled = busy;
  }
}

function showLibraryActionStatus(message) {
  if (!elements.libraryActionStatus) return;
  elements.libraryActionStatus.textContent = message;
  elements.libraryActionStatus.hidden = !message;
}

function showProjectHomeError(message) {
  elements.projectHomeError.textContent = message;
  elements.projectHomeError.hidden = false;
}

function hideProjectHomeError() {
  elements.projectHomeError.hidden = true;
  elements.projectHomeError.textContent = "";
}

function renderProjectSettingsForm() {
  const project = state.currentProject;
  if (!project || !elements.projectSettingsForm) return;
  const settings = project.settings || defaultRendererProjectSettings();
  elements.projectSettingsHeading.textContent = `${project.name} · 项目设置`;
  elements.projectNameInput.value = project.name || "";
  elements.projectDescriptionInput.value = project.description || "";
  renderProjectProviderOptions(settings.providerId);
  const preserveSavedModel = elements.projectProvider.value === settings.providerId;
  renderProjectModelOptions(settings.modelId, {
    preserveUnknown: preserveSavedModel,
  });
  // Runtime discovery may be the only source for a configured model. Keep the
  // persisted ID visible until the latest request for this project confirms
  // the available options, so unrelated saves cannot replace it silently.
  void loadProviderModelsForSelect(elements.projectProvider, elements.projectModel, {
    selectedModelId: settings.modelId,
    preserveUnknown: preserveSavedModel,
  });
  elements.projectAccuracy.value = settings.accuracyMode || "high";
  renderScenarioOptions(settings.scenarioId || "", true, false);
  elements.projectScenario.value = settings.scenarioId || "";
  elements.projectCustomPrompt.value = settings.customPrompt || "";
  elements.projectSceneFormat.value = settings.resolve.fieldFormats.scene;
  elements.projectShotFormat.value = settings.resolve.fieldFormats.shot;
  elements.projectTakeFormat.value = settings.resolve.fieldFormats.take;
  elements.projectGoodComment.value = settings.resolve.comments.goodTake;
  elements.projectHoldComment.value = settings.resolve.comments.holdTake;
  const readOnly = Boolean(project.archivedAt);
  // Archived projects remain inspectable, but every control is disabled until
  // the user explicitly restores the project from the library.
  for (const control of elements.projectSettingsForm.elements) {
    control.disabled = readOnly;
  }
  syncLegacyModelPicker(elements.projectModel);
  elements.projectSettingsStatus.textContent = readOnly
    ? "项目已归档，恢复后才能修改"
    : "";
}

function buildProjectSettingsFromForm() {
  const scene = elements.projectSceneFormat.value.trim();
  const shot = elements.projectShotFormat.value.trim();
  const take = elements.projectTakeFormat.value.trim();
  const goodTake = elements.projectGoodComment.value.trim();
  const holdTake = elements.projectHoldComment.value.trim();
  if (![scene, shot, take].every((value) => /^X{1,6}$/.test(value))) {
    throw new Error("场、镜、次格式必须由 1–6 个 X 组成。");
  }
  if (![goodTake, holdTake].every((value) => value && !/[\r\n]/.test(value))) {
    throw new Error("过条和保条标记不能为空，且不能包含换行。");
  }
  return {
    version: 1,
    providerId: elements.projectProvider.value || null,
    modelId: elements.projectModel.value || null,
    accuracyMode: elements.projectAccuracy.value,
    scenarioId: elements.projectScenario.value || null,
    customPrompt: elements.projectCustomPrompt.value.trim(),
    resolve: {
      fieldFormats: { scene, shot, take },
      comments: { goodTake, holdTake },
    },
  };
}

async function saveProjectSettings(event) {
  event.preventDefault();
  if (!state.currentProjectId) return;
  if (isProjectReadOnly()) {
    elements.projectSettingsStatus.textContent = "项目已归档，恢复后才能修改";
    return;
  }
  if (state.recognizing) {
    elements.projectSettingsStatus.textContent = "识别进行中，完成后才能修改项目设置";
    return;
  }
  try {
    const settings = buildProjectSettingsFromForm();
    const project = await updateProjectApi({
      id: state.currentProjectId,
      name: elements.projectNameInput.value,
      description: elements.projectDescriptionInput.value,
      settings,
    });
    state.currentProject = project;
    state.projects = state.projects.map((item) => item.id === project.id ? project : item);
    if (!state.currentTaskId) state.activeTaskSettings = project.settings;
    if (!state.currentTaskId) applyNewTaskRecognitionDefaults(project);
    renderProjectLibrary();
    elements.projectSettingsStatus.textContent = "已保存";
    renderRoute();
  } catch (error) {
    elements.projectSettingsStatus.textContent = error.message || "保存失败";
  }
}

function resetProjectOutputSettings() {
  const defaults = defaultRendererProjectSettings().resolve;
  elements.projectSceneFormat.value = defaults.fieldFormats.scene;
  elements.projectShotFormat.value = defaults.fieldFormats.shot;
  elements.projectTakeFormat.value = defaults.fieldFormats.take;
  elements.projectGoodComment.value = defaults.comments.goodTake;
  elements.projectHoldComment.value = defaults.comments.holdTake;
  elements.projectSettingsStatus.textContent = "默认值已填入，保存后生效";
}

function defaultRendererProjectSettings() {
  return {
    providerId: "",
    modelId: "",
    accuracyMode: "high",
    scenarioId: "",
    customPrompt: "",
    resolve: {
      fieldFormats: {
        scene: state.config?.workflow?.resolve?.fieldFormats?.scene || "XXX",
        shot: state.config?.workflow?.resolve?.fieldFormats?.shot || "XX",
        take: state.config?.workflow?.resolve?.fieldFormats?.take || "XX",
      },
      comments: {
        goodTake: state.config?.workflow?.resolve?.comments?.goodTake || "_OK",
        holdTake: state.config?.workflow?.resolve?.comments?.holdTake || "_KP",
      },
    },
  };
}

function applyNewTaskRecognitionDefaults(project = state.currentProject) {
  if (!project) return;
  const settings = project.settings || defaultRendererProjectSettings();
  const recent = project.lastRecognitionDefaults;
  const providerOptions = [...elements.provider.options].map((option) => option.value);
  const providerIsUsable = (providerId) => Boolean(providerId) &&
    providerOptions.includes(providerId) &&
    state.config?.providers.some(
      (provider) => provider.id === providerId && provider.configured,
    );
  // A removed provider must not leave controls on the previously opened
  // project. Fall back deterministically to project settings, then any usable
  // provider currently configured on this machine.
  const providerId = [recent?.providerId, settings.providerId]
    .find(providerIsUsable)
    || state.config?.providers.find((provider) => provider.configured)?.id
    || providerOptions[0]
    || "";
  elements.provider.value = providerId;
  renderModelOptions();

  const modelCandidates = [
    recent?.providerId === providerId ? recent.modelId : null,
    settings.providerId === providerId ? settings.modelId : null,
  ].filter(Boolean);
  const selectRememberedModel = () => {
    const availableModels = [...elements.model.options].map((option) => option.value);
    const desiredModel = modelCandidates.find((modelId) =>
      availableModels.includes(modelId));
    if (desiredModel) {
      elements.model.value = desiredModel;
      syncLegacyModelPicker(elements.model);
    }
  };
  selectRememberedModel();
  elements.accuracyMode.value = settings.accuracyMode || "high";
  elements.scenario.value = settings.scenarioId || "";
  elements.customPromptInput.value = recent
    ? recent.customPrompt || ""
    : settings.customPrompt || "";
  state.activeTaskSettings = settings;
  updateApiKeyFieldState();
  updateRecognizeState();

  // Discovery may add the remembered model after the first synchronous render.
  const projectId = project.id;
  void loadProviderModels().then(() => {
    if (state.currentProjectId !== projectId || state.currentTaskId) return;
    selectRememberedModel();
    renderModelNote();
    updateRecognizeState();
  });
}

function renderGlobalProviderOptions() {
  if (!elements.globalProvider || !state.config) return;
  const previous = elements.globalProvider.value;
  elements.globalProvider.innerHTML = state.config.providers.map((provider) =>
    `<option value="${escapeHtml(provider.id)}">${escapeHtml(provider.label)}${provider.configured ? "" : " · 未配置"}</option>`,
  ).join("");
  elements.globalProvider.value = state.config.providers.some(
    (provider) => provider.id === previous,
  ) ? previous : state.config.providers[0]?.id || "";
  updateGlobalApiKeyFieldState();
}

function updateGlobalApiKeyFieldState() {
  const provider = state.config?.providers.find(
    (item) => item.id === elements.globalProvider?.value,
  );
  if (!provider || !elements.globalApiKeyNote) return;
  const configurable = KEY_CONFIGURABLE_PROVIDERS.includes(provider.id);
  elements.globalApiKeyInput.disabled = !configurable;
  elements.globalSaveKeyButton.disabled = !configurable;
  elements.globalApiKeyNote.textContent = provider.configured
    ? "已配置 · 输入新 Key 可覆盖，留空保存可清除"
    : "未配置 · 粘贴 API Key 后保存";
}

async function saveGlobalProviderKey() {
  const provider = state.config?.providers.find(
    (item) => item.id === elements.globalProvider.value,
  );
  if (!provider) return;
  try {
    const savedKey = await saveProviderKeyApi(provider.id, elements.globalApiKeyInput.value.trim());
    elements.globalApiKeyInput.value = "";
    await loadConfig();
    renderProviderOptions();
    renderGlobalProviderOptions();
    renderApiStatus();
    await loadProviderModels();
    if (state.globalSettings) {
      state.globalSettings = {
        ...state.globalSettings,
        keyConfigured: {
          ...(state.globalSettings.keyConfigured || {}),
          [provider.id]: Boolean(savedKey?.configured),
        },
      };
    }
    renderProjectSettingsForm();
    if (!state.currentTaskId) applyNewTaskRecognitionDefaults();
    elements.globalApiKeyNote.textContent = "已保存。";
  } catch (error) {
    elements.globalApiKeyNote.textContent = error.message || "保存失败。";
  }
}

function renderProjectProviderOptions(selectedId = "") {
  if (!elements.projectProvider || !state.config) return;
  elements.projectProvider.innerHTML = state.config.providers.map((provider) =>
    `<option value="${escapeHtml(provider.id)}">${escapeHtml(provider.label)}${provider.configured ? "" : " · 未配置"}</option>`,
  ).join("");
  elements.projectProvider.value = state.config.providers.some(
    (provider) => provider.id === selectedId,
  ) ? selectedId : state.config.providers.find((provider) => provider.configured)?.id || "";
}

function renderProjectModelOptions(
  selectedId = "",
  { preserveUnknown = false } = {},
) {
  if (!elements.projectModel) return;
  const compatible = modelsForProvider(elements.projectProvider.value);
  const groups = modelOptionGroups(elements.projectProvider.value, compatible);
  const selectedAvailable = compatible.some((model) => model.id === selectedId);
  const rememberedOption = preserveUnknown && selectedId && !selectedAvailable
    ? `<option value="${escapeHtml(selectedId)}">${escapeHtml(selectedId)} · 已保存（当前未加载）</option>`
    : "";
  elements.projectModel.innerHTML = rememberedOption
    + (groups.map(modelOptionGroupHtml).join("") || (rememberedOption
      ? ""
      : '<option value="">没有发现可用的视觉模型</option>'));
  elements.projectModel.value = selectedAvailable || rememberedOption
    ? selectedId
    : compatible[0]?.id || "";
  syncLegacyModelPicker(elements.projectModel, groups);
}

async function loadProviderModelsForSelect(
  providerSelect,
  modelSelect,
  { selectedModelId = modelSelect.value, preserveUnknown = false } = {},
) {
  const token = projectModelOperations.start();
  const projectId = state.currentProjectId;
  const providerId = providerSelect.value;
  const provider = state.config?.providers.find((item) => item.id === providerSelect.value);
  if (!provider?.configured) {
    if (
      projectModelOperations.isCurrent(token)
      && state.currentProjectId === projectId
      && providerSelect.value === providerId
    ) {
      renderProjectModelOptions(selectedModelId, { preserveUnknown });
    }
    return false;
  }
  try {
    const data = await fetchModelsApi(provider.id, false);
    if (
      !projectModelOperations.isCurrent(token)
      || state.currentProjectId !== projectId
      || providerSelect.value !== providerId
    ) return false;
    state.providerModels[provider.id] = Array.isArray(data.models) ? data.models : [];
  } catch {
    // Static models remain available when discovery is unavailable.
  }
  if (
    !projectModelOperations.isCurrent(token)
    || state.currentProjectId !== projectId
    || providerSelect.value !== providerId
  ) return false;
  renderProjectModelOptions(selectedModelId, { preserveUnknown });
  return true;
}

function bindEvents() {
  // Keep the hidden native selects as the form/state source of truth while
  // enhancing both legacy model fields with the same collapsible groups.
  setupLegacyModelPicker(elements.model, "识别模型");
  setupLegacyModelPicker(elements.projectModel, "识别模型");
  elements.navProjects?.addEventListener("click", () => navigate("projects"));
  elements.navWorkspace?.addEventListener("click", () => {
    if (state.currentProjectId) navigate("workspace");
  });
  elements.navProjectSettings?.addEventListener("click", () => {
    if (state.currentProjectId) navigate("project-settings");
  });
  elements.navGlobalSettings?.addEventListener("click", () => navigate("global-settings"));
  elements.newProjectButton?.addEventListener("click", openProjectDialog);
  elements.importLibraryButton?.addEventListener("click", importProjectLibrary);
  elements.exportLibraryButton?.addEventListener("click", exportCurrentLibrary);
  elements.changeLibraryLocationButton?.addEventListener("click", changeLibraryLocation);
  elements.projectEmptyCreate?.addEventListener("click", openProjectDialog);
  elements.projectDialogClose?.addEventListener("click", closeProjectDialog);
  elements.projectDialogCancel?.addEventListener("click", closeProjectDialog);
  elements.projectDialog?.addEventListener("click", (event) => {
    if (event.target === elements.projectDialog) closeProjectDialog();
  });
  elements.projectDialogForm?.addEventListener("submit", createProjectFromDialog);
  elements.projectSettingsBack?.addEventListener("click", () => navigate("workspace"));
  elements.projectSettingsForm?.addEventListener("submit", saveProjectSettings);
  elements.projectSettingsReset?.addEventListener("click", resetProjectOutputSettings);
  elements.projectProvider?.addEventListener("change", async () => {
    renderProjectModelOptions();
    await loadProviderModelsForSelect(
      elements.projectProvider,
      elements.projectModel,
    );
  });
  elements.projectModel?.addEventListener("change", () => {
    // A deliberate user choice supersedes a discovery request that started
    // while restoring the previously saved model.
    projectModelOperations.invalidate();
  });
  elements.globalProvider?.addEventListener("change", updateGlobalApiKeyFieldState);
  elements.globalSaveKeyButton?.addEventListener("click", saveGlobalProviderKey);
  elements.globalSettingsFields?.addEventListener("input", handleGlobalSettingsInput);
  elements.globalSettingsFields?.addEventListener("change", handleGlobalSettingsInput);
  elements.globalSettingsSave?.addEventListener("click", () => void saveGlobalSettings());
  elements.globalSettingsReset?.addEventListener("click", () => void saveGlobalSettings(true));
  elements.globalOcrOpen?.addEventListener("click", openOcrSetup);

  elements.provider.addEventListener("change", async () => {
    updateApiKeyFieldState();
    renderModelOptions();
    updateRecognizeState();
    await loadProviderModels();
  });
  elements.model.addEventListener("change", () => {
    renderModelNote();
    updateRecognizeState();
  });
  elements.accuracyMode.addEventListener("change", updateRecognizeState);
  elements.scenario.addEventListener("change", updateRecognizeState);
  elements.modelRefresh.addEventListener("click", () => {
    loadProviderModels(true);
  });
  elements.metadataInput.addEventListener("change", (event) => {
    if (event.target.files?.[0]) loadResolveCsv(event.target.files[0]);
  });
  elements.imageInput.addEventListener("change", (event) => {
    if (event.target.files?.[0]) loadReportFile(event.target.files[0]);
  });
  elements.slateDirectoryButton.addEventListener("click", selectSlateDirectory);
  elements.removeMetadata.addEventListener("click", clearResolveCsv);
  elements.removeSlates.addEventListener("click", clearSlateMetadata);
  elements.removeFile.addEventListener("click", clearReportFile);
  elements.recognizeButton.addEventListener("click", recognize);
  elements.saveKeyButton.addEventListener("click", saveProviderKey);
  elements.ocrSetupLink.addEventListener("click", openOcrSetup);
  elements.ocrSetupClose.addEventListener("click", closeOcrSetup);
  elements.ocrSkipButton.addEventListener("click", skipOcrSetup);
  elements.ocrCheckButton.addEventListener("click", runOcrCheck);
  elements.ocrSaveButton.addEventListener("click", saveOcrSettings);
  elements.ocrSetupOverlay.addEventListener("click", (event) => {
    if (event.target === elements.ocrSetupOverlay) closeOcrSetup();
  });
  elements.addRow.addEventListener("click", () => {
    if (isProjectReadOnly()) return;
    state.detailSearch = "";
    elements.detailSearch.value = "";
    state.records.push(emptyRecord());
    renderTable();
    saveCurrentTask();
  });
  elements.detailSearch.addEventListener("input", () => {
    state.detailSearch = elements.detailSearch.value;
    renderTable();
  });
  for (const th of document.querySelectorAll("th[data-sort]")) {
    th.addEventListener("click", () => toggleDetailSort(th.dataset.sort));
  }
  elements.exportButton.addEventListener("click", exportCsv);
  elements.tabCsv.addEventListener("click", () => setResultsTab("csv"));
  elements.tabDetail.addEventListener("click", () => setResultsTab("detail"));
  elements.taskSelect.addEventListener("change", switchTask);
  elements.taskDelete.addEventListener("click", deleteCurrentTask);
  elements.taskSaveRetry?.addEventListener("click", () => {
    void taskAutosave.retry();
  });
  elements.slateCsvInput.addEventListener("change", (event) => {
    if (event.target.files?.[0]) loadSlateCsv(event.target.files[0]);
  });
  elements.removeSlateCsv.addEventListener("click", clearSlateCsv);
  elements.apiKeyInput.addEventListener("keydown", (event) => {
    if (event.key === "Enter") {
      event.preventDefault();
      saveProviderKey();
    }
  });

  elements.globalApiKeyInput?.addEventListener("keydown", (event) => {
    if (event.key === "Enter") {
      event.preventDefault();
      saveGlobalProviderKey();
    }
  });

  for (const grid of [elements.projectGrid, elements.archivedProjectGrid]) {
    grid?.addEventListener("click", handleProjectCardClick);
  }

  const resultTabs = [elements.tabCsv, elements.tabDetail];
  for (const tab of resultTabs) {
    tab.addEventListener("keydown", (event) => {
      const currentIndex = resultTabs.indexOf(event.currentTarget);
      let nextIndex = currentIndex;
      if (event.key === "ArrowRight") nextIndex = (currentIndex + 1) % resultTabs.length;
      if (event.key === "ArrowLeft") nextIndex = (currentIndex - 1 + resultTabs.length) % resultTabs.length;
      if (event.key === "Home") nextIndex = 0;
      if (event.key === "End") nextIndex = resultTabs.length - 1;
      if (nextIndex === currentIndex && !["Home", "End"].includes(event.key)) return;
      event.preventDefault();
      const name = nextIndex === 0 ? "csv" : "detail";
      setResultsTab(name);
      resultTabs[nextIndex].focus();
    });
  }

  document.addEventListener("keydown", handleRecognitionShortcut);
  window.addEventListener("beforeunload", (event) => {
    if (allowWindowClose || !taskAutosave.hasPending()) return;
    event.preventDefault();
    event.returnValue = false;
    // Keep the Electron window alive until its final pending edit is durable.
    void taskAutosave.flush().then((saved) => {
      if (!saved) return;
      allowWindowClose = true;
      window.close();
    });
  });

  bindFileDropzone(elements.metadataDropzone, elements.metadataInput, loadResolveCsv);
  bindFileDropzone(elements.dropzone, elements.imageInput, loadReportFile);
  bindFileDropzone(elements.slateCsvDropzone, elements.slateCsvInput, loadSlateCsv);
}

async function selectSlateDirectory() {
  if (
    !canSelectSlateDirectory({
      reportReady: state.imageDataGroups.length > 0,
      metadataLoaded: Boolean(state.metadataTable),
    }) ||
    state.slateScanning
  ) return;
  hideError();
  try {
    const result = await pickDirectoryApi();
    if (!result) return;
    state.slateMetadata = [];
    state.slateWarnings = [];
    elements.slateCard.hidden = true;
    elements.slateDropzone.hidden = false;

    const { keys, warnings: csvWarnings } = collectResolveMaterialKeys(
      state.metadataTable,
    );
    state.slateScanning = true;
    updateSlateDirectoryState();
    try {
      const scanResult = await scanSlateDirectoryApi(
        result.dirPath,
        keys,
        slateMaxDirectoryDepth(),
      );
      applySlateDirectoryResult({
        ...scanResult,
        warnings: [...csvWarnings, ...scanResult.warnings],
        directoryName: result.dirName || "已选素材目录",
      });
    } finally {
      state.slateScanning = false;
      updateSlateDirectoryState();
    }
  } catch (error) {
    showError(error.message || "无法读取所选素材目录。");
  }
}

function applySlateDirectoryResult({
  metadata,
  warnings,
  stats,
  directoryName,
  missingKeys,
}) {
  state.csvEdits.clear();
  state.missingMetadataKeys = new Set(missingKeys || []);
  if (!metadata.length) {
    state.slateMetadata = [];
    state.slateWarnings = compactSlateWarnings(warnings);
    const discovered = stats.discoveredSlateFiles || 0;
    const reason = discovered
      ? `找到 ${discovered} 个元数据文件，但均缺少有效的 Clip Name、Sensor FPS 或 Shot Date。`
      : `未找到与 CSV 素材匹配的元数据文件（已搜索前 ${slateMaxDirectoryDepth()} 层），请检查目录结构。`;
    showSlateScanFailure(directoryName, reason);
    if (state.records.length) renderTable();
    return;
  }

  const slateIndex = buildSlateMetadataIndex(metadata);
  state.slateMetadata = metadata;
  state.slateWarnings = compactSlateWarnings(warnings);
  elements.slateDirectoryName.textContent = directoryName;
  const indexedSlateEntries = [...slateIndex.byMaterialKey.values()];
  const cameraFpsCount = indexedSlateEntries.filter(
    (entry) => entry.sensorFps,
  ).length;
  const shootDayCount = indexedSlateEntries.filter(
    (entry) => entry.shootDay,
  ).length;
  const warningCount = warnings.length + slateIndex.warnings.length;
  const missingCount = state.missingMetadataKeys.size;
  const scanLabel = `访问 ${stats.visitedDirectories} 个目录 · 剪枝 ${stats.prunedDirectories} 个`;
  const cacheLabel = stats.cacheHits ? ` · 缓存 ${stats.cacheHits}` : "";
  const missingLabel = missingCount ? ` · 无元数据 ${missingCount} 个素材` : "";
  elements.slateFileMeta.textContent = `${stats.discoveredSlateFiles} 个元数据文件 · Camera FPS ${cameraFpsCount} 个素材 · Shoot Day ${shootDayCount} 个素材${missingLabel} · ${scanLabel}${cacheLabel}${warningCount ? ` · ${warningCount} 个警告` : ""}`;
  elements.slateCard.hidden = false;
  elements.slateDropzone.hidden = true;
  clearSlateStatus();
  if (state.records.length) renderTable();
}

function showSlateScanningState(directoryName) {
  elements.slateDirectoryName.textContent = directoryName;
  elements.slateFileMeta.textContent = "正在定向查找元数据文件…";
  elements.slateCard.hidden = false;
  elements.slateDropzone.hidden = true;
  setSlateStatus("正在定向查找元数据文件…", "loading");
}

function showSlateScanFailure(directoryName, reason) {
  elements.slateDirectoryName.textContent = directoryName;
  elements.slateFileMeta.textContent = reason;
  elements.slateCard.hidden = false;
  elements.slateDropzone.hidden = false;
  setSlateStatus(reason, "error");
}

function setSlateStatus(text, variant = "") {
  elements.slateStatus.textContent = text;
  elements.slateStatus.className = `slate-status${variant ? ` is-${variant}` : ""}`;
  elements.slateStatus.hidden = false;
}

function clearSlateStatus() {
  elements.slateStatus.textContent = "";
  elements.slateStatus.className = "slate-status";
  elements.slateStatus.hidden = true;
}

function slateMaxDirectoryDepth() {
  return Number(state.config?.workflow?.slate?.maxDirectoryDepth) || 4;
}

function renderSlateDirectoryConfig() {
  updateMetadataInputState();
  updateSlateDirectoryState();
}

function updateMetadataInputState() {
  const reportReady = state.imageDataGroups.length > 0;
  const slateCsvLoaded = Boolean(state.slateCsvRecords?.length);
  const writable = !isProjectReadOnly();
  const enabled = writable && canLoadResolveCsv({ reportReady, slateCsvLoaded });
  elements.metadataInput.disabled = !enabled;
  elements.metadataDropzone.classList.toggle("is-disabled", !enabled);
  elements.metadataDropzone.setAttribute("aria-disabled", String(!enabled));
  elements.metadataHelp.textContent = enabled
    ? "可选 · 载入后回填导出"
    : "可选 · 请先选择场记单或场记 CSV";

  // Slate CSV can always be loaded independently
  const slateEnabled = writable && canLoadSlateCsv();
  elements.slateCsvInput.disabled = !slateEnabled;
  elements.slateCsvDropzone.classList.toggle("is-disabled", !slateEnabled);
  elements.slateCsvDropzone.setAttribute("aria-disabled", String(!slateEnabled));
  elements.slateCsvHelp.textContent = slateEnabled
    ? "可辅助图片识别，也可直接合并 Resolve CSV"
    : "可选 · 请先选择场记单";
}

function updateSlateDirectoryState() {
  const enabled = !isProjectReadOnly() && canSelectSlateDirectory({
    reportReady: state.imageDataGroups.length > 0,
    metadataLoaded: Boolean(state.metadataTable),
  }) && !state.slateScanning;
  elements.slateDirectoryButton.disabled = !enabled;
  elements.slateHelp.textContent = state.slateScanning
    ? "正在定向查找元数据文件…"
    : !state.imageDataGroups.length
      ? "请先选择场记单"
      : state.metadataTable
      ? `按 CSV 素材定向查找 · 最多 ${slateMaxDirectoryDepth()} 层`
      : "请先载入 Resolve CSV";
  updateSupportDataSummary();
}

function clearSlateMetadata() {
  state.slateMetadata = [];
  state.csvEdits.clear();
  state.missingMetadataKeys = new Set();
  state.slateWarnings = [];
  state.slateScanning = false;
  elements.slateCard.hidden = true;
  elements.slateDropzone.hidden = false;
  clearSlateStatus();
  updateSlateDirectoryState();
  if (state.records.length) renderTable();
}

function compactSlateWarnings(warnings) {
  const limit = 20;
  if (warnings.length <= limit) return warnings;
  return [
    ...warnings.slice(0, limit),
    `另有 ${warnings.length - limit} 个元数据文件读取警告未逐条显示。`,
  ];
}

function bindFileDropzone(dropzone, input, loader) {
  for (const eventName of ["dragenter", "dragover"]) {
    dropzone.addEventListener(eventName, (event) => {
      event.preventDefault();
      if (!input.disabled) dropzone.classList.add("dragging");
    });
  }
  for (const eventName of ["dragleave", "drop"]) {
    dropzone.addEventListener(eventName, (event) => {
      event.preventDefault();
      dropzone.classList.remove("dragging");
    });
  }
  dropzone.addEventListener("drop", (event) => {
    if (input.disabled) return;
    const file = event.dataTransfer.files?.[0];
    if (file) loader(file);
  });
}

function renderProviderOptions() {
  const previous = elements.provider.value;
  elements.provider.innerHTML = state.config.providers
    .map(
      (provider) =>
        `<option value="${escapeHtml(provider.id)}">${escapeHtml(provider.label)}${provider.configured ? "" : " · 未配置"}</option>`,
    )
    .join("");

  if ([...elements.provider.options].some((option) => option.value === previous)) {
    elements.provider.value = previous;
  } else {
    elements.provider.value =
      state.config.providers.find((provider) => provider.configured)?.id ||
      "openrouter";
  }
  updateApiKeyFieldState();
}

// All supported providers can persist their API key through the Main process;
// OpenAI-compatible endpoint/model details are edited in Modern Global Settings
// (the bounded legacy page still exposes the credential action).
const KEY_CONFIGURABLE_PROVIDERS = [
  "openai",
  "openrouter",
  "tokenplan",
  "dashscope",
  "openai-compatible",
];

// Keep the fallback settings form data-driven. The typed Modern Renderer has
// richer affordances, but this inventory guarantees the recovery page cannot
// silently lose a newly supported .env.example option.
const GLOBAL_SETTINGS_GROUPS = [
  {
    title: "服务商接口",
    fields: [
      { key: "OPENAI_BASE_URL", label: "OpenAI Base URL", type: "url" },
      { key: "OPENROUTER_BASE_URL", label: "OpenRouter Base URL", type: "url" },
      { key: "OPENROUTER_SITE_URL", label: "OpenRouter 应用标识 URL", type: "url", hint: "可留空。" },
      { key: "TOKENPLAN_BASE_URL", label: "Token Plan Base URL", type: "url" },
      { key: "DASHSCOPE_BASE_URL", label: "DashScope Base URL", type: "url" },
    ],
  },
  {
    title: "OpenAI 兼容接口",
    fields: [
      { key: "OPENAI_COMPATIBLE_BASE_URL", label: "Base URL", type: "url" },
      { key: "OPENAI_COMPATIBLE_MODEL", label: "模型 ID" },
      { key: "OPENAI_COMPATIBLE_API_MODE", label: "请求接口", options: [["chat-completions", "Chat Completions"], ["responses", "Responses"]] },
      { key: "OPENAI_COMPATIBLE_JSON_MODE", label: "JSON 模式", options: [["json_schema", "JSON Schema"], ["json_object", "JSON Object"], ["prompt", "Prompt 约束"]] },
      { key: "OPENAI_COMPATIBLE_IMAGE_DETAIL", label: "图片细节", options: [["auto", "自动"], ["low", "低"], ["high", "高"], ["original", "原始"]] },
    ],
  },
  {
    title: "运行与缓存",
    fields: [
      { key: "SLATESYNC_CONFIG_PATH", label: "工作流配置路径", hint: "开发环境读取；修改后下次启动生效。" },
      { key: "MAX_BODY_MB", label: "请求体上限（MB）", type: "number", min: 20, max: 200, step: 1 },
      { key: "MODEL_REQUEST_TIMEOUT_MS", label: "模型请求超时（毫秒）", type: "number", min: 30000, max: 3600000, step: 1000 },
      { key: "MODEL_REQUEST_MAX_RETRIES", label: "超时重试次数", type: "number", min: 0, max: 3, step: 1 },
      { key: "MODEL_PAGE_CONCURRENCY", label: "并行提交页数", type: "number", min: 1, max: 6, step: 1 },
      { key: "MAX_CONCURRENT_RECOGNITIONS", label: "并行识别任务数", type: "number", min: 1, max: 16, step: 1 },
      { key: "PADDLE_PDX_CACHE_HOME", label: "Paddle 模型缓存路径", hint: "留空使用应用默认缓存目录。" },
    ],
  },
  {
    title: "Apple Vision OCR",
    fields: [
      { key: "VISIONOCR_ENABLED", label: "启用模式", options: [["auto", "自动"], ["true", "开启"], ["false", "关闭"]] },
      { key: "VISIONOCR_REQUIRED", label: "必需模式", options: [["false", "可选"], ["true", "必需"]] },
      { key: "VISIONOCR_LANGUAGE", label: "识别语言", hint: "可填写逗号分隔的语言。" },
      { key: "VISIONOCR_RECOGNITION_LEVEL", label: "识别精度", options: [["accurate", "高精度"], ["fast", "快速"]] },
      { key: "VISIONOCR_USE_LANGUAGE_CORRECTION", label: "语言校正", options: [["true", "启用"], ["false", "关闭"]] },
      { key: "VISIONOCR_MIN_CONFIDENCE", label: "最低置信度", type: "number", min: 0, max: 1, step: 0.01 },
      { key: "VISIONOCR_MAX_BLOCKS_PER_VIEW", label: "每个视图最多文字块", type: "number", min: 0, max: 10000, step: 1 },
      { key: "VISIONOCR_TIMEOUT_MS", label: "超时", hint: "填写 auto 或 10000–1800000 毫秒。" },
      { key: "VISIONOCR_BINARY", label: "Vision bridge 路径", hint: "留空则自动查找。" },
    ],
  },
  {
    title: "PaddleOCR",
    fields: [
      { key: "PADDLEOCR_ENABLED", label: "启用模式", options: [["auto", "自动"], ["true", "开启"], ["false", "关闭"]] },
      { key: "PADDLEOCR_REQUIRED", label: "必需模式", options: [["false", "可选"], ["true", "必需"]] },
      { key: "PADDLEOCR_MODEL_VERSION", label: "模型版本", options: [["PP-OCRv6", "PP-OCRv6（推荐）"], ["PP-OCRv5", "PP-OCRv5（兼容）"]] },
      { key: "PADDLEOCR_PRESET", label: "参数预设", options: [["custom", "自定义"], ["performance", "性能（质量优先）"], ["balanced", "平衡（推荐）"], ["fast", "快速（低延迟）"]] },
      { key: "PADDLEOCR_PROFILE", label: "性能档", options: [["fast", "快速"], ["balanced", "平衡"], ["accurate", "高精度"]] },
      { key: "PADDLEOCR_LANGUAGE", label: "识别语言" },
      { key: "PADDLEOCR_DEVICE", label: "计算设备" },
      { key: "PADDLEOCR_DETECTION_MODEL", label: "检测模型", hint: "留空使用性能档默认模型。" },
      { key: "PADDLEOCR_RECOGNITION_MODEL", label: "识别模型", hint: "留空使用性能档默认模型。" },
      { key: "PADDLEOCR_RECOGNITION_BATCH_SIZE", label: "识别批量大小", type: "number", min: 1, max: 64, step: 1 },
      { key: "PADDLEOCR_PYTHON", label: "Python 环境路径", hint: "例如 .venv-paddleocr/bin/python；留空使用自动检测。" },
      { key: "PADDLEOCR_MIN_CONFIDENCE", label: "最低置信度", type: "number", min: 0, max: 1, step: 0.01 },
      { key: "PADDLEOCR_MAX_BLOCKS_PER_VIEW", label: "每个视图最多文字块", type: "number", min: 0, max: 10000, step: 1 },
      { key: "PADDLEOCR_TEXT_DET_LIMIT_SIDE_LEN", label: "检测最长边", type: "number", min: 320, max: 4096, step: 1, hint: "320–4096；留空使用 PaddleOCR 默认值。" },
      { key: "PADDLEOCR_TIMEOUT_MS", label: "OCR 超时", hint: "填写 auto 或 10000–3600000 毫秒。" },
    ],
  },
];

function globalFieldMarkup(field, values) {
  const value = values?.[field.key] || "";
  const common = `data-global-key="${escapeHtml(field.key)}" spellcheck="false"`;
  const control = field.options
    ? `<select ${common}>${field.options.map(([option, label]) => `<option value="${escapeHtml(option)}"${value === option ? " selected" : ""}>${escapeHtml(label)}</option>`).join("")}</select>`
    : `<input type="${field.type || "text"}" ${common}${field.min === undefined ? "" : ` min="${field.min}" max="${field.max}" step="${field.step}"`} value="${escapeHtml(value)}" />`;
  return `<label class="field"><span>${escapeHtml(field.label)} <code>${escapeHtml(field.key)}</code></span>${control}${field.hint ? `<small class="global-settings-field-hint">${escapeHtml(field.hint)}</small>` : ""}</label>`;
}

function renderGlobalSettingsForm() {
  if (!elements.globalSettingsFields) return;
  if (!state.globalSettings) {
    elements.globalSettingsFields.innerHTML = '<p class="settings-help">正在读取本机全局配置…</p>';
    if (elements.globalSettingsCount) elements.globalSettingsCount.textContent = "读取中";
    return;
  }
  const values = state.globalSettingsDraft;
  elements.globalSettingsFields.innerHTML = GLOBAL_SETTINGS_GROUPS.map((group, index) => `
    <details class="global-settings-group"${index === 0 ? " open" : ""}>
      <summary>${escapeHtml(group.title)}</summary>
      <div class="global-settings-group-fields">${group.fields.map((field) => globalFieldMarkup(field, values)).join("")}</div>
    </details>
  `).join("");
  if (elements.globalSettingsCount) {
    elements.globalSettingsCount.textContent = `已覆盖 ${state.globalSettings.overrides?.length || 0} 项`;
  }
  if (elements.globalSettingsSave) elements.globalSettingsSave.disabled = state.globalSettingsLoading;
  if (elements.globalSettingsReset) elements.globalSettingsReset.disabled = state.globalSettingsLoading;
}

function setGlobalSettingsStatus(message, isError = false) {
  if (!elements.globalSettingsStatus) return;
  elements.globalSettingsStatus.textContent = message;
  elements.globalSettingsStatus.classList.toggle("error", isError);
}

async function loadGlobalSettings() {
  if (!elements.globalSettingsFields || state.globalSettingsLoading) return;
  state.globalSettingsLoading = true;
  renderGlobalSettingsForm();
  try {
    const data = await getGlobalSettingsApi();
    state.globalSettings = data;
    state.globalSettingsDraft = { ...(data.values || {}) };
    state.globalSettingsDirty = new Set();
    setGlobalSettingsStatus("");
    renderGlobalSettingsForm();
  } catch (error) {
    setGlobalSettingsStatus(error.message || "读取全局配置失败。", true);
  } finally {
    state.globalSettingsLoading = false;
    renderGlobalSettingsForm();
  }
}

function handleGlobalSettingsInput(event) {
  const key = event.target?.dataset?.globalKey;
  if (!key) return;
  state.globalSettingsDraft[key] = event.target.value;
  state.globalSettingsDirty.add(key);
  setGlobalSettingsStatus("有未保存修改");
}

async function saveGlobalSettings(reset = false) {
  if (!state.globalSettings || state.globalSettingsLoading) return;
  state.globalSettingsLoading = true;
  renderGlobalSettingsForm();
  try {
    const values = {};
    if (!reset) {
      // Resolved values include .env/defaults; send only dirty fields so a
      // normal save does not materialize inherited values as overrides.
      for (const key of state.globalSettingsDirty) values[key] = state.globalSettingsDraft[key] || "";
    }
    const data = await saveGlobalSettingsApi(reset ? { reset: true } : { values });
    state.globalSettings = data;
    state.globalSettingsDraft = { ...(data.values || {}) };
    state.globalSettingsDirty = new Set();
    await loadConfig();
    renderProviderOptions();
    renderGlobalProviderOptions();
    renderModelOptions();
    renderApiStatus();
    setGlobalSettingsStatus(data.restartRequired ? "已保存；工作流路径下次启动生效。" : reset ? "已恢复 .env 与内置默认。" : "已保存。");
  } catch (error) {
    setGlobalSettingsStatus(error.message || "保存全局配置失败。", true);
  } finally {
    state.globalSettingsLoading = false;
    renderGlobalSettingsForm();
  }
}

function updateApiKeyFieldState() {
  const provider = selectedProvider();
  const configurable = KEY_CONFIGURABLE_PROVIDERS.includes(provider?.id);
  elements.providerKeyField.hidden = !configurable;
  if (!configurable) return;
  elements.apiKeyNote.textContent = provider.configured
    ? "已配置 · 输入新 Key 可覆盖，留空保存可清除"
    : "未配置 · 粘贴 Key 后点保存";
  elements.apiKeyInput.placeholder = provider.configured
    ? "已配置 · 输入新 Key 覆盖"
    : "粘贴 API Key";
}

async function saveProviderKey() {
  const provider = selectedProvider();
  if (!provider) return;
  hideError();
  const apiKey = elements.apiKeyInput.value.trim();
  try {
    const data = await saveProviderKeyApi(provider.id, apiKey);
    elements.apiKeyInput.value = "";
    await loadConfig();
    renderProviderOptions();
    renderModelOptions();
    renderApiStatus();
    updateRecognizeState();
    const discovery = await loadProviderModels(true);
    updateApiKeySaveFeedback(discovery, Boolean(apiKey));
  } catch (error) {
    showError(error.message);
  }
}

function updateApiKeySaveFeedback(discovery, keyProvided) {
  const note = elements.apiKeyNote;
  if (!keyProvided) {
    note.textContent = "已清除 API Key";
    note.classList.remove("error");
    return;
  }
  if (discovery?.source === "api") {
    note.textContent = `保存成功 · 已连接 ${discovery.visionModelCount} 个视觉模型`;
    note.classList.remove("error");
    return;
  }
  note.textContent = `保存成功，但 Key 验证失败：${discovery?.warning || "无法读取模型列表"}`;
  note.classList.add("error");
}

function renderModelOptions() {
  const providerId = elements.provider.value;
  const compatible = modelsForProvider(providerId);
  const previous = elements.model.value;
  const groups = modelOptionGroups(providerId, compatible);
  elements.model.innerHTML = groups.length
    ? groups.map(modelOptionGroupHtml).join("")
    : '<option value="">没有发现可用的视觉模型</option>';

  if (compatible.some((model) => model.id === previous)) {
    elements.model.value = previous;
  } else if (compatible.length) {
    elements.model.value = compatible[0].id;
  }
  syncLegacyModelPicker(elements.model, groups);
  renderModelNote();
}

async function loadProviderModels(forceRefresh = false) {
  const provider = selectedProvider();
  if (!provider?.configured) {
    renderModelOptions();
    return provider ? state.modelDiscovery[provider.id] : undefined;
  }

  const providerId = provider.id;
  const requestId = ++state.modelRequestId;
  state.modelDiscovery[providerId] = { loading: true };
  elements.modelRefresh.disabled = true;
  renderModelNote();

  try {
    const data = await fetchModelsApi(providerId, forceRefresh);
    if (requestId !== state.modelRequestId || elements.provider.value !== providerId) {
      return state.modelDiscovery[providerId];
    }
    state.providerModels[providerId] = Array.isArray(data.models)
      ? data.models
      : [];
    state.modelDiscovery[providerId] = data;
    renderModelOptions();
    return data;
  } catch (error) {
    if (requestId !== state.modelRequestId || elements.provider.value !== providerId) {
      return state.modelDiscovery[providerId];
    }
    state.modelDiscovery[providerId] = {
      source: "client-fallback",
      warning: error.message || "无法读取实时模型列表",
    };
    renderModelOptions();
    return state.modelDiscovery[providerId];
  } finally {
    if (requestId === state.modelRequestId) {
      elements.modelRefresh.disabled = isProjectReadOnly();
      updateRecognizeState();
    }
  }
}

// Keep the legacy fallback renderer aligned with the typed Renderer: fixed
// recommendations remain visible, while discovered vendor buckets can collapse.
function modelOptionGroups(providerId, models) {
  if (providerId !== "openrouter") {
    const fixed = models.filter(isRecommendedModel);
    const discovered = models
      .filter((model) => !isRecommendedModel(model))
      .slice(0, MAX_DISCOVERED_MODELS);
    const groups = [];
    if (fixed.length) groups.push(modelOptionGroup("fixed", "固定模型", fixed, false));
    if (discovered.length) groups.push(modelOptionGroup("discovered", "其他视觉模型", discovered, true));
    return groups;
  }

  const featured = models.filter(isRecommendedModel);
  for (const model of models) {
    if (featured.length >= OPENROUTER_PRIMARY_MODELS) break;
    if (!isRecommendedModel(model)) featured.push(model);
  }
  const featuredIds = new Set(featured.map((model) => model.id));
  const groups = featured.length
    ? [modelOptionGroup(
      "openrouter-featured",
      "推荐模型 · 优先 " + OPENROUTER_PRIMARY_MODELS + " 个",
      featured,
      false,
    )]
    : [];
  const byVendor = new Map();
  for (const model of models) {
    if (featuredIds.has(model.id)) continue;
    const vendor = model.vendor || model.id.split("/", 1)[0] || "other";
    const vendorModels = byVendor.get(vendor) || [];
    vendorModels.push(model);
    byVendor.set(vendor, vendorModels);
  }
  for (const [vendor, vendorModels] of byVendor) {
    groups.push(modelOptionGroup(
      "openrouter-vendor-" + vendor,
      formatVendorLabel(vendor) + " · 其余 " + vendorModels.length + " 个",
      vendorModels,
      true,
    ));
  }
  return groups;
}

function isRecommendedModel(model) {
  // Static config entries do not carry discovery metadata, so keep those
  // curated choices alongside descriptors explicitly marked as fixed.
  return model.fixed === true || (model.fixed !== false && model.discovered !== true);
}

function formatVendorLabel(vendor) {
  const labels = {
    anthropic: "Anthropic",
    deepseek: "DeepSeek",
    google: "Google",
    meta: "Meta",
    mistralai: "Mistral AI",
    openai: "OpenAI",
    qwen: "Qwen",
    xai: "xAI",
  };
  const key = String(vendor || "other").toLowerCase();
  return labels[key] || key
    .split(/[-_]/g)
    .filter(Boolean)
    .map((part) => part.charAt(0).toUpperCase() + part.slice(1))
    .join(" ");
}

function modelOptionGroup(key, label, models, collapsible) {
  return { key, label, models, collapsible };
}

function modelOptionLabel(model) {
  const indicators = [
    model.qualityLabel ? "精度 " + model.qualityLabel : "",
    model.valueLabel ? "性价比 " + model.valueLabel : "",
  ].filter(Boolean);
  const suffix = indicators.length ? " · " + indicators.join(" · ") : "";
  return String(model.label || model.id) + suffix;
}

function modelOptionGroupHtml(group) {
  const options = group.models
    .map((model) => '<option value="' + escapeHtml(model.id) + '">' + escapeHtml(modelOptionLabel(model)) + "</option>")
    .join("");
  return '<optgroup label="' + escapeHtml(group.label) + '">' + options + "</optgroup>";
}

// The legacy page retains a native select for existing form serialization,
// but presents the same disclosure-based model list as the modern Renderer.
function setupLegacyModelPicker(select, accessibleLabel) {
  if (!select || legacyModelPickers.has(select) || !select.parentElement) return;
  const wrapper = document.createElement("div");
  wrapper.className = "legacy-model-picker";
  const trigger = document.createElement("button");
  trigger.type = "button";
  trigger.id = select.id + "-trigger";
  trigger.className = "legacy-model-picker-trigger";
  trigger.setAttribute("aria-haspopup", "listbox");
  trigger.setAttribute("aria-expanded", "false");
  trigger.setAttribute("aria-label", accessibleLabel);
  const menu = document.createElement("div");
  menu.className = "legacy-model-picker-menu";
  menu.id = select.id + "-options";
  menu.setAttribute("role", "listbox");
  const picker = {
    select,
    wrapper,
    trigger,
    menu,
    groups: [],
    expandedGroups: new Set(),
    open: false,
  };
  select.classList.add("legacy-model-picker-native");
  // Keep the native control as the form/state source, but expose only the
  // custom trigger to keyboard and assistive-technology users.
  select.tabIndex = -1;
  select.setAttribute("aria-hidden", "true");
  const associatedLabel = document.querySelector('label[for="' + select.id + '"]');
  if (associatedLabel) associatedLabel.htmlFor = trigger.id;
  select.parentElement.insertBefore(wrapper, select);
  wrapper.append(select, trigger, menu);
  legacyModelPickers.set(select, picker);
  // Project settings wraps this control in a label; prevent nested buttons
  // from re-triggering that label after they handle their own action.
  wrapper.addEventListener("click", (event) => event.stopPropagation());
  trigger.setAttribute("aria-controls", menu.id);
  trigger.addEventListener("click", () => toggleLegacyModelPicker(picker));
  trigger.addEventListener("keydown", (event) => {
    if (event.key === "Escape" && picker.open) {
      event.preventDefault();
      closeLegacyModelPicker(picker, true);
      return;
    }
    if (!picker.open && ["Enter", " ", "ArrowDown", "ArrowUp"].includes(event.key)) {
      event.preventDefault();
      openLegacyModelPicker(picker);
    }
  });
  select.addEventListener("change", () => syncLegacyModelPicker(select));
  document.addEventListener("pointerdown", (event) => {
    if (picker.open && event.target instanceof Node && !wrapper.contains(event.target)) {
      closeLegacyModelPicker(picker);
    }
  });
  document.addEventListener("keydown", (event) => {
    if (picker.open && event.key === "Escape") {
      event.preventDefault();
      closeLegacyModelPicker(picker, true);
    }
  });
  // Fixed positioning lets the menu escape panel scroll containers; close it
  // when geometry changes so it never stays detached from its trigger.
  const closeOnLegacyPickerScroll = (event) => {
    if (event.target instanceof Node && picker.wrapper.contains(event.target)) return;
    if (picker.open) closeLegacyModelPicker(picker);
  };
  document.addEventListener("scroll", closeOnLegacyPickerScroll, true);
  window.addEventListener("resize", closeOnLegacyPickerScroll);
  syncLegacyModelPicker(select);
}

function positionLegacyModelPickerMenu(picker) {
  const triggerRect = picker.trigger.getBoundingClientRect();
  const gap = 6;
  const viewportPadding = 12;
  const preferredHeight = 320;
  const availableBelow = Math.max(0, window.innerHeight - triggerRect.bottom - gap - viewportPadding);
  const availableAbove = Math.max(0, triggerRect.top - gap - viewportPadding);
  const openBelow =
    availableBelow >= Math.min(preferredHeight, window.innerHeight - viewportPadding * 2) ||
    availableBelow >= availableAbove;
  const availableHeight = openBelow ? availableBelow : availableAbove;
  picker.menu.style.left = triggerRect.left + "px";
  picker.menu.style.width = triggerRect.width + "px";
  picker.menu.style.top = openBelow ? triggerRect.bottom + gap + "px" : "";
  picker.menu.style.bottom = openBelow ? "" : window.innerHeight - triggerRect.top + gap + "px";
  picker.menu.style.maxHeight = Math.min(420, availableHeight) + "px";
}

function openLegacyModelPicker(picker) {
  if (picker.select.disabled) return;
  const selectedGroup = picker.groups.find((group) =>
    group.models.some((model) => model.id === picker.select.value),
  );
  if (selectedGroup?.collapsible) picker.expandedGroups.add(selectedGroup.key);
  picker.open = true;
  picker.trigger.setAttribute("aria-expanded", "true");
  positionLegacyModelPickerMenu(picker);
  renderLegacyModelPickerMenu(picker);
}

function closeLegacyModelPicker(picker, restoreFocus = false) {
  picker.open = false;
  picker.trigger.setAttribute("aria-expanded", "false");
  picker.menu.hidden = true;
  if (restoreFocus) picker.trigger.focus();
}

function toggleLegacyModelPicker(picker) {
  if (picker.open) closeLegacyModelPicker(picker);
  else openLegacyModelPicker(picker);
}

function syncLegacyModelPicker(select, groups) {
  const picker = legacyModelPickers.get(select);
  if (!picker) return;
  if (groups) picker.groups = groups;
  const selectedOption = select.selectedOptions?.[0];
  picker.trigger.textContent = selectedOption?.textContent?.trim() || "选择视觉模型";
  picker.trigger.disabled = select.disabled;
  if (select.disabled && picker.open) closeLegacyModelPicker(picker);
  renderLegacyModelPickerMenu(picker);
}

function renderLegacyModelPickerMenu(picker, focusGroupKey = null) {
  // Rebuilding keeps the rendered groups in sync; a requested focus key lets
  // a disclosure toggle preserve the keyboard user's position through it.
  picker.menu.replaceChildren();
  if (!picker.groups.length) {
    const empty = document.createElement("div");
    empty.className = "legacy-model-picker-empty";
    empty.textContent = "暂无可用模型";
    picker.menu.append(empty);
    picker.menu.hidden = !picker.open;
    return;
  }
  for (const group of picker.groups) {
    const section = document.createElement("section");
    section.className = "legacy-model-picker-group";
    const collapsible = group.collapsible === true;
    const expanded = !collapsible || picker.expandedGroups.has(group.key);
    const optionsId = picker.menu.id + "-" + String(group.key).replace(/[^a-zA-Z0-9_-]/g, "-");
    const header = document.createElement(collapsible ? "button" : "div");
    header.className = "legacy-model-picker-group-header";
    header.textContent = group.label;
    if (collapsible) {
      header.type = "button";
      header.dataset.groupKey = group.key;
      header.dataset.expanded = String(expanded);
      header.setAttribute("aria-expanded", String(expanded));
      header.setAttribute("aria-controls", optionsId);
      header.addEventListener("click", () => {
        const shouldRestoreFocus = document.activeElement === header;
        if (picker.expandedGroups.has(group.key)) picker.expandedGroups.delete(group.key);
        else picker.expandedGroups.add(group.key);
        renderLegacyModelPickerMenu(picker, shouldRestoreFocus ? group.key : null);
      });
    } else {
      header.dataset.fixed = "true";
    }
    section.append(header);
    if (expanded) {
      const options = document.createElement("div");
      options.id = optionsId;
      options.className = "legacy-model-picker-options";
      options.setAttribute("role", "group");
      options.setAttribute("aria-label", group.label);
      for (const model of group.models) {
        const option = document.createElement("button");
        option.type = "button";
        option.className = "legacy-model-picker-option";
        option.setAttribute("role", "option");
        option.setAttribute("aria-selected", String(picker.select.value === model.id));
        option.textContent = modelOptionLabel(model);
        if (picker.select.value === model.id) {
          const check = document.createElement("span");
          check.className = "legacy-model-picker-check";
          check.textContent = "✓";
          check.setAttribute("aria-hidden", "true");
          option.append(check);
        }
        option.addEventListener("click", () => {
          if (picker.select.disabled) return;
          picker.select.value = model.id;
          picker.select.dispatchEvent(new Event("change", { bubbles: true }));
          closeLegacyModelPicker(picker, true);
        });
        options.append(option);
      }
      section.append(options);
    }
    picker.menu.append(section);
  }
  picker.menu.hidden = !picker.open;
  if (focusGroupKey) {
    const focusTarget = Array.from(picker.menu.querySelectorAll(".legacy-model-picker-group-header")).find(
      (candidate) => candidate.dataset.groupKey === focusGroupKey,
    );
    if (focusTarget) focusTarget.focus();
  }
}

function modelsForProvider(providerId) {
  const discovered = state.providerModels[providerId];
  if (Array.isArray(discovered)) return discovered;
  if (!state.config) return [];
  return state.config.models
    .filter((model) => model.providers.includes(providerId))
    .map((model, index) => ({
      ...model,
      fixed: true,
      fixedPriority: index,
      verifiedAvailable: false,
    }));
}

function renderModelNote() {
  const model = selectedModel();
  const provider = selectedProvider();
  if (!provider) return;
  const discovery = state.modelDiscovery[provider.id];
  if (discovery?.loading) {
    elements.modelNote.innerHTML =
      "<strong>正在读取可用模型…</strong>";
    return;
  }
  if (!model) {
    elements.modelNote.innerHTML = discovery?.warning
      ? `<strong>没有可用的视觉模型</strong><br>${escapeHtml(discovery.warning)}`
      : "<strong>没有可用的视觉模型</strong>";
    return;
  }
  const quality = model.qualityLabel ? `识别精度 ${model.qualityLabel}` : "";
  const value = model.valueLabel ? `性价比 ${model.valueLabel}` : "";
  const availability = model.verifiedAvailable
    ? "可用"
    : "待验证";
  const warning = discovery?.warning
    ? `<br><span class="model-warning">实时列表读取失败：${escapeHtml(discovery.warning)}</span>`
    : "";
  const details = [quality, value, availability].filter(Boolean).join(" · ");

  elements.modelNote.innerHTML = `
    <strong>${escapeHtml(model.description)}</strong>${details ? `<br>${escapeHtml(details)}` : ""}${
      provider.configured
        ? ""
        : `<br>需要配置 ${(provider.requiredEnv || []).join("、")}`
    }${warning}
  `;
}

function renderApiStatus() {
  const configured = state.config.providers.filter(
    (provider) => provider.configured,
  );
  const ocrReady = state.config.ocr?.enabled && state.config.ocr?.available;
  elements.apiStatus.textContent = configured.length
    ? `API${ocrReady ? " + OCR" : ""} 就绪`
    : "API 未配置";
  elements.apiStatus.classList.toggle("ready", configured.length > 0);
}

function renderOcrSetupLink() {
  elements.ocrSetupLink.hidden = false;
  renderGlobalOcrStatus();
}

function renderGlobalOcrStatus() {
  if (!elements.globalOcrStatus) return;
  const ready = state.config?.ocr?.enabled && state.config?.ocr?.available;
  elements.globalOcrStatus.textContent = ready
    ? "已启用"
    : state.ocrSettings?.setupSkipped
      ? "已跳过"
      : "未配置";
  elements.globalOcrStatus.classList.toggle("is-ready", Boolean(ready));
}

async function maybeShowOcrSetup() {
  if (!state.config) return;

  const ocrReady = state.config.ocr?.enabled && state.config.ocr?.available;
  if (ocrReady) return;

  let settings;
  try {
    settings = await getOcrSettingsApi();
  } catch {
    return;
  }
  state.ocrSettings = settings;
  renderGlobalOcrStatus();
  if (settings.setupCompleted || settings.setupSkipped) return;

  if (settings.pythonPath) elements.ocrPythonPath.value = settings.pythonPath;
  openOcrSetup();
}

async function openOcrSetup() {
  hideError();
  if (!elements.ocrPythonPath.value) {
    try {
      const settings = await getOcrSettingsApi();
      if (settings.pythonPath) elements.ocrPythonPath.value = settings.pythonPath;
    } catch {
      // Keep the dialog usable when persisted OCR settings cannot be read.
    }
  }
  elements.ocrSetupOverlay.hidden = false;
  elements.ocrPythonPath.focus();
}

function closeOcrSetup() {
  elements.ocrSetupOverlay.hidden = true;
}

async function runOcrCheck() {
  const pythonPath = elements.ocrPythonPath.value.trim();
  const resultEl = elements.ocrCheckResult;
  resultEl.hidden = false;
  resultEl.className = "ocr-check-result";
  resultEl.textContent = "正在检测…";
  elements.ocrCheckButton.disabled = true;
  try {
    const result = await checkOcrApi(pythonPath);
    if (result?.ok) {
      resultEl.classList.add("is-ok");
      resultEl.textContent = `✓ 检测通过 · PaddleOCR ${result.paddleOcrVersion || "unknown"}（Paddle ${result.paddleVersion || "unknown"}）`;
    } else {
      resultEl.classList.add("is-error");
      resultEl.textContent = `✗ ${result?.error?.message || "检测失败"}`;
    }
  } catch (error) {
    resultEl.classList.add("is-error");
    resultEl.textContent = `✗ ${error.message}`;
  } finally {
    elements.ocrCheckButton.disabled = false;
  }
}

async function saveOcrSettings() {
  const pythonPath = elements.ocrPythonPath.value.trim();
  if (!pythonPath) {
    showError("请先填写 PaddleOCR Python 环境路径。");
    return;
  }
  hideError();
  elements.ocrSaveButton.disabled = true;
  try {
    await saveOcrSettingsApi({ pythonPath });
    if (state.globalSettings) {
      state.globalSettings = {
        ...state.globalSettings,
        values: { ...state.globalSettings.values, PADDLEOCR_PYTHON: pythonPath },
        overrides: state.globalSettings.overrides.includes("PADDLEOCR_PYTHON")
          ? state.globalSettings.overrides
          : [...state.globalSettings.overrides, "PADDLEOCR_PYTHON"],
      };
      state.globalSettingsDraft.PADDLEOCR_PYTHON = pythonPath;
      state.globalSettingsDirty.delete("PADDLEOCR_PYTHON");
    }
    elements.ocrSetupOverlay.hidden = true;
    await loadConfig();
    renderApiStatus();
    renderGlobalOcrStatus();
    renderGlobalSettingsForm();
  } catch (error) {
    showError(error.message);
  } finally {
    elements.ocrSaveButton.disabled = false;
  }
}

async function skipOcrSetup() {
  try {
    await saveOcrSettingsApi({ skip: true });
    state.ocrSettings = {
      ...(state.ocrSettings || {}),
      setupSkipped: true,
      setupCompleted: false,
    };
    renderGlobalOcrStatus();
    elements.ocrSetupOverlay.hidden = true;
  } catch (error) {
    showError(error.message);
  }
}

async function loadResolveCsv(file) {
  hideError();
  if (!canLoadResolveCsv({ reportReady: state.imageDataGroups.length > 0, slateCsvLoaded: Boolean(state.slateCsvRecords?.length) })) {
    elements.metadataInput.value = "";
    showError("请先选择场记单或场记 CSV，再载入 Resolve CSV。");
    return;
  }
  if (!/\.csv$/i.test(file.name)) {
    elements.metadataInput.value = "";
    showError("请上传从 DaVinci Resolve 导出的 CSV 文件。");
    return;
  }
  if (file.size > 100 * 1024 * 1024) {
    elements.metadataInput.value = "";
    showError("Resolve CSV 文件大小不能超过 100 MB。");
    return;
  }

  try {
    const data = await file.arrayBuffer();
    // Keep the source buffer available for the renderer fallback until the
    // Worker confirms decoding; transferring it here would detach it.
    const { table } = await runCsvBackgroundTask({
      type: "decode-metadata",
      data,
    });
    // Keep the renderer fallback primed without cloning the large table. It is
    // used only if the module Worker becomes unavailable later in the session.
    fallbackCsvProcessor({ type: "prime-metadata", table });
    state.metadataFile = file;
    state.metadataTable = table;
    state.csvEdits.clear();
    elements.metadataFileName.textContent = file.name;
    elements.metadataFileMeta.textContent = `${table.rows.length} 条素材 · ${table.headers.length} 列 · ${encodingLabel(table.format)}`;
    elements.metadataCard.hidden = false;
    elements.metadataDropzone.hidden = true;
    if (state.records.length) {
      renderTable();
      setResultsTab("csv");
    }
  } catch (error) {
    elements.metadataInput.value = "";
    showError(error.message || "无法读取 Resolve CSV。");
  } finally {
    updateRecognizeState();
    updateExportState();
    updateMetadataInputState();
    updateSlateDirectoryState();
  }

}

function clearResolveCsv() {
  clearSlateMetadata();
  state.metadataFile = null;
  state.metadataTable = null;
  clearCsvWorkerMetadata();
  state.csvEdits.clear();
  elements.metadataInput.value = "";
  elements.metadataCard.hidden = true;
  elements.metadataDropzone.hidden = false;
  if (state.records.length) renderTable();
  updateRecognizeState();
  updateExportState();
  updateMetadataInputState();
  updateSlateDirectoryState();
}

async function loadSlateCsv(file) {
  hideError();
  if (!/\.csv$/i.test(file.name)) {
    elements.slateCsvInput.value = "";
    showError("请上传场记系统导出的 CSV 文件。");
    return;
  }
  if (file.size > 10 * 1024 * 1024) {
    elements.slateCsvInput.value = "";
    showError("场记 CSV 文件大小不能超过 10 MB。");
    return;
  }

  try {
    const text = await file.text();
    const { parseSlateCsv } = await import("./slate-csv-parser.js");
    const { records } = parseSlateCsv(text);
    state.slateCsvRecords = records;
    state.slateCsvFileName = file.name;
    elements.slateCsvFileName.textContent = file.name;
    elements.slateCsvFileMeta.textContent = `${records.length} 条场记记录`;
    elements.slateCsvCard.hidden = false;
    elements.slateCsvDropzone.hidden = true;
    if (shouldResetSlateCsvResults(state.latestResponse?.inputMode)) {
      resetRecognitionResults();
    }
    updateMetadataInputState();
    updateRecognizeState();
  } catch (error) {
    elements.slateCsvInput.value = "";
    showError(error.message || "无法读取场记 CSV。");
  }
}

function clearSlateCsv() {
  const clearMergedResults = shouldResetSlateCsvResults(
    state.latestResponse?.inputMode,
  );
  state.slateCsvRecords = null;
  state.slateCsvFileName = null;
  elements.slateCsvInput.value = "";
  elements.slateCsvCard.hidden = true;
  elements.slateCsvDropzone.hidden = false;
  if (clearMergedResults) resetRecognitionResults();
  updateMetadataInputState();
  updateRecognizeState();
}

async function loadReportFile(file) {
  hideError();
  const allowed = state.config?.upload?.acceptedTypes || [
    "image/jpeg",
    "image/png",
    "image/webp",
    "application/pdf",
  ];
  const isPdf = file.type === "application/pdf" || /\.pdf$/i.test(file.name);
  if (!allowed.includes(file.type) && !isPdf) {
    showError("只支持 PDF、JPEG、PNG 或 WebP。");
    return;
  }
  if (file.size > (state.config?.upload?.maxBytes || 20 * 1024 * 1024)) {
    showError("文件大小不能超过 20 MB。");
    return;
  }

  if (!(await flushPendingTaskSave())) {
    elements.imageInput.value = "";
    return;
  }
  // Selecting a source document starts a new task. Invalidate a historical
  // task load before clearing its UI, then restore this project's defaults.
  taskOperations.invalidate();
  state.currentTaskId = null;
  taskAutosave.reset();
  applyNewTaskRecognitionDefaults();
  renderTaskSwitcher();

  if (state.metadataTable || state.slateMetadata.length) clearResolveCsv();
  resetRecognitionResults();
  try {
    setPreparing(true);
    let imageGroups = [];
    let previewPages = [];
    let pageCount;
    let meta;
    if (isPdf) {
      const prepared = await preparePdf(file);
      imageGroups = prepared.imageDataGroups;
      previewPages = imageGroups.map((group) => group[0]);
      pageCount = prepared.pageCount;
      meta = `${formatBytes(file.size)} · ${pageCount} 页 · 多视图双重查漏`;
    } else {
      const processed = await prepareImage(file);
      imageGroups = [processed.imageDataGroup];
      previewPages = [processed.dataUrl];
      pageCount = 1;
      meta = `${formatBytes(file.size)} · ${processed.width} × ${processed.height} · 多视图核心复核`;
    }

    state.reportFile = file;
    state.imageDataGroups = imageGroups;
    state.pageCount = pageCount;
    elements.fileThumb.src = previewPages[0];
    renderPreviewPages(previewPages);
    elements.fileName.textContent = file.name;
    elements.fileMeta.textContent = meta;
    elements.fileCard.hidden = false;
    elements.dropzone.hidden = true;
    elements.emptyPreview.hidden = true;
    elements.previewScroll.hidden = false;
    updateTaskProgress({
      phase: "prepare-complete",
      percent: 100,
      message: `${pageCount} 页场记单图像已准备完成`,
    });
  } catch (error) {
    clearReportFile();
    showError(error.message || "无法读取文件。");
  } finally {
    setPreparing(false);
    updateRecognizeState();
    updateMetadataInputState();
    updateSlateDirectoryState();
  }
}

function clearReportFile() {
  if (state.metadataTable || state.slateMetadata.length) clearResolveCsv();
  state.reportFile = null;
  state.imageDataGroups = [];
  state.pageCount = 0;
  resetRecognitionResults();
  elements.imageInput.value = "";
  elements.fileCard.hidden = true;
  elements.dropzone.hidden = false;
  elements.emptyPreview.hidden = false;
  elements.previewScroll.hidden = true;
  elements.previewScroll.innerHTML = "";
  updateRecognizeState();
}

function renderPreviewPages(pages) {
  elements.previewScroll.innerHTML = pages
    .map(
      (src, index) => `
        <figure class="preview-page">
          <img src="${src}" alt="场记单第 ${index + 1} 页" loading="lazy" decoding="async" />
          <figcaption>第 ${index + 1} 页 · 共 ${pages.length} 页</figcaption>
        </figure>`,
    )
    .join("");
}

async function prepareImage(file) {
  updateTaskProgress({
    phase: "preparing",
    percent: 12,
    message: "正在读取图片并检查分辨率",
  });
  const source = await fileToDataUrl(file);
  const image = await loadImage(source);
  updateTaskProgress({
    phase: "preparing",
    percent: 60,
    message: "正在生成模型输入图像",
  });
  const maxDimension = 2600;
  const scale = Math.min(1, maxDimension / Math.max(image.width, image.height));
  const width = Math.max(1, Math.round(image.width * scale));
  const height = Math.max(1, Math.round(image.height * scale));

  const canvas = document.createElement("canvas");
  canvas.width = width;
  canvas.height = height;
  const context = canvas.getContext("2d", { alpha: false });
  context.fillStyle = "#ffffff";
  context.fillRect(0, 0, width, height);
  context.drawImage(image, 0, 0, width, height);

  const croppedCanvas = cropVerticalWhitespace(canvas);
  const detailLayout = calculateDetailSegments(croppedCanvas.height);
  // Image uploads must receive the same full + repeated-header core views as
  // PDFs; otherwise high-accuracy mode gets only one downscaled JPEG for the
  // tiny C0XX and scene/shot/take cells in a photographed slate.
  const imageDataGroup = [
    await canvasToDataUrl(resizeCanvas(croppedCanvas, 2600), "image/jpeg", 0.92),
  ];
  for (const segment of detailLayout.segments) {
    await yieldToRenderer();
    const detailCanvas = resizeCanvas(
      createDetailComposite(croppedCanvas, detailLayout.header, segment),
      3000,
      true,
    );
    imageDataGroup.push(await canvasToDataUrl(detailCanvas, "image/jpeg", 0.93));
  }

  const prepared = {
    dataUrl: imageDataGroup[0],
    imageDataGroup,
    width,
    height,
  };
  updateTaskProgress({
    phase: "preparing",
    percent: 95,
    message: "图片预处理完成",
  });
  return prepared;
}

async function preparePdf(file) {
  let documentHandle;
  try {
    const arrayBuffer = await file.arrayBuffer();
    const loadingTask = pdfjsLib.getDocument({
      data: new Uint8Array(arrayBuffer),
    });
    documentHandle = await loadingTask.promise;
    if (!documentHandle.numPages) throw new Error("PDF 中没有可识别的页面");
    if (documentHandle.numPages > 20) {
      throw new Error("PDF 最多支持 20 页，请拆分后重新上传");
    }

    let completedPages = 0;
    const pageNumbers = Array.from(
      { length: documentHandle.numPages },
      (_, index) => index + 1,
    );
    const imageDataGroups = await mapWithConcurrency(
      pageNumbers,
      PDF_PREPARE_CONCURRENCY,
      async (pageNumber) => {
        updateTaskProgress({
          phase: "preparing",
          percent: 5 + Math.round((completedPages / documentHandle.numPages) * 90),
          message: `正在准备第 ${pageNumber}/${documentHandle.numPages} 页高清图像`,
          completed: completedPages,
          total: documentHandle.numPages,
        });
        const imageGroup = await preparePdfPage(documentHandle, pageNumber);
        completedPages += 1;
        updateTaskProgress({
          phase: "preparing",
          percent: 5 + Math.round((completedPages / documentHandle.numPages) * 90),
          message: `已生成 ${completedPages}/${documentHandle.numPages} 页整页图与局部放大图`,
          completed: completedPages,
          total: documentHandle.numPages,
        });
        return imageGroup;
      },
    );

    return {
      imageDataGroups,
      previewDataUrl: imageDataGroups[0][0],
      pageCount: documentHandle.numPages,
    };
  } catch (error) {
    if (error?.name === "PasswordException") {
      throw new Error("PDF 已加密，请移除密码后再上传。");
    }
    throw new Error(`无法读取 PDF：${error?.message || "文件可能已损坏"}`);
  } finally {
    if (documentHandle) await documentHandle.destroy();
  }
}

async function preparePdfPage(documentHandle, pageNumber) {
  const page = await documentHandle.getPage(pageNumber);
  try {
    const baseViewport = page.getViewport({ scale: 1 });
    const scale = Math.min(
      4,
      3000 / Math.max(baseViewport.width, baseViewport.height),
    );
    const viewport = page.getViewport({ scale });
    const canvas = document.createElement("canvas");
    canvas.width = Math.ceil(viewport.width);
    canvas.height = Math.ceil(viewport.height);
    const context = canvas.getContext("2d", { alpha: false });
    context.fillStyle = "#ffffff";
    context.fillRect(0, 0, canvas.width, canvas.height);
    await page.render({
      canvasContext: context,
      viewport,
      background: "#ffffff",
    }).promise;
    const croppedCanvas = cropVerticalWhitespace(canvas);
    const outputCanvas = resizeCanvas(croppedCanvas, 2600);
    const detailLayout = calculateDetailSegments(croppedCanvas.height);
    const output = [await canvasToDataUrl(outputCanvas, "image/jpeg", 0.92)];
    for (const segment of detailLayout.segments) {
      await yieldToRenderer();
      const detailCanvas = resizeCanvas(
        createDetailComposite(croppedCanvas, detailLayout.header, segment),
        3000,
        true,
      );
      output.push(await canvasToDataUrl(detailCanvas, "image/jpeg", 0.93));
    }
    return output;
  } finally {
    page.cleanup();
  }
}

async function mapWithConcurrency(items, limit, mapper) {
  const results = new Array(items.length);
  let nextIndex = 0;

  async function worker() {
    while (nextIndex < items.length) {
      const index = nextIndex;
      nextIndex += 1;
      results[index] = await mapper(items[index], index);
    }
  }

  const workerCount = Math.min(Math.max(1, limit), items.length);
  await Promise.all(Array.from({ length: workerCount }, () => worker()));
  return results;
}

function cropVerticalWhitespace(sourceCanvas) {
  const analysisWidth = Math.min(512, sourceCanvas.width);
  const analysisHeight = Math.max(
    1,
    Math.round((sourceCanvas.height * analysisWidth) / sourceCanvas.width),
  );
  const analysisCanvas = document.createElement("canvas");
  analysisCanvas.width = analysisWidth;
  analysisCanvas.height = analysisHeight;
  const analysisContext = analysisCanvas.getContext("2d", { alpha: false });
  analysisContext.fillStyle = "#ffffff";
  analysisContext.fillRect(0, 0, analysisWidth, analysisHeight);
  analysisContext.drawImage(sourceCanvas, 0, 0, analysisWidth, analysisHeight);

  const bounds = findDenseRowBand(
    analysisContext.getImageData(0, 0, analysisWidth, analysisHeight),
  );
  if (!bounds.cropped) return sourceCanvas;

  const sourceTop = Math.max(
    0,
    Math.floor((bounds.top * sourceCanvas.height) / analysisHeight),
  );
  const sourceBottom = Math.min(
    sourceCanvas.height,
    Math.ceil((bounds.bottom * sourceCanvas.height) / analysisHeight),
  );
  const sourceHeight = Math.max(1, sourceBottom - sourceTop);
  const output = document.createElement("canvas");
  output.width = sourceCanvas.width;
  output.height = sourceHeight;
  const outputContext = output.getContext("2d", { alpha: false });
  outputContext.fillStyle = "#ffffff";
  outputContext.fillRect(0, 0, output.width, output.height);
  outputContext.drawImage(
    sourceCanvas,
    0,
    sourceTop,
    sourceCanvas.width,
    sourceHeight,
    0,
    0,
    output.width,
    output.height,
  );
  return output;
}

function createDetailComposite(sourceCanvas, header, segment) {
  const headerHeight = Math.max(1, header.bottom - header.top);
  const segmentHeight = Math.max(1, segment.bottom - segment.top);
  const sourceWidth = calculateCoreColumnWidth(sourceCanvas.width);
  const output = document.createElement("canvas");
  output.width = sourceWidth;
  output.height = headerHeight + segmentHeight;
  const context = output.getContext("2d", { alpha: false });
  context.fillStyle = "#ffffff";
  context.fillRect(0, 0, output.width, output.height);
  context.drawImage(
    sourceCanvas,
    0,
    header.top,
    sourceWidth,
    headerHeight,
    0,
    0,
    output.width,
    headerHeight,
  );
  context.drawImage(
    sourceCanvas,
    0,
    segment.top,
    sourceWidth,
    segmentHeight,
    0,
    headerHeight,
    output.width,
    segmentHeight,
  );
  return output;
}

function resizeCanvas(sourceCanvas, maxDimension, allowUpscale = false) {
  const scale = Math.min(
    allowUpscale ? Number.POSITIVE_INFINITY : 1,
    maxDimension / Math.max(sourceCanvas.width, sourceCanvas.height),
  );
  if (scale === 1) return sourceCanvas;

  const output = document.createElement("canvas");
  output.width = Math.max(1, Math.round(sourceCanvas.width * scale));
  output.height = Math.max(1, Math.round(sourceCanvas.height * scale));
  const context = output.getContext("2d", { alpha: false });
  context.fillStyle = "#ffffff";
  context.fillRect(0, 0, output.width, output.height);
  context.drawImage(sourceCanvas, 0, 0, output.width, output.height);
  return output;
}

async function recognize() {
  await refreshRuntimeConfig();
  if (recognitionReady()) {
    return recognizeWithPdf();
  }
  if (slateCsvMergeReady()) {
    return mergeSlateCsv();
  }
}

async function recognizeWithPdf() {
  if (!(await flushPendingTaskSave())) return;
  hideError();
  resetRecognitionResults();
  setProcessing(true);
  // Capture the request owner before awaiting IPC. Navigation is guarded while
  // recognizing, and this snapshot remains the final defence against stale UI
  // state if a future route introduces another way to change projects.
  const requestProjectId = state.currentProjectId;
  const requestSettingsSnapshot = cloneSettings(state.currentProject?.settings);

  try {
    const requestBody = await recognitionRequestBody();
    const data = await recognizeApi(requestBody, updateTaskProgress);
    const resultProjectId = data.projectId || requestProjectId;
    if (resultProjectId !== state.currentProjectId) {
      throw new Error("识别结果所属项目已变化，请返回原项目查看已保存任务。");
    }

    state.latestResponse = data;
    state.activeTaskSettings = data.projectSettingsSnapshot
      || requestSettingsSnapshot
      || state.activeTaskSettings;
    state.records = data.result.records.map(applyRecordFieldFormats);
    state.latestResponse.result.records = state.records;
    if (data.taskId) {
      state.currentTaskId = data.taskId;
      if (state.currentProject && data.lastRecognitionDefaults) {
        state.currentProject.lastRecognitionDefaults = data.lastRecognitionDefaults;
      }
      taskAutosave.reset();
      await loadTaskList(resultProjectId);
    }
    renderResults(data);
    await refreshScenarioProfiles(resultProjectId);
  } catch (error) {
    markTaskProgressError(error.message);
    showError(error.message);
  } finally {
    setProcessing(false);
  }
}

function cloneSettings(settings) {
  if (!settings || typeof settings !== "object") return null;
  return JSON.parse(JSON.stringify(settings));
}

async function mergeSlateCsv() {
  if (!(await flushPendingTaskSave())) return;
  hideError();
  resetRecognitionResults();
  state.currentTaskId = null;
  renderTaskSwitcher();

  // Build records from slate CSV, using Resolve CSV material keys.
  const records = state.slateCsvRecords.map((sr, index) =>
    applyRecordFieldFormats({
      id: `slate-csv-${index}`,
      cardNumber: sr.materialKey?.match(/^([A-Z]\d+)/)?.[1] || null,
      videoCode: sr.materialKey?.match(/(C\d+)$/)?.[1] || null,
      scene: sr.scene,
      shot: sr.shot,
      take: sr.take,
      takeStatus: sr.comments,
      description: null,
      comments: null,
      shotSize: null,
      cameraPosition: null,
      confidence: "high",
    }),
  );

  state.records = records;
  state.latestResponse = {
    result: {
      sheetTitle: state.slateCsvFileName || "场记 CSV",
      records,
      warnings: [],
    },
    provider: null,
    model: null,
    inputMode: "slate-csv",
    accuracyMode: null,
    durationMs: 0,
    pageCount: 0,
    usage: null,
    ocr: { used: false, enabled: false },
  };
  renderResults(state.latestResponse);
}

async function recognitionRequestBody() {
  const maxRequestBytes =
    Number(state.config?.upload?.maxRequestBytes) || 80 * 1024 * 1024;
  let body = serializeCurrentRecognitionRequest();
  if (requestBodyFits(body, maxRequestBytes)) return body;

  for (const profile of REQUEST_COMPRESSION_PROFILES) {
    updateTaskProgress({
      phase: "preparing",
      percent: 2,
      message: `上传内容较大，正在压缩至 ${profile.maxDimension}px`,
    });
    await recompressImageGroups(profile);
    body = serializeCurrentRecognitionRequest();
    if (requestBodyFits(body, maxRequestBytes)) return body;
  }

  throw new Error(
    `处理后的场记单仍有 ${formatBytes(requestBodyBytes(body))}，超过上传限制，请拆分 PDF 后重试。`,
  );
}

function serializeCurrentRecognitionRequest() {
  const accuracyMode = elements.accuracyMode.value;
  const serialized = serializeRecognitionPayload({
    provider: elements.provider.value,
    model: elements.model.value,
    filename: state.reportFile.name,
    imageDataGroups: selectRecognitionImageGroups(
      state.imageDataGroups,
      accuracyMode,
    ),
    pageCount: state.pageCount,
    accuracyMode,
    customPrompt: elements.customPromptInput.value.trim(),
    scenarioId: elements.scenario.value || null,
    slateCsvRecords: state.slateCsvRecords,
  });
  const payload = JSON.parse(serialized);
  if (state.currentProjectId) {
    payload.projectId = state.currentProjectId;
    // Preserve an intentionally empty remembered prompt; omitting the field
    // would make the main process fall back to the project's older prompt.
    payload.customPrompt = elements.customPromptInput.value.trim();
  }
  return JSON.stringify(payload);
}

async function recompressImageGroups({ maxDimension, quality }) {
  const images = state.imageDataGroups.flatMap((group) =>
    group.map((_dataUrl, index) => ({ group, index })),
  );
  await mapWithConcurrency(
    images,
    PDF_PREPARE_CONCURRENCY,
    async ({ group, index }) => {
      const image = await loadImage(group[index]);
      const scale = Math.min(
        1,
        maxDimension / Math.max(image.naturalWidth, image.naturalHeight),
      );
      const width = Math.max(1, Math.round(image.naturalWidth * scale));
      const height = Math.max(1, Math.round(image.naturalHeight * scale));
      const canvas = document.createElement("canvas");
      canvas.width = width;
      canvas.height = height;
      const context = canvas.getContext("2d", { alpha: false });
      context.fillStyle = "#ffffff";
      context.fillRect(0, 0, width, height);
      context.drawImage(image, 0, 0, width, height);
      // Oversized-request recompression shares the same asynchronous encoder
      // as initial preparation so clicking Recognize cannot freeze the UI.
      group[index] = await canvasToDataUrl(canvas, "image/jpeg", quality);
      canvas.width = 1;
      canvas.height = 1;
      await yieldToRenderer();
    },
  );
}


function setResultsTab(name) {
  const showCsv = name === "csv";
  elements.tabCsv.classList.toggle("is-active", showCsv);
  elements.tabCsv.setAttribute("aria-selected", String(showCsv));
  elements.tabCsv.tabIndex = showCsv ? 0 : -1;
  elements.tabDetail.classList.toggle("is-active", !showCsv);
  elements.tabDetail.setAttribute("aria-selected", String(!showCsv));
  elements.tabDetail.tabIndex = showCsv ? -1 : 0;
  elements.panelCsv.hidden = !showCsv;
  elements.panelDetail.hidden = showCsv;
}

function handleRecognitionShortcut(event) {
  if (event.key !== "Enter" || (!event.metaKey && !event.ctrlKey)) return;
  const target = event.target;
  if (
    target instanceof HTMLElement &&
    target.matches("input, textarea, select, button, [contenteditable='true']")
  ) return;
  if (elements.recognizeButton.disabled) return;
  event.preventDefault();
  recognize();
}

function renderResults(data) {
  const count = data.result.records.length;
  elements.resultSummary.textContent = `${data.result.sheetTitle || "未命名场记单"} · ${count} 条记录`;

  const usage = data.usage || {};
  const metrics = data.inputMode === "slate-csv"
    ? ["SOURCE SLATE CSV", "MODE LOCAL MERGE", `ROWS ${count}`]
    : [
        `API ${data.provider}`,
        `MODEL ${data.model}`,
        // Historical snapshots may say "pdf", but every current model request
        // is rasterized into page images before it reaches Main.
        `MODE ${data.accuracyMode === "high" ? "HIGH ACCURACY" : "IMAGE"}`,
        `PAGES ${state.pageCount}`,
        `TIME ${(data.durationMs / 1000).toFixed(1)}s`,
      ];
  if (usage.input_tokens ?? usage.prompt_tokens) {
    metrics.push(`IN ${usage.input_tokens ?? usage.prompt_tokens} TOKENS`);
  }
  if (usage.output_tokens ?? usage.completion_tokens) {
    metrics.push(`OUT ${usage.output_tokens ?? usage.completion_tokens} TOKENS`);
  }
  if (data.ocr?.used) {
    metrics.push(`OCR ${data.ocr.model || "PaddleOCR"}`);
    metrics.push(`OCR BLOCKS ${data.ocr.blockCount}`);
    metrics.push(`OCR TIME ${(Number(data.ocr.durationMs || 0) / 1000).toFixed(1)}s`);
    if (data.ocr.cacheHit) metrics.push("OCR CACHE HIT");
  } else if (data.ocr?.enabled) {
    metrics.push("OCR FALLBACK");
  }
  if (data.scenario?.id) {
    const profile = state.scenarioProfiles.find(
      (candidate) => candidate.id === data.scenario.id,
    );
    metrics.push(
      `SCENARIO ${profile?.label || data.scenario.id} ${data.scenario.match || "matched"}`,
    );
  } else if (data.scenario?.warning) {
    metrics.push("SCENARIO FALLBACK");
  }
  elements.metrics.innerHTML = metrics
    .map((metric) => `<span class="metric">${escapeHtml(metric)}</span>`)
    .join("");

  renderTable();
  setResultsTab(state.metadataTable ? "csv" : "detail");
  elements.results.hidden = false;
  updateWorkflowSteps();
  elements.results.scrollIntoView({ behavior: "smooth", block: "start" });
}

// 识别明细的搜索 + 排序。只改变显示顺序/可见性，不改动原始索引——每项都
// 携带原始 index，编辑/删除仍写回 state.records[index]。
function detailSearchMatches(record, query) {
  if (!query) return true;
  const hay = [
    record.cardNumber,
    record.videoCode,
    `${record.cardNumber || ""}${record.videoCode || ""}`,
    record.scene,
    record.shot,
    record.take,
  ]
    .filter((value) => value != null && value !== "")
    .join(" ")
    .toUpperCase();
  return hay.includes(query);
}

function detailSortKey(field, record) {
  const value = record[field];
  if (value == null || value === "") return null;
  return String(value);
}

// 排序比较：空值恒排末尾；非空用 numeric localeCompare，兼顾 C009/C015 与
// 001/037 的数值序和中文（状态/景别）的本地化排序。
function compareDetailRecords(a, b) {
  const av = detailSortKey(state.detailSort.field, a.record);
  const bv = detailSortKey(state.detailSort.field, b.record);
  if (av == null && bv == null) return 0;
  if (av == null) return 1;
  if (bv == null) return -1;
  return (
    av.localeCompare(bv, undefined, { numeric: true }) *
    state.detailSort.direction
  );
}

// 返回搜索过滤 + 排序后的可见记录，元素带原始 index（供编辑/删除回写）。
function visibleDetailRecords() {
  const query = state.detailSearch.trim().toUpperCase();
  const entries = [];
  for (let index = 0; index < state.records.length; index++) {
    if (!detailSearchMatches(state.records[index], query)) continue;
    entries.push({ index, record: state.records[index] });
  }
  if (state.detailSort.field) {
    entries.sort((a, b) => {
      const cmp = compareDetailRecords(a, b);
      return cmp !== 0 ? cmp : a.index - b.index;
    });
  }
  return entries;
}

function toggleDetailSort(field) {
  if (state.detailSort.field === field) {
    state.detailSort.direction = state.detailSort.direction === 1 ? -1 : 1;
  } else {
    state.detailSort.field = field;
    state.detailSort.direction = 1;
  }
  renderDetailSortIndicators();
  renderTable();
}

function renderDetailSortIndicators() {
  for (const th of document.querySelectorAll("th[data-sort]")) {
    const indicator = th.querySelector(".sort-indicator");
    if (!indicator) continue;
    if (state.detailSort.field === th.dataset.sort) {
      indicator.textContent = state.detailSort.direction === 1 ? "▲" : "▼";
      th.classList.add("is-sorted");
    } else {
      indicator.textContent = "";
      th.classList.remove("is-sorted");
    }
  }
}

function renderTable() {
  const output = currentMergeOutput();
  const statuses = output.statuses;
  elements.tabDetailBadge.textContent = String(state.records.length);
  elements.tabDetailBadge.hidden = state.records.length === 0;
  renderCsvPreview(output);
  elements.resultBody.innerHTML = visibleDetailRecords()
    .map(({ index, record }) => {
      const status = statuses[index];
      return `
      <tr data-index="${index}"${record.takeStatus === "过" ? ' class="is-keeper"' : ""}>
        <td>${index + 1}</td>
        <td>${record.sourcePage || "-"}</td>
        ${textCell("cardNumber", record.cardNumber)}
        ${textCell("videoCode", record.videoCode)}
        ${textCell("scene", record.scene)}
        ${textCell("shot", record.shot)}
        ${textCell("take", record.take)}
        <td>
          <select data-field="takeStatus"${isProjectReadOnly() ? " disabled" : ""}>
            <option value="" ${record.takeStatus == null ? "selected" : ""}>未标记（留空）</option>
            <option value="过" ${record.takeStatus === "过" ? "selected" : ""}>☑ / √ → ${escapeHtml(resolveCommentsConfig().goodTake)}</option>
            <option value="保" ${record.takeStatus === "保" ? "selected" : ""}>△ / 三角形 → ${escapeHtml(resolveCommentsConfig().holdTake)}</option>
            <option value="废条" ${record.takeStatus === "废条" ? "selected" : ""}>X / × → 留空</option>
          </select>
        </td>
        ${textCell("description", record.description, "min-width:180px")}
        ${textCell("comments", record.comments, "min-width:160px")}
        ${textCell("shotSize", record.shotSize)}
        ${textCell("cameraPosition", record.cameraPosition)}
        <td>${exportLabel(status, record)}${missingMetadataBadge(record)}</td>
        <td><span class="confidence ${escapeHtml(record.confidence)}">${confidenceLabel(record.confidence)}</span></td>
        <td><button class="delete-row" type="button" aria-label="删除这一行"${isProjectReadOnly() ? " disabled" : ""}>×</button></td>
      </tr>`;
    })
    .join("");

  for (const row of elements.resultBody.querySelectorAll("tr")) {
    const index = Number(row.dataset.index);
    for (const input of row.querySelectorAll("[data-field]")) {
      if (isProjectReadOnly()) continue;
      const applyInput = () => {
        const field = input.dataset.field;
        state.records[index][field] = normalizeEditedField(
          field,
          input.value,
        );
        saveCurrentTask();
      };
      input.addEventListener("input", applyInput);
      input.addEventListener("change", () => {
        applyInput();
        input.value = state.records[index][input.dataset.field] || "";
        // 状态改为“过”时圈出次号，还原场记单上的圈条笔迹。
        if (input.dataset.field === "takeStatus") {
          row.classList.toggle(
            "is-keeper",
            state.records[index].takeStatus === "过",
          );
        }
        renderDerivedResultsAfterEdit();
      });
    }
    if (isProjectReadOnly()) continue;
    row.querySelector(".delete-row").addEventListener("click", () => {
      state.records.splice(index, 1);
      renderTable();
      saveCurrentTask();
    });
  }

  renderWarnings(output);
  renderResultSummary(output);
  updateExportState(output);
}

function renderDerivedResultsAfterEdit() {
  const output = currentMergeOutput();
  renderCsvPreview(output);
  renderWarnings(output);
  renderResultSummary(output);
  updateExportState(output);
}

function renderCsvPreview(output) {
  if (!output?.table) {
    elements.tabCsvBadge.hidden = true;
    elements.csvPreviewSummary.textContent = state.records.length
      ? "已保留识别结果"
      : "回填预览";
    elements.csvResultHead.innerHTML = "";
    elements.csvResultBody.innerHTML = "";
    elements.csvResultEmpty.textContent = state.records.length
      ? "未载入 Resolve CSV · 可在详情页校对后直接导出。"
      : "识别后显示回填结果。";
    elements.csvResultEmpty.hidden = false;
    return;
  }

  const table = applyCsvEdits(output.table);
  const { headers, rows } = table;
  const columns = resolveColumnIndexes(table.headers);
  const targetIndexes = new Set([
    columns.scene,
    columns.shot,
    columns.take,
    columns.comments,
    columns.cameraFps,
    columns.shootDay,
  ]);
  const matchedRowIndexes = new Set();
  for (const status of output.statuses || []) {
    if (status?.status !== "matched") continue;
    for (const rowIndex of status.rowIndexes || []) {
      matchedRowIndexes.add(rowIndex);
    }
  }
  const unrecognizedRowIndexes = new Set(output.unrecognizedRowIndexes || []);

  const anomalyMessagesByKey = new Map();
  for (const anomaly of detectSlateSequenceAnomalies(state.records)) {
    if (!anomaly.key) continue;
    const existing = anomalyMessagesByKey.get(anomaly.key);
    anomalyMessagesByKey.set(
      anomaly.key,
      existing ? `${existing}；${anomaly.message}` : anomaly.message,
    );
  }
  const anomalyRowIndexes = new Set();
  for (const [rowIndex, rowKey] of (output.rowKeys || []).entries()) {
    if (rowKey && anomalyMessagesByKey.has(rowKey)) {
      anomalyRowIndexes.add(rowIndex);
    }
  }
  const flaggedRowCount = new Set([
    ...anomalyRowIndexes,
    ...unrecognizedRowIndexes,
  ]).size;

  elements.csvPreviewSummary.textContent =
    `${rows.length} 行 × ${headers.length} 列` +
    (flaggedRowCount ? ` · ${flaggedRowCount} 行异常已标红` : "");
  elements.tabCsvBadge.textContent = `${rows.length}×${headers.length}`;
  elements.tabCsvBadge.hidden = false;
  elements.csvResultHead.innerHTML = `<tr>${headers
    .map(
      (header, columnIndex) =>
        `<th class="${targetIndexes.has(columnIndex) ? "csv-target-column" : ""}" title="${escapeHtml(header)}">${escapeHtml(header)}</th>`,
    )
    .join("")}</tr>`;
  elements.csvResultBody.innerHTML = rows
    .map((row, rowIndex) => {
      const rowKey = output.rowKeys?.[rowIndex] || "";
      const missing = Boolean(rowKey && state.missingMetadataKeys.has(rowKey));
      const anomalyMessage = anomalyRowIndexes.has(rowIndex)
        ? anomalyMessagesByKey.get(rowKey)
        : null;
      const cells = headers
        .map((_, columnIndex) => {
          const classes = [
            targetIndexes.has(columnIndex) ? "csv-target-column" : "",
            state.csvEdits.has(`${rowIndex}:${columnIndex}`)
              ? "csv-cell-edited"
              : "",
          ]
            .filter(Boolean)
            .join(" ");
          const flag =
            missing && columnIndex === 0
              ? `<span class="missing-metadata" title="素材目录中没有读取到元数据文件">无元数据</span>`
              : "";
          const cellClasses =
            missing && columnIndex === 0 ? `${classes} csv-flag-cell`.trim() : classes;
          const value = String(row[columnIndex] ?? "");
          const readOnly = isProjectReadOnly() ? " readonly" : "";
          return `<td class="${cellClasses}">${flag}<input data-row="${rowIndex}" data-col="${columnIndex}" value="${escapeHtml(value)}"${readOnly} /></td>`;
        })
        .join("");
      const rowClass = [
        matchedRowIndexes.has(rowIndex) ? "csv-matched-row" : "",
        unrecognizedRowIndexes.has(rowIndex) ? "csv-unrecognized-row" : "",
        missing ? "csv-missing-metadata-row" : "",
        anomalyMessage ? "csv-anomaly-row" : "",
      ]
        .filter(Boolean)
        .join(" ");
      const titleText = [
        missing ? "无元数据：素材目录中没有读取到元数据文件" : "",
        anomalyMessage ? `序列异常：${anomalyMessage}` : "",
      ]
        .filter(Boolean)
        .join("；");
      const rowTitle = titleText
        ? ` title="${escapeHtml(titleText)}"`
        : "";
      return `<tr class="${rowClass}"${rowTitle}>${cells}</tr>`;
    })
    .join("");

  bindCsvPreviewEdits(columns);

  elements.csvResultEmpty.textContent = "合成后的 CSV 没有数据行。";
  elements.csvResultEmpty.hidden = rows.length > 0;
}

function bindCsvPreviewEdits(columns) {
  for (const input of elements.csvResultBody.querySelectorAll(
    "[data-row][data-col]",
  )) {
    if (isProjectReadOnly()) continue;
    const applyInput = () => {
      const rowIndex = Number(input.dataset.row);
      const columnIndex = Number(input.dataset.col);
      const value = normalizeCsvCellEdit(
        fieldForColumn(columns, columnIndex),
        input.value,
      );
      const key = `${rowIndex}:${columnIndex}`;
      state.csvEdits.set(key, value);
      input.closest("td")?.classList.add("csv-cell-edited");
      // Keep the current input mounted; rebuilding a large CSV table on every
      // keystroke made manual correction noticeably laggy and lost focus.
      updateExportState({ exportableCount: 0 });
      saveCurrentTask();
    };
    input.addEventListener("input", applyInput);
    input.addEventListener("change", () => {
      applyInput();
      const key = `${input.dataset.row}:${input.dataset.col}`;
      input.value = state.csvEdits.get(key) || "";
    });
  }
}

function currentMergeOutput() {
  if (state.metadataTable) {
    return mergeSlateIntoResolveTable(
      state.metadataTable,
      state.records,
      state.slateMetadata,
      {
        fieldFormats: resolveFieldFormats(),
        comments: resolveCommentsConfig(),
      },
    );
  }
  return {
    table: null,
    statuses: state.records.map((_, recordIndex) => ({
      recordIndex,
      status: "no-metadata",
    })),
    warnings: [],
    matchedRecordCount: 0,
    updatedRowCount: 0,
    exportableCount: 0,
  };
}

function renderResultSummary(output) {
  const title = state.latestResponse?.result?.sheetTitle || "未命名场记单";
  const base = `${title} · 识别 ${state.records.length} 条`;
  elements.resultSummary.textContent = state.metadataTable
    ? `${base} · 覆盖 ${output.recognizedMaterialCount}/${output.expectedMaterialCount} 个 CSV 素材 · 可回填 ${output.matchedRecordCount} 条 / ${output.updatedRowCount} 行${state.slateMetadata.length ? ` · Camera FPS ${output.cameraFpsMatchedMaterialCount} 个素材 / ${output.cameraFpsMatchedRowCount} 行 · Shoot Day ${output.shootDayMatchedMaterialCount} 个素材 / ${output.shootDayMatchedRowCount} 行` : ""}`
    : `${base} · 可直接导出识别结果`;
}

function renderWarnings(output) {
  const warnings = [
    ...(state.latestResponse?.result?.warnings || []),
    ...(state.latestResponse?.scenario?.warning
      ? [state.latestResponse.scenario.warning]
      : []),
    ...state.slateWarnings,
    ...(output?.warnings || []),
  ];
  elements.warningList.hidden = warnings.length === 0;
  elements.tabWarningDot.hidden = warnings.length === 0;
  elements.warningList.innerHTML = warnings
    .map((warning) => `⚠ ${escapeHtml(warning)}`)
    .join("<br>");
}

function textCell(field, value, style = "") {
  const readOnly = isProjectReadOnly() ? " readonly" : "";
  return `<td><input style="${style}" data-field="${field}" value="${escapeHtml(value || "")}"${readOnly} /></td>`;
}

function exportLabel(status, record) {
  if (status?.status === "matched") {
    const suffix = status.matchedRows > 1 ? ` · ${status.matchedRows} 行` : "";
    const title = (status.fileNames || [status.fileName]).join("；");
    return `<span class="match-status matched" title="${escapeHtml(title)}">✓ ${escapeHtml(status.fileName)}${escapeHtml(suffix)}</span>`;
  }
  const label = {
    "no-metadata": "等待 Resolve CSV",
    "missing-key": "缺少卷号/视频码",
    duplicate: "重复识别，已合并",
    conflict: "同一素材信息冲突",
    unmatched: "CSV 中未找到素材",
    incomplete: "场次/镜/次不完整",
  }[status?.status] || materialPrefix(record.cardNumber, record.videoCode) || "缺少编号";
  return `<span class="match-status">${label}</span>`;
}

// 识别明细里，若某条记录对应的素材在目录扫描时没有读到元数据文件，
// 在「CSV 匹配」列后追加一个「无元数据」徽标。
function missingMetadataBadge(record) {
  const key = canonicalMaterialKey(record.cardNumber, record.videoCode);
  if (!key || !state.missingMetadataKeys.has(key)) return "";
  return `<span class="missing-metadata" title="素材目录中没有读取到元数据文件">无元数据</span>`;
}

async function exportCsv() {
  if (state.exporting) return;
  hideError();
  // Acquire the export lock before the first await so rapid clicks cannot
  // start overlapping Worker jobs or open multiple native save dialogs.
  setExporting(true);
  try {
    await refreshRuntimeConfig();
    await yieldToRenderer();
    if (state.metadataTable && state.metadataFile) {
      const { bytes } = await runCsvBackgroundTask({
        type: "export-resolve",
        records: state.records,
        slateMetadata: state.slateMetadata,
        csvEdits: [...state.csvEdits],
        fieldFormats: resolveFieldFormats(),
        comments: resolveCommentsConfig(),
      });
      await downloadCsv(bytes, `${baseName(state.metadataFile.name)}_场记已回填.csv`);
      return;
    }

    if (!state.records.length) {
      throw new Error("没有可导出的识别记录。");
    }
    const title = state.latestResponse?.result?.sheetTitle || "场记单";
    const { bytes } = await runCsvBackgroundTask({
      type: "export-standalone",
      records: state.records,
      fieldFormats: resolveFieldFormats(),
      comments: resolveCommentsConfig(),
    });
    await downloadCsv(bytes, `${baseName(title)}_场记识别.csv`);
  } catch (error) {
    showError(error.message || "无法导出 CSV。");
  } finally {
    setExporting(false);
  }
}

async function downloadCsv(bytes, filename) {
  await downloadFileApi(bytes, filename);
}

function emptyRecord() {
  return {
    id: `manual-${Date.now()}`,
    cardNumber: null,
    videoCode: null,
    scene: null,
    shot: null,
    take: null,
    takeStatus: null,
    description: null,
    comments: null,
    shotSize: null,
    cameraPosition: null,
    confidence: "low",
  };
}

function resolveFieldFormats() {
  return state.activeTaskSettings?.resolve?.fieldFormats
    || state.currentProject?.settings?.resolve?.fieldFormats
    || state.config?.workflow?.resolve?.fieldFormats || {
    scene: "XXX",
    shot: "XX",
    take: "XX",
  };
}

function resolveCommentsConfig() {
  return state.activeTaskSettings?.resolve?.comments
    || state.currentProject?.settings?.resolve?.comments
    || state.config?.workflow?.resolve?.comments || {
    goodTake: "_OK",
    holdTake: "_KP",
  };
}

function applyRecordFieldFormats(record) {
  const formats = resolveFieldFormats();
  return {
    ...record,
    scene: normalizeSceneValue(record.scene, formats.scene) || null,
    shot: normalizeShotValue(record.shot, formats.shot) || null,
    take: normalizeTakeValue(record.take, formats.take) || null,
  };
}

function normalizeEditedField(field, value) {
  const cleaned = value || null;
  const formats = resolveFieldFormats();
  if (field === "scene") {
    return normalizeSceneValue(cleaned, formats.scene) || null;
  }
  if (field === "shot") {
    return normalizeShotValue(cleaned, formats.shot) || null;
  }
  if (field === "take") {
    return normalizeTakeValue(cleaned, formats.take) || null;
  }
  return cleaned;
}

// 把用户对「回填预览」的手工编辑作为最后一层覆盖到合并结果上。
// 用 has() 而非值判空：这样「清空单元格」也能生效（存空串覆盖原值）。
function applyCsvEdits(table) {
  if (!state.csvEdits.size || !table) return table;
  return {
    ...table,
    rows: table.rows.map((row, rowIndex) =>
      row.map((cell, columnIndex) => {
        const key = `${rowIndex}:${columnIndex}`;
        return state.csvEdits.has(key) ? state.csvEdits.get(key) : cell;
      }),
    ),
  };
}

// 反查某列属于哪个可编辑字段（scene/shot/take/comments/cameraFps/shootDay）。
function fieldForColumn(columns, columnIndex) {
  for (const field of [
    "scene",
    "shot",
    "take",
    "comments",
    "cameraFps",
    "shootDay",
  ]) {
    if (columns[field] === columnIndex) return field;
  }
  return undefined;
}

// 归一化预览单元格编辑：scene/shot/take 复用明细页的零填充规范化，Comments
// 只保留配置的条次标记或空值，其余列去空格原样返回。
function normalizeCsvCellEdit(field, value) {
  if (field === "scene" || field === "shot" || field === "take") {
    return normalizeEditedField(field, value) || "";
  }
  if (field === "comments") {
    return canonicalResolveComment(value, resolveCommentsConfig());
  }
  return typeof value === "string" ? value.trim() : "";
}

function resetRecognitionResults() {
  state.records = [];
  state.csvEdits.clear();
  state.detailSearch = "";
  state.detailSort = { field: null, direction: 1 };
  if (elements.detailSearch) elements.detailSearch.value = "";
  renderDetailSortIndicators();
  state.latestResponse = null;
  elements.results.hidden = true;
  elements.resultBody.innerHTML = "";
  elements.csvPreviewSummary.textContent = "回填预览";
  elements.csvResultHead.innerHTML = "";
  elements.csvResultBody.innerHTML = "";
  elements.csvResultEmpty.hidden = true;
  elements.warningList.hidden = true;
  elements.warningList.innerHTML = "";
  elements.metrics.innerHTML = "";
  elements.resultSummary.textContent = "识别完成";
  elements.tabCsvBadge.hidden = true;
  elements.tabDetailBadge.hidden = true;
  elements.tabWarningDot.hidden = true;
  setResultsTab("csv");
  updateExportState(null);
  updateMetadataInputState();
  updateSlateDirectoryState();
  updateWorkflowSteps();
}

function setPreparing(value) {
  elements.processing.hidden = !value;
  elements.previewPanel.classList.toggle("is-busy", value);
  elements.previewPanel.classList.remove("is-ready");
  elements.previewStatus.textContent = value ? "正在准备文件" : "等待输入";
  if (value) {
    resetTaskProgress({
      phase: "preparing",
      percent: 2,
      message: "正在检查文件并准备场记单页面",
    });
  } else {
    updateWorkspaceStatus();
  }
}

function setProcessing(value) {
  state.recognizing = value;
  elements.processing.hidden = !value;
  elements.previewPanel.classList.toggle("is-busy", value);
  const ocrReady = state.config?.ocr?.enabled && state.config?.ocr?.available;
  if (value) {
    resetTaskProgress({
      phase: "starting",
      percent: 0,
      message: state.pageCount > 1
        ? `${ocrReady ? "先运行 OCR，再" : ""}识别 ${state.pageCount} 页`
        : `${ocrReady ? "先运行 OCR，再" : ""}识别场记单`,
    });
  }
  elements.imageInput.disabled = value;
  elements.removeFile.disabled = value;
  elements.recognizeButton.disabled = value;
  elements.recognizeButton.querySelector("span").textContent = value
    ? "识别中…"
    : "开始识别";
  if (value) {
    elements.previewPanel.classList.remove("is-ready");
    elements.previewStatus.textContent = "AI 识别进行中";
  }
  updateMetadataInputState();
  updateSlateDirectoryState();
  if (!value) {
    updateRecognizeState();
  }
}

const PROGRESS_PHASES = {
  preparing: ["正在准备场记单页面", "图像预处理"],
  "prepare-complete": ["场记单页面准备完成", "准备完成"],
  starting: ["正在启动识别任务", "准备识别"],
  ocr: ["本地 OCR 正在提取文字", "OCR 证据层"],
  primary: ["多模态模型正在主识别", "主识别"],
  audit: ["模型正在独立查漏", "核心字段查漏"],
  review: ["模型正在定向复核", "冲突复核"],
  "page-complete": ["正在汇总逐页识别", "逐页识别"],
  merge: ["正在合成最终结果", "结果校验"],
  complete: ["识别处理完成", "完成"],
};

function resetTaskProgress(progress) {
  state.progressPercent = 0;
  elements.processing.classList.remove("is-error");
  elements.progressBar.style.width = "0%";
  elements.progress.setAttribute("aria-valuenow", "0");
  updateTaskProgress(progress, true);
}

function updateTaskProgress(progress, allowDecrease = false) {
  if (!progress || typeof progress !== "object") return;
  const requested = Number(progress.percent);
  const bounded = Number.isFinite(requested)
    ? Math.max(0, Math.min(100, Math.round(requested)))
    : state.progressPercent;
  const percent = allowDecrease
    ? bounded
    : Math.max(state.progressPercent, bounded);
  state.progressPercent = percent;
  elements.progressBar.style.width = `${percent}%`;
  elements.progress.setAttribute("aria-valuenow", String(percent));
  elements.progressPercent.textContent = `${percent}%`;

  const [title, stage] = PROGRESS_PHASES[progress.phase] || [
    "正在识别场记单",
    "处理中",
  ];
  elements.processing.querySelector("strong").textContent = title;
  elements.progressStage.textContent = stage;
  if (progress.message) {
    elements.processing.querySelector("small").textContent = progress.message;
  }
}

function markTaskProgressError(message) {
  elements.processing.classList.add("is-error");
  elements.processing.querySelector("strong").textContent = "识别未完成";
  elements.processing.querySelector("small").textContent = message || "识别失败";
  elements.progressStage.textContent = "发生错误";
}

function updateRecognizeState() {
  const readOnly = isProjectReadOnly();
  const projectManagedAccuracy = Boolean(state.currentProject);
  const canRecognize = !readOnly && recognitionReady();
  const canMerge = !readOnly && !canRecognize && slateCsvMergeReady();
  elements.recognizeButton.disabled =
    readOnly || state.recognizing || (!canRecognize && !canMerge);
  elements.imageInput.disabled = readOnly || state.recognizing;
  // Accuracy is an authoritative project setting in Electron. Do not expose a
  // task-level control whose submitted value the main process must ignore.
  elements.provider.disabled = readOnly;
  elements.model.disabled = readOnly;
  syncLegacyModelPicker(elements.model);
  elements.modelRefresh.disabled = readOnly;
  elements.accuracyMode.disabled = readOnly || projectManagedAccuracy;
  elements.accuracyMode.title = projectManagedAccuracy
    ? "识别模式由当前项目设置管理"
    : "";
  if (elements.accuracyModeNote) {
    elements.accuracyModeNote.textContent = projectManagedAccuracy
      ? "由当前项目设置管理；需要调整时请打开项目设置"
      : "精确模式适合正式交付；清晰且格式稳定的场记单可使用快速模式";
  }
  elements.scenario.disabled = readOnly;
  elements.customPromptInput.disabled = readOnly;
  elements.removeFile.disabled = readOnly || state.recognizing;
  elements.removeMetadata.disabled = readOnly || state.recognizing;
  elements.removeSlates.disabled = readOnly || state.recognizing;
  elements.removeSlateCsv.disabled = readOnly || state.recognizing;
  elements.addRow.disabled = readOnly;
  elements.taskDelete.disabled = readOnly;
  elements.recognizeButton.querySelector("span").textContent = state.recognizing
    ? "识别中…"
    : canMerge
      ? "合并 CSV"
      : "开始识别";
  updateWorkspaceStatus({ canRecognize, canMerge });
  updateSupportDataSummary();
}

function updateWorkspaceStatus(status = {}) {
  const canRecognize = status.canRecognize ?? recognitionReady();
  const canMerge = status.canMerge ?? (!canRecognize && slateCsvMergeReady());
  const reportReady = state.imageDataGroups.length > 0;
  const providerReady = Boolean(selectedProvider()?.configured);
  const modelReady = Boolean(selectedModel());

  elements.previewPanel.classList.toggle(
    "is-ready",
    !state.recognizing && (reportReady || canMerge),
  );
  elements.previewPanel.classList.toggle("is-busy", state.recognizing);

  if (state.recognizing) {
    elements.previewStatus.textContent = "AI 识别进行中";
    elements.recognizeHint.textContent = "正在处理，请保持页面打开";
    elements.recognizeHint.classList.remove("is-ready");
    return;
  }

  if (reportReady) {
    elements.previewStatus.textContent = `${state.pageCount || 1} 页 · 已就绪`;
  } else if (canMerge) {
    elements.previewStatus.textContent = "CSV 合并模式";
  } else {
    elements.previewStatus.textContent = "等待输入";
  }

  elements.recognizeHint.classList.toggle("is-ready", canRecognize || canMerge);
  if (canRecognize) {
    elements.recognizeHint.textContent = "准备完成 · 点击开始，或按 ⌘ / Ctrl + Enter";
  } else if (canMerge) {
    elements.recognizeHint.textContent = "两份 CSV 已就绪 · 无需调用 AI，可直接合并";
  } else if (!reportReady && !state.slateCsvRecords?.length) {
    elements.recognizeHint.textContent = "先添加场记单，再开始识别";
  } else if (reportReady && !providerReady) {
    elements.recognizeHint.textContent = "请选择已配置的 API 服务商，或填写 API Key";
  } else if (reportReady && !modelReady) {
    elements.recognizeHint.textContent = "请选择一个可用的视觉模型";
  } else if (state.slateCsvRecords?.length && !state.metadataTable) {
    elements.recognizeHint.textContent = "再添加 Resolve CSV，即可直接合并";
  } else {
    elements.recognizeHint.textContent = "补齐输入后即可继续";
  }
  updateWorkflowSteps();
}

// Hero 工步条镜像真实状态：载入场记 → AI 识别 → 校对导出。
function updateWorkflowSteps() {
  const steps = document.querySelectorAll(".workflow-steps li");
  if (!steps.length) return;
  const reportReady =
    state.imageDataGroups.length > 0 ||
    Boolean(state.slateCsvRecords?.length && state.metadataTable);
  const hasResults = !elements.results.hidden;
  const current = hasResults ? 2 : reportReady ? 1 : 0;
  steps.forEach((li, index) => {
    li.classList.toggle("is-done", index < current);
    li.classList.toggle("is-current", index === current);
    if (index === current) {
      li.setAttribute("aria-current", "step");
    } else {
      li.removeAttribute("aria-current");
    }
  });
}

function updateSupportDataSummary() {
  const count = [
    Boolean(state.metadataTable),
    Boolean(state.slateCsvRecords?.length),
    Boolean(state.slateMetadata.length),
  ].filter(Boolean).length;
  elements.optionalInputs.classList.toggle("has-data", count > 0);
  elements.supportDataState.textContent = count ? `已添加 ${count} 项` : "可选";
}

function updateExportState(output = currentMergeOutput()) {
  const recordCount = state.records.length;
  // Manual preview edits must be able to unlock export when automatic merging
  // found no rows to change.
  const enabled = state.metadataTable
    ? canExportResolveCsv({
        metadataLoaded: true,
        recordCount,
        exportableCount: output?.exportableCount,
        hasManualEdits: state.csvEdits.size > 0,
      })
    : recordCount > 0;
  elements.exportButton.disabled = state.exporting || !enabled;
}

function setExporting(value) {
  state.exporting = value;
  if (value) {
    state.exportButtonEnabledBeforeBusy = !elements.exportButton.disabled;
  }
  elements.exportButton.textContent = value
    ? "正在准备 CSV…"
    : "下载 Resolve CSV";
  // Do not synchronously rebuild the full merge merely to change button busy
  // state; retain the already-computed eligibility from before this export.
  elements.exportButton.disabled = value
    ? true
    : !state.exportButtonEnabledBeforeBusy;
}

function recognitionReady() {
  return canStartRecognition({
    reportReady: state.imageDataGroups.length > 0,
    providerConfigured: Boolean(selectedProvider()?.configured),
    modelSelected: Boolean(selectedModel()),
  });
}

function slateCsvMergeReady() {
  return canMergeSlateCsv({
    slateCsvLoaded: Boolean(state.slateCsvRecords?.length),
    metadataLoaded: Boolean(state.metadataTable),
  });
}

function selectedProvider() {
  return state.config?.providers.find(
    (provider) => provider.id === elements.provider.value,
  );
}

function selectedModel() {
  return modelsForProvider(elements.provider.value).find(
    (model) => model.id === elements.model.value,
  );
}

async function loadTaskList(projectId = state.currentProjectId) {
  const token = taskListOperations.start();
  try {
    const data = await listTasksApi(projectId);
    if (
      !taskListOperations.isCurrent(token) ||
      projectId !== state.currentProjectId
    ) return false;
    state.tasks = taskListFromResponse(data);
    renderTaskSwitcher();
    return true;
  } catch {
    if (!taskListOperations.isCurrent(token)) return false;
    state.tasks = [];
    return false;
  }
}

function taskListFromResponse(data) {
  return Array.isArray(data) ? data : data?.tasks || [];
}

function renderTaskSwitcher() {
  const tasks = state.tasks;
  elements.taskSwitcher.hidden = tasks.length === 0;
  elements.taskSelect.innerHTML =
    '<option value="">新任务</option>' +
    tasks
      .map(
        (task) =>
          `<option value="${escapeHtml(task.id)}" ${task.id === state.currentTaskId ? "selected" : ""}>${escapeHtml(task.filename || "未命名")} · ${task.recordCount} 条 · ${formatTaskDate(task.updatedAt)}</option>`,
      )
      .join("");
  elements.taskDelete.hidden = !state.currentTaskId;
}

async function switchTask() {
  const token = taskOperations.start();
  const taskId = elements.taskSelect.value;
  const projectId = state.currentProjectId;
  if (state.recognizing) {
    elements.taskSelect.value = state.currentTaskId || "";
    showError("识别进行中，无法切换任务。");
    return;
  }
  const saved = await flushPendingTaskSave();
  if (!taskOperations.isCurrent(token)) return;
  if (!saved) {
    elements.taskSelect.value = state.currentTaskId || "";
    return;
  }
  if (!taskId) {
    // "新任务" — reset workspace
    state.currentTaskId = null;
    applyNewTaskRecognitionDefaults();
    clearReportFile();
    clearResolveCsv();
    resetRecognitionResults();
    taskAutosave.reset();
    renderTaskSwitcher();
    return;
  }
  if (taskId === state.currentTaskId) return;

  try {
    const task = await loadTaskApi(taskId, projectId);
    if (
      !taskOperations.isCurrent(token) ||
      state.currentProjectId !== projectId ||
      elements.taskSelect.value !== taskId
    ) return;
    // The old task remains editable while its replacement is loading. Flush a
    // second time so edits made during that await cannot be erased by reset().
    const savedDuringLoad = await flushPendingTaskSave();
    if (
      !taskOperations.isCurrent(token) ||
      state.currentProjectId !== projectId ||
      elements.taskSelect.value !== taskId
    ) return;
    if (!savedDuringLoad) {
      elements.taskSelect.value = state.currentTaskId || "";
      return;
    }
    restoreTask(task, { token, projectId });
  } catch (error) {
    if (!taskOperations.isCurrent(token)) return;
    showError(error.message || "无法加载任务。");
    elements.taskSelect.value = state.currentTaskId || "";
  }
}

function restoreTask(task, operation = {}) {
  state.currentTaskId = task.id;
  taskAutosave.reset();
  state.activeTaskSettings = task.projectSettingsSnapshot
    || state.currentProject?.settings
    || defaultRendererProjectSettings();

  // Clear current state
  clearReportFile();
  clearResolveCsv();
  resetRecognitionResults();

  restoreResolveCsvState(task);
  renderScenarioOptions(task.scenarioId || "", false);

  // Restore recognition config
  if (task.provider) elements.provider.value = task.provider;
  if (["high", "standard"].includes(task.accuracyMode)) {
    elements.accuracyMode.value = task.accuracyMode;
  }
  if (Object.hasOwn(task, "customPrompt")) {
    elements.customPromptInput.value = task.customPrompt || "";
  }
  updateApiKeyFieldState();
  renderModelOptions();
  if (task.model) {
    // Wait for models to load, then select
    loadProviderModels().then(() => {
      if (
        (operation.token && !taskOperations.isCurrent(operation.token)) ||
        (operation.projectId && state.currentProjectId !== operation.projectId) ||
        state.currentTaskId !== task.id
      ) return;
      if ([...elements.model.options].some((o) => o.value === task.model)) {
        elements.model.value = task.model;
        syncLegacyModelPicker(elements.model);
        renderModelNote();
      }
    });
  }

  // Restore recognition result
  if (task.result?.records?.length) {
    // Re-apply field normalization so older saved tasks also display and
    // export scene suffixes such as 87a as the canonical value 87A.
    const restoredRecords = (task.editedRecords || task.result.records).map(
      applyRecordFieldFormats,
    );
    state.records = restoredRecords;
    state.latestResponse = {
      result: { ...task.result, records: restoredRecords },
      provider: task.provider,
      model: task.model,
      usage: task.usage,
      durationMs: task.durationMs,
      ocr: task.ocrSummary,
      pageCount: task.pageCount,
      accuracyMode: task.accuracyMode,
      inputMode: "images",
      scenario: task.scenarioId
        ? {
            id: task.scenarioId,
            match: task.scenarioMatch || "selected",
            fingerprint: task.scenarioFingerprint || null,
          }
        : null,
    };
    state.pageCount = task.pageCount || 0;
    elements.results.hidden = false;
    renderResults(state.latestResponse);
  }

  renderTaskSwitcher();
  updateRecognizeState();
}

function restoreResolveCsvState(task) {
  const saved = restoreCsvPreviewState(task);
  if (!saved) return;

  state.metadataTable = saved.metadataTable;
  primeCsvWorkerMetadata(saved.metadataTable);
  // The restored task only needs the filename for export; the original File
  // object cannot survive a reload, so keep a small compatible name object.
  state.metadataFile = { name: saved.metadataFilename };
  state.csvEdits.clear();
  for (const [key, value] of saved.csvEdits) state.csvEdits.set(key, value);
  state.slateMetadata = saved.slateMetadata;
  state.slateWarnings = saved.slateWarnings;
  state.missingMetadataKeys = new Set(saved.missingMetadataKeys);

  elements.metadataFileName.textContent = saved.metadataFilename;
  elements.metadataFileMeta.textContent = `${saved.metadataTable.rows.length} 条素材 · ${saved.metadataTable.headers.length} 列 · ${encodingLabel(saved.metadataTable.format)}`;
  elements.metadataCard.hidden = false;
  elements.metadataDropzone.hidden = true;

  if (saved.slateMetadata.length) {
    elements.slateDirectoryName.textContent =
      saved.slateDirectoryName || "已保存的素材目录";
    elements.slateFileMeta.textContent = `${saved.slateMetadata.length} 个已保存元数据文件`;
    elements.slateCard.hidden = false;
    elements.slateDropzone.hidden = true;
  }
}

async function deleteCurrentTask() {
  if (!state.currentTaskId || isProjectReadOnly()) return;
  const task = state.tasks.find((t) => t.id === state.currentTaskId);
  const label = task?.filename || "未命名";
  if (!confirm(`确定删除任务"${label}"吗？此操作不可撤销。`)) return;

  try {
    if (!(await flushPendingTaskSave())) return;
    const taskId = state.currentTaskId;
    const projectId = state.currentProjectId;
    const token = taskOperations.start();
    taskListOperations.invalidate();
    await deleteTaskApi(taskId, projectId);
    const [project, taskData] = await Promise.all([
      loadProjectApi(projectId),
      listTasksApi(projectId),
    ]);
    if (
      !taskOperations.isCurrent(token) ||
      state.currentProjectId !== projectId
    ) return;

    state.currentTaskId = null;
    clearReportFile();
    clearResolveCsv();
    resetRecognitionResults();
    taskAutosave.reset();
    state.tasks = taskListFromResponse(taskData);
    if (project) {
      // Project details recompute lastRecognitionDefaults from tasks that still
      // exist, so deleting the latest result cannot seed the next task.
      state.currentProject = project;
      state.projects = state.projects.map((item) =>
        item.id === project.id ? { ...item, ...project } : item);
      applyNewTaskRecognitionDefaults(project);
    }
    renderTaskSwitcher();
  } catch (error) {
    showError(error.message || "删除任务失败。");
  }
}

function saveCurrentTask() {
  if (isProjectReadOnly() || !state.currentTaskId || !state.latestResponse) return;
  taskAutosave.markDirty();
}

function captureCurrentTaskSave() {
  if (isProjectReadOnly() || !state.currentTaskId || !state.latestResponse) return null;
  // Keep the editable Resolve preview and source metadata with an immutable
  // task snapshot so a later keystroke cannot mutate an in-flight IPC payload.
  const csvState = serializeCsvPreviewState({
    metadataTable: state.metadataTable,
    metadataFilename: state.metadataFile?.name,
    csvEdits: state.csvEdits,
    slateMetadata: state.slateMetadata,
    slateWarnings: state.slateWarnings,
    missingMetadataKeys: [...state.missingMetadataKeys],
    slateDirectoryName: elements.slateDirectoryName.textContent,
  });
  return {
    projectId: state.currentProjectId,
    task: JSON.parse(JSON.stringify({
      id: state.currentTaskId,
      editedRecords: state.records,
      status: "edited",
      ...csvState,
    })),
  };
}

async function flushPendingTaskSave() {
  const saved = await taskAutosave.flush();
  if (!saved) showError("手动编辑保存失败，请重试后再继续。");
  return saved;
}

function renderTaskSaveStatus(status) {
  if (!elements.taskSaveStatus || !elements.taskSaveRetry) return;
  const labels = {
    idle: "",
    dirty: "未保存",
    saving: "保存中…",
    saved: "已保存",
    error: "保存失败",
  };
  elements.taskSaveStatus.textContent = labels[status.state] || "";
  elements.taskSaveStatus.dataset.state = status.state;
  elements.taskSaveStatus.hidden = status.state === "idle";
  elements.taskSaveRetry.hidden = status.state !== "error";
}

function formatTaskDate(isoString) {
  if (!isoString) return "";
  const date = new Date(isoString);
  const month = String(date.getMonth() + 1).padStart(2, "0");
  const day = String(date.getDate()).padStart(2, "0");
  const hours = String(date.getHours()).padStart(2, "0");
  const minutes = String(date.getMinutes()).padStart(2, "0");
  return `${month}-${day} ${hours}:${minutes}`;
}

function showError(message) {
  elements.error.textContent = message;
  elements.error.hidden = false;
}

function hideError() {
  elements.error.hidden = true;
  elements.error.textContent = "";
}

function fileToDataUrl(file) {
  return new Promise((resolve, reject) => {
    const reader = new FileReader();
    reader.onload = () => resolve(reader.result);
    reader.onerror = reject;
    reader.readAsDataURL(file);
  });
}

function loadImage(url) {
  return new Promise((resolve, reject) => {
    const image = new Image();
    image.onload = () => resolve(image);
    image.onerror = reject;
    image.src = url;
  });
}

function canvasToDataUrl(canvas, type, quality) {
  return new Promise((resolve, reject) => {
    // Chromium performs toBlob encoding asynchronously; unlike toDataURL this
    // does not hold the renderer thread throughout JPEG compression.
    canvas.toBlob((blob) => {
      if (!blob) {
        reject(new Error("无法编码场记单页面图像"));
        return;
      }
      const reader = new FileReader();
      reader.onload = () => resolve(reader.result);
      reader.onerror = () => reject(reader.error || new Error("无法读取页面图像"));
      reader.readAsDataURL(blob);
    }, type, quality);
  });
}

function yieldToRenderer() {
  // scheduler.yield is available in recent Electron; the timer fallback keeps
  // older runtimes responsive between canvas/CSV phases as well.
  return globalThis.scheduler?.yield
    ? globalThis.scheduler.yield()
    : new Promise((resolve) => setTimeout(resolve, 0));
}

async function runCsvBackgroundTask(task, transfer = []) {
  if (csvWorker) {
    try {
      const result = await csvWorker.request(task, transfer);
      if (result?.bytes instanceof ArrayBuffer) {
        return { ...result, bytes: new Uint8Array(result.bytes) };
      }
      return result;
    } catch (error) {
      // Validation errors came from a healthy Worker and must reach the user;
      // only infrastructure failures should retry on the renderer.
      if (error.csvWorkerTask) throw error;
      console.warn(`[csv-worker] ${error.message}；改用 renderer 兼容路径`);
    }
  }
  await yieldToRenderer();
  return fallbackCsvProcessor(task);
}

function primeCsvWorkerMetadata(table) {
  fallbackCsvProcessor({ type: "prime-metadata", table });
  if (csvWorker) {
    void csvWorker.request({ type: "prime-metadata", table }).catch((error) => {
      console.warn(`[csv-worker] 无法缓存 Resolve CSV：${error.message}`);
    });
  }
}

function clearCsvWorkerMetadata() {
  fallbackCsvProcessor({ type: "clear-metadata" });
  if (csvWorker) {
    void csvWorker.request({ type: "clear-metadata" }).catch(() => {});
  }
}

function formatBytes(bytes) {
  if (bytes < 1024) return `${bytes} B`;
  if (bytes < 1024 * 1024) return `${(bytes / 1024).toFixed(1)} KB`;
  return `${(bytes / 1024 / 1024).toFixed(1)} MB`;
}

function encodingLabel(format) {
  const encoding = {
    "utf-16le": "UTF-16LE",
    "utf-16be": "UTF-16BE",
    "utf-8": "UTF-8",
  }[format.encoding] || String(format.encoding || "未知编码").toUpperCase();
  return `${encoding}${format.bom ? " BOM" : ""}`;
}

function baseName(filename) {
  return filename
    .replace(/\.[^.]+$/, "")
    .replace(/[^\w\u4e00-\u9fff-]+/g, "_");
}

function confidenceLabel(value) {
  return { high: "高", medium: "中", low: "低" }[value] || "低";
}

function escapeHtml(value) {
  return String(value)
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;")
    .replaceAll("'", "&#039;");
}

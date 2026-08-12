import {
  buildSlateMetadataIndex,
  buildStandaloneResolveTable,
  collectResolveMaterialKeys,
  decodeResolveCsv,
  encodeResolveCsv,
  extractCombinedMaterialKey,
  materialPrefix,
  mergeSlateIntoResolveTable,
  normalizeSceneValue,
  normalizeShotValue,
  normalizeTakeValue,
  parseSlateMetadataText,
  resolveColumnIndexes,
} from "./resolve-csv.js";
import { scanSlateDirectory } from "./slate-directory.js";
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
  isElectron,
  fetchConfig,
  saveProviderKeyApi,
  fetchModelsApi,
  recognizeStreamApi,
  downloadFileApi,
  pickDirectoryApi,
  scanSlateDirectoryApi,
  listTasksApi,
  loadTaskApi,
  saveTaskApi,
  deleteTaskApi,
} from "./electron-bridge.js";
import {
  REQUEST_COMPRESSION_PROFILES,
  requestBodyBytes,
  requestBodyFits,
  serializeRecognitionRequest as serializeRecognitionPayload,
} from "./recognition-request.js";
import * as pdfjsLib from "./vendor/pdfjs/pdf.mjs";

pdfjsLib.GlobalWorkerOptions.workerSrc = "./vendor/pdfjs/pdf.worker.mjs";
const PDF_PREPARE_CONCURRENCY = 2;
const MAX_DISCOVERED_MODELS = 24;

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
  slateRootHandle: null,
  slateFallbackFiles: null,
  slateCache: new Map(),
  slateScanController: null,
  slateScanning: false,
  recognizing: false,
  imageDataGroups: [],
  pageCount: 0,
  records: [],
  latestResponse: null,
  progressPercent: 0,
  currentTaskId: null,
  tasks: [],
  slateCsvRecords: null,
  slateCsvFileName: null,
};

const elements = {
  apiStatus: document.querySelector("#api-status"),
  provider: document.querySelector("#provider-select"),
  model: document.querySelector("#model-select"),
  modelRefresh: document.querySelector("#model-refresh"),
  modelNote: document.querySelector("#model-note"),
  metadataDropzone: document.querySelector("#metadata-dropzone"),
  metadataInput: document.querySelector("#metadata-input"),
  metadataHelp: document.querySelector("#metadata-help"),
  metadataCard: document.querySelector("#metadata-card"),
  metadataFileName: document.querySelector("#metadata-file-name"),
  metadataFileMeta: document.querySelector("#metadata-file-meta"),
  removeMetadata: document.querySelector("#remove-metadata"),
  slateInput: document.querySelector("#slate-input"),
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
  largePreview: document.querySelector("#large-preview"),
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
  slateCsvDropzone: document.querySelector("#slate-csv-dropzone"),
  slateCsvInput: document.querySelector("#slate-csv-input"),
  slateCsvHelp: document.querySelector("#slate-csv-help"),
  slateCsvCard: document.querySelector("#slate-csv-card"),
  slateCsvFileName: document.querySelector("#slate-csv-file-name"),
  slateCsvFileMeta: document.querySelector("#slate-csv-file-meta"),
  removeSlateCsv: document.querySelector("#remove-slate-csv"),
};

init();

async function init() {
  bindEvents();
  try {
    await loadConfig();
    renderSlateDirectoryConfig();
    renderProviderOptions();
    renderModelOptions();
    renderApiStatus();
    updateExportState();
    updateMetadataInputState();
    updateSlateDirectoryState();
    await loadProviderModels();
    await loadTaskList();
  } catch {
    showError("无法读取服务配置，请确认 SlateSync 已启动。");
  }
}

async function loadConfig() {
  state.config = await fetchConfig();
}

function bindEvents() {
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
  elements.modelRefresh.addEventListener("click", () => {
    loadProviderModels(true);
  });
  elements.metadataInput.addEventListener("change", (event) => {
    if (event.target.files?.[0]) loadResolveCsv(event.target.files[0]);
  });
  elements.imageInput.addEventListener("change", (event) => {
    if (event.target.files?.[0]) loadReportFile(event.target.files[0]);
  });
  elements.slateInput.addEventListener("change", (event) => {
    if (event.target.files?.length) loadSlateDirectory(event.target.files);
  });
  elements.slateDirectoryButton.addEventListener("click", selectSlateDirectory);
  elements.removeMetadata.addEventListener("click", clearResolveCsv);
  elements.removeSlates.addEventListener("click", clearSlateMetadata);
  elements.removeFile.addEventListener("click", clearReportFile);
  elements.recognizeButton.addEventListener("click", recognize);
  elements.saveKeyButton.addEventListener("click", saveProviderKey);
  elements.addRow.addEventListener("click", () => {
    state.records.push(emptyRecord());
    renderTable();
    saveCurrentTask();
  });
  elements.exportButton.addEventListener("click", exportCsv);
  elements.tabCsv.addEventListener("click", () => setResultsTab("csv"));
  elements.tabDetail.addEventListener("click", () => setResultsTab("detail"));
  elements.taskSelect.addEventListener("change", switchTask);
  elements.taskDelete.addEventListener("click", deleteCurrentTask);
  elements.slateCsvInput.addEventListener("change", (event) => {
    if (event.target.files?.[0]) loadSlateCsv(event.target.files[0]);
  });
  elements.removeSlateCsv.addEventListener("click", clearSlateCsv);

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

  if (isElectron) {
    await selectSlateDirectoryElectron();
    return;
  }

  if (typeof globalThis.showDirectoryPicker !== "function") {
    elements.slateInput.click();
    return;
  }

  try {
    const rootHandle = await globalThis.showDirectoryPicker({
      id: "slatesync-slate-root",
      mode: "read",
    });
    state.slateRootHandle = rootHandle;
    state.slateFallbackFiles = null;
    state.slateCache = new Map();
    state.slateMetadata = [];
    state.slateWarnings = [];
    await loadSlateDirectoryHandle(rootHandle);
  } catch (error) {
    if (error?.name !== "AbortError") {
      showError(error.message || "无法读取所选素材目录。");
    }
  }
}

async function selectSlateDirectoryElectron() {
  try {
    const result = await pickDirectoryApi();
    if (!result) return;
    state.slateRootHandle = null;
    state.slateFallbackFiles = null;
    state.slateCache = new Map();
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
        compatibilityMode: false,
      });
    } finally {
      state.slateScanning = false;
      updateSlateDirectoryState();
    }
  } catch (error) {
    showError(error.message || "无法读取所选素材目录。");
  }
}

async function loadSlateDirectoryHandle(rootHandle) {
  const { keys, warnings: csvWarnings } = collectResolveMaterialKeys(
    state.metadataTable,
  );
  state.slateScanController?.abort();
  const controller = new AbortController();
  state.slateScanController = controller;
  state.slateScanning = true;
  updateSlateDirectoryState();
  showSlateScanningState(rootHandle.name || "已选素材目录");

  try {
    const result = await scanSlateDirectory(rootHandle, {
      expectedKeys: keys,
      maxDepth: slateMaxDirectoryDepth(),
      readConcurrency: 4,
      cache: state.slateCache,
      signal: controller.signal,
    });
    if (state.slateScanController !== controller) return;
    applySlateDirectoryResult({
      ...result,
      warnings: [...csvWarnings, ...result.warnings],
      directoryName: rootHandle.name || "已选素材目录",
      compatibilityMode: false,
    });
  } catch (error) {
    if (error?.name !== "AbortError") {
      showSlateScanFailure(
        rootHandle.name || "已选素材目录",
        error.message || "无法读取所选素材目录。",
      );
    }
  } finally {
    if (state.slateScanController === controller) {
      state.slateScanning = false;
      updateSlateDirectoryState();
    }
  }
}

async function loadSlateDirectory(fileList) {
  if (!canSelectSlateDirectory({
    reportReady: state.imageDataGroups.length > 0,
    metadataLoaded: Boolean(state.metadataTable),
  })) {
    elements.slateInput.value = "";
    showError("请先选择场记单并载入 Resolve CSV，再选择素材根目录。");
    return;
  }

  hideError();
  state.slateRootHandle = null;
  state.slateFallbackFiles = [...fileList];
  const files = state.slateFallbackFiles;
  const { keys, warnings: csvWarnings } = collectResolveMaterialKeys(
    state.metadataTable,
  );
  const expectedKeys = new Set(keys);
  const maxDepth = slateMaxDirectoryDepth();
  const warnings = [...csvWarnings];
  const allSlateFiles = files.filter((file) => /slate\.txt$/i.test(file.name));
  const withinDepth = allSlateFiles.filter((file) =>
    relativeFileDirectoryDepth(file.webkitRelativePath || file.name) <= maxDepth,
  );
  const skippedDeep = allSlateFiles.length - withinDepth.length;
  if (skippedDeep) {
    warnings.push(
      `${skippedDeep} 个 slate.txt 超过配置的 ${maxDepth} 层搜索范围，已跳过。`,
    );
  }
  const slateFiles = withinDepth.filter((file) => {
    const key = extractCombinedMaterialKey(
      file.webkitRelativePath || file.name,
    );
    return !key || expectedKeys.has(key);
  });
  const firstPath = files[0]?.webkitRelativePath || files[0]?.name || "";
  const directoryName = firstPath.split("/").filter(Boolean)[0] || "已选素材目录";
  if (!slateFiles.length) {
    elements.slateInput.value = "";
    showSlateScanFailure(
      directoryName,
      `所选目录的前 ${maxDepth} 层中没有找到匹配的 slate.txt，请检查目录结构与素材编号。`,
    );
    return;
  }

  const parsed = [];
  const oversized = slateFiles.filter((file) => file.size > 2 * 1024 * 1024);
  if (oversized.length) {
    warnings.push(`${oversized.length} 个超过 2 MB 的 slate.txt 已跳过。`);
  }
  const readable = slateFiles.filter((file) => file.size <= 2 * 1024 * 1024);

  state.slateScanning = true;
  updateSlateDirectoryState();
  showSlateScanningState(directoryName);
  try {
    for (let offset = 0; offset < readable.length; offset += 4) {
      const batch = readable.slice(offset, offset + 4);
      const results = await Promise.all(
        batch.map(async (file) => {
          const sourceName = file.webkitRelativePath || file.name;
          try {
            return {
              metadata: parseSlateMetadataText(
                await file.arrayBuffer(),
                sourceName,
              ),
            };
          } catch (error) {
            return { warning: error.message || `${sourceName} 无法读取` };
          }
        }),
      );
      for (const result of results) {
        if (result.metadata) parsed.push(result.metadata);
        if (result.warning) warnings.push(result.warning);
      }
    }
  } finally {
    state.slateScanning = false;
    updateSlateDirectoryState();
  }

  applySlateDirectoryResult({
    metadata: parsed,
    warnings,
    stats: {
      discoveredSlateFiles: slateFiles.length,
      readSlateFiles: readable.length,
      cacheHits: 0,
      visitedDirectories: 0,
      prunedDirectories: allSlateFiles.length - slateFiles.length - skippedDeep,
      skippedDeepDirectories: skippedDeep,
    },
    directoryName,
    compatibilityMode: true,
  });
}

function applySlateDirectoryResult({
  metadata,
  warnings,
  stats,
  directoryName,
  compatibilityMode,
}) {
  if (!metadata.length) {
    state.slateMetadata = [];
    state.slateWarnings = compactSlateWarnings(warnings);
    const discovered = stats.discoveredSlateFiles || 0;
    const reason = discovered
      ? `找到 ${discovered} 个 slate.txt，但均缺少有效的 Clip Name、Sensor FPS 或 Shot Date。`
      : `未找到与 CSV 素材匹配的 slate.txt（已搜索前 ${slateMaxDirectoryDepth()} 层），请检查目录结构。`;
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
  const scanLabel = compatibilityMode
    ? "兼容模式"
    : `访问 ${stats.visitedDirectories} 个目录 · 剪枝 ${stats.prunedDirectories} 个`;
  const cacheLabel = stats.cacheHits ? ` · 缓存 ${stats.cacheHits}` : "";
  elements.slateFileMeta.textContent = `${stats.discoveredSlateFiles} 个 slate.txt · Camera FPS ${cameraFpsCount} 个素材 · Shoot Day ${shootDayCount} 个素材 · ${scanLabel}${cacheLabel}${warningCount ? ` · ${warningCount} 个警告` : ""}`;
  elements.slateCard.hidden = false;
  elements.slateDropzone.hidden = true;
  clearSlateStatus();
  if (state.records.length) renderTable();
}

function showSlateScanningState(directoryName) {
  elements.slateDirectoryName.textContent = directoryName;
  elements.slateFileMeta.textContent = "正在定向查找 slate.txt…";
  elements.slateCard.hidden = false;
  elements.slateDropzone.hidden = true;
  setSlateStatus("正在定向查找 slate.txt…", "loading");
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

function relativeFileDirectoryDepth(path) {
  const parts = String(path || "").split("/").filter(Boolean);
  return Math.max(0, parts.length - 2);
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
  const enabled = canLoadResolveCsv({ reportReady, slateCsvLoaded });
  elements.metadataInput.disabled = !enabled;
  elements.metadataDropzone.classList.toggle("is-disabled", !enabled);
  elements.metadataDropzone.setAttribute("aria-disabled", String(!enabled));
  elements.metadataHelp.textContent = enabled
    ? "可选 · 载入后回填导出"
    : "可选 · 请先选择场记单或场记 CSV";

  // Slate CSV can always be loaded independently
  const slateEnabled = canLoadSlateCsv();
  elements.slateCsvInput.disabled = !slateEnabled;
  elements.slateCsvDropzone.classList.toggle("is-disabled", !slateEnabled);
  elements.slateCsvDropzone.setAttribute("aria-disabled", String(!slateEnabled));
  elements.slateCsvHelp.textContent = slateEnabled
    ? "可辅助图片识别，也可直接合并 Resolve CSV"
    : "可选 · 请先选择场记单";
}

function updateSlateDirectoryState() {
  const enabled = canSelectSlateDirectory({
    reportReady: state.imageDataGroups.length > 0,
    metadataLoaded: Boolean(state.metadataTable),
  }) && !state.slateScanning;
  elements.slateDirectoryButton.disabled = !enabled;
  elements.slateInput.disabled = !enabled;
  elements.slateHelp.textContent = state.slateScanning
    ? "正在定向查找 slate.txt…"
    : !state.imageDataGroups.length
      ? "请先选择场记单"
      : state.metadataTable
      ? `按 CSV 素材定向查找 · 最多 ${slateMaxDirectoryDepth()} 层`
      : "请先载入 Resolve CSV";
}

function clearSlateMetadata() {
  state.slateScanController?.abort();
  state.slateMetadata = [];
  state.slateWarnings = [];
  state.slateRootHandle = null;
  state.slateFallbackFiles = null;
  state.slateCache = new Map();
  state.slateScanning = false;
  elements.slateInput.value = "";
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
    `另有 ${warnings.length - limit} 个 slate.txt 读取警告未逐条显示。`,
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

const WEB_CONFIGURABLE_PROVIDERS = [
  "openai",
  "openrouter",
  "tokenplan",
  "dashscope",
];

function updateApiKeyFieldState() {
  const provider = selectedProvider();
  const configurable = WEB_CONFIGURABLE_PROVIDERS.includes(provider?.id);
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

  const fixed = compatible.filter((model) => model.fixed !== false);
  const discovered = compatible.filter((model) => model.fixed === false);
  const ranked = discovered.slice(0, MAX_DISCOVERED_MODELS);
  const groups = [];
  if (fixed.length) {
    groups.push(modelOptionGroup("固定模型", fixed));
  }
  if (ranked.length) {
    const suffix = discovered.length > ranked.length ? `（前 ${ranked.length}）` : "";
    groups.push(modelOptionGroup(`其他视觉模型${suffix}`, ranked));
  }
  elements.model.innerHTML = groups.length
    ? groups.join("")
    : '<option value="">没有发现可用的视觉模型</option>';

  if (compatible.some((model) => model.id === previous)) {
    elements.model.value = previous;
  } else if (compatible.length) {
    elements.model.value = compatible[0].id;
  }
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
      elements.modelRefresh.disabled = false;
      updateRecognizeState();
    }
  }
}

function modelOptionGroup(label, models) {
  const options = models
    .map((model) => {
      const indicators = [
        model.qualityLabel ? `精度 ${model.qualityLabel}` : "",
        model.valueLabel ? `性价比 ${model.valueLabel}` : "",
      ].filter(Boolean);
      const suffix = indicators.length ? ` · ${indicators.join(" · ")}` : "";
      return `<option value="${escapeHtml(model.id)}">${escapeHtml(`${model.label}${suffix}`)}</option>`;
    })
    .join("");
  return `<optgroup label="${escapeHtml(label)}">${options}</optgroup>`;
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

  let loaded = false;
  try {
    const table = decodeResolveCsv(await file.arrayBuffer());
    state.metadataFile = file;
    state.metadataTable = table;
    elements.metadataFileName.textContent = file.name;
    elements.metadataFileMeta.textContent = `${table.rows.length} 条素材 · ${table.headers.length} 列 · ${encodingLabel(table.format)}`;
    elements.metadataCard.hidden = false;
    elements.metadataDropzone.hidden = true;
    loaded = true;
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

  if (loaded && state.slateRootHandle) {
    try {
      await loadSlateDirectoryHandle(state.slateRootHandle);
    } catch (error) {
      if (error?.name !== "AbortError") {
        showError(error.message || "无法按新的 CSV 重新扫描素材目录。");
      }
    }
  } else if (loaded && state.slateFallbackFiles?.length) {
    await loadSlateDirectory(state.slateFallbackFiles);
  }
}

function clearResolveCsv() {
  clearSlateMetadata();
  state.metadataFile = null;
  state.metadataTable = null;
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

  if (state.metadataTable || state.slateMetadata.length) clearResolveCsv();
  resetRecognitionResults();
  try {
    setPreparing(true);
    let imageGroups = [];
    let previewDataUrl;
    let pageCount;
    let meta;
    if (isPdf) {
      const prepared = await preparePdf(file);
      imageGroups = prepared.imageDataGroups;
      previewDataUrl = prepared.previewDataUrl;
      pageCount = prepared.pageCount;
      meta = `${formatBytes(file.size)} · ${pageCount} 页 · 多视图双重查漏`;
    } else {
      const processed = await prepareImage(file);
      imageGroups = [[processed.dataUrl]];
      previewDataUrl = processed.dataUrl;
      pageCount = 1;
      meta = `${formatBytes(file.size)} · ${processed.width} × ${processed.height}`;
    }

    state.reportFile = file;
    state.imageDataGroups = imageGroups;
    state.pageCount = pageCount;
    elements.fileThumb.src = previewDataUrl;
    elements.largePreview.src = previewDataUrl;
    elements.fileName.textContent = file.name;
    elements.fileMeta.textContent = meta;
    elements.fileCard.hidden = false;
    elements.dropzone.hidden = true;
    elements.emptyPreview.hidden = true;
    elements.largePreview.hidden = false;
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
  elements.largePreview.hidden = true;
  updateRecognizeState();
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

  if (scale === 1 && file.type !== "image/png") {
    updateTaskProgress({
      phase: "preparing",
      percent: 95,
      message: "原图清晰度符合识别要求",
    });
    return { dataUrl: source, width, height };
  }

  const canvas = document.createElement("canvas");
  canvas.width = width;
  canvas.height = height;
  const context = canvas.getContext("2d", { alpha: false });
  context.fillStyle = "#ffffff";
  context.fillRect(0, 0, width, height);
  context.drawImage(image, 0, 0, width, height);

  const prepared = {
    dataUrl: canvas.toDataURL("image/jpeg", 0.9),
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
    const details = detailLayout.segments.map(
      (segment) =>
        resizeCanvas(
          createDetailComposite(
            croppedCanvas,
            detailLayout.header,
            segment,
          ),
          3000,
          true,
        ).toDataURL("image/jpeg", 0.93),
    );
    return [
      outputCanvas.toDataURL("image/jpeg", 0.92),
      ...details,
    ];
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
  if (recognitionReady()) {
    return recognizeWithPdf();
  }
  if (slateCsvMergeReady()) {
    return mergeSlateCsv();
  }
}

async function recognizeWithPdf() {
  hideError();
  resetRecognitionResults();
  setProcessing(true);

  try {
    const requestBody = await recognitionRequestBody();
    const data = await recognizeStreamApi(requestBody, updateTaskProgress);

    state.latestResponse = data;
    state.records = data.result.records.map(applyRecordFieldFormats);
    state.latestResponse.result.records = state.records;
    if (data.taskId) {
      state.currentTaskId = data.taskId;
      await loadTaskList();
    }
    renderResults(data);
  } catch (error) {
    markTaskProgressError(error.message);
    showError(error.message);
  } finally {
    setProcessing(false);
  }
}

function mergeSlateCsv() {
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
  return serializeRecognitionPayload({
    provider: elements.provider.value,
    model: elements.model.value,
    filename: state.reportFile.name,
    imageDataGroups: state.imageDataGroups,
    pageCount: state.pageCount,
    customPrompt: elements.customPromptInput.value.trim(),
    slateCsvRecords: state.slateCsvRecords,
  });
}

async function recompressImageGroups({ maxDimension, quality }) {
  for (const group of state.imageDataGroups) {
    for (let index = 0; index < group.length; index += 1) {
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
      group[index] = canvas.toDataURL("image/jpeg", quality);
      canvas.width = 1;
      canvas.height = 1;
    }
  }
}


function setResultsTab(name) {
  const showCsv = name === "csv";
  elements.tabCsv.classList.toggle("is-active", showCsv);
  elements.tabCsv.setAttribute("aria-selected", String(showCsv));
  elements.tabDetail.classList.toggle("is-active", !showCsv);
  elements.tabDetail.setAttribute("aria-selected", String(!showCsv));
  elements.panelCsv.hidden = !showCsv;
  elements.panelDetail.hidden = showCsv;
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
        `MODE ${data.inputMode === "pdf" ? "PDF" : data.accuracyMode === "high" ? "HIGH ACCURACY" : "IMAGE"}`,
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
  elements.metrics.innerHTML = metrics
    .map((metric) => `<span class="metric">${escapeHtml(metric)}</span>`)
    .join("");

  renderTable();
  setResultsTab(state.metadataTable ? "csv" : "detail");
  elements.results.hidden = false;
  elements.results.scrollIntoView({ behavior: "smooth", block: "start" });
}

function renderTable() {
  const output = currentMergeOutput();
  const statuses = output.statuses;
  elements.tabDetailBadge.textContent = String(state.records.length);
  elements.tabDetailBadge.hidden = state.records.length === 0;
  renderCsvPreview(output);
  elements.resultBody.innerHTML = state.records
    .map((record, index) => {
      const status = statuses[index];
      return `
      <tr data-index="${index}">
        <td>${index + 1}</td>
        <td>${record.sourcePage || "-"}</td>
        ${textCell("cardNumber", record.cardNumber)}
        ${textCell("videoCode", record.videoCode)}
        ${textCell("scene", record.scene)}
        ${textCell("shot", record.shot)}
        ${textCell("take", record.take)}
        <td>
          <select data-field="takeStatus">
            <option value="" ${record.takeStatus == null ? "selected" : ""}>未标记（留空）</option>
            <option value="过" ${record.takeStatus === "过" ? "selected" : ""}>☑ / √ → _OK</option>
            <option value="保" ${record.takeStatus === "保" ? "selected" : ""}>△ / 三角形 → _KP</option>
            <option value="废条" ${record.takeStatus === "废条" ? "selected" : ""}>X / × → 留空</option>
          </select>
        </td>
        ${textCell("description", record.description, "min-width:180px")}
        ${textCell("comments", record.comments, "min-width:160px")}
        ${textCell("shotSize", record.shotSize)}
        ${textCell("cameraPosition", record.cameraPosition)}
        <td>${exportLabel(status, record)}</td>
        <td><span class="confidence ${escapeHtml(record.confidence)}">${confidenceLabel(record.confidence)}</span></td>
        <td><button class="delete-row" type="button" aria-label="删除这一行">×</button></td>
      </tr>`;
    })
    .join("");

  for (const row of elements.resultBody.querySelectorAll("tr")) {
    const index = Number(row.dataset.index);
    for (const input of row.querySelectorAll("[data-field]")) {
      input.addEventListener("change", () => {
        const field = input.dataset.field;
        state.records[index][field] = normalizeEditedField(
          field,
          input.value,
        );
        renderTable();
        saveCurrentTask();
      });
    }
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

  const { headers, rows } = output.table;
  const columns = resolveColumnIndexes(output.table.headers);
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

  elements.csvPreviewSummary.textContent = `${rows.length} 行 × ${headers.length} 列`;
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
      const cells = headers
        .map((_, columnIndex) => {
          const classes = targetIndexes.has(columnIndex) ? "csv-target-column" : "";
          const value = String(row[columnIndex] ?? "");
          return `<td class="${classes}" title="${escapeHtml(value)}">${escapeHtml(value)}</td>`;
        })
        .join("");
      const rowClass = matchedRowIndexes.has(rowIndex)
        ? "csv-matched-row"
        : unrecognizedRowIndexes.has(rowIndex)
          ? "csv-unrecognized-row"
          : "";
      return `<tr class="${rowClass}">${cells}</tr>`;
    })
    .join("");
  elements.csvResultEmpty.textContent = "合成后的 CSV 没有数据行。";
  elements.csvResultEmpty.hidden = rows.length > 0;
}

function currentMergeOutput() {
  if (state.metadataTable) {
    return mergeSlateIntoResolveTable(
      state.metadataTable,
      state.records,
      state.slateMetadata,
      { fieldFormats: resolveFieldFormats() },
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
  return `<td><input style="${style}" data-field="${field}" value="${escapeHtml(value || "")}" /></td>`;
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

async function exportCsv() {
  if (state.metadataTable && state.metadataFile) {
    const output = currentMergeOutput();
    if (!output.exportableCount) {
      showError("没有匹配到可写入的完整记录，请检查卷号、视频码、场次、镜和次。");
      return;
    }
    const bytes = encodeResolveCsv(output.table, {
      fieldFormats: resolveFieldFormats(),
    });
    downloadCsv(bytes, `${baseName(state.metadataFile.name)}_场记已回填.csv`);
    return;
  }

  if (!state.records.length) {
    showError("没有可导出的识别记录。");
    return;
  }
  const table = buildStandaloneResolveTable(state.records, {
    fieldFormats: resolveFieldFormats(),
  });
  if (!table.rows.length) {
    showError("没有场次、镜、次完整的识别记录可导出。");
    return;
  }
  const title = state.latestResponse?.result?.sheetTitle || "场记单";
  const bytes = encodeResolveCsv(table, {
    fieldFormats: resolveFieldFormats(),
  });
  downloadCsv(bytes, `${baseName(title)}_场记识别.csv`);
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
  return state.config?.workflow?.resolve?.fieldFormats || {
    scene: "XXX",
    shot: "XX",
    take: "XX",
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

function resetRecognitionResults() {
  state.records = [];
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
}

function setPreparing(value) {
  elements.processing.hidden = !value;
  if (value) {
    resetTaskProgress({
      phase: "preparing",
      percent: 2,
      message: "正在检查文件并准备场记单页面",
    });
  }
}

function setProcessing(value) {
  state.recognizing = value;
  elements.processing.hidden = !value;
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
  const canRecognize = recognitionReady();
  const canMerge = !canRecognize && slateCsvMergeReady();
  elements.recognizeButton.disabled =
    state.recognizing || (!canRecognize && !canMerge);
  elements.recognizeButton.querySelector("span").textContent = state.recognizing
    ? "识别中…"
    : canMerge
      ? "合并 CSV"
      : "开始识别";
}

function updateExportState(output = currentMergeOutput()) {
  const recordCount = state.records.length;
  const enabled = state.metadataTable
    ? canExportResolveCsv({
        metadataLoaded: true,
        recordCount,
        exportableCount: output?.exportableCount,
      })
    : recordCount > 0;
  elements.exportButton.disabled = !enabled;
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

async function loadTaskList() {
  try {
    const data = await listTasksApi();
    state.tasks = Array.isArray(data) ? data : data.tasks || [];
    renderTaskSwitcher();
  } catch {
    state.tasks = [];
  }
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
  const taskId = elements.taskSelect.value;
  if (!taskId) {
    // "新任务" — reset workspace
    state.currentTaskId = null;
    clearReportFile();
    clearResolveCsv();
    resetRecognitionResults();
    renderTaskSwitcher();
    return;
  }
  if (taskId === state.currentTaskId) return;
  if (state.recognizing) {
    elements.taskSelect.value = state.currentTaskId || "";
    showError("识别进行中，无法切换任务。");
    return;
  }

  try {
    const task = await loadTaskApi(taskId);
    restoreTask(task);
  } catch (error) {
    showError(error.message || "无法加载任务。");
    elements.taskSelect.value = state.currentTaskId || "";
  }
}

function restoreTask(task) {
  state.currentTaskId = task.id;

  // Clear current state
  clearReportFile();
  clearResolveCsv();
  resetRecognitionResults();

  // Restore recognition config
  if (task.provider) elements.provider.value = task.provider;
  if (task.customPrompt) elements.customPromptInput.value = task.customPrompt;
  updateApiKeyFieldState();
  renderModelOptions();
  if (task.model) {
    // Wait for models to load, then select
    loadProviderModels().then(() => {
      if ([...elements.model.options].some((o) => o.value === task.model)) {
        elements.model.value = task.model;
        renderModelNote();
      }
    });
  }

  // Restore recognition result
  if (task.result?.records?.length) {
    state.records = task.editedRecords || task.result.records;
    state.latestResponse = {
      result: task.result,
      provider: task.provider,
      model: task.model,
      usage: task.usage,
      durationMs: task.durationMs,
      ocr: task.ocrSummary,
      pageCount: task.pageCount,
      accuracyMode: task.accuracyMode,
      inputMode: "images",
    };
    state.pageCount = task.pageCount || 0;
    elements.results.hidden = false;
    renderResults(state.latestResponse);
  }

  renderTaskSwitcher();
  updateRecognizeState();
}

async function deleteCurrentTask() {
  if (!state.currentTaskId) return;
  const task = state.tasks.find((t) => t.id === state.currentTaskId);
  const label = task?.filename || "未命名";
  if (!confirm(`确定删除任务"${label}"吗？此操作不可撤销。`)) return;

  try {
    await deleteTaskApi(state.currentTaskId);
    state.currentTaskId = null;
    clearReportFile();
    clearResolveCsv();
    resetRecognitionResults();
    await loadTaskList();
  } catch (error) {
    showError(error.message || "删除任务失败。");
  }
}

async function saveCurrentTask() {
  if (!state.currentTaskId || !state.latestResponse) return;
  try {
    await saveTaskApi({
      id: state.currentTaskId,
      editedRecords: state.records,
      status: "edited",
    });
  } catch {
    // best-effort save
  }
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

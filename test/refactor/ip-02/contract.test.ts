import { describe, expect, it } from "vitest";
import { createSlateSyncApi } from "../../../src/preload/index";
import type {
  ConfigData,
  DirectorySelection,
  FileSaveResult,
  JsonSchemaCapabilityResult,
  LogsReadResult,
  LibraryExportResult,
  LibraryImportResult,
  LibraryInfo,
  LibraryLocationResult,
  LibraryRenameResult,
  ModelDiscoveryResult,
  OcrCheckResult,
  OcrEngineStatus,
  OcrSelection,
  OcrSettings,
  ProgressData,
  ProjectData,
  ProjectSummary,
  RecognitionData,
  Result,
  ScanResult,
  ScenarioData,
  ScenarioProfile,
  ScenarioSummary,
  TaskData,
  TaskListItem,
  VisionOcrCheckResult,
} from "../../../src/shared/contracts/index";

interface Listener {
  (event: unknown, payload: ProgressData): void;
}

function makeTransport(responses: Readonly<Record<string, unknown>> = {}) {
  const calls: Array<{ channel: string; payload?: unknown }> = [];
  const listeners = new Set<Listener>();
  let failure: unknown = null;
  return {
    invoke(channel: string, payload?: unknown): Promise<unknown> {
      calls.push(payload === undefined ? { channel } : { channel, payload });
      if (failure !== null) return Promise.reject(failure);
      return Promise.resolve(responses[channel]);
    },
    on(_channel: string, listener: Listener): void {
      listeners.add(listener);
    },
    removeListener(_channel: string, listener: Listener): void {
      listeners.delete(listener);
    },
    emit(payload: ProgressData): void {
      for (const listener of listeners) listener({}, payload);
    },
    setFailure(next: unknown): void {
      failure = next;
    },
    calls,
    listeners,
  };
}

const ocrEngine = {
  id: "paddleocr",
  label: "PaddleOCR",
  mode: "auto",
  enabled: false,
  available: false,
  required: false,
  modelVersion: "PP-OCRv5",
} satisfies OcrEngineStatus;

const config = {
  providers: [{ id: "openai", label: "OpenAI", configured: false, requiredEnv: ["OPENAI_API_KEY"] }],
  models: [{ id: "openai/gpt", label: "GPT", description: "Vision", providers: ["openai"] }],
  ocr: ocrEngine,
  ocrEngines: [ocrEngine],
  ocrSelection: {
    id: null,
    label: "未启用本地 OCR",
    mode: "disabled",
    reason: "没有检测到可用的本地 OCR；识别将降级为页面图片识别。",
    available: false,
    enabled: false,
    required: false,
  } satisfies OcrSelection,
  upload: { acceptedTypes: ["image/png"], maxBytes: 20, maxRequestBytes: 40 },
  workflow: {
    slate: { maxDirectoryDepth: 4 },
    scenario: { matching: { threshold: 0.8, ambiguityMargin: 0.1 } },
    resolve: {
      fieldFormats: { scene: "XXX", shot: "XX", take: "XX" },
      comments: { goodTake: "_OK", holdTake: "_KP" },
    },
  },
} satisfies ConfigData;

const projectSettings = {
  version: 1,
  providerId: "openai",
  modelId: "openai/gpt",
  accuracyMode: "standard",
  scenarioId: null,
  customPrompt: "",
  resolve: {
    fieldFormats: { scene: "XXX", shot: "XX", take: "XX" },
    comments: { goodTake: "_OK", holdTake: "_KP" },
  },
} as const;

const projectSummary = {
  id: "project-1",
  name: "Demo",
  description: "",
  relativePath: "Projects/project-1",
  archivedAt: null,
  createdAt: "2026-01-01T00:00:00.000Z",
  updatedAt: "2026-01-01T00:00:00.000Z",
  taskCount: 1,
  latestTaskAt: "2026-01-01T00:00:00.000Z",
  canArchive: true,
} satisfies ProjectSummary;

const project = {
  ...projectSummary,
  settings: projectSettings,
  lastRecognitionDefaults: {
    providerId: "openai",
    modelId: "openai/gpt",
    customPrompt: "",
  },
} satisfies ProjectData;

const library = {
  id: "library-1",
  name: "Library",
  formatVersion: 1,
  path: "/synthetic/library.slatesync-library",
} satisfies LibraryInfo;

const validatedLibrary = { ...library, projectCount: 1 } as const;
const importedLibrary = {
  canceled: false,
  restartRequired: true,
  library: validatedLibrary,
} satisfies LibraryImportResult;
const exportedLibrary = {
  canceled: false,
  library: validatedLibrary,
} satisfies LibraryExportResult;
const changedLibrary = importedLibrary satisfies LibraryLocationResult;
const renamedLibrary = {
  canceled: false,
  restartRequired: true,
  library,
} satisfies LibraryRenameResult;

const scenarioField = {
  label: "",
  aliases: [],
  region: null,
  inherit: false,
  required: false,
} as const;
const scenarioProfile = {
  schemaVersion: 1,
  fingerprintVersion: 1,
  fingerprint: "scenario-fingerprint",
  label: "Profile",
  layout: {
    pages: [],
    headerTokens: [],
    cameraGroups: [],
    columnBands: [],
    rowBands: [],
    blockCount: 0,
  },
  fields: {
    cardNumber: scenarioField,
    videoCode: scenarioField,
    scene: scenarioField,
    shot: scenarioField,
    take: scenarioField,
    takeStatus: scenarioField,
    description: scenarioField,
    comments: scenarioField,
    shotSize: scenarioField,
    cameraPosition: scenarioField,
  },
  recognition: { headerTokens: [], promptHints: [] },
  output: {
    resolve: {
      fieldFormats: { scene: "XXX", shot: "XX", take: "XX" },
      comments: { goodTake: "_OK", holdTake: "_KP" },
    },
  },
} satisfies ScenarioProfile;

const scenario = {
  ...scenarioProfile,
  id: "scenario-1",
  sampleCount: 1,
  createdAt: "2026-01-01T00:00:00.000Z",
  updatedAt: "2026-01-01T00:00:00.000Z",
  lastUsedAt: "2026-01-01T00:00:00.000Z",
} satisfies ScenarioData;

const scenarioSummary = {
  id: scenario.id,
  label: scenario.label,
  fingerprint: scenario.fingerprint,
  fingerprintVersion: scenario.fingerprintVersion,
  schemaVersion: scenario.schemaVersion,
  sampleCount: scenario.sampleCount,
  fieldCount: 10,
  createdAt: scenario.createdAt,
  updatedAt: scenario.updatedAt,
  lastUsedAt: scenario.lastUsedAt,
} satisfies ScenarioSummary;

const task = {
  id: "task-1",
  projectId: "project-1",
  projectSettingsSnapshot: projectSettings,
  status: "completed",
  filename: "slate.png",
  fileType: "image/png",
  fileSize: 10,
  pageCount: 1,
  imageDataGroups: null,
  resolveCsvBase64: null,
  resolveCsvFilename: "timeline.csv",
  resolveCsvTable: {
    headers: ["File Name", "Scene"],
    rows: [["A001C001.mov", "001"]],
    format: {
      encoding: "utf-8",
      bom: false,
      delimiter: ",",
      lineEnding: "\n",
      finalNewline: true,
    },
  },
  resolveCsvEdits: { "0:1": "002" },
  slateMetadata: [{ materialKey: "A:1:1", sensorFps: "24" }],
  slateWarnings: [],
  missingMetadataKeys: ["A:1:2"],
  slateDirectoryName: "Day 01",
  scenarioId: scenario.id,
  scenarioMatch: "selected",
  scenarioFingerprint: scenario.fingerprint,
  provider: "openai",
  model: "openai/gpt",
  customPrompt: "",
  accuracyMode: "standard",
  result: {
    sheetTitle: "Day 01",
    records: [{ cardNumber: "A001", videoCode: "C001", confidence: "high" }],
    warnings: [],
  },
  usage: { inputTokens: 10, outputTokens: 5 },
  durationMs: 1,
  ocrSummary: null,
  diagnosticSessionId: null,
  editedRecords: null,
  createdAt: "2026-01-01T00:00:00.000Z",
  updatedAt: "2026-01-01T00:00:01.000Z",
} satisfies TaskData;

const taskList = [{
  id: "task-1",
  filename: "slate.png",
  provider: "openai",
  model: "openai/gpt",
  pageCount: 1,
  scenarioId: null,
  recordCount: 1,
  status: "completed",
  createdAt: "2026-01-01T00:00:00.000Z",
  updatedAt: "2026-01-01T00:00:01.000Z",
}] satisfies TaskListItem[];

const ocrSummary = {
  enabled: false,
  available: false,
  used: false,
  cacheHit: false,
  engine: "paddleocr",
  model: null,
  profile: null,
  profileLabel: null,
  detectionModel: null,
  recognitionModel: null,
  recognitionBatchSize: null,
  device: null,
  pageCount: 0,
  viewCount: 0,
  blockCount: 0,
  lowConfidenceBlockCount: 0,
  durationMs: 0,
  warning: null,
} as const;

const recognition = {
  provider: "openai",
  model: "openai/gpt",
  inputMode: "images",
  durationMs: 1,
  pageCount: 1,
  accuracyMode: "standard",
  usage: { input_tokens: 10, output_tokens: 5 },
  ocr: ocrSummary,
  scenario: null,
  result: {
    sheetTitle: "Day 01",
    records: [{
      id: "record-1",
      sourcePage: 1,
      cardNumber: "A001",
      videoCode: "C001",
      scene: "001",
      shot: "01",
      take: "01",
      takeStatus: "过",
      description: null,
      comments: null,
      shotSize: null,
      cameraPosition: null,
      confidence: "high",
    }],
    warnings: [],
  },
  projectId: "project-1",
  projectSettingsSnapshot: projectSettings,
  lastRecognitionDefaults: {
    providerId: "openai",
    modelId: "openai/gpt",
    customPrompt: "",
  },
  diagnosticSessionId: null,
  taskId: "task-1",
} satisfies RecognitionData;

const modelDiscovery = {
  provider: "openai",
  source: "api",
  refreshedAt: "2026-01-01T00:00:00.000Z",
  availableModelCount: 1,
  visionModelCount: 1,
  fixedModelCount: 1,
  models: config.models,
} satisfies ModelDiscoveryResult;

const directory = { dirPath: "/synthetic", dirName: "synthetic" } satisfies DirectorySelection;
const scan = {
  metadata: [{
    sourceName: "A001C001-slate.txt",
    clipName: "A001C001",
    materialKey: "A:1:1",
    sensorFps: "24",
    shootDay: "26-01-01",
  }],
  warnings: [],
  stats: {
    visitedDirectories: 2,
    prunedDirectories: 0,
    skippedDeepDirectories: 0,
    discoveredSlateFiles: 1,
    readSlateFiles: 1,
    learnedStructures: 0,
  },
  missingKeys: [],
} satisfies ScanResult;
const saveResult = { saved: true, filePath: "/synthetic/demo.csv" } satisfies FileSaveResult;
const ocrSettings = { pythonPath: "python3", setupCompleted: true, setupSkipped: false } satisfies OcrSettings;
const ocrCheck = { ok: true, paddleVersion: "3", paddleOcrVersion: "3" } satisfies OcrCheckResult;
const visionOcrCheck = { ok: true, engine: "Vision", modelVersion: "macOS-Vision", systemVersion: "15.0" } satisfies VisionOcrCheckResult;
const jsonSchemaCheck = {
  supported: true,
  model: "local-vision",
  transport: "chat-completions",
  status: 200,
  checkedAt: "2026-08-26T00:00:00.000Z",
  message: "接口支持 JSON Schema，且模型返回符合探针结构。",
} satisfies JsonSchemaCapabilityResult;
const logsRead = { entries: [], hasMore: false } satisfies LogsReadResult;

const responses: Readonly<Record<string, unknown>> = {
  "get-config": config,
  "list-projects": [projectSummary],
  "get-library-info": library,
  "import-project-library": importedLibrary,
  "export-project-library": exportedLibrary,
  "change-library-location": changedLibrary,
  "rename-library": renamedLibrary,
  "create-project": project,
  "load-project": project,
  "update-project": project,
  "archive-project": project,
  "restore-project": project,
  "delete-project": { deleted: project.id },
  "list-scenarios": [scenarioSummary],
  "load-scenario": scenario,
  "import-scenario": scenario,
  "list-tasks": taskList,
  "load-task": task,
  "save-task": "task-1",
  "delete-task": { deleted: "task-1" },
  "get-models": modelDiscovery,
  recognize: recognition,
  "cancel-recognition": { canceled: true },
  "save-file": saveResult,
  "select-directory": directory,
  "scan-slate-directory": scan,
  "save-provider-key": { provider: "openai", configured: true },
  "get-ocr-settings": ocrSettings,
  "save-ocr-settings": ocrSettings,
  "check-ocr": ocrCheck,
  "check-vision-ocr": visionOcrCheck,
  "check-compatible-json-schema": jsonSchemaCheck,
  "logs-read": logsRead,
};

function expectSuccess<T>(result: Result<T>, expected: T): void {
  expect(result).toEqual({ ok: true, data: expected });
}

describe("IP-02 Shared Contract and typed Preload", () => {
  it("exposes exactly seven namespaces and exact success DTOs for all 33 operations", async () => {
    const transport = makeTransport(responses);
    const api = createSlateSyncApi(transport);
    expect(Object.keys(api)).toEqual(["app", "projects", "tasks", "recognition", "files", "settings", "logs"]);
    expect(api).not.toHaveProperty("invoke");
    expect(api).not.toHaveProperty("electronAPI");

    expectSuccess(await api.app.getConfig(), config);
    expectSuccess(await api.projects.list(), [projectSummary]);
    expectSuccess(await api.projects.getLibraryInfo(), library);
    expectSuccess(await api.projects.importLibrary(), importedLibrary);
    expectSuccess(await api.projects.exportLibrary(), exportedLibrary);
    expectSuccess(await api.projects.changeLibraryLocation(), changedLibrary);
    expectSuccess(await api.projects.renameLibrary({ name: "Renamed" }), renamedLibrary);
    expectSuccess(await api.projects.create({ name: "Demo" }), project);
    expectSuccess(await api.projects.load({ id: project.id }), project);
    expectSuccess(await api.projects.update({ id: project.id, name: "Demo" }), project);
    expectSuccess(await api.projects.archive({ id: project.id }), project);
    expectSuccess(await api.projects.restore({ id: project.id }), project);
    expectSuccess(await api.projects.delete({ id: project.id }), { deleted: project.id });
    expectSuccess(await api.projects.listScenarios({ projectId: project.id }), [scenarioSummary]);
    expectSuccess(await api.projects.loadScenario({ projectId: project.id, id: scenario.id }), scenario);
    expectSuccess(await api.projects.importScenario({ projectId: project.id, profile: scenarioProfile }), scenario);
    expectSuccess(await api.tasks.list({ projectId: project.id }), taskList);
    expectSuccess(await api.tasks.load({ projectId: project.id, id: "task-1" }), task);
    expectSuccess(await api.tasks.save({ projectId: project.id, task }), "task-1");
    expectSuccess(await api.tasks.delete({ projectId: project.id, id: "task-1" }), { deleted: "task-1" });
    expectSuccess(await api.recognition.getModels({ providerId: "openai", forceRefresh: true }), modelDiscovery);
    expectSuccess(await api.recognition.run({ taskId: "task-1", provider: "openai", imageDataUrl: "data:image/png;base64,AAAA" }), recognition);
    expectSuccess(await api.recognition.cancel({ projectId: project.id }), { canceled: true });
    expectSuccess(await api.files.save({ defaultFilename: "demo.csv", data: new Uint8Array([1, 2, 3]) }), saveResult);
    expectSuccess(await api.files.selectDirectory(), directory);
    expectSuccess(await api.files.scanSlateDirectory({ dirPath: "/synthetic", expectedKeys: ["A:1:1"], maxDepth: 4 }), scan);
    expectSuccess(await api.settings.saveProviderKey({ provider: "openai", apiKey: "synthetic-key" }), { provider: "openai", configured: true });
    expectSuccess(await api.settings.getOcrSettings(), ocrSettings);
    expectSuccess(await api.settings.saveOcrSettings({ pythonPath: "python3" }), ocrSettings);
    expectSuccess(await api.settings.checkOcr({ pythonPath: "python3" }), ocrCheck);
    expectSuccess(await api.settings.checkVisionOcr(), visionOcrCheck);
    expectSuccess(await api.settings.checkCompatibleJsonSchema(), jsonSchemaCheck);
    expectSuccess(await api.logs.read({ limit: 10 }), logsRead);

    expect(transport.calls.map(({ channel }) => channel)).toEqual(Object.keys(responses));
    expect(transport.calls[7]?.payload).toEqual({ name: "Demo" });
    expect(transport.calls[13]?.payload).toEqual({ projectId: project.id });
    expect(transport.calls[21]?.payload).toEqual({ taskId: "task-1", provider: "openai", imageDataUrl: "data:image/png;base64,AAAA" });
    expect(transport.calls[22]?.payload).toEqual({ projectId: project.id });
  });

  it("maps the complete failure matrix without transport boilerplate, paths, or retry changes", async () => {
    const cases = [
      [{ message: "项目名称不能为空" }, { code: "UNKNOWN", message: "项目名称不能为空", retryable: false }],
      [{ code: "ENOENT", message: "任务不存在" }, { code: "ENOENT", message: "任务不存在", retryable: false }],
      [{ code: "PROJECT_BUSY", message: "项目正在归档" }, { code: "PROJECT_BUSY", message: "项目正在归档", retryable: false }],
      [{ code: "LIBRARY_BUSY", message: "项目库正在切换" }, { code: "LIBRARY_BUSY", message: "项目库正在切换", retryable: false }],
      [{ status: 503, message: "服务暂时不可用" }, { code: "HTTP_503", message: "服务暂时不可用", retryable: true }],
      [{ status: 504, message: "读取模型列表超时" }, { code: "HTTP_504", message: "读取模型列表超时", retryable: true }],
      [{ message: "文件对话框不可用" }, { code: "UNKNOWN", message: "文件对话框不可用", retryable: false }],
      [{ message: "Error invoking remote method 'recognize': Error: failed at /Users/example/private.json" }, { code: "UNKNOWN", message: "Error: failed at <path>", retryable: false }],
    ] as const;

    for (const [failure, expected] of cases) {
      const transport = makeTransport();
      transport.setFailure(failure);
      expect(await createSlateSyncApi(transport).app.getConfig()).toEqual({
        ok: false,
        error: expected,
      });
    }
  });

  it("keeps subscribers independent, idempotent, and silent after removal", () => {
    const transport = makeTransport();
    const api = createSlateSyncApi(transport);
    const first: ProgressData[] = [];
    const second: ProgressData[] = [];
    const unsubscribeFirst = api.recognition.onProgress((event) => first.push(event));
    const unsubscribeSecond = api.recognition.onProgress((event) => second.push(event));

    transport.emit({ phase: "recognition", percent: 25 });
    unsubscribeFirst();
    unsubscribeFirst();
    transport.emit({ phase: "complete", percent: 100 });
    unsubscribeSecond();
    transport.emit({ phase: "late", percent: 100 });

    expect(first).toEqual([{ phase: "recognition", percent: 25 }]);
    expect(second).toEqual([
      { phase: "recognition", percent: 25 },
      { phase: "complete", percent: 100 },
    ]);
    expect(transport.listeners.size).toBe(0);
  });

  it("keeps full buffers zero-copy and copies only an exact subview", async () => {
    const transport = makeTransport({ "save-file": saveResult });
    const api = createSlateSyncApi(transport);
    const full = new Uint8Array([1, 2, 3]);
    await api.files.save({ defaultFilename: "full.csv", data: full });
    expect((transport.calls[0]?.payload as { data: ArrayBuffer }).data).toBe(full.buffer);

    const backing = new Uint8Array([9, 8, 7, 6, 5]);
    await api.files.save({ defaultFilename: "range.csv", data: backing.subarray(1, 4) });
    const data = (transport.calls[1]?.payload as { data: ArrayBuffer }).data;
    expect(data).not.toBe(backing.buffer);
    expect([...new Uint8Array(data)]).toEqual([8, 7, 6]);
  });
});

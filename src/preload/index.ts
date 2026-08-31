import type {
  AppError,
  BinaryPayload,
  CustomProviderConfigRequest,
  CustomProviderDeleteRequest,
  CustomProviderSummary,
  UpdateCustomProviderRequest,
  GlobalSettingsData,
  GlobalSettingsRequest,
  LogsOpenDirectoryResult,
  LogsReadRequest,
  ModelsRequest,
  OcrCheckRequest,
  VisionOcrCheckResult,
  OcrSettingsRequest,
  ProjectIdRequest,
  ProjectRequest,
  ProjectScopedRequest,
  ProjectTaskIdRequest,
  ProjectTaskRequest,
  ProviderKeyRequest,
  RecognitionRequest,
  SaveFileRequest,
  ScanSlateDirectoryRequest,
  ScenarioIdRequest,
  ScenarioImportRequest,
  LibraryRenameRequest,
  SlateSyncApi,
  ProgressData,
  ModelProbeRequest,
  ModelProbeResult,
  ModelProbeProgress,
} from "../shared/contracts/index.js";
import { toAppError } from "../shared/errors/index.js";

/** IP-01 build marker remains available while IP-02 owns the active gateway. */
export const PRELOAD_BUILD_TARGET = "preload" as const;

type ProgressListener = (event: ProgressData) => void;
type ModelProbeProgressListener = (event: ModelProbeProgress) => void;

interface PreloadTransport {
  invoke(channel: string): Promise<unknown>;
  invoke(channel: string, payload: unknown): Promise<unknown>;
  on(channel: string, listener: (_event: unknown, payload: any) => void): void;
  removeListener(channel: string, listener: (_event: unknown, payload: any) => void): void;
}

interface ContextBridge {
  exposeInMainWorld(name: string, value: SlateSyncApi): void;
}

interface ElectronRuntime {
  readonly contextBridge: ContextBridge;
  readonly ipcRenderer: PreloadTransport;
}

function invokeResult<T>(transport: PreloadTransport, channel: string, payload?: unknown): Promise<import("../shared/contracts/index.js").Result<T>> {
  const call = payload === undefined
    ? transport.invoke(channel)
    : transport.invoke(channel, payload);
  return call.then(
    (data): import("../shared/contracts/index.js").Result<T> => ({ ok: true, data: data as T }),
    (error: unknown): import("../shared/contracts/index.js").Result<T> => ({ ok: false, error: toAppError(error) }),
  );
}

function exactBinary(data: BinaryPayload): ArrayBuffer {
  if (data instanceof ArrayBuffer) return data;
  if (!ArrayBuffer.isView(data)) throw new TypeError("files.save requires ArrayBuffer or ArrayBufferView");
  const buffer = data.buffer;
  if (buffer instanceof ArrayBuffer && data.byteOffset === 0 && data.byteLength === buffer.byteLength) {
    return buffer;
  }
  return new Uint8Array(data.buffer, data.byteOffset, data.byteLength).slice().buffer;
}

export function createSlateSyncApi(transport: PreloadTransport): SlateSyncApi {
  const request = <T>(channel: string, payload?: unknown) => invokeResult<T>(transport, channel, payload);
  const onProgress = (listener: ProgressListener): (() => void) => {
    const wrapped = (_event: unknown, payload: ProgressData) => listener(payload);
    let active = true;
    transport.on("recognition-progress", wrapped);
    return () => {
      if (!active) return;
      active = false;
      transport.removeListener("recognition-progress", wrapped);
    };
  };
  const onModelProbeProgress = (listener: ModelProbeProgressListener): (() => void) => {
    const wrapped = (_event: unknown, payload: ModelProbeProgress) => listener(payload);
    let active = true;
    transport.on("model-probe-progress", wrapped);
    return () => {
      if (!active) return;
      active = false;
      transport.removeListener("model-probe-progress", wrapped);
    };
  };

  return {
    app: {
      getConfig: () => request("get-config"),
    },
    projects: {
      list: () => request("list-projects"),
      getLibraryInfo: () => request("get-library-info"),
      importLibrary: () => request("import-project-library"),
      exportLibrary: () => request("export-project-library"),
      changeLibraryLocation: () => request("change-library-location"),
      renameLibrary: (body: LibraryRenameRequest) => request("rename-library", body),
      create: (body: ProjectRequest) => request("create-project", body),
      load: (body: ProjectIdRequest) => request("load-project", body),
      update: (body: ProjectRequest) => request("update-project", body),
      archive: (body: ProjectIdRequest) => request("archive-project", body),
      restore: (body: ProjectIdRequest) => request("restore-project", body),
      delete: (body: ProjectIdRequest) => request("delete-project", body),
      listScenarios: (body: ProjectScopedRequest) => request("list-scenarios", body),
      loadScenario: (body: ScenarioIdRequest) => request("load-scenario", body),
      importScenario: (body: ScenarioImportRequest) => request("import-scenario", body),
    },
    tasks: {
      list: (body: ProjectScopedRequest) => request("list-tasks", body),
      load: (body: ProjectTaskIdRequest) => request("load-task", body),
      save: (body: ProjectTaskRequest) => request("save-task", body),
      delete: (body: ProjectTaskIdRequest) => request("delete-task", body),
    },
    recognition: {
      getModels: (body: ModelsRequest) => request("get-models", body),
      run: (body: RecognitionRequest) => request("recognize", body),
      cancel: (body: ProjectScopedRequest) => request("cancel-recognition", body),
      onProgress,
    },
    files: {
      save: (body: SaveFileRequest) => request("save-file", {
        defaultFilename: body.defaultFilename,
        data: exactBinary(body.data),
      }),
      selectDirectory: () => request("select-directory"),
      scanSlateDirectory: (body: ScanSlateDirectoryRequest) => request("scan-slate-directory", body),
    },
    settings: {
      saveProviderKey: (body: ProviderKeyRequest) => request("save-provider-key", body),
      getGlobalSettings: () => request<GlobalSettingsData>("get-global-settings"),
      saveGlobalSettings: (body: GlobalSettingsRequest) => request<GlobalSettingsData>("save-global-settings", body),
      getOcrSettings: () => request("get-ocr-settings"),
      saveOcrSettings: (body: OcrSettingsRequest) => request("save-ocr-settings", body),
      checkOcr: (body: OcrCheckRequest) => request("check-ocr", body),
      checkVisionOcr: () => request<VisionOcrCheckResult>("check-vision-ocr"),
      checkCompatibleJsonSchema: () => request("check-compatible-json-schema"),
      listCustomProviders: () => request<CustomProviderSummary[]>("list-custom-providers"),
      createCustomProvider: (body: CustomProviderConfigRequest) => request<CustomProviderSummary>("create-custom-provider", body),
      updateCustomProvider: (body: UpdateCustomProviderRequest) => request<CustomProviderSummary>("update-custom-provider", body),
      deleteCustomProvider: (body: CustomProviderDeleteRequest) => request<{ deleted: string }>("delete-custom-provider", body),
      probeCustomModels: (body: ModelProbeRequest) => request<ModelProbeResult>("probe-custom-models", body),
      cancelCustomModelProbe: (body: { providerId: string }) => request<{ canceled: boolean }>("cancel-custom-model-probe", body),
      onModelProbeProgress,
    },
    // Logs stay read-only over IPC: the Main process is the single writer of
    // the local log files. Opening the folder is an OS action, not a Renderer
    // filesystem escape, so it also stays behind the typed Main boundary.
    logs: {
      read: (body: LogsReadRequest) => request("logs-read", body),
      openDirectory: () => request<LogsOpenDirectoryResult>("logs-open-directory"),
    },
  };
}

/** Called only by the tiny CommonJS bootstrap loaded by BrowserWindow. */
export function exposeSlateSync(): void {
  // require is used at the final CJS boundary so the typed source stays
  // environment-neutral while Electron remains external to the Vite bundle.
  const { contextBridge, ipcRenderer } = require("electron") as ElectronRuntime;
  contextBridge.exposeInMainWorld("slateSync", createSlateSyncApi(ipcRenderer));
}

// Vite emits this entry as one sandbox-compatible CommonJS file. It starts
// only inside Electron's Preload runtime; Node imports used by unit tests and
// the gateway benchmark continue to receive the pure factory without effects.
if (typeof process !== "undefined" && typeof process.versions.electron === "string") {
  exposeSlateSync();
}

export type { AppError };

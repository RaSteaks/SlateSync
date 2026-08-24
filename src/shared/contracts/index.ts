/**
 * Shared Contract v1 is the single Renderer-facing description of values that
 * the existing Main handlers actually return. Persisted compatibility shapes
 * are named separately from live recognition DTOs so legacy snapshots remain
 * readable without turning the public contract into an unbounded JSON bag.
 */
export type BinaryPayload = ArrayBuffer | ArrayBufferView;

export type Result<T> =
  | { readonly ok: true; readonly data: T }
  | { readonly ok: false; readonly error: AppError };

export interface AppError {
  readonly code: string;
  readonly message: string;
  readonly retryable: boolean;
}

export interface ProviderSummary {
  readonly id: string;
  readonly label: string;
  readonly configured: boolean;
  readonly requiredEnv: readonly string[];
}

export interface ModelData {
  readonly id: string;
  readonly label: string;
  readonly description: string;
  readonly providers: readonly string[];
  readonly imageDetail?: "auto" | "low" | "high" | "original";
  readonly directId?: string;
  readonly apiId?: string;
  readonly openRouterStructuredOutputs?: boolean;
  readonly fixed?: boolean;
  readonly fixedPriority?: number | null;
  readonly discovered?: boolean;
  readonly verifiedAvailable?: boolean;
  readonly qualityScore?: number;
  readonly valueScore?: number;
  readonly qualityLabel?: string;
  readonly valueLabel?: string;
}

export interface OcrEngineStatus {
  readonly id: string;
  readonly label: string;
  readonly mode: string;
  readonly enabled: boolean;
  readonly available: boolean;
  readonly required: boolean;
  readonly language?: string;
  readonly recognitionLevel?: string;
  readonly usesLanguageCorrection?: boolean;
  readonly minimumConfidence?: number;
  readonly maxBlocksPerView?: number;
  readonly modelVersion?: string;
  readonly profile?: string;
  readonly profileLabel?: string;
  readonly detectionModel?: string;
  readonly recognitionModel?: string;
  readonly recognitionBatchSize?: number;
  readonly device?: string;
}

export interface ResolveFieldFormats {
  readonly scene: string;
  readonly shot: string;
  readonly take: string;
}

export interface ResolveComments {
  readonly goodTake: string;
  readonly holdTake: string;
}

export interface WorkflowConfig {
  readonly slate: { readonly maxDirectoryDepth: number };
  readonly scenario: {
    readonly matching: {
      readonly threshold: number;
      readonly ambiguityMargin: number;
    };
  };
  readonly resolve: {
    readonly fieldFormats: ResolveFieldFormats;
    readonly comments: ResolveComments;
  };
}

export interface UploadLimits {
  readonly acceptedTypes: readonly string[];
  readonly maxBytes: number;
  readonly maxRequestBytes: number;
}

export interface ConfigData {
  readonly providers: readonly ProviderSummary[];
  readonly models: readonly ModelData[];
  readonly ocr: OcrEngineStatus;
  readonly ocrEngines: readonly OcrEngineStatus[];
  readonly upload: UploadLimits;
  readonly workflow: WorkflowConfig;
}

export interface ProjectSettings {
  readonly version: number;
  readonly providerId: string | null;
  readonly modelId: string | null;
  readonly accuracyMode: "high" | "standard";
  readonly scenarioId: string | null;
  readonly customPrompt: string;
  readonly resolve: {
    readonly fieldFormats: ResolveFieldFormats;
    readonly comments: ResolveComments;
  };
}

export interface RecognitionDefaults {
  readonly providerId: string;
  readonly modelId: string;
  readonly customPrompt: string;
}

/** Lightweight list-projects row; settings remain project-database owned. */
export interface ProjectSummary {
  readonly id: string;
  readonly name: string;
  readonly description: string;
  readonly relativePath: string;
  readonly archivedAt: string | null;
  readonly createdAt: string;
  readonly updatedAt: string;
  readonly taskCount: number;
  readonly latestTaskAt: string | null;
  readonly canArchive: boolean;
}

/** load/create/update/archive/restore additionally resolve project settings. */
export interface ProjectData extends ProjectSummary {
  readonly settings: ProjectSettings;
  readonly lastRecognitionDefaults: RecognitionDefaults | null;
}

export interface LibraryInfo {
  readonly id: string;
  readonly name: string;
  readonly formatVersion: number;
  readonly path: string;
}

export interface ValidatedLibraryInfo extends LibraryInfo {
  readonly projectCount: number;
}

export type LibraryImportResult =
  | { readonly canceled: true }
  | {
      readonly canceled: false;
      readonly restartRequired: true;
      readonly library: ValidatedLibraryInfo;
    };

export type LibraryExportResult =
  | { readonly canceled: true }
  | { readonly canceled: false; readonly library: ValidatedLibraryInfo };

export type LibraryLocationResult = LibraryImportResult;

export interface ProjectRequest {
  readonly id?: string;
  readonly name?: string;
  readonly description?: string;
  readonly settings?: ProjectSettings;
}

export interface ProjectIdRequest {
  readonly id: string;
}

export interface ProjectScopedRequest {
  readonly projectId: string;
}

export interface ProjectTaskRequest extends ProjectScopedRequest {
  readonly task: TaskSaveData;
}

export interface ProjectTaskIdRequest extends ProjectScopedRequest {
  readonly id: string;
}

export interface ScenarioIdRequest extends ProjectScopedRequest {
  readonly id: string;
}

export interface ScenarioImportRequest extends ProjectScopedRequest {
  readonly profile: ScenarioProfile;
}

export interface ModelsRequest {
  readonly providerId: string;
  readonly forceRefresh?: boolean;
}

export interface ProviderKeyRequest {
  readonly provider: string;
  readonly apiKey: string;
}

export interface SlateCsvRecord {
  readonly fileName?: string | null;
  readonly materialKey?: string | null;
  readonly cardNumber?: string | null;
  readonly videoCode?: string | null;
  readonly scene?: string | null;
  readonly shot?: string | null;
  readonly take?: string | null;
  readonly comments?: "过" | "保" | "废条" | null;
  readonly cameraFps?: string | null;
  readonly shootDay?: string | null;
}

export interface RecognitionRequest {
  /** Existing draft to complete in place; omitted only for a genuinely new run. */
  readonly taskId?: string | null;
  readonly provider?: string;
  readonly model?: string;
  readonly imageDataUrl?: string;
  readonly imageDataUrls?: readonly string[];
  readonly imageDataGroups?: readonly (readonly string[])[];
  readonly pdfDataUrl?: string;
  readonly pageCount?: number;
  readonly filename?: string;
  readonly accuracyMode?: "high" | "standard";
  readonly customPrompt?: string;
  readonly scenarioId?: string | null;
  readonly projectId?: string | null;
  readonly slateCsvRecords?: readonly SlateCsvRecord[] | null;
}

export interface SaveFileRequest {
  readonly defaultFilename: string;
  readonly data: BinaryPayload;
}

export interface ScanSlateDirectoryRequest {
  readonly dirPath: string;
  readonly expectedKeys: readonly string[];
  readonly maxDepth?: number;
}

export interface OcrSettingsRequest {
  readonly pythonPath?: string;
  readonly skip?: boolean;
}

export interface OcrCheckRequest {
  readonly pythonPath: string;
}

export interface OcrSettings {
  readonly pythonPath: string;
  readonly setupCompleted: boolean;
  readonly setupSkipped: boolean;
}

export type OcrCheckResult =
  | {
      readonly ok: true;
      readonly paddleVersion: string;
      readonly paddleOcrVersion: string;
    }
  | {
      readonly ok: false;
      readonly error: { readonly code: string; readonly message: string };
    };

export interface RecognitionRecord {
  readonly id: string;
  readonly sourcePage: number | null;
  readonly cardNumber: string | null;
  readonly videoCode: string | null;
  readonly scene: string | null;
  readonly shot: string | null;
  readonly take: string | null;
  readonly takeStatus: "过" | "保" | "废条" | null;
  readonly description: string | null;
  readonly comments: string | null;
  readonly shotSize: string | null;
  readonly cameraPosition: string | null;
  readonly confidence: "high" | "medium" | "low";
  readonly reviewRequiredFields?: readonly string[];
}

/** Older task snapshots can contain normalized records predating newer keys. */
export interface PersistedRecognitionRecord {
  readonly id?: string;
  readonly sourcePage?: number | null;
  readonly cardNumber?: string | null;
  readonly videoCode?: string | null;
  readonly scene?: string | null;
  readonly shot?: string | null;
  readonly take?: string | null;
  readonly takeStatus?: "过" | "保" | "废条" | null;
  readonly description?: string | null;
  readonly comments?: string | null;
  readonly shotSize?: string | null;
  readonly cameraPosition?: string | null;
  readonly confidence?: "high" | "medium" | "low";
  readonly reviewRequiredFields?: readonly string[];
}

export interface RecognitionSheet {
  readonly sheetTitle: string | null;
  readonly records: readonly RecognitionRecord[];
  readonly warnings: readonly string[];
}

export interface PersistedRecognitionSheet {
  readonly sheetTitle?: string | null;
  readonly records: readonly PersistedRecognitionRecord[];
  readonly warnings?: readonly string[];
}

/** Providers and frozen snapshots use both OpenAI naming generations. */
export interface TokenUsage {
  readonly prompt_tokens?: number;
  readonly completion_tokens?: number;
  readonly total_tokens?: number;
  readonly input_tokens?: number;
  readonly output_tokens?: number;
  readonly inputTokens?: number;
  readonly outputTokens?: number;
  readonly totalTokens?: number;
}

export interface OcrSummary {
  readonly enabled: boolean;
  readonly available: boolean;
  readonly used: boolean;
  readonly cacheHit: boolean;
  readonly engine: string;
  readonly model: string | null;
  readonly profile: string | null;
  readonly profileLabel: string | null;
  readonly detectionModel: string | null;
  readonly recognitionModel: string | null;
  readonly recognitionBatchSize: number | null;
  readonly device: string | null;
  readonly pageCount: number;
  readonly viewCount: number;
  readonly blockCount: number;
  readonly lowConfidenceBlockCount: number;
  readonly durationMs: number;
  readonly warning: string | null;
}

export interface ScenarioSelection {
  readonly id: string | null;
  readonly match: string;
  readonly score: number;
  readonly fingerprint: string | null;
  readonly warning: string | null;
}

export interface RecognitionData {
  readonly provider: string;
  readonly model: string;
  readonly inputMode: "images" | "pdf";
  readonly durationMs: number;
  readonly pageCount: number;
  readonly accuracyMode: "high" | "standard";
  readonly usage: TokenUsage | null;
  readonly ocr: OcrSummary;
  readonly scenario: ScenarioSelection | null;
  readonly result: RecognitionSheet;
  readonly projectId: string | null;
  readonly projectSettingsSnapshot: ProjectSettings | null;
  readonly lastRecognitionDefaults: RecognitionDefaults | null;
  readonly diagnosticSessionId: string | null;
  readonly taskId: string | null;
}

export interface ProgressData {
  readonly type?: "progress";
  readonly phase?: string;
  readonly percent?: number;
  readonly message?: string;
  readonly pageNumber?: number | null;
  readonly completed?: number;
  readonly total?: number;
  readonly completedViews?: number;
  readonly totalViews?: number;
  readonly viewIndex?: number | null;
  readonly cacheHit?: boolean;
}

export interface TaskListItem {
  readonly id?: string;
  readonly filename?: string | null;
  readonly provider?: string | null;
  readonly model?: string | null;
  readonly pageCount?: number;
  readonly scenarioId: string | null;
  readonly recordCount: number;
  readonly status: string;
  readonly createdAt?: string | null;
  readonly updatedAt?: string | null;
}

export type ResolveCsvEncoding = "utf-8" | "utf-16le" | "utf-16be";

export interface ResolveCsvFormat {
  readonly encoding?: ResolveCsvEncoding;
  readonly bom?: boolean;
  readonly delimiter?: string;
  readonly lineEnding?: "\r\n" | "\n" | "\r";
  readonly finalNewline?: boolean;
  /** Frozen legacy snapshots used `newline` before `lineEnding` was canonical. */
  readonly newline?: "\r\n" | "\n" | "\r";
}

export interface ResolveCsvTable {
  readonly headers: readonly string[];
  readonly rows: readonly (readonly string[])[];
  readonly format: ResolveCsvFormat;
}

export type ResolveCsvEdits = Readonly<Record<`${number}:${number}`, string>>;

export interface ScannedSlateMetadata {
  readonly sourceName: string;
  readonly clipName: string;
  readonly materialKey: string;
  readonly sensorFps: string;
  readonly shootDay: string;
}

export interface PersistedSlateMetadata {
  readonly sourceName?: string;
  readonly clipName?: string;
  readonly materialKey: string;
  readonly sensorFps?: string | null;
  readonly shootDay?: string | null;
}

/** Known task snapshot fields; all are optional because old rows are additive. */
export interface TaskData {
  readonly id?: string | null;
  readonly projectId?: string | null;
  readonly projectSettingsSnapshot?: ProjectSettings | null;
  readonly status?: string;
  readonly filename?: string | null;
  readonly fileType?: string | null;
  readonly fileSize?: number;
  readonly pageCount?: number;
  readonly imageDataGroups?: readonly (readonly string[])[] | null;
  readonly resolveCsvBase64?: string | null;
  readonly resolveCsvFilename?: string | null;
  readonly resolveCsvTable?: ResolveCsvTable | null;
  readonly resolveCsvEdits?: ResolveCsvEdits | null;
  readonly slateMetadata?: readonly PersistedSlateMetadata[] | null;
  readonly slateWarnings?: readonly string[] | null;
  readonly missingMetadataKeys?: readonly string[] | null;
  readonly slateDirectoryName?: string | null;
  readonly scenarioId?: string | null;
  readonly scenarioMatch?: string | null;
  readonly scenarioFingerprint?: string | null;
  readonly provider?: string | null;
  readonly model?: string | null;
  readonly customPrompt?: string | null;
  readonly accuracyMode?: "high" | "standard" | null;
  readonly result?: PersistedRecognitionSheet | null;
  readonly usage?: TokenUsage | null;
  readonly durationMs?: number;
  readonly ocrSummary?: OcrSummary | null;
  readonly diagnosticSessionId?: string | null;
  readonly editedRecords?: readonly PersistedRecognitionRecord[] | null;
  readonly createdAt?: string | null;
  readonly updatedAt?: string | null;
}

/** The legacy adapter currently saves full tasks or id-based sparse edits. */
export type TaskSaveData = TaskData & { readonly id?: string | null };

export interface ScenarioPageShape {
  readonly pageNumber: number;
  readonly views: readonly {
    readonly width: number;
    readonly height: number;
    readonly orientation: string;
    readonly blockCount: number;
  }[];
}

export interface ScenarioLayout {
  readonly pages: readonly ScenarioPageShape[];
  readonly headerTokens: readonly string[];
  readonly cameraGroups: readonly string[];
  readonly columnBands: readonly number[];
  readonly rowBands: readonly number[];
  readonly blockCount: number;
}

export interface ScenarioFieldProfile {
  readonly label: string;
  readonly aliases: readonly string[];
  readonly region: readonly number[] | null;
  readonly inherit: boolean;
  readonly required: boolean;
}

export interface ScenarioFields {
  readonly cardNumber: ScenarioFieldProfile;
  readonly videoCode: ScenarioFieldProfile;
  readonly scene: ScenarioFieldProfile;
  readonly shot: ScenarioFieldProfile;
  readonly take: ScenarioFieldProfile;
  readonly takeStatus: ScenarioFieldProfile;
  readonly description: ScenarioFieldProfile;
  readonly comments: ScenarioFieldProfile;
  readonly shotSize: ScenarioFieldProfile;
  readonly cameraPosition: ScenarioFieldProfile;
}

export interface ScenarioProfile {
  readonly schemaVersion: number;
  readonly fingerprintVersion: number;
  readonly fingerprint: string;
  readonly label: string;
  readonly layout: ScenarioLayout;
  readonly fields: ScenarioFields;
  readonly recognition: {
    readonly headerTokens: readonly string[];
    readonly promptHints: readonly string[];
  };
  readonly output: {
    readonly resolve: {
      readonly fieldFormats: ResolveFieldFormats;
      readonly comments: ResolveComments;
    };
  };
}

export interface ScenarioData extends ScenarioProfile {
  readonly id: string;
  readonly sampleCount: number;
  readonly createdAt: string;
  readonly updatedAt: string;
  readonly lastUsedAt: string;
}

export interface ScenarioSummary {
  readonly id: string;
  readonly label: string;
  readonly fingerprint: string;
  readonly fingerprintVersion: number;
  readonly schemaVersion: number;
  readonly sampleCount: number;
  readonly fieldCount: number;
  readonly createdAt: string;
  readonly updatedAt: string;
  readonly lastUsedAt: string;
}

export interface FileSaveResult {
  readonly saved: boolean;
  readonly filePath?: string;
}

export interface DirectorySelection {
  readonly dirPath: string;
  readonly dirName: string;
}

export interface ScanStats {
  readonly visitedDirectories: number;
  readonly prunedDirectories: number;
  readonly skippedDeepDirectories: number;
  readonly discoveredSlateFiles: number;
  readonly readSlateFiles: number;
  readonly learnedStructures: number;
}

export interface ScanResult {
  readonly metadata: readonly ScannedSlateMetadata[];
  readonly warnings: readonly string[];
  readonly stats: ScanStats;
  readonly missingKeys: readonly string[];
}

export interface ModelDiscoveryResult {
  readonly provider: string;
  readonly source: "api" | "static-fallback";
  readonly refreshedAt: string;
  readonly availableModelCount: number | null;
  readonly visionModelCount: number;
  readonly fixedModelCount: number;
  readonly warning?: string;
  readonly models: readonly ModelData[];
}

export interface SlateSyncApi {
  readonly app: {
    getConfig(): Promise<Result<ConfigData>>;
  };
  readonly projects: {
    list(): Promise<Result<ProjectSummary[]>>;
    getLibraryInfo(): Promise<Result<LibraryInfo | null>>;
    importLibrary(): Promise<Result<LibraryImportResult>>;
    exportLibrary(): Promise<Result<LibraryExportResult>>;
    changeLibraryLocation(): Promise<Result<LibraryLocationResult>>;
    create(request: ProjectRequest): Promise<Result<ProjectData>>;
    load(request: ProjectIdRequest): Promise<Result<ProjectData>>;
    update(request: ProjectRequest): Promise<Result<ProjectData>>;
    archive(request: ProjectIdRequest): Promise<Result<ProjectData>>;
    restore(request: ProjectIdRequest): Promise<Result<ProjectData>>;
    delete(request: ProjectIdRequest): Promise<Result<{ readonly deleted: string }>>;
    listScenarios(request: ProjectScopedRequest): Promise<Result<ScenarioSummary[]>>;
    loadScenario(request: ScenarioIdRequest): Promise<Result<ScenarioData>>;
    importScenario(request: ScenarioImportRequest): Promise<Result<ScenarioData>>;
  };
  readonly tasks: {
    list(request: ProjectScopedRequest): Promise<Result<TaskListItem[]>>;
    load(request: ProjectTaskIdRequest): Promise<Result<TaskData>>;
    save(request: ProjectTaskRequest): Promise<Result<string>>;
    delete(request: ProjectTaskIdRequest): Promise<Result<{ readonly deleted: string }>>;
  };
  readonly recognition: {
    getModels(request: ModelsRequest): Promise<Result<ModelDiscoveryResult>>;
    run(request: RecognitionRequest): Promise<Result<RecognitionData>>;
    cancel(request: ProjectScopedRequest): Promise<Result<{ readonly canceled: boolean }>>;
    onProgress(listener: (event: ProgressData) => void): () => void;
  };
  readonly files: {
    save(request: SaveFileRequest): Promise<Result<FileSaveResult>>;
    selectDirectory(): Promise<Result<DirectorySelection | null>>;
    scanSlateDirectory(request: ScanSlateDirectoryRequest): Promise<Result<ScanResult>>;
  };
  readonly settings: {
    saveProviderKey(request: ProviderKeyRequest): Promise<Result<{
      readonly provider: string;
      readonly configured: boolean;
    }>>;
    getOcrSettings(): Promise<Result<OcrSettings>>;
    saveOcrSettings(request: OcrSettingsRequest): Promise<Result<OcrSettings>>;
    checkOcr(request: OcrCheckRequest): Promise<Result<OcrCheckResult>>;
  };
}

declare global {
  interface Window {
    slateSync: SlateSyncApi;
  }
}

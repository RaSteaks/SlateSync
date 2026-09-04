import Foundation

public enum TakeStatus: String, Codable, Hashable, Sendable {
    case passed = "过"
    case hold = "保"
    case rejected = "废条"
}

public enum RecognitionConfidence: String, Codable, Hashable, Sendable {
    case high
    case medium
    case low
}

public struct SlateCsvRecord: Codable, Hashable, Sendable {
    public let fileName: String?
    public let materialKey: String?
    public let cardNumber: String?
    public let videoCode: String?
    public let scene: String?
    public let shot: String?
    public let take: String?
    public let comments: TakeStatus?
    public let cameraFps: String?
    public let shootDay: String?

    public init(
        fileName: String? = nil,
        materialKey: String? = nil,
        cardNumber: String? = nil,
        videoCode: String? = nil,
        scene: String? = nil,
        shot: String? = nil,
        take: String? = nil,
        comments: TakeStatus? = nil,
        cameraFps: String? = nil,
        shootDay: String? = nil
    ) {
        self.fileName = fileName
        self.materialKey = materialKey
        self.cardNumber = cardNumber
        self.videoCode = videoCode
        self.scene = scene
        self.shot = shot
        self.take = take
        self.comments = comments
        self.cameraFps = cameraFps
        self.shootDay = shootDay
    }
}

public struct RecognitionRequest: Codable, Hashable, Sendable {
    public let taskId: String?
    public let provider: String?
    public let model: String?
    public let imageDataUrl: String?
    public let imageDataUrls: [String]?
    public let imageDataGroups: [[String]]?
    public let pageCount: Int?
    public let filename: String?
    public let accuracyMode: ProjectSettings.AccuracyMode?
    public let customPrompt: String?
    public let scenarioId: String?
    public let projectId: String?
    public let slateCsvRecords: [SlateCsvRecord]?

    public init(
        taskId: String? = nil,
        provider: String? = nil,
        model: String? = nil,
        imageDataUrl: String? = nil,
        imageDataUrls: [String]? = nil,
        imageDataGroups: [[String]]? = nil,
        pageCount: Int? = nil,
        filename: String? = nil,
        accuracyMode: ProjectSettings.AccuracyMode? = nil,
        customPrompt: String? = nil,
        scenarioId: String? = nil,
        projectId: String? = nil,
        slateCsvRecords: [SlateCsvRecord]? = nil
    ) {
        self.taskId = taskId
        self.provider = provider
        self.model = model
        self.imageDataUrl = imageDataUrl
        self.imageDataUrls = imageDataUrls
        self.imageDataGroups = imageDataGroups
        self.pageCount = pageCount
        self.filename = filename
        self.accuracyMode = accuracyMode
        self.customPrompt = customPrompt
        self.scenarioId = scenarioId
        self.projectId = projectId
        self.slateCsvRecords = slateCsvRecords
    }
}

public struct RecognitionRecord: Codable, Hashable, Sendable {
    public let id: String
    public let sourcePage: Int?
    public let cardNumber: String?
    public let videoCode: String?
    public let scene: String?
    public let shot: String?
    public let take: String?
    public let takeStatus: TakeStatus?
    public let description: String?
    public let comments: String?
    public let shotSize: String?
    public let cameraPosition: String?
    public let confidence: RecognitionConfidence
    public let reviewRequiredFields: [String]?

    public init(
        id: String,
        sourcePage: Int? = nil,
        cardNumber: String? = nil,
        videoCode: String? = nil,
        scene: String? = nil,
        shot: String? = nil,
        take: String? = nil,
        takeStatus: TakeStatus? = nil,
        description: String? = nil,
        comments: String? = nil,
        shotSize: String? = nil,
        cameraPosition: String? = nil,
        confidence: RecognitionConfidence,
        reviewRequiredFields: [String]? = nil
    ) {
        self.id = id
        self.sourcePage = sourcePage
        self.cardNumber = cardNumber
        self.videoCode = videoCode
        self.scene = scene
        self.shot = shot
        self.take = take
        self.takeStatus = takeStatus
        self.description = description
        self.comments = comments
        self.shotSize = shotSize
        self.cameraPosition = cameraPosition
        self.confidence = confidence
        self.reviewRequiredFields = reviewRequiredFields
    }
}

public struct PersistedRecognitionRecord: Codable, Hashable, Sendable {
    public let id: String?
    public let sourcePage: Int?
    public let cardNumber: String?
    public let videoCode: String?
    public let scene: String?
    public let shot: String?
    public let take: String?
    public let takeStatus: TakeStatus?
    public let description: String?
    public let comments: String?
    public let shotSize: String?
    public let cameraPosition: String?
    public let confidence: RecognitionConfidence?
    public let reviewRequiredFields: [String]?

    public init(
        id: String? = nil,
        sourcePage: Int? = nil,
        cardNumber: String? = nil,
        videoCode: String? = nil,
        scene: String? = nil,
        shot: String? = nil,
        take: String? = nil,
        takeStatus: TakeStatus? = nil,
        description: String? = nil,
        comments: String? = nil,
        shotSize: String? = nil,
        cameraPosition: String? = nil,
        confidence: RecognitionConfidence? = nil,
        reviewRequiredFields: [String]? = nil
    ) {
        self.id = id
        self.sourcePage = sourcePage
        self.cardNumber = cardNumber
        self.videoCode = videoCode
        self.scene = scene
        self.shot = shot
        self.take = take
        self.takeStatus = takeStatus
        self.description = description
        self.comments = comments
        self.shotSize = shotSize
        self.cameraPosition = cameraPosition
        self.confidence = confidence
        self.reviewRequiredFields = reviewRequiredFields
    }
}

public struct RecognitionSheet: Codable, Hashable, Sendable {
    public let sheetTitle: String?
    public let records: [RecognitionRecord]
    public let warnings: [String]

    public init(sheetTitle: String? = nil, records: [RecognitionRecord], warnings: [String] = []) {
        self.sheetTitle = sheetTitle
        self.records = records
        self.warnings = warnings
    }
}

public struct PersistedRecognitionSheet: Codable, Hashable, Sendable {
    public let sheetTitle: String?
    public let records: [PersistedRecognitionRecord]
    public let warnings: [String]

    public init(sheetTitle: String? = nil, records: [PersistedRecognitionRecord], warnings: [String] = []) {
        self.sheetTitle = sheetTitle
        self.records = records
        self.warnings = warnings
    }

    private enum CodingKeys: String, CodingKey {
        case sheetTitle
        case records
        case warnings
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        sheetTitle = try values.decodeIfPresent(String.self, forKey: .sheetTitle)
        records = try values.decode([PersistedRecognitionRecord].self, forKey: .records)
        // Frozen Electron task snapshots predate this optional field. The
        // native decoder must supply the same empty-list default instead of
        // turning an otherwise readable task into a key-not-found failure.
        warnings = try values.decodeIfPresent([String].self, forKey: .warnings) ?? []
    }

    public func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encodeIfPresent(sheetTitle, forKey: .sheetTitle)
        try values.encode(records, forKey: .records)
        try values.encode(warnings, forKey: .warnings)
    }
}

/// Both OpenAI naming generations are accepted; the encoder emits the stable
/// snake_case keys used by the older diagnostic snapshots.
public struct TokenUsage: Codable, Hashable, Sendable {
    public let promptTokens: Int?
    public let completionTokens: Int?
    public let totalTokens: Int?
    public let inputTokens: Int?
    public let outputTokens: Int?

    public init(
        promptTokens: Int? = nil,
        completionTokens: Int? = nil,
        totalTokens: Int? = nil,
        inputTokens: Int? = nil,
        outputTokens: Int? = nil
    ) {
        self.promptTokens = promptTokens
        self.completionTokens = completionTokens
        self.totalTokens = totalTokens
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
    }

    private enum CodingKeys: String, CodingKey {
        case promptTokensSnake = "prompt_tokens"
        case completionTokensSnake = "completion_tokens"
        case totalTokensSnake = "total_tokens"
        case inputTokensSnake = "input_tokens"
        case outputTokensSnake = "output_tokens"
        case promptTokens
        case completionTokens
        case totalTokens
        case inputTokens
        case outputTokens
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        if let value = try values.decodeIfPresent(Int.self, forKey: .promptTokensSnake) {
            promptTokens = value
        } else {
            promptTokens = try values.decodeIfPresent(Int.self, forKey: .promptTokens)
        }
        if let value = try values.decodeIfPresent(Int.self, forKey: .completionTokensSnake) {
            completionTokens = value
        } else {
            completionTokens = try values.decodeIfPresent(Int.self, forKey: .completionTokens)
        }
        if let value = try values.decodeIfPresent(Int.self, forKey: .totalTokensSnake) {
            totalTokens = value
        } else {
            totalTokens = try values.decodeIfPresent(Int.self, forKey: .totalTokens)
        }
        if let value = try values.decodeIfPresent(Int.self, forKey: .inputTokensSnake) {
            inputTokens = value
        } else {
            inputTokens = try values.decodeIfPresent(Int.self, forKey: .inputTokens)
        }
        if let value = try values.decodeIfPresent(Int.self, forKey: .outputTokensSnake) {
            outputTokens = value
        } else {
            outputTokens = try values.decodeIfPresent(Int.self, forKey: .outputTokens)
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encodeIfPresent(promptTokens, forKey: .promptTokensSnake)
        try values.encodeIfPresent(completionTokens, forKey: .completionTokensSnake)
        try values.encodeIfPresent(totalTokens, forKey: .totalTokensSnake)
        try values.encodeIfPresent(inputTokens, forKey: .inputTokensSnake)
        try values.encodeIfPresent(outputTokens, forKey: .outputTokensSnake)
    }
}

public struct OcrSummary: Codable, Hashable, Sendable {
    public let enabled: Bool
    public let available: Bool
    public let used: Bool
    public let cacheHit: Bool
    public let engine: String
    public let model: String?
    public let profile: String?
    public let profileLabel: String?
    public let detectionModel: String?
    public let recognitionModel: String?
    public let recognitionBatchSize: Int?
    public let device: String?
    public let pageCount: Int
    public let viewCount: Int
    public let blockCount: Int
    public let lowConfidenceBlockCount: Int
    public let durationMs: Int
    public let warning: String?

    public init(
        enabled: Bool,
        available: Bool,
        used: Bool,
        cacheHit: Bool,
        engine: String,
        model: String? = nil,
        profile: String? = nil,
        profileLabel: String? = nil,
        detectionModel: String? = nil,
        recognitionModel: String? = nil,
        recognitionBatchSize: Int? = nil,
        device: String? = nil,
        pageCount: Int,
        viewCount: Int,
        blockCount: Int,
        lowConfidenceBlockCount: Int,
        durationMs: Int,
        warning: String? = nil
    ) {
        self.enabled = enabled
        self.available = available
        self.used = used
        self.cacheHit = cacheHit
        self.engine = engine
        self.model = model
        self.profile = profile
        self.profileLabel = profileLabel
        self.detectionModel = detectionModel
        self.recognitionModel = recognitionModel
        self.recognitionBatchSize = recognitionBatchSize
        self.device = device
        self.pageCount = pageCount
        self.viewCount = viewCount
        self.blockCount = blockCount
        self.lowConfidenceBlockCount = lowConfidenceBlockCount
        self.durationMs = durationMs
        self.warning = warning
    }
}

public struct ScenarioSelection: Codable, Hashable, Sendable {
    public let id: String?
    public let match: String
    public let score: Double
    public let fingerprint: String?
    public let warning: String?

    public init(id: String? = nil, match: String, score: Double, fingerprint: String? = nil, warning: String? = nil) {
        self.id = id
        self.match = match
        self.score = score
        self.fingerprint = fingerprint
        self.warning = warning
    }
}

public struct RecognitionData: Codable, Hashable, Sendable {
    public let provider: String
    public let model: String
    public let inputMode: RecognitionInputMode
    public let durationMs: Int
    public let pageCount: Int
    public let accuracyMode: ProjectSettings.AccuracyMode
    public let usage: TokenUsage?
    public let ocr: OcrSummary
    public let scenario: ScenarioSelection?
    public let result: RecognitionSheet
    public let projectId: String?
    public let projectSettingsSnapshot: ProjectSettings?
    public let lastRecognitionDefaults: RecognitionDefaults?
    public let diagnosticSessionId: String?
    public let taskId: String?

    public init(
        provider: String,
        model: String,
        inputMode: RecognitionInputMode = .images,
        durationMs: Int,
        pageCount: Int,
        accuracyMode: ProjectSettings.AccuracyMode,
        usage: TokenUsage? = nil,
        ocr: OcrSummary,
        scenario: ScenarioSelection? = nil,
        result: RecognitionSheet,
        projectId: String? = nil,
        projectSettingsSnapshot: ProjectSettings? = nil,
        lastRecognitionDefaults: RecognitionDefaults? = nil,
        diagnosticSessionId: String? = nil,
        taskId: String? = nil
    ) {
        self.provider = provider
        self.model = model
        self.inputMode = inputMode
        self.durationMs = durationMs
        self.pageCount = pageCount
        self.accuracyMode = accuracyMode
        self.usage = usage
        self.ocr = ocr
        self.scenario = scenario
        self.result = result
        self.projectId = projectId
        self.projectSettingsSnapshot = projectSettingsSnapshot
        self.lastRecognitionDefaults = lastRecognitionDefaults
        self.diagnosticSessionId = diagnosticSessionId
        self.taskId = taskId
    }
}

public enum RecognitionInputMode: String, Codable, Hashable, Sendable {
    case images
}

public enum ProgressEventType: String, Codable, Hashable, Sendable {
    case progress
}

public struct ProgressData: Codable, Hashable, Sendable {
    public let type: ProgressEventType?
    public let phase: String?
    public let percent: Double?
    public let message: String?
    public let warning: String?
    public let pageNumber: Int?
    public let completed: Int?
    public let total: Int?
    public let completedViews: Int?
    public let totalViews: Int?
    public let viewIndex: Int?
    public let cacheHit: Bool?

    public init(
        type: ProgressEventType? = nil,
        phase: String? = nil,
        percent: Double? = nil,
        message: String? = nil,
        warning: String? = nil,
        pageNumber: Int? = nil,
        completed: Int? = nil,
        total: Int? = nil,
        completedViews: Int? = nil,
        totalViews: Int? = nil,
        viewIndex: Int? = nil,
        cacheHit: Bool? = nil
    ) {
        self.type = type
        self.phase = phase
        self.percent = percent
        self.message = message
        self.warning = warning
        self.pageNumber = pageNumber
        self.completed = completed
        self.total = total
        self.completedViews = completedViews
        self.totalViews = totalViews
        self.viewIndex = viewIndex
        self.cacheHit = cacheHit
    }
}

public enum LogLevel: String, Codable, Hashable, Sendable {
    case info
    case warn
    case error
}

public struct LogEntry: Codable, Hashable, Sendable {
    public let timestamp: String
    public let level: LogLevel
    public let category: String
    public let message: String
    public let phase: String?
    public let percent: Double?
    public let completed: Int?
    public let total: Int?
    public let pageNumber: Int?

    public init(
        timestamp: String,
        level: LogLevel,
        category: String,
        message: String,
        phase: String? = nil,
        percent: Double? = nil,
        completed: Int? = nil,
        total: Int? = nil,
        pageNumber: Int? = nil
    ) {
        self.timestamp = timestamp
        self.level = level
        self.category = category
        self.message = message
        self.phase = phase
        self.percent = percent
        self.completed = completed
        self.total = total
        self.pageNumber = pageNumber
    }
}

public struct LogsReadRequest: Codable, Hashable, Sendable {
    public let limit: Int?
    public let level: LogLevel?
    public let category: String?

    public init(limit: Int? = nil, level: LogLevel? = nil, category: String? = nil) {
        self.limit = limit
        self.level = level
        self.category = category
    }
}

public struct LogsReadResult: Codable, Hashable, Sendable {
    public let entries: [LogEntry]
    public let hasMore: Bool

    public init(entries: [LogEntry], hasMore: Bool) {
        self.entries = entries
        self.hasMore = hasMore
    }
}

public struct LogsOpenDirectoryResult: Codable, Hashable, Sendable {
    public let opened: Bool

    public init(opened: Bool) {
        self.opened = opened
    }
}

public struct TaskListItem: Codable, Hashable, Sendable {
    public let id: String?
    public let filename: String?
    public let provider: String?
    public let model: String?
    public let pageCount: Int?
    public let scenarioId: String?
    public let recordCount: Int
    public let status: String
    public let createdAt: String?
    public let updatedAt: String?

    public init(
        id: String? = nil,
        filename: String? = nil,
        provider: String? = nil,
        model: String? = nil,
        pageCount: Int? = nil,
        scenarioId: String? = nil,
        recordCount: Int,
        status: String,
        createdAt: String? = nil,
        updatedAt: String? = nil
    ) {
        self.id = id
        self.filename = filename
        self.provider = provider
        self.model = model
        self.pageCount = pageCount
        self.scenarioId = scenarioId
        self.recordCount = recordCount
        self.status = status
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

public typealias ResolveCsvEncoding = ResolveCSVEncoding
public typealias ResolveCsvFormat = ResolveCSVFormat
public typealias ResolveCsvTable = ResolveCSVTable
public typealias ResolveCsvEdits = [String: String]

public struct ScannedSlateMetadata: Codable, Hashable, Sendable {
    public let sourceName: String
    public let clipName: String
    public let materialKey: String
    public let sensorFps: String
    public let shootDay: String

    public init(sourceName: String, clipName: String, materialKey: String, sensorFps: String, shootDay: String) {
        self.sourceName = sourceName
        self.clipName = clipName
        self.materialKey = materialKey
        self.sensorFps = sensorFps
        self.shootDay = shootDay
    }
}

public struct PersistedSlateMetadata: Codable, Hashable, Sendable {
    public let sourceName: String?
    public let clipName: String?
    public let materialKey: String
    public let sensorFps: String?
    public let shootDay: String?

    public init(materialKey: String, sourceName: String? = nil, clipName: String? = nil, sensorFps: String? = nil, shootDay: String? = nil) {
        self.sourceName = sourceName
        self.clipName = clipName
        self.materialKey = materialKey
        self.sensorFps = sensorFps
        self.shootDay = shootDay
    }
}

public struct TaskData: Codable, Hashable, Sendable {
    public let id: String?
    public let projectId: String?
    public let projectSettingsSnapshot: ProjectSettings?
    public let status: String?
    public let filename: String?
    public let fileType: String?
    public let fileSize: Int?
    public let pageCount: Int?
    public let imageDataGroups: [[String]]?
    public let resolveCsvBase64: String?
    public let resolveCsvFilename: String?
    public let resolveCsvTable: ResolveCSVTable?
    public let resolveCsvEdits: [String: String]?
    public let slateMetadata: [PersistedSlateMetadata]?
    public let slateWarnings: [String]?
    public let missingMetadataKeys: [String]?
    public let slateDirectoryName: String?
    public let scenarioId: String?
    public let scenarioMatch: String?
    public let scenarioFingerprint: String?
    public let provider: String?
    public let model: String?
    public let customPrompt: String?
    public let accuracyMode: ProjectSettings.AccuracyMode?
    public let result: PersistedRecognitionSheet?
    public let usage: TokenUsage?
    public let durationMs: Int?
    public let ocrSummary: OcrSummary?
    public let diagnosticSessionId: String?
    public let editedRecords: [PersistedRecognitionRecord]?
    public let createdAt: String?
    public let updatedAt: String?

    public init(
        id: String? = nil,
        projectId: String? = nil,
        projectSettingsSnapshot: ProjectSettings? = nil,
        status: String? = nil,
        filename: String? = nil,
        fileType: String? = nil,
        fileSize: Int? = nil,
        pageCount: Int? = nil,
        imageDataGroups: [[String]]? = nil,
        resolveCsvBase64: String? = nil,
        resolveCsvFilename: String? = nil,
        resolveCsvTable: ResolveCSVTable? = nil,
        resolveCsvEdits: [String: String]? = nil,
        slateMetadata: [PersistedSlateMetadata]? = nil,
        slateWarnings: [String]? = nil,
        missingMetadataKeys: [String]? = nil,
        slateDirectoryName: String? = nil,
        scenarioId: String? = nil,
        scenarioMatch: String? = nil,
        scenarioFingerprint: String? = nil,
        provider: String? = nil,
        model: String? = nil,
        customPrompt: String? = nil,
        accuracyMode: ProjectSettings.AccuracyMode? = nil,
        result: PersistedRecognitionSheet? = nil,
        usage: TokenUsage? = nil,
        durationMs: Int? = nil,
        ocrSummary: OcrSummary? = nil,
        diagnosticSessionId: String? = nil,
        editedRecords: [PersistedRecognitionRecord]? = nil,
        createdAt: String? = nil,
        updatedAt: String? = nil
    ) {
        self.id = id
        self.projectId = projectId
        self.projectSettingsSnapshot = projectSettingsSnapshot
        self.status = status
        self.filename = filename
        self.fileType = fileType
        self.fileSize = fileSize
        self.pageCount = pageCount
        self.imageDataGroups = imageDataGroups
        self.resolveCsvBase64 = resolveCsvBase64
        self.resolveCsvFilename = resolveCsvFilename
        self.resolveCsvTable = resolveCsvTable
        self.resolveCsvEdits = resolveCsvEdits
        self.slateMetadata = slateMetadata
        self.slateWarnings = slateWarnings
        self.missingMetadataKeys = missingMetadataKeys
        self.slateDirectoryName = slateDirectoryName
        self.scenarioId = scenarioId
        self.scenarioMatch = scenarioMatch
        self.scenarioFingerprint = scenarioFingerprint
        self.provider = provider
        self.model = model
        self.customPrompt = customPrompt
        self.accuracyMode = accuracyMode
        self.result = result
        self.usage = usage
        self.durationMs = durationMs
        self.ocrSummary = ocrSummary
        self.diagnosticSessionId = diagnosticSessionId
        self.editedRecords = editedRecords
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

public typealias TaskSaveData = TaskData

public struct ScenarioViewShape: Codable, Hashable, Sendable {
    public let width: Int
    public let height: Int
    public let orientation: String
    public let blockCount: Int

    public init(width: Int, height: Int, orientation: String, blockCount: Int) {
        self.width = width
        self.height = height
        self.orientation = orientation
        self.blockCount = blockCount
    }
}

public struct ScenarioPageShape: Codable, Hashable, Sendable {
    public let pageNumber: Int
    public let views: [ScenarioViewShape]

    public init(pageNumber: Int, views: [ScenarioViewShape]) {
        self.pageNumber = pageNumber
        self.views = views
    }
}

public struct ScenarioLayout: Codable, Hashable, Sendable {
    public let pages: [ScenarioPageShape]
    public let headerTokens: [String]
    public let cameraGroups: [String]
    public let columnBands: [Double]
    public let rowBands: [Double]
    public let blockCount: Int

    public init(pages: [ScenarioPageShape], headerTokens: [String], cameraGroups: [String], columnBands: [Double], rowBands: [Double], blockCount: Int) {
        self.pages = pages
        self.headerTokens = headerTokens
        self.cameraGroups = cameraGroups
        self.columnBands = columnBands
        self.rowBands = rowBands
        self.blockCount = blockCount
    }
}

public struct ScenarioFieldProfile: Codable, Hashable, Sendable {
    public let label: String
    public let aliases: [String]
    public let region: [Double]?
    public let inherit: Bool
    public let required: Bool

    public init(label: String, aliases: [String], region: [Double]? = nil, inherit: Bool, required: Bool) {
        self.label = label
        self.aliases = aliases
        self.region = region
        self.inherit = inherit
        self.required = required
    }
}

public struct ScenarioFields: Codable, Hashable, Sendable {
    public let cardNumber: ScenarioFieldProfile
    public let videoCode: ScenarioFieldProfile
    public let scene: ScenarioFieldProfile
    public let shot: ScenarioFieldProfile
    public let take: ScenarioFieldProfile
    public let takeStatus: ScenarioFieldProfile
    public let description: ScenarioFieldProfile
    public let comments: ScenarioFieldProfile
    public let shotSize: ScenarioFieldProfile
    public let cameraPosition: ScenarioFieldProfile

    public init(cardNumber: ScenarioFieldProfile, videoCode: ScenarioFieldProfile, scene: ScenarioFieldProfile, shot: ScenarioFieldProfile, take: ScenarioFieldProfile, takeStatus: ScenarioFieldProfile, description: ScenarioFieldProfile, comments: ScenarioFieldProfile, shotSize: ScenarioFieldProfile, cameraPosition: ScenarioFieldProfile) {
        self.cardNumber = cardNumber
        self.videoCode = videoCode
        self.scene = scene
        self.shot = shot
        self.take = take
        self.takeStatus = takeStatus
        self.description = description
        self.comments = comments
        self.shotSize = shotSize
        self.cameraPosition = cameraPosition
    }
}

public struct ScenarioRecognitionConfig: Codable, Hashable, Sendable {
    public let headerTokens: [String]
    public let promptHints: [String]

    public init(headerTokens: [String], promptHints: [String]) {
        self.headerTokens = headerTokens
        self.promptHints = promptHints
    }
}

public struct ScenarioOutputConfig: Codable, Hashable, Sendable {
    public let resolve: ProjectSettings.ResolveSettings

    public init(resolve: ProjectSettings.ResolveSettings) {
        self.resolve = resolve
    }
}

public struct ScenarioProfile: Codable, Hashable, Sendable {
    public let schemaVersion: Int
    public let fingerprintVersion: Int
    public let fingerprint: String
    public let label: String
    public let layout: ScenarioLayout
    public let fields: ScenarioFields
    public let recognition: ScenarioRecognitionConfig
    public let output: ScenarioOutputConfig

    public init(schemaVersion: Int, fingerprintVersion: Int, fingerprint: String, label: String, layout: ScenarioLayout, fields: ScenarioFields, recognition: ScenarioRecognitionConfig, output: ScenarioOutputConfig) {
        self.schemaVersion = schemaVersion
        self.fingerprintVersion = fingerprintVersion
        self.fingerprint = fingerprint
        self.label = label
        self.layout = layout
        self.fields = fields
        self.recognition = recognition
        self.output = output
    }
}

public struct ScenarioData: Codable, Hashable, Sendable {
    public let id: String
    public let schemaVersion: Int
    public let fingerprintVersion: Int
    public let fingerprint: String
    public let label: String
    public let layout: ScenarioLayout
    public let fields: ScenarioFields
    public let recognition: ScenarioRecognitionConfig
    public let output: ScenarioOutputConfig
    public let sampleCount: Int
    public let createdAt: String
    public let updatedAt: String
    public let lastUsedAt: String

    public init(id: String, profile: ScenarioProfile, sampleCount: Int, createdAt: String, updatedAt: String, lastUsedAt: String) {
        self.id = id
        schemaVersion = profile.schemaVersion
        fingerprintVersion = profile.fingerprintVersion
        fingerprint = profile.fingerprint
        label = profile.label
        layout = profile.layout
        fields = profile.fields
        recognition = profile.recognition
        output = profile.output
        self.sampleCount = sampleCount
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.lastUsedAt = lastUsedAt
    }
}

public struct ScenarioSummary: Codable, Hashable, Sendable {
    public let id: String
    public let label: String
    public let fingerprint: String
    public let fingerprintVersion: Int
    public let schemaVersion: Int
    public let sampleCount: Int
    public let fieldCount: Int
    public let createdAt: String
    public let updatedAt: String
    public let lastUsedAt: String

    public init(id: String, label: String, fingerprint: String, fingerprintVersion: Int, schemaVersion: Int, sampleCount: Int, fieldCount: Int, createdAt: String, updatedAt: String, lastUsedAt: String) {
        self.id = id
        self.label = label
        self.fingerprint = fingerprint
        self.fingerprintVersion = fingerprintVersion
        self.schemaVersion = schemaVersion
        self.sampleCount = sampleCount
        self.fieldCount = fieldCount
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.lastUsedAt = lastUsedAt
    }
}

public struct FileSaveResult: Codable, Hashable, Sendable {
    public let saved: Bool
    public let filePath: String?

    public init(saved: Bool, filePath: String? = nil) {
        self.saved = saved
        self.filePath = filePath
    }
}

public struct DirectorySelection: Codable, Hashable, Sendable {
    public let dirPath: String
    public let dirName: String

    public init(dirPath: String, dirName: String) {
        self.dirPath = dirPath
        self.dirName = dirName
    }
}

public struct ScanStats: Codable, Hashable, Sendable {
    public let visitedDirectories: Int
    public let prunedDirectories: Int
    public let skippedDeepDirectories: Int
    public let discoveredSlateFiles: Int
    public let readSlateFiles: Int
    public let learnedStructures: Int

    public init(visitedDirectories: Int, prunedDirectories: Int, skippedDeepDirectories: Int, discoveredSlateFiles: Int, readSlateFiles: Int, learnedStructures: Int) {
        self.visitedDirectories = visitedDirectories
        self.prunedDirectories = prunedDirectories
        self.skippedDeepDirectories = skippedDeepDirectories
        self.discoveredSlateFiles = discoveredSlateFiles
        self.readSlateFiles = readSlateFiles
        self.learnedStructures = learnedStructures
    }
}

public struct ScanResult: Codable, Hashable, Sendable {
    public let metadata: [ScannedSlateMetadata]
    public let warnings: [String]
    public let stats: ScanStats
    public let missingKeys: [String]

    public init(metadata: [ScannedSlateMetadata], warnings: [String], stats: ScanStats, missingKeys: [String]) {
        self.metadata = metadata
        self.warnings = warnings
        self.stats = stats
        self.missingKeys = missingKeys
    }
}

public enum ModelDiscoverySource: String, Codable, Hashable, Sendable {
    case api
    case staticFallback = "static-fallback"
}

public struct ModelDiscoveryResult: Codable, Hashable, Sendable {
    public let provider: String
    public let source: ModelDiscoverySource
    public let refreshedAt: String
    public let availableModelCount: Int?
    public let visionModelCount: Int
    public let fixedModelCount: Int
    public let pendingModelCount: Int?
    public let modelsEndpointAvailable: Bool?
    public let warning: String?
    public let models: [ModelData]
    public let pendingModels: [ModelData]?
    public let unsupportedModelCount: Int?
    public let unsupportedModels: [UnsupportedModel]?
    public let failedModelCount: Int?
    public let failedModels: [ModelData]?
    public let statusCounts: ModelStatusCounts?

    public struct UnsupportedModel: Codable, Hashable, Sendable {
        public let id: String
        public let reason: String
        public let capabilityStatus: ModelCapabilityStatus?

        public init(id: String, reason: String, capabilityStatus: ModelCapabilityStatus? = nil) {
            self.id = id
            self.reason = reason
            self.capabilityStatus = capabilityStatus
        }
    }

    public struct ModelStatusCounts: Codable, Hashable, Sendable {
        public let usable: Int
        public let pending: Int
        public let unsupported: Int
        public let failed: Int

        public init(usable: Int, pending: Int, unsupported: Int, failed: Int) {
            self.usable = usable
            self.pending = pending
            self.unsupported = unsupported
            self.failed = failed
        }
    }

    public init(provider: String, source: ModelDiscoverySource, refreshedAt: String, availableModelCount: Int?, visionModelCount: Int, fixedModelCount: Int, models: [ModelData], pendingModelCount: Int? = nil, modelsEndpointAvailable: Bool? = nil, warning: String? = nil, pendingModels: [ModelData]? = nil, unsupportedModelCount: Int? = nil, unsupportedModels: [UnsupportedModel]? = nil, failedModelCount: Int? = nil, failedModels: [ModelData]? = nil, statusCounts: ModelStatusCounts? = nil) {
        self.provider = provider
        self.source = source
        self.refreshedAt = refreshedAt
        self.availableModelCount = availableModelCount
        self.visionModelCount = visionModelCount
        self.fixedModelCount = fixedModelCount
        self.pendingModelCount = pendingModelCount
        self.modelsEndpointAvailable = modelsEndpointAvailable
        self.warning = warning
        self.models = models
        self.pendingModels = pendingModels
        self.unsupportedModelCount = unsupportedModelCount
        self.unsupportedModels = unsupportedModels
        self.failedModelCount = failedModelCount
        self.failedModels = failedModels
        self.statusCounts = statusCounts
    }
}

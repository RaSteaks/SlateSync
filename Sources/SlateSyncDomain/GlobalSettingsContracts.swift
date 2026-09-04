import Foundation

public enum GlobalSettingKey: String, CaseIterable, Codable, Hashable, Sendable {
    case openAIBaseUrl = "OPENAI_BASE_URL"
    case openRouterBaseUrl = "OPENROUTER_BASE_URL"
    case openRouterSiteUrl = "OPENROUTER_SITE_URL"
    case tokenPlanBaseUrl = "TOKENPLAN_BASE_URL"
    case dashScopeBaseUrl = "DASHSCOPE_BASE_URL"
    case openAICompatibleBaseUrl = "OPENAI_COMPATIBLE_BASE_URL"
    case openAICompatibleModel = "OPENAI_COMPATIBLE_MODEL"
    case openAICompatibleAPIMode = "OPENAI_COMPATIBLE_API_MODE"
    case openAICompatibleJSONMode = "OPENAI_COMPATIBLE_JSON_MODE"
    case openAICompatibleImageDetail = "OPENAI_COMPATIBLE_IMAGE_DETAIL"
    case slateSyncConfigPath = "SLATESYNC_CONFIG_PATH"
    case maxBodyMB = "MAX_BODY_MB"
    case modelRequestTimeoutMS = "MODEL_REQUEST_TIMEOUT_MS"
    case modelRequestMaxRetries = "MODEL_REQUEST_MAX_RETRIES"
    case modelPageConcurrency = "MODEL_PAGE_CONCURRENCY"
    case maxConcurrentRecognitions = "MAX_CONCURRENT_RECOGNITIONS"
    case paddleOCREnabled = "PADDLEOCR_ENABLED"
    case paddleOCRRequired = "PADDLEOCR_REQUIRED"
    case paddleOCRModelVersion = "PADDLEOCR_MODEL_VERSION"
    case paddleOCRPreset = "PADDLEOCR_PRESET"
    case paddleOCRProfile = "PADDLEOCR_PROFILE"
    case paddleOCRLanguage = "PADDLEOCR_LANGUAGE"
    case paddleOCRDevice = "PADDLEOCR_DEVICE"
    case paddleOCRDetectionModel = "PADDLEOCR_DETECTION_MODEL"
    case paddleOCRRecognitionModel = "PADDLEOCR_RECOGNITION_MODEL"
    case paddleOCRRecognitionBatchSize = "PADDLEOCR_RECOGNITION_BATCH_SIZE"
    case paddleOCRPython = "PADDLEOCR_PYTHON"
    case paddleOCRMinConfidence = "PADDLEOCR_MIN_CONFIDENCE"
    case paddleOCRMaxBlocksPerView = "PADDLEOCR_MAX_BLOCKS_PER_VIEW"
    case paddleOCRTextDetLimitSideLen = "PADDLEOCR_TEXT_DET_LIMIT_SIDE_LEN"
    case paddleOCRTimeoutMS = "PADDLEOCR_TIMEOUT_MS"
    case paddlePDXCacheHome = "PADDLE_PDX_CACHE_HOME"
    case visionOCREnabled = "VISIONOCR_ENABLED"
    case visionOCRRequired = "VISIONOCR_REQUIRED"
    case visionOCRLanguage = "VISIONOCR_LANGUAGE"
    case visionOCRRecognitionLevel = "VISIONOCR_RECOGNITION_LEVEL"
    case visionOCRUseLanguageCorrection = "VISIONOCR_USE_LANGUAGE_CORRECTION"
    case visionOCRMinConfidence = "VISIONOCR_MIN_CONFIDENCE"
    case visionOCRMaxBlocksPerView = "VISIONOCR_MAX_BLOCKS_PER_VIEW"
    case visionOCRTimeoutMS = "VISIONOCR_TIMEOUT_MS"
    case visionOCRBinary = "VISIONOCR_BINARY"
}

/// The values object is encoded as a JSON object with the exact environment
/// variable keys used by the Electron settings page.
public struct GlobalSettingValues: Codable, Hashable, Sendable {
    public var values: [GlobalSettingKey: String]

    public init(_ values: [GlobalSettingKey: String] = [:]) {
        self.values = values
    }

    public subscript(_ key: GlobalSettingKey) -> String? {
        get { values[key] }
        set { values[key] = newValue }
    }

    public var rawValues: [String: String] {
        Dictionary(uniqueKeysWithValues: values.map { ($0.rawValue, $1) })
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode([String: String].self)
        values = Dictionary(uniqueKeysWithValues: raw.compactMap { key, value in
            guard let known = GlobalSettingKey(rawValue: key) else { return nil }
            return (known, value)
        })
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValues)
    }
}

/// A patch keeps `nil` as an explicit delete operation while retaining a
/// typed key set. The raw initializer is used at the JSON/IPC boundary so an
/// unknown key cannot be silently persisted.
public struct GlobalSettingsPatch: Codable, Hashable, Sendable {
    public var values: [GlobalSettingKey: String?]

    public init(_ values: [GlobalSettingKey: String?] = [:]) {
        self.values = values
    }

    public init(rawValues: [String: String?]) throws {
        var normalized: [GlobalSettingKey: String?] = [:]
        for (rawKey, rawValue) in rawValues {
            guard let key = GlobalSettingKey(rawValue: rawKey) else {
                throw SlateSyncError(code: "GLOBAL_CONFIG_INVALID", message: "不支持的全局配置项：\(rawKey)")
            }
            normalized[key] = try GlobalSettingsValidator.normalizedPatchValue(rawValue, for: key)
        }
        values = normalized
    }

    public var rawValues: [String: String?] {
        Dictionary(uniqueKeysWithValues: values.map { ($0.rawValue, $1) })
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode([String: String?].self)
        try self.init(rawValues: raw)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValues)
    }
}

public struct GlobalSettingsRequest: Codable, Hashable, Sendable {
    public let values: GlobalSettingsPatch?
    public let reset: Bool?

    public init(values: GlobalSettingsPatch? = nil, reset: Bool? = nil) {
        self.values = values
        self.reset = reset
    }
}

public struct GlobalSettingsData: Codable, Hashable, Sendable {
    public let values: GlobalSettingValues
    public let overrides: [GlobalSettingKey]
    public let keyConfigured: [String: Bool]
    public let restartRequired: Bool
    public let customProviders: [CustomProviderSummary]?

    public init(
        values: GlobalSettingValues,
        overrides: [GlobalSettingKey] = [],
        keyConfigured: [String: Bool] = [:],
        restartRequired: Bool = false,
        customProviders: [CustomProviderSummary]? = nil
    ) {
        self.values = values
        self.overrides = overrides
        self.keyConfigured = keyConfigured
        self.restartRequired = restartRequired
        self.customProviders = customProviders
    }
}

/// The validation rules mirror `electron/global-settings.mjs`, including
/// normalized URL casing, bounded numeric values, and enum spellings.
/// Shared source labels keep every native configuration consumer on one
/// precedence policy. Persistence adapts these labels instead of duplicating
/// the selection rules.
public enum GlobalSettingValueSource: String, Codable, Hashable, Sendable {
    case explicit
    case globalSettings
    case legacySettings
    case processEnvironment
    case envFile
    case defaults
}

public struct ResolvedGlobalSetting: Codable, Hashable, Sendable {
    public let value: String
    public let source: GlobalSettingValueSource

    public init(value: String, source: GlobalSettingValueSource) {
        self.value = value
        self.source = source
    }
}

public enum GlobalSettingsValidator {
    public static let defaults = GlobalSettingValues([
        .openAIBaseUrl: "https://api.openai.com/v1",
        .openRouterBaseUrl: "https://openrouter.ai/api/v1",
        .openRouterSiteUrl: "https://github.com/RaSteaks/SlateSync",
        .tokenPlanBaseUrl: "https://dashscope.aliyuncs.com/compatible-mode/v1",
        .dashScopeBaseUrl: "https://dashscope.aliyuncs.com/compatible-mode/v1",
        .openAICompatibleBaseUrl: "https://your-provider.example/v1",
        .openAICompatibleModel: "your-vision-model",
        .openAICompatibleAPIMode: "chat-completions",
        .openAICompatibleJSONMode: "json_object",
        .openAICompatibleImageDetail: "high",
        .slateSyncConfigPath: "slatesync.config.json",
        .maxBodyMB: "80",
        .modelRequestTimeoutMS: "180000",
        .modelRequestMaxRetries: "1",
        .modelPageConcurrency: "2",
        .maxConcurrentRecognitions: "1",
        .paddleOCREnabled: "auto",
        .paddleOCRRequired: "false",
        .paddleOCRModelVersion: "PP-OCRv6",
        .paddleOCRPreset: "custom",
        .paddleOCRProfile: "balanced",
        .paddleOCRLanguage: "ch",
        .paddleOCRDevice: "cpu",
        .paddleOCRDetectionModel: "",
        .paddleOCRRecognitionModel: "",
        .paddleOCRRecognitionBatchSize: "",
        .paddleOCRPython: "",
        .paddleOCRMinConfidence: "0.10",
        .paddleOCRMaxBlocksPerView: "0",
        .paddleOCRTextDetLimitSideLen: "",
        .paddleOCRTimeoutMS: "auto",
        .paddlePDXCacheHome: "",
        .visionOCREnabled: "auto",
        .visionOCRRequired: "false",
        .visionOCRLanguage: "zh-Hans",
        .visionOCRRecognitionLevel: "accurate",
        .visionOCRUseLanguageCorrection: "true",
        .visionOCRMinConfidence: "0.10",
        .visionOCRMaxBlocksPerView: "0",
        .visionOCRTimeoutMS: "auto",
        .visionOCRBinary: "",
    ])

    /// Resolves the default map for a concrete native data root. The static
    /// map remains available for Electron-compatible callers without a root.
    public static func defaultValues(applicationSupportRoot: URL? = nil) -> GlobalSettingValues {
        var values = defaults.values
        if let applicationSupportRoot {
            values[.paddlePDXCacheHome] = applicationSupportRoot
                .appending(path: "paddlex", directoryHint: .isDirectory)
                .path
        }
        return GlobalSettingValues(values)
    }

    public static func normalizedPatchValue(_ value: String?, for key: GlobalSettingKey) throws -> String? {
        // `null` is an explicit delete at the IPC boundary; preserve it so
        // GlobalConfigStore can remove the stored override instead of turning
        // the request into an empty-string value.
        guard let value else { return nil }
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if normalized.isEmpty { return "" }
        return try validate(normalized, for: key)
    }

    public static func sanitize(_ rawValues: [String: String]) -> GlobalSettingValues {
        var result: [GlobalSettingKey: String] = [:]
        for (rawKey, rawValue) in rawValues {
            guard let key = GlobalSettingKey(rawValue: rawKey) else { continue }
            guard let value = try? validate(rawValue.trimmingCharacters(in: .whitespacesAndNewlines), for: key) else {
                continue
            }
            if !value.isEmpty { result[key] = value }
        }
        return GlobalSettingValues(result)
    }

    public static func resolveValues(
        processEnvironment: [String: String] = [:],
        envFile: [String: String] = [:],
        globalOverrides: GlobalSettingValues = .init(),
        explicit: GlobalSettingValues = .init(),
        legacyPaddlePythonPath: String? = nil,
        applicationSupportRoot: URL? = nil
    ) -> GlobalSettingValues {
        GlobalSettingValues(
            GlobalSettingsResolution.resolveAll(
                processEnvironment: processEnvironment,
                envFile: envFile,
                globalOverrides: globalOverrides,
                explicit: explicit,
                legacyPaddlePythonPath: legacyPaddlePythonPath,
                applicationSupportRoot: applicationSupportRoot
            ).reduce(into: [:]) { result, entry in
                result[entry.key] = entry.value.value
            }
        )
    }

    public static func overrides(in values: GlobalSettingValues) -> [GlobalSettingKey] {
        GlobalSettingKey.allCases.filter { values[$0] != nil }
    }

    public static func normalizeOcrRoutingPatch(_ patch: GlobalSettingsPatch) -> GlobalSettingsPatch {
        var normalized = patch.values
        if normalized[.paddleOCREnabled] == "false" {
            normalized[.paddleOCRRequired] = "false"
        }
        if normalized[.visionOCREnabled] == "false" {
            normalized[.visionOCRRequired] = "false"
        }
        if normalized[.paddleOCREnabled] == "true" {
            normalized[.visionOCREnabled] = "false"
            normalized[.visionOCRRequired] = "false"
        } else if normalized[.visionOCREnabled] == "true" {
            normalized[.paddleOCREnabled] = "false"
            normalized[.paddleOCRRequired] = "false"
        }
        return GlobalSettingsPatch(normalized)
    }

    private static func validate(_ value: String, for key: GlobalSettingKey) throws -> String {
        let urlKeys: Set<GlobalSettingKey> = [
            .openAIBaseUrl, .openRouterBaseUrl, .openRouterSiteUrl,
            .tokenPlanBaseUrl, .dashScopeBaseUrl, .openAICompatibleBaseUrl,
        ]
        if urlKeys.contains(key) { return try normalizedURL(value, key: key) }

        let enumValues: [GlobalSettingKey: Set<String>] = [
            .openAICompatibleAPIMode: ["chat-completions", "responses"],
            .openAICompatibleJSONMode: ["json_schema", "json_object", "prompt"],
            .openAICompatibleImageDetail: ["auto", "low", "high", "original"],
            .paddleOCREnabled: ["auto", "true", "false"],
            .paddleOCRRequired: ["true", "false"],
            .paddleOCRPreset: ["custom", "performance", "balanced", "fast"],
            .paddleOCRProfile: ["fast", "balanced", "accurate"],
            .visionOCREnabled: ["auto", "true", "false"],
            .visionOCRRequired: ["true", "false"],
            .visionOCRRecognitionLevel: ["accurate", "fast"],
            .visionOCRUseLanguageCorrection: ["true", "false"],
        ]
        if let accepted = enumValues[key] {
            let normalized = value.lowercased()
            guard accepted.contains(normalized) else {
                throw invalid("\(key.rawValue) 值无效")
            }
            return normalized
        }

        switch key {
        case .maxBodyMB: return try integer(value, key, range: 20...200)
        case .modelRequestTimeoutMS: return try integer(value, key, range: 30_000...3_600_000)
        case .modelRequestMaxRetries: return try integer(value, key, range: 0...3)
        case .modelPageConcurrency: return try integer(value, key, range: 1...6)
        case .maxConcurrentRecognitions: return try integer(value, key, range: 1...16)
        case .paddleOCRRecognitionBatchSize: return try integer(value, key, range: 1...64)
        case .paddleOCRMaxBlocksPerView: return try integer(value, key, range: 0...10_000)
        case .paddleOCRTextDetLimitSideLen: return try integer(value, key, range: 320...4096)
        case .visionOCRMaxBlocksPerView: return try integer(value, key, range: 0...10_000)
        case .paddleOCRMinConfidence, .visionOCRMinConfidence: return try decimal(value, key, range: 0...1)
        case .paddleOCRTimeoutMS: return try timeout(value, key, maximum: 3_600_000)
        case .visionOCRTimeoutMS: return try timeout(value, key, maximum: 1_800_000)
        default: break
        }

        let maximum: Int
        switch key {
        case .paddleOCRLanguage, .visionOCRLanguage: maximum = 120
        case .openAICompatibleModel, .paddleOCRModelVersion,
             .paddleOCRDetectionModel, .paddleOCRRecognitionModel: maximum = 200
        case .slateSyncConfigPath, .paddlePDXCacheHome, .visionOCRBinary: maximum = 2_048
        case .paddleOCRPython: maximum = 200
        default: maximum = 200
        }
        guard JavaScriptCompatibility.utf16Length(value) <= maximum, !value.unicodeScalars.contains(where: { scalar in
            scalar.value <= 0x1F || scalar.value == 0x7F
        }) else {
            throw invalid("\(key.rawValue) 文本值无效")
        }
        return value
    }

    private static func normalizedURL(_ value: String, key: GlobalSettingKey) throws -> String {
        guard let normalized = HTTPURLNormalizer.normalize(
            value,
            trailingSlashPolicy: .removeOne
        ) else {
            throw invalid("\(key.rawValue) 必须是无账号、查询参数和片段的 http(s) URL")
        }
        return normalized
    }

    private static func integer(_ value: String, _ key: GlobalSettingKey, range: ClosedRange<Int>) throws -> String {
        guard let number = JavaScriptCompatibility.number(value),
              number.isFinite,
              number.rounded() == number,
              number >= Double(range.lowerBound),
              number <= Double(range.upperBound),
              let canonical = JavaScriptCompatibility.numberString(number) else {
            throw invalid("\(key.rawValue) 必须是 \(range.lowerBound)–\(range.upperBound) 之间的整数")
        }
        let integer = Int(number)
        guard range.contains(integer) else {
            throw invalid("\(key.rawValue) 必须是 \(range.lowerBound)–\(range.upperBound) 之间的整数")
        }
        return canonical
    }

    private static func decimal(_ value: String, _ key: GlobalSettingKey, range: ClosedRange<Double>) throws -> String {
        guard let number = JavaScriptCompatibility.number(value),
              number.isFinite,
              range.contains(number),
              let canonical = JavaScriptCompatibility.numberString(number) else {
            throw invalid("\(key.rawValue) 必须是有效数字")
        }
        return canonical
    }

    private static func timeout(_ value: String, _ key: GlobalSettingKey, maximum: Int) throws -> String {
        if value.lowercased() == "auto" { return "auto" }
        return try integer(value, key, range: 10_000...maximum)
    }

    private static func invalid(_ message: String) -> SlateSyncError {
        SlateSyncError(code: "GLOBAL_CONFIG_INVALID", message: message)
    }
}

/// Single precedence implementation shared by domain compatibility helpers and
/// persistence. Empty explicit/global/legacy values are unset; an empty process
/// value is intentionally a mask and therefore resolves to the built-in
/// default rather than allowing a .env value through.
public enum GlobalSettingsResolution {
    public static func resolve(
        key: GlobalSettingKey,
        processEnvironment: [String: String] = [:],
        envFile: [String: String] = [:],
        globalOverrides: GlobalSettingValues = .init(),
        explicit: GlobalSettingValues = .init(),
        legacyPaddlePythonPath: String? = nil,
        applicationSupportRoot: URL? = nil
    ) -> ResolvedGlobalSetting {
        let defaults = GlobalSettingsValidator.defaultValues(
            applicationSupportRoot: applicationSupportRoot
        )

        if let value = nonEmpty(explicit[key]) {
            return ResolvedGlobalSetting(value: value, source: .explicit)
        }
        if let value = nonEmpty(globalOverrides[key]) {
            return ResolvedGlobalSetting(value: value, source: .globalSettings)
        }
        if key == .paddleOCRPython,
           let value = nonEmpty(legacyPaddlePythonPath) {
            return ResolvedGlobalSetting(value: value, source: .legacySettings)
        }
        if let processValue = processEnvironment[key.rawValue] {
            let cleaned = clean(processValue)
            if !cleaned.isEmpty {
                return ResolvedGlobalSetting(value: cleaned, source: .processEnvironment)
            }
            return ResolvedGlobalSetting(
                value: defaults[key] ?? "",
                source: .defaults
            )
        }
        if let envValue = nonEmpty(envFile[key.rawValue]) {
            return ResolvedGlobalSetting(value: envValue, source: .envFile)
        }
        return ResolvedGlobalSetting(value: defaults[key] ?? "", source: .defaults)
    }

    public static func resolveAll(
        processEnvironment: [String: String] = [:],
        envFile: [String: String] = [:],
        globalOverrides: GlobalSettingValues = .init(),
        explicit: GlobalSettingValues = .init(),
        legacyPaddlePythonPath: String? = nil,
        applicationSupportRoot: URL? = nil
    ) -> [GlobalSettingKey: ResolvedGlobalSetting] {
        Dictionary(uniqueKeysWithValues: GlobalSettingKey.allCases.map { key in
            (
                key,
                resolve(
                    key: key,
                    processEnvironment: processEnvironment,
                    envFile: envFile,
                    globalOverrides: globalOverrides,
                    explicit: explicit,
                    legacyPaddlePythonPath: legacyPaddlePythonPath,
                    applicationSupportRoot: applicationSupportRoot
                )
            )
        })
    }

    private static func clean(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value else { return nil }
        let cleaned = clean(value)
        return cleaned.isEmpty ? nil : cleaned
    }
}

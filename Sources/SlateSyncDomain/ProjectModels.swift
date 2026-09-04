import Foundation

public struct ResolveFieldFormats: Codable, Hashable, Sendable {
    public var scene: String
    public var shot: String
    public var take: String

    public init(scene: String = "XXX", shot: String = "XX", take: String = "XX") {
        self.scene = scene
        self.shot = shot
        self.take = take
    }

    private enum CodingKeys: String, CodingKey {
        case scene
        case shot
        case take
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        // Workflow configuration is strict after canonicalization: trim and
        // uppercase first, then reject anything outside the X-only grammar.
        scene = (try values.decodeIfPresent(String.self, forKey: .scene) ?? "XXX")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased()
        shot = (try values.decodeIfPresent(String.self, forKey: .shot) ?? "XX")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased()
        take = (try values.decodeIfPresent(String.self, forKey: .take) ?? "XX")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased()
        try validate()
    }

    /// The Electron normalizer accepts only fixed-width X templates. Keeping
    /// validation on the value object prevents future native callers from
    /// silently changing Resolve field width semantics.
    public func validate() throws {
        guard Self.isValidFormat(scene), Self.isValidFormat(shot), Self.isValidFormat(take) else {
            throw SlateSyncError(code: "CONFIG_INVALID", message: "Resolve 字段格式必须由 1–6 个 X 组成")
        }
    }

    private static func isValidFormat(_ value: String) -> Bool {
        !value.isEmpty && value.count <= 6 && value.allSatisfy { $0 == "X" }
    }
}
public struct ResolveComments: Codable, Hashable, Sendable {
    public var goodTake: String
    public var holdTake: String

    public init(goodTake: String = "_OK", holdTake: String = "_KP") {
        self.goodTake = goodTake
        self.holdTake = holdTake
    }

    private enum CodingKeys: String, CodingKey {
        case goodTake
        case holdTake
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        // Workflow normalization trims string tokens before strict validation,
        // matching Electron's `normalizeCommentToken` without making malformed
        // non-string values silently pass through the strict config boundary.
        goodTake = (try values.decodeIfPresent(String.self, forKey: .goodTake) ?? "_OK")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        holdTake = (try values.decodeIfPresent(String.self, forKey: .holdTake) ?? "_KP")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        try validate()
    }

    /// Comment markers are written to Resolve and must remain single-line,
    /// bounded text just like the existing config normalizer.
    public func validate() throws {
        guard Self.isValidToken(goodTake), Self.isValidToken(holdTake) else {
            throw SlateSyncError(code: "CONFIG_INVALID", message: "Resolve Comments 标记必须是 1–32 个不含换行的字符")
        }
    }

    private static func isValidToken(_ value: String) -> Bool {
        !value.isEmpty && JavaScriptCompatibility.utf16Length(value) <= 32 &&
            !value.contains(where: { $0 == "\r" || $0 == "\n" })
    }
}

public struct ProjectSettings: Codable, Hashable, Sendable {
    public var version: Int
    public var providerId: String?
    public var modelId: String?
    public var accuracyMode: AccuracyMode
    public var scenarioId: String?
    public var customPrompt: String
    public var resolve: ResolveSettings

    public enum AccuracyMode: String, Codable, Sendable { case high, standard }

    public struct ResolveSettings: Codable, Hashable, Sendable {
        public var fieldFormats: ResolveFieldFormats
        public var comments: ResolveComments

        public init(
            fieldFormats: ResolveFieldFormats = .init(),
            comments: ResolveComments = .init()
        ) {
            self.fieldFormats = fieldFormats
            self.comments = comments
        }

        private enum CodingKeys: String, CodingKey {
            case fieldFormats
            case comments
        }

        public init(from decoder: any Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            fieldFormats = try values.decodeIfPresent(ResolveFieldFormats.self, forKey: .fieldFormats) ?? .init()
            comments = try values.decodeIfPresent(ResolveComments.self, forKey: .comments) ?? .init()
        }

        public func encode(to encoder: any Encoder) throws {
            var values = encoder.container(keyedBy: CodingKeys.self)
            try values.encode(fieldFormats, forKey: .fieldFormats)
            try values.encode(comments, forKey: .comments)
        }
    }

    public init(
        version: Int = 1,
        providerId: String? = nil,
        modelId: String? = nil,
        accuracyMode: AccuracyMode = .high,
        scenarioId: String? = nil,
        customPrompt: String = "",
        resolve: ResolveSettings = .init()
    ) {
        self.version = version
        self.providerId = providerId
        self.modelId = modelId
        self.accuracyMode = accuracyMode
        self.scenarioId = scenarioId
        self.customPrompt = customPrompt
        self.resolve = resolve
    }

    private enum CodingKeys: String, CodingKey {
        case version
        case providerId
        case modelId
        case accuracyMode
        case scenarioId
        case customPrompt
        case resolve
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        // Electron always emits the current project-settings version after
        // normalization. Treat an old, future, or malformed stored value as
        // recoverable here; WorkflowConfig remains the strict boundary.
        version = 1
        providerId = Self.cleanOptionalID(try values.decodeIfPresent(JSONValue.self, forKey: .providerId))
        modelId = Self.cleanOptionalID(try values.decodeIfPresent(JSONValue.self, forKey: .modelId))
        // Invalid enum values are normalized to the Electron default rather
        // than making a legacy project unreadable.
        if case .string(let value)? = try values.decodeIfPresent(JSONValue.self, forKey: .accuracyMode),
           let mode = AccuracyMode(rawValue: value) {
            accuracyMode = mode
        } else {
            accuracyMode = .high
        }
        scenarioId = Self.cleanOptionalID(try values.decodeIfPresent(JSONValue.self, forKey: .scenarioId))
        customPrompt = Self.truncateUTF16(
            Self.javascriptString(try values.decodeIfPresent(JSONValue.self, forKey: .customPrompt))
                .trimmingCharacters(in: .whitespacesAndNewlines),
            maximumLength: 2_000
        )
        // Project snapshots are intentionally forgiving: malformed Resolve
        // fields fall back independently, while WorkflowConfig still decodes
        // ResolveSettings strictly and rejects the same malformed values.
        resolve = Self.normalizedProjectResolve(
            try values.decodeIfPresent(JSONValue.self, forKey: .resolve)
        )
        try validate()
    }

    public func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(version, forKey: .version)
        // Explicit nulls preserve the TypeScript contract, whose optional
        // project fields are present as `null` rather than omitted.
        try values.encode(providerId, forKey: .providerId)
        try values.encode(modelId, forKey: .modelId)
        try values.encode(accuracyMode, forKey: .accuracyMode)
        try values.encode(scenarioId, forKey: .scenarioId)
        try values.encode(customPrompt, forKey: .customPrompt)
        try values.encode(resolve, forKey: .resolve)
    }

    /// Project settings use Electron's forgiving normalizer at the storage
    /// boundary. A separately loaded WorkflowConfig remains strict.
    public func validate() throws {
        guard version == 1 else {
            throw SlateSyncError(code: "PROJECT_SETTINGS_VERSION", message: "不支持的项目设置版本")
        }
        try resolve.fieldFormats.validate()
        try resolve.comments.validate()
        guard JavaScriptCompatibility.utf16Length(customPrompt) <= 2_000, !customPrompt.contains("\0") else {
            throw SlateSyncError(code: "PROJECT_SETTINGS_INVALID", message: "自定义提示词过长或包含无效字符")
        }
    }

    private static func normalizedProjectResolve(_ value: JSONValue?) -> ResolveSettings {
        guard case .object(let resolve) = value else { return .init() }
        let fieldFormats = object(in: resolve["fieldFormats"])
        let fallbackFormats = ResolveFieldFormats()
        let comments = object(in: resolve["comments"])
        let fallbackComments = ResolveComments()

        return ResolveSettings(
            fieldFormats: ResolveFieldFormats(
                scene: safeFieldFormat(
                    javascriptString(fieldFormats?["scene"]),
                    fallback: fallbackFormats.scene
                ),
                shot: safeFieldFormat(
                    javascriptString(fieldFormats?["shot"]),
                    fallback: fallbackFormats.shot
                ),
                take: safeFieldFormat(
                    javascriptString(fieldFormats?["take"]),
                    fallback: fallbackFormats.take
                )
            ),
            comments: ResolveComments(
                goodTake: safeCommentToken(
                    comments?["goodTake"],
                    fallback: fallbackComments.goodTake
                ),
                holdTake: safeCommentToken(
                    comments?["holdTake"],
                    fallback: fallbackComments.holdTake
                )
            )
        )
    }

    private static func object(in value: JSONValue?) -> [String: JSONValue]? {
        guard case .object(let object) = value else { return nil }
        return object
    }

    /// Implements the small String(value || "") subset used by the
    /// JavaScript project-settings normalizer for legacy JSON values.
    private static func javascriptString(_ value: JSONValue?) -> String {
        guard let value else { return "" }
        switch value {
        case .null:
            return ""
        case .boolean(let value):
            return value ? "true" : ""
        case .number(let value):
            guard value != 0, value.isFinite else { return "" }
            return JavaScriptCompatibility.numberString(value) ?? ""
        case .string(let value):
            return value
        case .array(let values):
            // JavaScript's Array#toString applies normal String coercion to
            // each element, so `[0]` is "0" even though top-level
            // `String(0 || "")` is empty. Keep the two coercion contexts
            // separate for legacy JSON values.
            return values.map { javascriptArrayElementString($0) }.joined(separator: ",")
        case .object:
            return "[object Object]"
        }
    }

    private static func javascriptArrayElementString(_ value: JSONValue) -> String {
        switch value {
        case .null:
            return ""
        case .boolean(let value):
            return value ? "true" : "false"
        case .number(let value):
            return JavaScriptCompatibility.numberString(value) ?? "NaN"
        case .string(let value):
            return value
        case .array(let values):
            return values.map { javascriptArrayElementString($0) }.joined(separator: ",")
        case .object:
            return "[object Object]"
        }
    }

    private static func cleanOptionalID(_ value: JSONValue?) -> String? {
        let cleaned = javascriptString(value).trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? nil : cleaned
    }

    private static func safeFieldFormat(_ value: String, fallback: String) -> String {
        let token = value.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard token.range(of: #"^X{1,6}$"#, options: .regularExpression) != nil else {
            return fallback
        }
        return token
    }

    private static func safeCommentToken(_ value: JSONValue?, fallback: String) -> String {
        // Electron uses String(value || "") at this forgiving boundary. Keep
        // that coercion here; the strict ResolveComments type still rejects
        // non-string JSON when decoding workflow configuration.
        let token = truncateUTF16(
            javascriptString(value).trimmingCharacters(in: .whitespacesAndNewlines),
            maximumLength: 32
        )
        guard !token.isEmpty, !token.contains(where: { $0 == "\r" || $0 == "\n" }) else {
            return fallback
        }
        return token
    }

    private static func truncateUTF16(_ value: String, maximumLength: Int) -> String {
        String(decoding: value.utf16.prefix(maximumLength), as: UTF16.self)
    }
}

public struct ProjectSummary: Identifiable, Codable, Hashable, Sendable {
    public let id: String
    public var name: String
    public var description: String
    public let relativePath: String
    public var archivedAt: String?
    public let createdAt: String
    public var updatedAt: String
    public var taskCount: Int
    public var latestTaskAt: String?
    public var canArchive: Bool

    public init(
        id: String,
        name: String,
        description: String = "",
        relativePath: String,
        archivedAt: String? = nil,
        createdAt: String,
        updatedAt: String,
        taskCount: Int = 0,
        latestTaskAt: String? = nil,
        canArchive: Bool = true
    ) {
        self.id = id
        self.name = name
        self.description = description
        self.relativePath = relativePath
        self.archivedAt = archivedAt
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.taskCount = taskCount
        self.latestTaskAt = latestTaskAt
        self.canArchive = canArchive
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case description
        case relativePath
        case archivedAt
        case createdAt
        case updatedAt
        case taskCount
        case latestTaskAt
        case canArchive
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        name = try values.decode(String.self, forKey: .name)
        description = try values.decodeIfPresent(String.self, forKey: .description) ?? ""
        relativePath = try values.decode(String.self, forKey: .relativePath)
        archivedAt = try values.decodeIfPresent(String.self, forKey: .archivedAt)
        createdAt = try values.decodeIfPresent(String.self, forKey: .createdAt) ?? ""
        updatedAt = try values.decodeIfPresent(String.self, forKey: .updatedAt) ?? ""
        taskCount = try values.decodeIfPresent(Int.self, forKey: .taskCount) ?? 0
        latestTaskAt = try values.decodeIfPresent(String.self, forKey: .latestTaskAt)
        canArchive = try values.decodeIfPresent(Bool.self, forKey: .canArchive) ?? true
    }

    public func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(id, forKey: .id)
        try values.encode(name, forKey: .name)
        try values.encode(description, forKey: .description)
        try values.encode(relativePath, forKey: .relativePath)
        try values.encode(archivedAt, forKey: .archivedAt)
        try values.encode(createdAt, forKey: .createdAt)
        try values.encode(updatedAt, forKey: .updatedAt)
        try values.encode(taskCount, forKey: .taskCount)
        try values.encode(latestTaskAt, forKey: .latestTaskAt)
        try values.encode(canArchive, forKey: .canArchive)
    }
}

public struct ProjectData: Codable, Hashable, Sendable {
    public var id: String
    public var name: String
    public var description: String
    public var relativePath: String
    public var archivedAt: String?
    public var createdAt: String
    public var updatedAt: String
    public var taskCount: Int
    public var latestTaskAt: String?
    public var canArchive: Bool
    public var settings: ProjectSettings
    public var lastRecognitionDefaults: RecognitionDefaults?

    /// This computed view keeps the small native library screen source
    /// compatible while the Codable shape now matches the flat shared DTO.
    public var summary: ProjectSummary {
        ProjectSummary(
            id: id,
            name: name,
            description: description,
            relativePath: relativePath,
            archivedAt: archivedAt,
            createdAt: createdAt,
            updatedAt: updatedAt,
            taskCount: taskCount,
            latestTaskAt: latestTaskAt,
            canArchive: canArchive
        )
    }

    public init(
        summary: ProjectSummary,
        settings: ProjectSettings = .init(),
        lastRecognitionDefaults: RecognitionDefaults? = nil
    ) {
        id = summary.id
        name = summary.name
        description = summary.description
        relativePath = summary.relativePath
        archivedAt = summary.archivedAt
        createdAt = summary.createdAt
        updatedAt = summary.updatedAt
        taskCount = summary.taskCount
        latestTaskAt = summary.latestTaskAt
        canArchive = summary.canArchive
        self.settings = settings
        self.lastRecognitionDefaults = lastRecognitionDefaults
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case description
        case relativePath
        case archivedAt
        case createdAt
        case updatedAt
        case taskCount
        case latestTaskAt
        case canArchive
        case settings
        case lastRecognitionDefaults
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        name = try values.decode(String.self, forKey: .name)
        description = try values.decodeIfPresent(String.self, forKey: .description) ?? ""
        relativePath = try values.decode(String.self, forKey: .relativePath)
        archivedAt = try values.decodeIfPresent(String.self, forKey: .archivedAt)
        createdAt = try values.decodeIfPresent(String.self, forKey: .createdAt) ?? ""
        updatedAt = try values.decodeIfPresent(String.self, forKey: .updatedAt) ?? ""
        taskCount = try values.decodeIfPresent(Int.self, forKey: .taskCount) ?? 0
        latestTaskAt = try values.decodeIfPresent(String.self, forKey: .latestTaskAt)
        canArchive = try values.decodeIfPresent(Bool.self, forKey: .canArchive) ?? true
        settings = try values.decodeIfPresent(ProjectSettings.self, forKey: .settings) ?? .init()
        lastRecognitionDefaults = try values.decodeIfPresent(RecognitionDefaults.self, forKey: .lastRecognitionDefaults)
    }

    public func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(id, forKey: .id)
        try values.encode(name, forKey: .name)
        try values.encode(description, forKey: .description)
        try values.encode(relativePath, forKey: .relativePath)
        try values.encode(archivedAt, forKey: .archivedAt)
        try values.encode(createdAt, forKey: .createdAt)
        try values.encode(updatedAt, forKey: .updatedAt)
        try values.encode(taskCount, forKey: .taskCount)
        try values.encode(latestTaskAt, forKey: .latestTaskAt)
        try values.encode(canArchive, forKey: .canArchive)
        try values.encode(settings, forKey: .settings)
        try values.encode(lastRecognitionDefaults, forKey: .lastRecognitionDefaults)
    }
}

public struct LibraryInfo: Codable, Hashable, Sendable {
    public let id: String
    public var name: String
    public let formatVersion: Int
    public let path: String

    public init(id: String, name: String, formatVersion: Int = 1, path: String) {
        self.id = id
        self.name = name
        self.formatVersion = formatVersion
        self.path = path
    }
}

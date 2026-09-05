import Foundation

public enum RecognitionStage: String, Codable, Hashable, Sendable {
    case primary
    case audit
    case review
}

/// Provider-only image bytes. Project media enters through PreparedImage,
/// while the capability probe may use its frozen project-free PNG oracle.
public struct ProviderImage: Hashable, Sendable {
    public let data: Data
    public let mimeType: String
    public let width: Int
    public let height: Int

    public init(_ image: PreparedImage) {
        data = image.jpeg; mimeType = "image/jpeg"
        width = image.width; height = image.height
    }

    public init(data: Data, mimeType: String, width: Int, height: Int) throws {
        let signatureIsValid = switch mimeType {
        case "image/jpeg": data.starts(with: [0xff, 0xd8, 0xff]) && data.suffix(2) == Data([0xff, 0xd9])
        case "image/png": data.starts(with: [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a])
        case "image/webp": data.count >= 12 && data.prefix(4) == Data("RIFF".utf8) && data.dropFirst(8).prefix(4) == Data("WEBP".utf8)
        default: false
        }
        guard signatureIsValid, width > 0, height > 0 else { throw RecognitionFailure.invalidInput }
        self.data = data; self.mimeType = mimeType
        self.width = width; self.height = height
    }

    public var dataURL: String { "data:\(mimeType);base64," + data.base64EncodedString() }
}

public struct RecognitionPageInput: Sendable {
    public let pageNumber: Int
    public let views: [PreparedMediaView]
    public let fullOCREvidence: String
    public let coreOCREvidence: String

    public init(
        pageNumber: Int,
        views: [PreparedMediaView],
        fullOCREvidence: String = "",
        coreOCREvidence: String = ""
    ) {
        self.pageNumber = pageNumber
        self.views = views
        self.fullOCREvidence = fullOCREvidence
        self.coreOCREvidence = coreOCREvidence
    }
}

public struct RecognitionStageRequest: Sendable {
    public let provider: ProviderDescriptor
    public let model: ResolvedModel
    public let stage: RecognitionStage
    public let filename: String
    public let images: [ProviderImage]
    public let systemPrompt: String
    public let userInstruction: String?
    public let schema: JSONValue
    public let timeoutMilliseconds: Int
    public let maximumTimeoutRetries: Int

    public init(
        provider: ProviderDescriptor,
        model: ResolvedModel,
        stage: RecognitionStage,
        filename: String,
        images: [PreparedImage],
        systemPrompt: String,
        userInstruction: String? = nil,
        schema: JSONValue,
        timeoutMilliseconds: Int = 180_000,
        maximumTimeoutRetries: Int = 1
    ) {
        self.provider = provider
        self.model = model
        self.stage = stage
        self.filename = filename
        self.images = images.map(ProviderImage.init)
        self.systemPrompt = systemPrompt
        self.userInstruction = userInstruction
        self.schema = schema
        self.timeoutMilliseconds = timeoutMilliseconds
        self.maximumTimeoutRetries = maximumTimeoutRetries
    }

    /// The synthetic capability probe uses this initializer so its frozen PNG
    /// never needs to masquerade as SM-06 prepared JPEG project media.
    public init(
        provider: ProviderDescriptor,
        model: ResolvedModel,
        stage: RecognitionStage,
        filename: String,
        providerImages: [ProviderImage],
        systemPrompt: String,
        userInstruction: String? = nil,
        schema: JSONValue,
        timeoutMilliseconds: Int = 180_000,
        maximumTimeoutRetries: Int = 1
    ) {
        self.provider = provider
        self.model = model
        self.stage = stage
        self.filename = filename
        images = providerImages
        self.systemPrompt = systemPrompt
        self.userInstruction = userInstruction
        self.schema = schema
        self.timeoutMilliseconds = timeoutMilliseconds
        self.maximumTimeoutRetries = maximumTimeoutRetries
    }
}

public struct RecognitionStageResponse: Codable, Hashable, Sendable {
    public let text: String
    public let usage: TokenUsage?
    public let responseID: String?
    public let model: String?
    public let formatMode: ProviderJSONMode

    public init(text: String, usage: TokenUsage? = nil, responseID: String? = nil, model: String? = nil, formatMode: ProviderJSONMode) {
        self.text = text
        self.usage = usage
        self.responseID = responseID
        self.model = model
        self.formatMode = formatMode
    }
}

/// The one compatibility adapter for model, OCR, and imported CSV status
/// aliases. Unknown and blank text deliberately remain nil.
public enum LegacyTakeStatusAdapter {
    public static func status(from value: String?) -> TakeStatus? {
        let normalized = (value ?? "")
            .precomposedStringWithCompatibilityMapping
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "\u{FE0F}", with: "")
        switch normalized {
        case "过", "过条", "好条", "ok", "pass", "☑", "✅", "√", "✓", "✔": return .passed
        case "保", "保条", "hold", "三角", "三角形", "triangle", "△", "▲": return .hold
        case "废条", "废", "ng", "x", "×", "✕", "✖": return .rejected
        default: return nil
        }
    }

    public static func status(value: String?, legacyGoodTake: Bool?) -> TakeStatus? {
        status(from: value) ?? (value == nil ? legacyGoodTake.map { $0 ? .passed : .hold } : nil)
    }

    public static func status(fromResolveComment value: String?, comments: ResolveComments = .init()) -> TakeStatus? {
        let token = (value ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else { return nil }
        if token.caseInsensitiveCompare(comments.goodTake) == .orderedSame || ["OK", "_OK"].contains(token.uppercased()) { return .passed }
        if token.caseInsensitiveCompare(comments.holdTake) == .orderedSame || ["KP", "_KP"].contains(token.uppercased()) { return .hold }
        return status(from: token)
    }
}

public enum RecognitionRuntimeOptions {
    public static func timeoutMilliseconds(_ raw: String?) -> Int {
        guard let raw, let value = Double(raw), value.isFinite, value > 0 else { return 180_000 }
        return min(3_600_000, max(30_000, Int(value.rounded())))
    }

    public static func maximumTimeoutRetries(_ raw: String?) -> Int {
        guard let raw, let value = Int(raw), (0...3).contains(value) else { return 1 }
        return value
    }

    public static func pageConcurrency(_ raw: String?) -> Int {
        guard let raw, let value = Int(raw), (1...6).contains(value) else { return 2 }
        return value
    }

    public static func globalConcurrency(_ raw: String?) -> Int {
        guard let raw, let value = Int(raw), (1...16).contains(value) else { return 1 }
        return value
    }
}

/// Native OCR-first entrypoint. MediaInput is consumed locally and cannot
/// encode into a provider payload; legacy JSON is accepted only so the
/// direct-PDF guard can reject it before any side effect.
public struct NativeRecognitionRequest: Sendable {
    public let projectID: String
    public let input: MediaInput
    public let filename: String
    public let taskID: String?
    public let providerID: String?
    public let modelID: String?
    public let settings: ProjectSettings?
    public let slateCSVRecords: [SlateCsvRecord]
    public let legacyRequest: Data?
    public let maximumRequestBytes: Int
    public let cacheEnabled: Bool

    public init(
        projectID: String,
        input: MediaInput,
        filename: String,
        taskID: String? = nil,
        providerID: String? = nil,
        modelID: String? = nil,
        settings: ProjectSettings? = nil,
        slateCSVRecords: [SlateCsvRecord] = [],
        legacyRequest: Data? = nil,
        maximumRequestBytes: Int = 80 * 1024 * 1024,
        cacheEnabled: Bool = true
    ) {
        self.projectID = projectID
        self.input = input
        self.filename = filename
        self.taskID = taskID
        self.providerID = providerID
        self.modelID = modelID
        self.settings = settings
        self.slateCSVRecords = slateCSVRecords
        self.legacyRequest = legacyRequest
        self.maximumRequestBytes = maximumRequestBytes
        self.cacheEnabled = cacheEnabled
    }
}

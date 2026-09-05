import Foundation

public enum OCREngineID: String, Codable, Sendable { case vision, paddle = "paddleocr" }

/// Coordinates are view-local, top-left LTRB. The old OCRBlock continues to
/// encode xywh in Vision's bottom-left space; conversion is explicit below.
public struct OCRTextBlock: Codable, Hashable, Sendable {
    public let order: Int
    public let text: String
    public let confidence: Double
    public let bbox: [Int]
    public let bboxNormalized: [Double]
    public init(order: Int, text: String, confidence: Double, bbox: [Int], bboxNormalized: [Double]) {
        self.order = order; self.text = text; self.confidence = confidence; self.bbox = bbox; self.bboxNormalized = bboxNormalized
    }
    public func legacyBlock() throws -> OCRBlock {
        guard bboxNormalized.count == 4, bboxNormalized.allSatisfy(\.isFinite) else { throw MediaFailure.protocolError }
        let b = bboxNormalized
        return .init(text: text, confidence: confidence, boundingBox: .init(x: b[0], y: 1 - b[3], width: b[2] - b[0], height: b[3] - b[1]))
    }
}

public struct OCRViewEvidence: Codable, Hashable, Sendable {
    public let viewIndex: Int
    public let viewType: PreparedViewType
    public let width: Int
    public let height: Int
    public let durationMs: Int
    public let truncated: Bool
    public let blocks: [OCRTextBlock]
    public init(viewIndex: Int, viewType: PreparedViewType, width: Int, height: Int, durationMs: Int = 0, truncated: Bool = false, blocks: [OCRTextBlock]) {
        self.viewIndex = viewIndex; self.viewType = viewType; self.width = width; self.height = height; self.durationMs = durationMs; self.truncated = truncated; self.blocks = blocks
    }
    private enum CodingKeys: String, CodingKey { case viewIndex, viewType, width, height, durationMs, truncated, blocks }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // Older normalized evidence omits advisory timing/truncation fields.
        self.init(viewIndex: try c.decode(Int.self, forKey: .viewIndex), viewType: try c.decode(PreparedViewType.self, forKey: .viewType), width: try c.decode(Int.self, forKey: .width), height: try c.decode(Int.self, forKey: .height), durationMs: try c.decodeIfPresent(Int.self, forKey: .durationMs) ?? 0, truncated: try c.decodeIfPresent(Bool.self, forKey: .truncated) ?? false, blocks: try c.decode([OCRTextBlock].self, forKey: .blocks))
    }
}
public struct OCRPageEvidence: Codable, Hashable, Sendable {
    public let pageNumber: Int
    public let views: [OCRViewEvidence]
    public init(pageNumber: Int, views: [OCRViewEvidence]) { self.pageNumber = pageNumber; self.views = views }
}
public struct OCREngineResult: Codable, Hashable, Sendable {
    public let engine: OCREngineID
    public let modelVersion: String
    public let used: Bool
    public let pages: [OCRPageEvidence]
    public let durationMs: Int
    public init(engine: OCREngineID, modelVersion: String, used: Bool = true, pages: [OCRPageEvidence], durationMs: Int = 0) {
        self.engine = engine; self.modelVersion = modelVersion; self.used = used; self.pages = pages; self.durationMs = durationMs
    }
    public var blockCount: Int { pages.flatMap(\.views).reduce(0) { $0 + $1.blocks.count } }
}
public struct OCRSelection: Codable, Hashable, Sendable {
    public let id: OCREngineID?
    public let mode: String
    public let required: Bool
    public init(id: OCREngineID?, mode: String, required: Bool = false) { self.id = id; self.mode = mode; self.required = required }
}
public enum OCROutcome: Codable, Hashable, Sendable {
    case used(OCREngineResult, cacheHit: Bool)
    case degraded(engine: OCREngineID?, warning: String)
    case disabled
    public var result: OCREngineResult? { if case .used(let result, _) = self { result } else { nil } }
}
public struct OCRSummary: Codable, Hashable, Sendable {
    public let enabled: Bool
    public let available: Bool
    public let engine: OCREngineID?
    public let model: String?
    public let preset: String?
    public let presetLabel: String?
    public let profile: String?
    public let profileLabel: String?
    public let detectionModel: String?
    public let recognitionModel: String?
    public let recognitionBatchSize: Int?
    public let textDetLimitSideLen: Int?
    public let device: String?
    public let used: Bool
    public let cacheHit: Bool
    public let pageCount: Int
    public let viewCount: Int
    public let blockCount: Int
    public let lowConfidenceBlockCount: Int
    public let durationMs: Int
    public let warning: String?
    public init(outcome: OCROutcome, selection: OCRSelection? = nil, paddle: PaddleOCRConfiguration? = nil) {
        let result = outcome.result
        let views = result?.pages.flatMap(\.views) ?? []
        engine = result?.engine ?? selection?.id; used = result?.used ?? false
        enabled = selection?.id != nil || result != nil; available = result != nil
        // Retain effective model metadata for optional failure diagnostics;
        // empty custom model overrides have the legacy summary's null meaning.
        model = result?.modelVersion ?? paddle?.modelVersion; preset = paddle?.preset; profile = paddle?.profile
        presetLabel = paddle?.presetLabel; profileLabel = paddle?.profileLabel
        detectionModel = paddle?.detectionModel.isEmpty == false ? paddle?.detectionModel : nil
        recognitionModel = paddle?.recognitionModel.isEmpty == false ? paddle?.recognitionModel : nil
        recognitionBatchSize = paddle?.recognitionBatchSize; textDetLimitSideLen = paddle?.textDetLimitSideLen; device = paddle?.device
        pageCount = result?.pages.count ?? 0; viewCount = views.count
        blockCount = result?.blockCount ?? 0
        lowConfidenceBlockCount = views.flatMap(\.blocks).filter { $0.confidence < 0.65 }.count
        durationMs = result?.durationMs ?? 0
        if case .used(_, let hit) = outcome { cacheHit = hit } else { cacheHit = false }
        if case .degraded(_, let value) = outcome { warning = value } else { warning = nil }
    }
}

/// A monotonic clock is injectable for deadlines, including time spent queued.
public protocol OCRClock: Sendable {
    func nowMilliseconds() -> Double
    func sleep(milliseconds: Int) async throws
}
public struct SystemOCRClock: OCRClock {
    public init() {}
    public func nowMilliseconds() -> Double { ProcessInfo.processInfo.systemUptime * 1000 }
    public func sleep(milliseconds: Int) async throws { try await Task.sleep(for: .milliseconds(milliseconds)) }
}
public struct OCRDeadline: Sendable {
    public let end: Double
    public init(clock: any OCRClock, timeoutMilliseconds: Double) { end = clock.nowMilliseconds() + timeoutMilliseconds }
    public func check(clock: any OCRClock, operation: MediaOperation) throws {
        try operation.check()
        if clock.nowMilliseconds() >= end { throw MediaFailure.timeout }
    }
}

// Process configuration and transport carry values only across module owners.
public struct OCRProcessLaunch: Sendable {
    public let executable: URL
    public let arguments: [String]
    public let directory: URL
    public let environment: [String: String]
    public init(executable: URL, arguments: [String], directory: URL, environment: [String: String]) {
        self.executable = executable; self.arguments = arguments; self.directory = directory; self.environment = environment
    }
}
public protocol OCRProcessTransport: Sendable {
    func exchange(_ request: Data, requestID: String?, oneShot: Bool, deadline: OCRDeadline, operation: MediaOperation, progress: MediaProgressSink?) async throws -> Data
    func close() async
}

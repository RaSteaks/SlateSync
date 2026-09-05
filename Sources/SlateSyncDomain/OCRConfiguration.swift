import Foundation

/// Resolve runtime settings separately from SM-03's strict editor validation.
/// Raw legacy values retain JavaScript coercion, including Vision's empty=0
/// versus Paddle's empty=unset behavior. All engines/probes use this snapshot.
public struct VisionOCRConfiguration: Codable, Hashable, Sendable {
    public let language: String
    public var languages: [String] { language.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty } }
    public let recognitionLevel: String
    public let usesLanguageCorrection: Bool
    public let minimumConfidence: Double
    public let maxBlocksPerView: Int
    public let binary: String
    public let timeout: String
    public init(_ values: GlobalSettingValues = .init()) {
        let r = OCRSettingReader(values.rawValues)
        language = r.clean("VISIONOCR_LANGUAGE", fallback: "zh-Hans")
        recognitionLevel = r.clean("VISIONOCR_RECOGNITION_LEVEL") == "fast" ? "fast" : "accurate"
        usesLanguageCorrection = r.boolean("VISIONOCR_USE_LANGUAGE_CORRECTION", fallback: true)
        minimumConfidence = r.number("VISIONOCR_MIN_CONFIDENCE", fallback: 0.1, minimum: 0, maximum: 1, emptyIsUnset: false)
        maxBlocksPerView = Int(r.number("VISIONOCR_MAX_BLOCKS_PER_VIEW", fallback: 0, minimum: 0, maximum: 10_000, emptyIsUnset: false))
        binary = r.clean("VISIONOCR_BINARY"); timeout = r.clean("VISIONOCR_TIMEOUT_MS")
    }
    public func timeoutMilliseconds(views: Int) -> Double { OCRSettingReader.timeout(timeout, engine: .vision, views: views) }
}

public struct PaddleOCRConfiguration: Codable, Hashable, Sendable {
    public let preset: String
    // Labels are compatibility metadata; the Python protocol consumes only
    // effective inference parameters, not localized presentation strings.
    public var presetLabel: String { ["performance":"性能（质量优先）", "balanced":"平衡（推荐）", "fast":"快速（低延迟）"][preset] ?? "自定义" }
    public var profileLabel: String { preset == "custom" ? (["fast":"快速", "balanced":"平衡", "accurate":"高精度"][profile] ?? profile) : presetLabel }
    public let modelVersion: String
    public let profile: String
    public let detectionModel: String
    public let recognitionModel: String
    public let recognitionBatchSize: Int
    public let minimumConfidence: Double
    public let maxBlocksPerView: Int
    public let textDetLimitSideLen: Int
    public let language: String
    public let device: String
    public let timeout: String
    public init(_ values: GlobalSettingValues = .init()) {
        let r = OCRSettingReader(values.rawValues)
        language = r.clean("PADDLEOCR_LANGUAGE", fallback: "ch")
        device = r.clean("PADDLEOCR_DEVICE", fallback: "cpu")
        timeout = r.clean("PADDLEOCR_TIMEOUT_MS")
        let requested = r.clean("PADDLEOCR_PRESET").lowercased()
        if ["performance", "balanced", "fast"].contains(requested) {
            preset = requested; profile = requested; modelVersion = "PP-OCRv6"
            let index = ["performance", "balanced", "fast"].firstIndex(of: requested) ?? 0
            let size = ["medium", "small", "tiny"][index]
            detectionModel = "PP-OCRv6_\(size)_det"; recognitionModel = "PP-OCRv6_\(size)_rec"
            recognitionBatchSize = [4,8,16][index]; minimumConfidence = [0.05,0.10,0.25][index]
            maxBlocksPerView = [0,256,64][index]; textDetLimitSideLen = [1280,960,736][index]
        } else {
            preset = "custom"
            let version = r.clean("PADDLEOCR_MODEL_VERSION", fallback: "PP-OCRv6")
            modelVersion = version.lowercased() == "pp-ocrv5" ? "PP-OCRv5" : (version.lowercased() == "pp-ocrv6" ? "PP-OCRv6" : version)
            let requestedProfile = r.clean("PADDLEOCR_PROFILE").lowercased()
            profile = ["fast","balanced","accurate"].contains(requestedProfile) ? requestedProfile : (modelVersion == "PP-OCRv5" ? "balanced" : "accurate")
            let index = ["fast","balanced","accurate"].firstIndex(of: profile) ?? 1
            let resolvedVersion = modelVersion
            func model(_ key: String, fallback: String) -> String {
                let value = r.clean(key)
                if value.isEmpty || (resolvedVersion == "PP-OCRv5" && value.lowercased().hasPrefix("pp-ocrv6_")) || (resolvedVersion == "PP-OCRv6" && value.lowercased().hasPrefix("pp-ocrv5_")) { return fallback }
                return value
            }
            detectionModel = model("PADDLEOCR_DETECTION_MODEL", fallback: modelVersion == "PP-OCRv5" ? ["PP-OCRv5_mobile_det","PP-OCRv5_mobile_det","PP-OCRv5_server_det"][index] : "")
            recognitionModel = model("PADDLEOCR_RECOGNITION_MODEL", fallback: modelVersion == "PP-OCRv5" ? ["PP-OCRv5_mobile_rec","PP-OCRv5_server_rec","PP-OCRv5_server_rec"][index] : "")
            recognitionBatchSize = Int(r.number("PADDLEOCR_RECOGNITION_BATCH_SIZE", fallback: Double([16,8,4][index]), minimum: 1, maximum: 64))
            minimumConfidence = r.number("PADDLEOCR_MIN_CONFIDENCE", fallback: 0.1, minimum: 0, maximum: 1)
            maxBlocksPerView = Int(r.number("PADDLEOCR_MAX_BLOCKS_PER_VIEW", fallback: 0, minimum: 0, maximum: 10_000))
            textDetLimitSideLen = Int(r.number("PADDLEOCR_TEXT_DET_LIMIT_SIDE_LEN", fallback: 960, minimum: 320, maximum: 4096))
        }
    }
    public func timeoutMilliseconds(views: Int) -> Double { OCRSettingReader.timeout(timeout, engine: .paddle, views: views) }
}

public struct OCRSettingReader: Sendable {
    public let raw: [String: String]
    public init(_ raw: [String: String]) { self.raw = raw }
    public func clean(_ key: String, fallback: String = "") -> String {
        let value = raw[key]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return value.isEmpty ? fallback : value
    }
    public func boolean(_ key: String, fallback: Bool) -> Bool { Self.explicitMode(raw[key]) ?? fallback }
    public static func explicitMode(_ value: String?) -> Bool? {
        let value = value?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        if ["1","true","yes","on"].contains(value) { return true }
        if ["0","false","no","off"].contains(value) { return false }
        return nil
    }
    public func number(_ key: String, fallback: Double, minimum: Double, maximum: Double, emptyIsUnset: Bool = true) -> Double {
        guard let value = raw[key], !(emptyIsUnset && value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty),
              let number = JavaScriptCompatibility.number(value), number.isFinite else { return fallback }
        return max(minimum, min(maximum, number))
    }
    public static func timeout(_ raw: String, engine: OCREngineID, views: Int) -> Double {
        let maximum = engine == .vision ? 1_800_000.0 : 3_600_000.0
        let fallback = engine == .vision ? 60_000.0 : 720_000.0
        if !raw.isEmpty, raw.lowercased() != "auto" {
            guard let value = JavaScriptCompatibility.number(raw), value.isFinite else { return fallback }
            return min(maximum, max(10_000, value))
        }
        return min(maximum, max(fallback, (engine == .vision ? 10_000 : 120_000) + Double(max(1, views)) * (engine == .vision ? 15_000 : 45_000)))
    }
}

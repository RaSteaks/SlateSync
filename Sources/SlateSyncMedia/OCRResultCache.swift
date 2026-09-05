import CryptoKit
import Foundation
import SlateSyncDomain

public actor OCRResultCache {
    private var values: [OCREngineID: [String: OCREngineResult]] = [:]
    private var order: [OCREngineID: [String]] = [:]
    private var generation = 0
    public init() {}
    public func currentGeneration() -> Int { generation }
    public func lookup(_ key: String, engine: OCREngineID) -> OCREngineResult? {
        guard let value = values[engine]?[key] else { return nil }
        order[engine, default: []].removeAll { $0 == key }; order[engine, default: []].append(key)
        return value
    }
    public func insert(_ result: OCREngineResult, key: String, generation expected: Int, operation: MediaOperation) {
        guard generation == expected, !operation.isCanceled, result.used, result.blockCount > 0 else { return }
        let engine = result.engine
        values[engine, default: [:]][key] = result
        order[engine, default: []].removeAll { $0 == key }; order[engine, default: []].append(key)
        while order[engine, default: []].count > 8 {
            let removed = order[engine, default: []].removeFirst(); values[engine]?.removeValue(forKey: removed)
        }
    }
    public func clear() { generation += 1; values.removeAll(); order.removeAll() }
    public func remove(_ key: String, engine: OCREngineID) {
        values[engine]?.removeValue(forKey: key); order[engine]?.removeAll { $0 == key }
    }
    public static func key(document: PreparedDocument, engine: OCREngineID, settings: GlobalSettingValues, session: String) throws -> String {
        // Structured JSON separates page/view boundaries and orders. A source
        // filename is not evidence; session and effective output config are.
        struct Key: Encodable { let session: String; let engine: OCREngineID; let pages: [PreparedMediaPage]; let configuration: Data }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys,.withoutEscapingSlashes]
        let config = try engine == .vision ? encoder.encode(VisionOCRConfiguration(settings)) : encoder.encode(PaddleOCRConfiguration(settings))
        return SHA256.hash(data: try encoder.encode(Key(session: session, engine: engine, pages: document.pages, configuration: config))).map { String(format: "%02x", $0) }.joined()
    }
}

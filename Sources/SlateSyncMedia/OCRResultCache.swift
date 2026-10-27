import CryptoKit
import Foundation
import SlateSyncDomain

public actor OCRResultCache {
    private struct Entry { let result: OCREngineResult; let session: String }
    private var values: [OCREngineID: [String: Entry]] = [:]
    private var order: [OCREngineID: [String]] = [:]
    private var generation = 0
    private var sessionGenerations: [String: Int] = [:]
    private let capacity: Int
    public init(capacity: Int = 8) { self.capacity = max(1, capacity) }
    public func currentGeneration(session: String = "") -> Int {
        if let value = sessionGenerations[session] { return value }
        sessionGenerations[session] = generation
        return generation
    }
    public func lookup(_ key: String, engine: OCREngineID) -> OCREngineResult? {
        guard let value = values[engine]?[key] else { return nil }
        order[engine, default: []].removeAll { $0 == key }; order[engine, default: []].append(key)
        return value.result
    }
    public func insert(_ result: OCREngineResult, key: String, generation expected: Int, operation: MediaOperation, session: String = "") {
        guard (sessionGenerations[session] ?? generation) == expected,
              !operation.isCanceled, result.used, result.blockCount > 0 else { return }
        let engine = result.engine
        values[engine, default: [:]][key] = .init(result: result, session: session)
        order[engine, default: []].removeAll { $0 == key }; order[engine, default: []].append(key)
        while order[engine, default: []].count > capacity {
            let removed = order[engine, default: []].removeFirst(); values[engine]?.removeValue(forKey: removed)
        }
    }
    public func clear() { generation += 1; sessionGenerations.removeAll(); values.removeAll(); order.removeAll() }
    public func clear(session: String) {
        // Only this namespace loses its epoch. Other projects' in-flight OCR
        // can still populate their caches after a neighboring project closes.
        generation += 1
        sessionGenerations.removeValue(forKey: session)
        for engine in Array(values.keys) {
            let keys = values[engine, default: [:]].filter { $0.value.session == session }.map(\.key)
            for key in keys { remove(key, engine: engine) }
        }
    }
    public func remove(_ key: String, engine: OCREngineID) {
        values[engine]?.removeValue(forKey: key); order[engine]?.removeAll { $0 == key }
    }
    public static func key(document: PreparedDocument, engine: OCREngineID, settings: GlobalSettingValues, session: String) throws -> String {
        // Structured JSON separates page/view boundaries and orders. A source
        // filename is not evidence; session and effective output config are.
        struct View: Encodable { let index: Int; let type: PreparedViewType; let width: Int; let height: Int; let digest: Data }
        struct Page: Encodable { let number: Int; let views: [View] }
        struct Key: Encodable { let session: String; let engine: OCREngineID; let pages: [Page]; let configuration: Data }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys,.withoutEscapingSlashes]
        let config = try engine == .vision ? encoder.encode(VisionOCRConfiguration(settings)) : encoder.encode(PaddleOCRConfiguration(settings))
        let pages = document.pages.map { page in Page(number: page.pageNumber, views: page.views.map { view in
            .init(index: view.viewIndex, type: view.viewType, width: view.image.width, height: view.image.height,
                  digest: Data(SHA256.hash(data: view.image.jpeg)))
        }) }
        return SHA256.hash(data: try encoder.encode(Key(session: session, engine: engine, pages: pages, configuration: config))).map { String(format: "%02x", $0) }.joined()
    }
}

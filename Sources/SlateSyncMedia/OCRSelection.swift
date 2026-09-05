import Foundation
import SlateSyncDomain

public enum OCRSelectionPolicy {
    /// Capability and execution share this precedence. Required choices never
    /// disappear behind an optional engine; fallback happens only at selection.
    public static func resolve(raw: [String: String], visionAvailable: Bool, paddleAvailable: Bool, autoEnable: Bool = true) -> OCRSelection {
        let r = OCRSettingReader(raw)
        let vr = r.boolean("VISIONOCR_REQUIRED", fallback: false), pr = r.boolean("PADDLEOCR_REQUIRED", fallback: false)
        let vm = OCRSettingReader.explicitMode(raw["VISIONOCR_ENABLED"]), pm = OCRSettingReader.explicitMode(raw["PADDLEOCR_ENABLED"])
        func enabled(_ key: String, _ explicit: Bool?, _ available: Bool) -> Bool {
            if let explicit { return explicit }
            return r.clean(key, fallback: "auto").lowercased() == "auto" && autoEnable && available
        }
        let vision = enabled("VISIONOCR_ENABLED", vm, visionAvailable), paddle = enabled("PADDLEOCR_ENABLED", pm, paddleAvailable)
        if vr { return .init(id: .vision, mode: "required", required: true) }
        if pr { return .init(id: .paddle, mode: "required", required: true) }
        if vm == true { return .init(id: .vision, mode: "explicit") }
        if pm == true { return .init(id: .paddle, mode: "explicit") }
        if vm == false { return paddle ? .init(id: .paddle, mode: "fallback") : .init(id: nil, mode: "disabled") }
        if vision { return .init(id: .vision, mode: "auto") }
        if paddle { return .init(id: .paddle, mode: "auto") }
        return .init(id: nil, mode: "disabled")
    }
}

public actor LocalOCRService {
    private let vision: (any LocalOCREngine)?
    private let paddle: (any LocalOCREngine)?
    private let settings: GlobalSettingValues
    public let selection: OCRSelection
    private let cache = OCRResultCache()
    private var generation = 0
    private var active: [UUID: MediaOperation] = [:]
    private var clearing = false, closed = false
    private var clearTask: Task<Void, Never>?
    public init(vision: (any LocalOCREngine)?, paddle: (any LocalOCREngine)?, settings: GlobalSettingValues, visionAvailable: Bool, paddleAvailable: Bool, autoEnable: Bool = true) {
        self.vision = vision; self.paddle = paddle; self.settings = settings
        selection = OCRSelectionPolicy.resolve(raw: settings.rawValues, visionAvailable: visionAvailable, paddleAvailable: paddleAvailable, autoEnable: autoEnable)
    }
    public func recognize(_ document: PreparedDocument, session: String, cacheEnabled: Bool = true, operation: MediaOperation, progress: MediaProgressSink? = nil) async throws -> OCROutcome {
        try document.validate(); try operation.check()
        guard !clearing, !closed else { throw MediaFailure.closed }
        guard let engineID = selection.id else { return .disabled }
        let id = UUID(), captured = generation
        active[id] = operation
        defer { active.removeValue(forKey: id) }
        let cacheGeneration = await cache.currentGeneration()
        let key = try OCRResultCache.key(document: document, engine: engineID, settings: settings, session: session)
        if cacheEnabled, let result = await cache.lookup(key, engine: engineID) {
            try operation.check(); guard captured == generation else { throw MediaFailure.canceled }
            progress?(.init(stage: "cache-hit", completed: document.viewCount, total: document.viewCount))
            try operation.check()
            return .used(result, cacheHit: true)
        }
        do {
            guard let engine = engineID == .vision ? vision : paddle else { throw MediaFailure.unavailable }
            let result = try await engine.recognize(document, operation: operation, progress: { value in
                if !operation.isCanceled { progress?(value) }
            })
            try operation.check(); guard generation == captured else { throw MediaFailure.canceled }
            guard result.engine == engineID, result.used, result.blockCount > 0,
                  result.pages.flatMap(\.views).flatMap(\.blocks).contains(where: { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else { throw MediaFailure.unavailable }
            if cacheEnabled { await cache.insert(result, key: key, generation: cacheGeneration, operation: operation) }
            try operation.check(); guard generation == captured else { throw MediaFailure.canceled }
            return .used(result, cacheHit: false)
        } catch {
            if operation.isCanceled || MediaFailure.isTerminal(error) || generation != captured {
                // If cancellation won while the cache actor committed, remove
                // this result before reporting the operation as canceled.
                if cacheEnabled { await cache.remove(key, engine: engineID) }
                throw MediaFailure.canceled
            }
            if selection.required { throw SlateSyncError(code: "OCR_REQUIRED", message: "必需的本地 OCR 未产生有效证据", retryable: true) }
            return .degraded(engine: engineID, warning: "本地 OCR 未产生有效证据，将使用页面图片继续识别。")
        }
    }
    public func clearSession() async {
        if let clearTask { await clearTask.value; return }
        clearing = true
        generation += 1
        for operation in active.values { operation.cancel() }
        let task = Task { await self.drainSession() }
        clearTask = task
        await task.value
        clearTask = nil; clearing = false
    }
    private func drainSession() async {
        await cache.clear()
        // Engine calls own the actual work; wait until all late callbacks and
        // results have drained before acknowledging a project/session switch.
        while !active.isEmpty { try? await Task.sleep(for: .milliseconds(5)) }
    }
    public func close() async {
        closed = true
        await clearSession()
        await vision?.close(); await paddle?.close()
    }
    public func summary(_ outcome: OCROutcome) -> OCRSummary {
        .init(outcome: outcome, selection: selection, paddle: selection.id == .paddle ? PaddleOCRConfiguration(settings) : nil)
    }
}

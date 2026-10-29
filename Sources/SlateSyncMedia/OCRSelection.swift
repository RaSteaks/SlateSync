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
    private let cache: OCRResultCache
    private let cacheByView: Bool
    private var generation = 0
    private var active: [UUID: MediaOperation] = [:]
    private var clearing = false, closed = false
    private var clearTask: Task<Void, Never>?
    private var drainWaiters: [CheckedContinuation<Void, Never>] = []
    public init(vision: (any LocalOCREngine)?, paddle: (any LocalOCREngine)?, settings: GlobalSettingValues, visionAvailable: Bool, paddleAvailable: Bool, autoEnable: Bool = true, cacheByView: Bool = false) {
        self.vision = vision; self.paddle = paddle; self.settings = settings
        self.cacheByView = cacheByView
        // 64 views cover the existing 20-page/3-view document bound without
        // retaining raw images. The legacy document cache keeps its 8-entry API.
        cache = OCRResultCache(capacity: cacheByView ? 64 : 8)
        selection = OCRSelectionPolicy.resolve(raw: settings.rawValues, visionAvailable: visionAvailable, paddleAvailable: paddleAvailable, autoEnable: autoEnable)
    }
    public func recognize(_ document: PreparedDocument, session: String, cacheEnabled: Bool = true, operation: MediaOperation, progress: MediaProgressSink? = nil, localImages: [[LocalOCRImage]]? = nil, deadline: OCRDeadline? = nil, allowsEmptyResult: Bool = false) async throws -> OCROutcome {
        try document.validate(); try operation.check()
        try LocalOCRImage.validate(localImages, document: document)
        guard !clearing, !closed else { throw MediaFailure.closed }
        guard let engineID = selection.id else { return .disabled }
        let id = UUID(), captured = generation
        active[id] = operation
        defer {
            active.removeValue(forKey: id)
            if active.isEmpty {
                let waiting = drainWaiters; drainWaiters.removeAll()
                waiting.forEach { $0.resume() }
            }
        }
        let supportsLossless = await supportsLosslessInput
        let effectiveImages = supportsLossless ? localImages : nil
        let useViewCache = cacheByView || effectiveImages != nil
        let cacheGeneration = await cache.currentGeneration(session: session)
        let key = try useViewCache ? "" : OCRResultCache.key(document: document, engine: engineID, settings: settings, session: session)
        let withinDeadline = deadline.map { SystemOCRClock().nowMilliseconds() < $0.end } ?? true
        if cacheEnabled, !useViewCache, withinDeadline, let result = await cache.lookup(key, engine: engineID) {
            try operation.check(); guard captured == generation else { throw MediaFailure.canceled }
            progress?(.init(stage: "cache-hit", completed: document.viewCount, total: document.viewCount))
            try operation.check()
            return .used(result, cacheHit: true)
        }
        do {
            guard let engine = engineID == .vision ? vision : paddle else { throw MediaFailure.unavailable }
            let result: OCREngineResult
            let allCached: Bool
            if useViewCache {
                (result, allCached) = try await recognizeViews(document, engineID: engineID, engine: engine,
                    session: session, cacheEnabled: cacheEnabled, operation: operation, progress: progress,
                    cacheGeneration: cacheGeneration, localImages: effectiveImages, deadline: deadline)
            } else {
                result = try await perform(engine, document: document, localImages: nil, deadline: deadline, operation: operation, progress: { value in
                    if !operation.isCanceled { progress?(value) }
                })
                allCached = false
            }
            try operation.check(); guard generation == captured else { throw MediaFailure.canceled }
            // Staged callers validate nonempty evidence across the complete
            // document, so a blank page does not fail a required OCR batch.
            guard result.engine == engineID, result.used,
                  allowsEmptyResult || result.pages.flatMap(\.views).flatMap(\.blocks).contains(where: { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else { throw MediaFailure.unavailable }
            if cacheEnabled, !useViewCache { await cache.insert(result, key: key, generation: cacheGeneration, operation: operation, session: session) }
            try operation.check(); guard generation == captured else { throw MediaFailure.canceled }
            return .used(result, cacheHit: allCached)
        } catch {
            if operation.isCanceled || MediaFailure.isTerminal(error) || generation != captured {
                // If cancellation won while the cache actor committed, remove
                // this result before reporting the operation as canceled.
                if cacheEnabled { await cache.remove(key, engine: engineID) }
                // CARRY-05：真实取消（operation 被取消、会话代际推进、
                // CancellationError/RECOGNITION_CANCELED）才归并 canceled；
                // 引擎关闭（OCR_CLOSED，如 Paddle worker 进程消失）保留原错误码
                // 向上传播，让上层能区分"服务终止"与"用户取消"并采用不同提示。
                if !operation.isCanceled, generation == captured, MediaFailure.isEngineClosed(error) {
                    throw error
                }
                throw MediaFailure.canceled
            }
            if selection.required { throw SlateSyncError(code: "OCR_REQUIRED", message: "必需的本地 OCR 未产生有效证据", retryable: true) }
            return .degraded(engine: engineID, warning: "本地 OCR 未产生有效证据，将使用页面图片继续识别。")
        }
    }
    private func recognizeViews(_ document: PreparedDocument, engineID: OCREngineID, engine: any LocalOCREngine,
                                session: String, cacheEnabled: Bool, operation: MediaOperation,
                                progress: MediaProgressSink?, cacheGeneration: Int, localImages: [[LocalOCRImage]]?, deadline: OCRDeadline?) async throws -> (OCREngineResult, Bool) {
        let start = ProcessInfo.processInfo.systemUptime
        var evidence: [String: OCREngineResult] = [:]
        var keys: [[String]] = [], missing: [(key: String, image: PreparedImage, local: LocalOCRImage?)] = []
        var scheduled = Set<String>()
        for (pageIndex, page) in document.pages.enumerated() {
            var pageKeys: [String] = []
            for (viewIndex, view) in page.views.enumerated() {
                try operation.check()
                try deadline?.check(clock: SystemOCRClock(), operation: operation)
                // Normalize identity for caching, then batch all misses into one
                // engine lease so document deadlines and worker reuse stay bounded.
                let single = PreparedDocument(filename: "", pages: [.init(pageNumber: 1,
                    views: [.init(viewIndex: 0, viewType: .full, image: view.image)])])
                let local = localImages?[pageIndex][viewIndex]
                let key = try local.map { try OCRResultCache.key(image: $0, engine: engineID, settings: settings, session: session) }
                    ?? OCRResultCache.key(document: single, engine: engineID, settings: settings, session: session)
                pageKeys.append(key)
                if scheduled.insert(key).inserted {
                    if cacheEnabled, let cached = await cache.lookup(key, engine: engineID) { evidence[key] = cached }
                    else { missing.append((key, view.image, local)) }
                }
            }
            keys.append(pageKeys)
        }
        if !missing.isEmpty {
            var batch: [PreparedMediaPage] = []
            var localBatch: [[LocalOCRImage]] = []
            for start in stride(from: 0, to: missing.count, by: 3) {
                let views = missing[start..<min(start + 3, missing.count)].enumerated().map { index, value in
                    PreparedMediaView(viewIndex: index, viewType: index == 0 ? .full : .coreDetail, image: value.image)
                }
                batch.append(.init(pageNumber: batch.count + 1, views: views))
                localBatch.append(missing[start..<min(start + 3, missing.count)].compactMap(\.local))
            }
            let multiplicities = keys.joined().reduce(into: [String: Int]()) { $0[$1, default: 0] += 1 }
            let cachedCount = keys.joined().filter { evidence[$0] != nil }.count
            let progressCounts = missing.reduce(into: [cachedCount]) { counts, view in
                counts.append(counts[counts.count - 1] + multiplicities[view.key, default: 0])
            }
            let result = try await perform(engine, document: .init(filename: document.filename, pages: batch),
                localImages: localImages == nil ? nil : localBatch, deadline: deadline, operation: operation, progress: { value in
                // Duplicate views complete with their shared inference, not
                // before it. Cached views alone contribute to initial progress.
                if !operation.isCanceled {
                    let completed = progressCounts[min(max(0, value.completed), progressCounts.count - 1)]
                    progress?(.init(stage: value.stage, completed: completed, total: document.viewCount))
                }
            })
            let observations = result.pages.flatMap(\.views)
            guard result.engine == engineID, observations.count == missing.count else { throw MediaFailure.protocolError }
            for (input, observed) in zip(missing, observations) {
                try operation.check()
                guard observed.width == input.image.width, observed.height == input.image.height else { throw MediaFailure.protocolError }
                let value = OCREngineResult(engine: engineID, modelVersion: result.modelVersion, used: result.used,
                    pages: [.init(pageNumber: 1, views: [.init(viewIndex: 0, viewType: .full, width: observed.width, height: observed.height,
                        durationMs: observed.durationMs, truncated: observed.truncated, blocks: observed.blocks)])], durationMs: observed.durationMs)
                evidence[input.key] = value
                if cacheEnabled { await cache.insert(value, key: input.key, generation: cacheGeneration, operation: operation, session: session) }
            }
        }
        try operation.check()
        let fresh = Set(missing.map(\.key))
        let pages = try document.pages.enumerated().map { index, page in
            OCRPageEvidence(pageNumber: page.pageNumber, views: try page.views.enumerated().map { viewIndex, view in
                let key = keys[index][viewIndex]
                guard let observed = evidence[key]?.pages.first?.views.first else { throw MediaFailure.protocolError }
                return .init(viewIndex: view.viewIndex, viewType: view.viewType, width: observed.width, height: observed.height,
                    durationMs: fresh.contains(key) ? observed.durationMs : 0, truncated: observed.truncated, blocks: observed.blocks)
            })
        }
        progress?(.init(stage: missing.isEmpty ? "cache-hit" : engineID.rawValue, completed: document.viewCount, total: document.viewCount))
        return (.init(engine: engineID, modelVersion: evidence.values.first?.modelVersion ?? "", used: evidence.values.allSatisfy(\.used), pages: pages,
                      durationMs: Int((ProcessInfo.processInfo.systemUptime - start) * 1000)), cacheEnabled && missing.isEmpty)
    }
    public var supportsLosslessInput: Bool {
        get async {
            guard let id = selection.id,
                  let engine = (id == .vision ? vision : paddle) as? any StagedLocalOCREngine else { return false }
            return await engine.supportsLosslessInput
        }
    }
    public func deadline(views: Int) -> OCRDeadline {
        let timeout = selection.id == .paddle ? PaddleOCRConfiguration(settings).timeoutMilliseconds(views: views)
            : VisionOCRConfiguration(settings).timeoutMilliseconds(views: views)
        return .init(clock: SystemOCRClock(), timeoutMilliseconds: timeout)
    }
    private func perform(_ engine: any LocalOCREngine, document: PreparedDocument, localImages: [[LocalOCRImage]]?,
                         deadline: OCRDeadline?, operation: MediaOperation, progress: MediaProgressSink?) async throws -> OCREngineResult {
        try deadline?.check(clock: SystemOCRClock(), operation: operation)
        let result: OCREngineResult
        if let staged = engine as? any StagedLocalOCREngine {
            result = try await staged.recognize(document, localImages: localImages, deadline: deadline, operation: operation, progress: progress)
        } else {
            result = try await engine.recognize(document, operation: operation, progress: progress)
        }
        try deadline?.check(clock: SystemOCRClock(), operation: operation)
        return result
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
    public func clearCachedSession(_ session: String) async { await cache.clear(session: session) }
    private func drainSession() async {
        await cache.clear()
        // Engine calls own the actual work; wait until all late callbacks and
        // results have drained before acknowledging a project/session switch.
        if !active.isEmpty { await withCheckedContinuation { drainWaiters.append($0) } }
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

import Foundation
import SlateSyncDomain
import Vision

public protocol VisionObservationSource: Sendable {
    func observations(_ image: PreparedImage, configuration: VisionOCRConfiguration, deadline: OCRDeadline, operation: MediaOperation) async throws -> [RawVisionObservation]
    func available(configuration: VisionOCRConfiguration) async -> Bool
}

/// The request, image and results are owned by this actor for the entire
/// synchronous Vision call. Its callback receives the request from Vision and
/// cancels it on the executing thread; no mutable request crosses actors.
public actor NativeVisionObservationSource: VisionObservationSource {
    private let clock: any OCRClock
    public init(clock: any OCRClock = SystemOCRClock()) { self.clock = clock }
    private nonisolated static func makeRequest(_ configuration: VisionOCRConfiguration) -> VNRecognizeTextRequest {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = configuration.recognitionLevel == "fast" ? .fast : .accurate
        request.usesLanguageCorrection = configuration.usesLanguageCorrection
        if configuration.languages.isEmpty { request.automaticallyDetectsLanguage = true }
        else { request.recognitionLanguages = configuration.languages }
        return request
    }
    public func available(configuration: VisionOCRConfiguration) -> Bool {
        guard let languages = try? Self.makeRequest(configuration).supportedRecognitionLanguages() else { return false }
        return configuration.languages.allSatisfy { languages.contains($0) }
    }
    /// 同步 Vision 调用的专用串行队列。VNImageRequestHandler.perform 对
    /// accurate 级别的大图可能长时间阻塞，必须固定在队列线程执行；actor 在
    /// continuation 上挂起等待，不再占用 Swift 协作线程池。
    private static let performQueue = DispatchQueue(label: "com.slatesync.vision.perform", qos: .userInitiated)

    public func observations(_ image: PreparedImage, configuration: VisionOCRConfiguration, deadline: OCRDeadline, operation: MediaOperation) async throws -> [RawVisionObservation] {
        try deadline.check(clock: clock, operation: operation)
        let decoded = try ImageRasterizer.decode(image.jpeg, maximum: 3000)
        let clock = clock
        // VNImageRequestHandler、VNRecognizeTextRequest 和 Vision 的结果类型
        // 都不是 Sendable：它们的整个生命周期（构造、progressHandler、perform、
        // 读取并归一化 results）全部固定在 Vision 专用串行队列闭包内完成，只把
        // Sendable 的识别结论跨回 actor。串行队列对每次调用恰好调度一次闭包，
        // continuation 因此恰好恢复一次，对象也只在队列线程上创建和释放。
        struct Outcome: Sendable { var observations: [RawVisionObservation] }
        do {
            let outcome: Outcome = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Outcome, Error>) in
                Self.performQueue.async {
                    let handler = VNImageRequestHandler(cgImage: decoded)
                    let request = Self.makeRequest(configuration)
                    request.progressHandler = { request, _, _ in
                        if operation.isCanceled || clock.nowMilliseconds() >= deadline.end { request.cancel() }
                    }
                    do { try handler.perform([request]) }
                    catch { return continuation.resume(throwing: error) }
                    request.progressHandler = { _, _, _ in }
                    continuation.resume(returning: Outcome(observations: (request.results ?? []).compactMap { observation in
                        guard let candidate = observation.topCandidates(1).first else { return nil }
                        let b = observation.boundingBox
                        return .init(text: candidate.string, confidence: Double(candidate.confidence), box: .init(x: b.minX, y: b.minY, width: b.width, height: b.height))
                    }))
                }
            }
            // perform 返回后的检查语义不变：同步框架段不会发出进度，返回前
            // 必须再核对一次截止时间与取消状态。
            try deadline.check(clock: clock, operation: operation)
            return outcome.observations
        } catch {
            try deadline.check(clock: clock, operation: operation)
            throw SlateSyncError(code: "VISIONOCR_FAILED", message: "Vision OCR 识别失败", retryable: true)
        }
    }
}

/// The non-Sendable Vision objects never leave the `performQueue` closure
/// that creates them; the serial queue schedules that closure exactly once
/// per call, so the continuation is always resumed exactly once and only the
/// Sendable normalized observations cross back onto the actor.
public actor VisionOCRService: LocalOCREngine, OCRServing, OCRCapabilityProbing {
    private let configuration: VisionOCRConfiguration
    private let source: any VisionObservationSource
    private let clock: any OCRClock
    private let bridge: VisionBridgeAdapter?
    private let leases = OCRLeaseCoordinator()
    private var closed = false
    public init(configuration: VisionOCRConfiguration = .init(), source: (any VisionObservationSource)? = nil, clock: any OCRClock = SystemOCRClock(), runtimeDirectory: URL? = nil, environment: [String: String] = [:]) {
        self.configuration = configuration; self.clock = clock
        self.source = source ?? NativeVisionObservationSource(clock: clock)
        if !configuration.binary.isEmpty, configuration.binary.hasPrefix("/") || runtimeDirectory != nil {
            let base = runtimeDirectory ?? URL(fileURLWithPath: configuration.binary).deletingLastPathComponent()
            bridge = .init(binary: OCRRuntimePaths.resolve(configuration.binary, relativeTo: base), directory: base, environment: environment, clock: clock)
        } else { bridge = nil }
    }
    public func isAvailable() async -> Bool {
        guard !closed else { return false }
        if !configuration.binary.isEmpty { return await bridge?.available() ?? false }
        return await source.available(configuration: configuration)
    }
    public func recognize(_ document: PreparedDocument, operation: MediaOperation = .init(), progress: MediaProgressSink? = nil) async throws -> OCREngineResult {
        try document.validate()
        let deadline = OCRDeadline(clock: clock, timeoutMilliseconds: configuration.timeoutMilliseconds(views: document.viewCount))
        return try await withTaskCancellationHandler {
            guard !closed else { throw MediaFailure.closed }
            let lease = try await leases.acquire(operation: operation, deadline: deadline, clock: clock)
            do {
                let result = try await performRecognition(document, operation: operation, progress: progress, deadline: deadline)
                await leases.release(lease)
                return result
            } catch {
                await leases.release(lease)
                throw error
            }
        } onCancel: { operation.cancel() }
    }

    private func performRecognition(_ document: PreparedDocument, operation: MediaOperation, progress: MediaProgressSink?, deadline: OCRDeadline) async throws -> OCREngineResult {
        if !configuration.binary.isEmpty {
            guard let bridge else { throw SlateSyncError(code: "VISIONOCR_BINARY", message: "Vision OCR 相对路径缺少基准目录") }
            return try await bridge.recognize(document, configuration: configuration, deadline: deadline, operation: operation, progress: progress)
        }
        var pages: [OCRPageEvidence] = [], completed = 0
        let start = clock.nowMilliseconds()
        for page in document.pages {
            var views: [OCRViewEvidence] = []
            for view in page.views {
                try deadline.check(clock: clock, operation: operation)
                let observations = try await source.observations(view.image, configuration: configuration, deadline: deadline, operation: operation)
                try deadline.check(clock: clock, operation: operation)
                views.append(VisionObservationNormalizer.normalize(observations, view: view, configuration: configuration))
                completed += 1
                progress?(.init(stage: "vision", completed: completed, total: document.viewCount))
            }
            pages.append(.init(pageNumber: page.pageNumber, views: views))
        }
        try deadline.check(clock: clock, operation: operation)
        return .init(engine: .vision, modelVersion: "macOS-Vision", pages: pages, durationMs: Int(clock.nowMilliseconds() - start))
    }
    public func recognize(images: [Data]) async throws -> [OCRPageResult] {
        // Legacy flat API retains bottom-left xywh Codable semantics through one
        // explicit adapter, and shares the bounded native recognition pipeline.
        var pages: [PreparedMediaPage] = []
        for (index, data) in images.enumerated() {
            let image = try PreparedImageEncoder.encode(ImageRasterizer.decode(data), maximum: 2600, quality: 0.92)
            pages.append(.init(pageNumber: index + 1, views: [.init(viewIndex: 0, viewType: .full, image: image)]))
        }
        let result = try await recognize(.init(filename: "", pages: pages))
        return try result.pages.map { .init(page: $0.pageNumber, blocks: try $0.views.flatMap(\.blocks).map { try $0.legacyBlock() }) }
    }
    public func close() async {
        closed = true
        await leases.beginClose(permanent: true)
        await bridge?.close()
        await leases.finishClose()
    }
}

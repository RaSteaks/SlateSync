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
    private func request(_ configuration: VisionOCRConfiguration) -> VNRecognizeTextRequest {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = configuration.recognitionLevel == "fast" ? .fast : .accurate
        request.usesLanguageCorrection = configuration.usesLanguageCorrection
        if configuration.languages.isEmpty { request.automaticallyDetectsLanguage = true }
        else { request.recognitionLanguages = configuration.languages }
        return request
    }
    public func available(configuration: VisionOCRConfiguration) -> Bool {
        guard let languages = try? request(configuration).supportedRecognitionLanguages() else { return false }
        return configuration.languages.allSatisfy { languages.contains($0) }
    }
    /// 同步 Vision 调用的专用串行队列。VNImageRequestHandler.perform 对
    /// accurate 级别的大图可能长时间阻塞，必须固定在队列线程执行；actor 在
    /// continuation 上挂起等待，不再占用 Swift 协作线程池。
    private static let performQueue = DispatchQueue(label: "com.slatesync.vision.perform", qos: .userInitiated)

    public func observations(_ image: PreparedImage, configuration: VisionOCRConfiguration, deadline: OCRDeadline, operation: MediaOperation) async throws -> [RawVisionObservation] {
        try deadline.check(clock: clock, operation: operation)
        let decoded = try ImageRasterizer.decode(image.jpeg, maximum: 3000)
        let request = request(configuration)
        let clock = clock
        request.progressHandler = { request, _, _ in
            if operation.isCanceled || clock.nowMilliseconds() >= deadline.end { request.cancel() }
        }
        defer { request.progressHandler = { _, _, _ in } }
        // perform 本身仍是同步阻塞调用，但被移到专用队列上执行；取消依旧
        // 依赖 progressHandler，perform 返回后的检查语义不变。VNImageRequest
        // Handler/VNRecognizeTextRequest 不是 Sendable，队列闭包只捕获下面
        // 这个 queue-owned context（不再捕获裸指针）：passRetained 的所有权
        // 整体移交给 Vision 专用串行队列，在队列线程恰好消费并释放一次。
        let handler = VNImageRequestHandler(cgImage: decoded)
        do {
            _ = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                let context = VisionPerformContext(
                    handler: handler,
                    request: request,
                    continuation: continuation
                )
                Self.performQueue.async { context.perform() }
            }
        } catch {
            try deadline.check(clock: clock, operation: operation)
            throw SlateSyncError(code: "VISIONOCR_FAILED", message: "Vision OCR 识别失败", retryable: true)
        }
        // A synchronous framework section may not issue progress. Always check
        // again, cancel the request, and drain perform() before returning failure.
        do { try deadline.check(clock: clock, operation: operation) }
        catch { request.cancel(); throw error }
        return (request.results ?? []).compactMap { observation in
            guard let candidate = observation.topCandidates(1).first else { return nil }
            let b = observation.boundingBox
            return .init(text: candidate.string, confidence: Double(candidate.confidence), box: .init(x: b.minX, y: b.minY, width: b.width, height: b.height))
        }
    }
}

/// Queue-owned context carrying the retained Vision handler/request and the
/// continuation across the strict-concurrency boundary in one Sendable box —
/// the DispatchQueue closure captures this object and nothing else. The
/// retained objects are consumed and released exactly once, on the Vision
/// serial queue, through the single `perform()` path shared by normal
/// completion, a thrown error, and a cancelled request: `performQueue` is
/// serial, so the consumption flag needs no lock and the continuation is
/// always resumed exactly once.
private final class VisionPerformContext: @unchecked Sendable {
    private let handler: Unmanaged<VNImageRequestHandler>
    private let request: Unmanaged<VNRecognizeTextRequest>
    private let continuation: CheckedContinuation<Void, Error>
    private var consumed = false

    init(handler: VNImageRequestHandler, request: VNRecognizeTextRequest, continuation: CheckedContinuation<Void, Error>) {
        self.handler = Unmanaged.passRetained(handler)
        self.request = Unmanaged.passRetained(request)
        self.continuation = continuation
    }

    /// Runs on the Vision perform queue only; the serial queue guarantees the
    /// single consume-and-release.
    func perform() {
        guard !consumed else { return }
        consumed = true
        let handler = handler.takeRetainedValue()
        let request = request.takeRetainedValue()
        do { try handler.perform([request]); continuation.resume() }
        catch { continuation.resume(throwing: error) }
    }
}

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

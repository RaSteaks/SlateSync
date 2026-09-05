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
    public func observations(_ image: PreparedImage, configuration: VisionOCRConfiguration, deadline: OCRDeadline, operation: MediaOperation) throws -> [RawVisionObservation] {
        try deadline.check(clock: clock, operation: operation)
        let decoded = try ImageRasterizer.decode(image.jpeg, maximum: 3000)
        let request = request(configuration)
        let clock = clock
        request.progressHandler = { request, _, _ in
            if operation.isCanceled || clock.nowMilliseconds() >= deadline.end { request.cancel() }
        }
        defer { request.progressHandler = { _, _, _ in } }
        do { try VNImageRequestHandler(cgImage: decoded).perform([request]) }
        catch {
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

public actor VisionOCRService: LocalOCREngine, OCRServing, OCRCapabilityProbing {
    private let configuration: VisionOCRConfiguration
    private let source: any VisionObservationSource
    private let clock: any OCRClock
    private let bridge: VisionBridgeAdapter?
    private var active: MediaOperation?
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
            while active != nil {
                try deadline.check(clock: clock, operation: operation)
                if closed { throw MediaFailure.closed }
                do { try await clock.sleep(milliseconds: 5) }
                catch is CancellationError { throw MediaFailure.canceled }
            }
            guard !closed else { throw MediaFailure.closed }
            try deadline.check(clock: clock, operation: operation)
            active = operation
            defer { active = nil }
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
        } onCancel: { operation.cancel() }
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
        closed = true; active?.cancel(); await bridge?.close()
        while active != nil { try? await Task.sleep(for: .milliseconds(5)) }
    }
}

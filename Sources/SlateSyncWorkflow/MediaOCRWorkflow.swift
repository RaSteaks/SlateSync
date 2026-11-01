import CryptoKit
import Foundation
import SlateSyncDomain
import SlateSyncMedia

public struct MediaOCRArtifact: Sendable {
    public let document: PreparedDocument
    public let outcome: OCROutcome
    public let selection: OCRSelection
    public let summary: OCRSummary
    public let evidence: [String]
    public let coreEvidence: [String]
    public let sourceDigests: [Int: String]
    public let stageDurationsMs: [String: Int]
    public let observation: ScenarioObservationInput
    public let optimization: RecognitionMediaContext?
}

/// Prepares OCR-quality evidence before independently fitting transfer images.
/// The injectable consumer is a handoff, with no Provider transport,
/// retry policy or Scenario persistence introduced in this phase.
public actor MediaOCRWorkflow {
    public typealias Consumer = @Sendable (MediaOCRArtifact, MediaOperation) async throws -> Void
    private let preparation: any MediaPreparing
    private let compression: any MediaRecompressing
    private let ocr: LocalOCRService
    private let ownsOCR: Bool
    private let policy: RecognitionOptimizationPolicy
    private var generation = 0
    private var closed = false
    private var session: String?
    private var active: (id: Int, operation: MediaOperation, task: Task<MediaOCRArtifact, any Error>)?
    public init(preparation: any MediaPreparing = MediaPreparationService(), compression: any MediaRecompressing = MediaPreparationService(), ocr: LocalOCRService, ownsOCR: Bool = true, policy: RecognitionOptimizationPolicy = .baseline) {
        self.preparation = preparation; self.compression = compression; self.ocr = ocr; self.ownsOCR = ownsOCR; self.policy = policy
    }
    public func run(input: MediaInput, session requestedSession: String, accuracy: MediaAccuracy = .high, options: MediaPreparationOptions = .init(), cacheEnabled: Bool = true, legacyRequest: Data? = nil, maxRequestBytes: Int = 80 * 1024 * 1024, measure: (@Sendable (PreparedDocument) throws -> Int)? = nil, progress: MediaProgressSink? = nil, consume: Consumer? = nil, preparedDocument: PreparedDocument? = nil) async throws -> MediaOCRArtifact {
        if let legacyRequest { try PreparedDocument.rejectLegacyPDF(in: legacyRequest) }
        guard !closed else { throw MediaFailure.closed }
        generation += 1
        let id = generation
        if let previous = active {
            previous.operation.cancel(); previous.task.cancel()
            _ = try? await previous.task.value
        }
        guard id == generation, !closed else { throw MediaFailure.canceled }
        if session != requestedSession {
            if ownsOCR { await ocr.clearSession() }
            guard id == generation, !closed else { throw MediaFailure.canceled }
            session = requestedSession
        }
        let operation = MediaOperation(), preparation = preparation, compression = compression, ocr = ocr, policy = policy
        let task = Task {
            let started = ProcessInfo.processInfo.systemUptime
            try operation.check()
            // A native preview can hand off its already prepared pages without
            // rasterizing the original file again. It still passes the same
            // validation, selection, request budget, OCR and cancellation path.
            let ocrDocument: PreparedDocument
            let outcome: OCROutcome
            let preparedAt: Double
            var context: RecognitionMediaContext?
            if policy != .baseline, preparedDocument == nil, let native = preparation as? MediaPreparationService {
                let source = try await native.recognitionSource(input, maximumInputBytes: options.maximumInputBytes, operation: operation)
                let optimized = try await OptimizedMediaOCR.run(source: source, ocr: ocr, policy: policy,
                    includesDetails: options.includesDetails && accuracy == .high, session: requestedSession,
                    cacheEnabled: cacheEnabled, operation: operation, progress: progress)
                ocrDocument = optimized.document; outcome = optimized.outcome
                preparedAt = started
                context = .init(policy: policy, source: source, structures: optimized.structures,
                    fullMappings: optimized.fullMappings, diagnostics: optimized.diagnostics)
            } else {
                let retained: PreparedDocument
                if let preparedDocument {
                    try preparedDocument.validate()
                    retained = preparedDocument
                } else {
                    retained = try await preparation.prepare(input,
                        options: .init(maximumInputBytes: options.maximumInputBytes, includesDetails: options.includesDetails && accuracy == .high),
                        operation: operation, progress: progress)
                }
                try operation.check()
                preparedAt = ProcessInfo.processInfo.systemUptime
                ocrDocument = retained.selected(accuracy)
                outcome = try await ocr.recognize(ocrDocument, session: requestedSession, cacheEnabled: cacheEnabled, operation: operation, progress: progress)
                if policy != .baseline {
                    // Restored views lack trustworthy source transforms. Do not
                    // guess their relationship to an input file or stitched crop.
                    context = .init(policy: policy, source: nil, structures: [:], fullMappings: [:],
                        diagnostics: ["已有视图或媒体适配器缺少原页映射，使用兼容识别路径。"])
                }
            }
            let recognizedAt = ProcessInfo.processInfo.systemUptime
            // Provider byte limits must not lower local OCR quality. Compression
            // changes transfer images only; normalized OCR coordinates still align.
            var selected = ocrDocument
            if let measure { selected = try await MediaRequestBudget.fit(selected, maxRequestBytes: maxRequestBytes, compressor: compression, operation: operation, measure: measure) }
            try operation.check()
            let selection = await ocr.selection
            let sourceDigests = Dictionary(uniqueKeysWithValues: ocrDocument.pages.map { page in
                (page.pageNumber, "page:\(page.pageNumber):" + SHA256.hash(data: page.views[0].image.jpeg).map { String(format: "%02x", $0) }.joined())
            })
            let artifact = MediaOCRArtifact(document: selected, outcome: outcome, selection: selection, summary: await ocr.summary(outcome),
                evidence: (outcome.result?.pages ?? []).map { OCREvidenceFormatter.format($0, engine: outcome.result?.engine.rawValue ?? "local") },
                coreEvidence: (outcome.result?.pages ?? []).map { OCREvidenceFormatter.format($0, engine: outcome.result?.engine.rawValue ?? "local", core: true) },
                sourceDigests: sourceDigests,
                stageDurationsMs: context?.source != nil ? ["prepareOCR": Int((recognizedAt - started) * 1000),
                    "transfer": Int((ProcessInfo.processInfo.systemUptime - recognizedAt) * 1000)] : ["prepare": Int((preparedAt - started) * 1000), "ocr": Int((recognizedAt - preparedAt) * 1000),
                                   "transfer": Int((ProcessInfo.processInfo.systemUptime - recognizedAt) * 1000)],
                observation: ScenarioOCRAdapter.observation(filename: selected.filename, outcome: outcome), optimization: context)
            try operation.check()
            if let consume { try await consume(artifact, operation) }
            try operation.check()
            return artifact
        }
        active = (id,operation,task)
        defer { if active?.id == id { active = nil } }
        return try await withTaskCancellationHandler {
            let result = try await task.value
            try operation.check()
            guard id == generation, !closed else { throw MediaFailure.canceled }
            return result
        } onCancel: { operation.cancel(); task.cancel() }
    }
    public func cancel() async {
        generation += 1
        if let active { active.operation.cancel(); active.task.cancel(); _ = try? await active.task.value }
    }
    public func close() async {
        closed = true; await cancel()
        // Shared engines are closed by the coordinator after every task drains.
        if ownsOCR { await ocr.close() }
    }
}

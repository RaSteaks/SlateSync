import Foundation
import SlateSyncDomain
import SlateSyncMedia

public struct MediaOCRArtifact: Sendable {
    public let document: PreparedDocument
    public let outcome: OCROutcome
    public let selection: OCRSelection
    public let summary: OCRSummary
    public let evidence: [String]
    public let observation: ScenarioObservationInput
}

/// A focused local façade for SM-07: prepare -> select/compress -> OCR ->
/// evidence. The injectable consumer is a handoff, with no Provider transport,
/// retry policy or Scenario persistence introduced in this phase.
public actor MediaOCRWorkflow {
    public typealias Consumer = @Sendable (MediaOCRArtifact, MediaOperation) async throws -> Void
    private let preparation: any MediaPreparing
    private let compression: any MediaRecompressing
    private let ocr: LocalOCRService
    private var generation = 0
    private var closed = false
    private var session: String?
    private var active: (id: Int, operation: MediaOperation, task: Task<MediaOCRArtifact, any Error>)?
    public init(preparation: any MediaPreparing = MediaPreparationService(), compression: any MediaRecompressing = MediaPreparationService(), ocr: LocalOCRService) {
        self.preparation = preparation; self.compression = compression; self.ocr = ocr
    }
    public func run(input: MediaInput, session requestedSession: String, accuracy: MediaAccuracy = .high, options: MediaPreparationOptions = .init(), cacheEnabled: Bool = true, legacyRequest: Data? = nil, maxRequestBytes: Int = 80 * 1024 * 1024, measure: (@Sendable (PreparedDocument) throws -> Int)? = nil, progress: MediaProgressSink? = nil, consume: Consumer? = nil) async throws -> MediaOCRArtifact {
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
            await ocr.clearSession()
            guard id == generation, !closed else { throw MediaFailure.canceled }
            session = requestedSession
        }
        let operation = MediaOperation(), preparation = preparation, compression = compression, ocr = ocr
        let task = Task {
            try operation.check()
            let retained = try await preparation.prepare(input, options: options, operation: operation, progress: progress)
            try operation.check()
            var selected = retained.selected(accuracy)
            if let measure { selected = try await MediaRequestBudget.fit(selected, maxRequestBytes: maxRequestBytes, compressor: compression, operation: operation, measure: measure) }
            let outcome = try await ocr.recognize(selected, session: requestedSession, cacheEnabled: cacheEnabled, operation: operation, progress: progress)
            try operation.check()
            let selection = await ocr.selection
            let artifact = MediaOCRArtifact(document: selected, outcome: outcome, selection: selection, summary: await ocr.summary(outcome), evidence: (outcome.result?.pages ?? []).map { OCREvidenceFormatter.format($0, engine: outcome.result?.engine.rawValue ?? "local") }, observation: ScenarioOCRAdapter.observation(filename: selected.filename, outcome: outcome))
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
        closed = true; await cancel(); await ocr.close()
    }
}

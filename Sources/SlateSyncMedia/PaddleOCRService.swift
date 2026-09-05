import Foundation
import SlateSyncDomain

/// One immutable settings snapshot drives probes, preload and recognition;
/// shutdown also drains standalone capability probes owned by this service.
public actor PaddleOCRService: LocalOCREngine, OCRCapabilityProbing {
    private let configuration: PaddleOCRConfiguration
    private let supervisor: OCRProcessSupervisor
    private let paths: OCRRuntimePaths
    private let clock: any OCRClock
    private var closed = false
    private var probes: [UUID: ManagedOCRProcess] = [:]
    public init(configuration: PaddleOCRConfiguration = .init(), paths: OCRRuntimePaths, supervisor: OCRProcessSupervisor? = nil, clock: any OCRClock = SystemOCRClock()) {
        self.configuration = configuration; self.paths = paths; self.clock = clock
        self.supervisor = supervisor ?? OCRProcessSupervisor(paths: paths, clock: clock)
    }
    public func preload(operation: MediaOperation = .init()) async throws {
        guard !closed else { throw MediaFailure.closed }
        _ = try await supervisor.execute(configuration: configuration, document: nil, operation: operation)
    }
    public func recognize(_ document: PreparedDocument, operation: MediaOperation, progress: MediaProgressSink?) async throws -> OCREngineResult {
        try document.validate(); try operation.check()
        guard !closed else { throw MediaFailure.closed }
        guard let data = try await supervisor.execute(configuration: configuration, document: document, operation: operation, progress: progress) else { throw MediaFailure.protocolError }
        try operation.check()
        return try OCRResponseNormalizer.decode(data, engine: .paddle, fallbackModel: configuration.modelVersion, document: document)
    }
    public func check(operation: MediaOperation = .init()) async throws -> Data {
        guard !closed else { throw MediaFailure.closed }
        try paths.validate()
        let process = ManagedOCRProcess(launch: .init(executable: paths.python, arguments: [paths.runner.path,"--check"], directory: paths.workingDirectory, environment: paths.environment), clock: clock)
        let id = UUID(); probes[id] = process
        defer { probes.removeValue(forKey: id) }
        let result = try await process.exchange(Data(), requestID: nil, oneShot: true, deadline: .init(clock: clock, timeoutMilliseconds: 120_000), operation: operation, progress: nil)
        await process.close(); try OCRProcessSupervisor.requireSuccess(result)
        guard !closed else { throw MediaFailure.closed }
        return result
    }
    public func isAvailable() async -> Bool { (try? await check()) != nil }
    public func close() async {
        closed = true
        for probe in probes.values { await probe.close() }
        await supervisor.close(shutdown: true)
    }
}

enum OCRResponseNormalizer {
    static func decode(_ data: Data, engine: OCREngineID, fallbackModel: String, document: PreparedDocument) throws -> OCREngineResult {
        struct Response: Decodable { let ok: Bool; let modelVersion: String?; let durationMs: Int?; let pages: [OCRPageEvidence] }
        guard let response = try? JSONDecoder().decode(Response.self, from: data), response.ok,
              response.pages.count == document.pages.count else { throw MediaFailure.protocolError }
        var pages: [OCRPageEvidence] = []
        for (page, prepared) in zip(response.pages, document.pages) {
            guard page.pageNumber == prepared.pageNumber, page.views.count == prepared.views.count else { throw MediaFailure.protocolError }
            var views: [OCRViewEvidence] = []
            for (view, original) in zip(page.views, prepared.views) {
                guard view.viewIndex == original.viewIndex, view.viewType == original.viewType, view.width == original.image.width, view.height == original.image.height else { throw MediaFailure.protocolError }
                let blocks = view.blocks.compactMap { block -> OCRTextBlock? in
                    let text = block.text.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !text.isEmpty, block.bboxNormalized.count == 4, block.bboxNormalized.allSatisfy(\.isFinite), block.bbox.count == 4, block.confidence.isFinite else { return nil }
                    return .init(order: block.order, text: text, confidence: max(0,min(1,block.confidence)), bbox: block.bbox, bboxNormalized: block.bboxNormalized)
                }
                views.append(.init(viewIndex: view.viewIndex, viewType: view.viewType, width: view.width, height: view.height, durationMs: view.durationMs, truncated: view.truncated, blocks: blocks))
            }
            pages.append(.init(pageNumber: page.pageNumber, views: views))
        }
        return .init(engine: engine, modelVersion: response.modelVersion ?? fallbackModel, pages: pages, durationMs: response.durationMs ?? 0)
    }
}

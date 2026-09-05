import Foundation
import SlateSyncDomain

/// Explicit VISIONOCR_BINARY preserves the legacy stdin/sentinel protocol.
/// Relative paths resolve only against an injected base; no runtime compilation.
public actor VisionBridgeAdapter {
    private let binary: URL
    private let directory: URL
    private let environment: [String: String]
    private let clock: any OCRClock
    private var process: ManagedOCRProcess?
    private var probes: [UUID: ManagedOCRProcess] = [:]
    private var closed = false
    public init(binary: URL, directory: URL, environment: [String: String], clock: any OCRClock = SystemOCRClock()) {
        self.binary = binary; self.directory = directory; self.environment = OCRChildEnvironment.make(environment); self.clock = clock
    }
    public func available() async -> Bool {
        guard !closed, FileManager.default.isExecutableFile(atPath: binary.path) else { return false }
        let probe = ManagedOCRProcess(launch: .init(executable: binary, arguments: ["--check"], directory: directory, environment: environment), clock: clock)
        let id = UUID(); probes[id] = probe
        defer { probes.removeValue(forKey: id) }
        do {
            let response = try await probe.exchange(Data(), requestID: nil, oneShot: true, deadline: .init(clock: clock, timeoutMilliseconds: 120_000), operation: .init(), progress: nil)
            await probe.close(); try OCRProcessSupervisor.requireSuccess(response)
            return !closed
        } catch { await probe.close(); return false }
    }
    public func recognize(_ document: PreparedDocument, configuration: VisionOCRConfiguration, deadline: OCRDeadline, operation: MediaOperation, progress: MediaProgressSink?) async throws -> OCREngineResult {
        guard !closed else { throw MediaFailure.closed }
        guard FileManager.default.isExecutableFile(atPath: binary.path) else { throw SlateSyncError(code: "VISIONOCR_BINARY", message: "配置的 Vision OCR bridge 不可执行") }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.withoutEscapingSlashes]
        var payload = try JSONDecoder().decode([String: JSONValue].self, from: encoder.encode(configuration))
        payload["pages"] = .array(document.pages.map { page in .object(["pageNumber":.number(Double(page.pageNumber)),"images":.array(page.views.map { .string($0.image.dataURL) })]) })
        let process = ManagedOCRProcess(launch: .init(executable: binary, arguments: [], directory: directory, environment: environment), clock: clock)
        self.process = process
        do {
            let data = try await process.exchange(encoder.encode(payload), requestID: nil, oneShot: true, deadline: deadline, operation: operation, progress: progress)
            await process.close(); self.process = nil
            return try OCRResponseNormalizer.decode(data, engine: .vision, fallbackModel: "macOS-Vision", document: document)
        } catch { await process.close(); self.process = nil; throw error }
    }
    public func close() async {
        closed = true
        await process?.close()
        for probe in probes.values { await probe.close() }
    }
}

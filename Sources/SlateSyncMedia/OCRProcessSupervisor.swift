import Foundation
import SlateSyncDomain

/// The resident worker has exactly one active lease. Its deadline is created
/// before joining the queue; canceling a waiter cannot kill another lease.
public actor OCRProcessSupervisor {
    public struct Snapshot: Sendable { public let active: Int; public let pending: Int; public let launches: Int; public let warmups: Int; public let hasWorker: Bool }
    private let paths: OCRRuntimePaths
    private let clock: any OCRClock
    private let factory: @Sendable (OCRProcessLaunch) -> any OCRProcessTransport
    private var worker: (any OCRProcessTransport)?
    private var workerKey: Data?
    private var active: MediaOperation?
    private var pending = 0, generation = 0, launches = 0, warmups = 0
    private var shutdown = false
    private var closingTask: Task<Void, Never>?
    public init(paths: OCRRuntimePaths, clock: any OCRClock = SystemOCRClock(), factory: (@Sendable (OCRProcessLaunch) -> any OCRProcessTransport)? = nil) {
        self.paths = paths; self.clock = clock
        self.factory = factory ?? { ManagedOCRProcess(launch: $0, clock: clock) }
    }
    public func snapshot() -> Snapshot { .init(active: active == nil ? 0 : 1, pending: max(0,pending - (active == nil ? 0 : 1)), launches: launches, warmups: warmups, hasWorker: worker != nil) }

    public func execute(configuration: PaddleOCRConfiguration, document: PreparedDocument?, operation: MediaOperation, progress: MediaProgressSink? = nil, deadline explicitDeadline: OCRDeadline? = nil) async throws -> Data? {
        let deadline = explicitDeadline ?? OCRDeadline(clock: clock, timeoutMilliseconds: configuration.timeoutMilliseconds(views: document?.viewCount ?? 1))
        let capturedGeneration = generation
        pending += 1
        defer { pending -= 1 }
        return try await withTaskCancellationHandler {
            while active != nil {
                try check(capturedGeneration, deadline, operation)
                do { try await clock.sleep(milliseconds: 5) }
                catch is CancellationError { throw MediaFailure.canceled }
            }
            try check(capturedGeneration, deadline, operation)
            active = operation
            defer { active = nil }
            do {
                try paths.validate()
                let payload = try Self.payload(configuration, document: document)
                let key = try Self.payload(configuration, document: nil)
                if workerKey != key {
                    await shutdownIdleWorker(); worker = nil; workerKey = nil
                    try check(capturedGeneration, deadline, operation)
                }
                if worker == nil {
                    worker = makeProcess(server: true)
                    let id = UUID().uuidString
                    let warmup = try Self.envelope(key, type: "warmup", id: id)
                    guard let worker else { throw MediaFailure.closed }
                    let response = try await worker.exchange(warmup, requestID: id, oneShot: false, deadline: deadline, operation: operation, progress: progress)
                    try Self.requireSuccess(response)
                    try check(capturedGeneration, deadline, operation)
                    workerKey = key; warmups += 1
                }
                guard document != nil else { return nil }
                let id = UUID().uuidString
                guard let worker else { throw MediaFailure.closed }
                let response = try await worker.exchange(Self.envelope(payload, type: "recognize", id: id), requestID: id, oneShot: false, deadline: deadline, operation: operation, progress: progress)
                try Self.requireSuccess(response)
                try check(capturedGeneration, deadline, operation)
                return response
            } catch {
                await worker?.close(); worker = nil; workerKey = nil
                if operation.isCanceled || error is CancellationError { throw MediaFailure.canceled }
                try check(capturedGeneration, deadline, operation)
                let code = (error as? SlateSyncError)?.code ?? ""
                // Only transport startup/exit/unsupported-server faults recover.
                // Malformed evidence, cancellation and expired deadlines do not.
                guard document != nil, ["OCR_PROCESS_START","OCR_PROCESS_EXIT","OCR_SERVER_UNSUPPORTED"].contains(code) else { throw error }
                let fallback = makeProcess(server: false)
                worker = fallback
                do {
                    let result = try await fallback.exchange(Self.payload(configuration, document: document), requestID: nil, oneShot: true, deadline: deadline, operation: operation, progress: progress)
                    await fallback.close(); worker = nil
                    try check(capturedGeneration, deadline, operation)
                    try Self.requireSuccess(result)
                    return result
                } catch {
                    await fallback.close(); worker = nil
                    if operation.isCanceled || error is CancellationError { throw MediaFailure.canceled }
                    throw error
                }
            }
        } onCancel: { operation.cancel() }
    }
    private func check(_ expected: Int, _ deadline: OCRDeadline, _ operation: MediaOperation) throws {
        try deadline.check(clock: clock, operation: operation)
        guard !shutdown, closingTask == nil, generation == expected else { throw MediaFailure.closed }
    }
    private func makeProcess(server: Bool) -> any OCRProcessTransport {
        launches += 1
        return factory(.init(executable: paths.python, arguments: [paths.runner.path] + (server ? ["--server"] : []), directory: paths.workingDirectory, environment: paths.environment))
    }
    public func close(shutdown permanent: Bool = false) async {
        if permanent { shutdown = true }
        if let closingTask { await closingTask.value; return }
        generation += 1; active?.cancel()
        let task = Task { await self.drainAndClose() }
        closingTask = task
        await task.value
        closingTask = nil
    }
    private func drainAndClose() async {
        if active == nil { await shutdownIdleWorker() }
        else { await worker?.close() }
        while active != nil || pending > 0 { try? await Task.sleep(for: .milliseconds(5)) }
        worker = nil; workerKey = nil
    }
    private func shutdownIdleWorker() async {
        guard let worker else { return }
        // Idle configuration changes and normal shutdown use the runner's
        // protocol. Active cancellation always uses the bounded signal path.
        let id = UUID().uuidString
        if let request = try? Self.envelope(Data("{}".utf8), type: "shutdown", id: id) {
            _ = try? await worker.exchange(request, requestID: id, oneShot: false, deadline: .init(clock: clock, timeoutMilliseconds: 5000), operation: .init(), progress: nil)
        }
        await worker.close()
    }
    static func payload(_ configuration: PaddleOCRConfiguration, document: PreparedDocument?) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys,.withoutEscapingSlashes]
        var object = try JSONDecoder().decode([String: JSONValue].self, from: encoder.encode(configuration))
        object.removeValue(forKey: "timeout"); object.removeValue(forKey: "preset")
        if let document {
            object["pages"] = .array(document.pages.map { page in
                .object(["pageNumber": .number(Double(page.pageNumber)), "images": .array(page.views.map { .string($0.image.dataURL) })])
            })
        }
        return try encoder.encode(object)
    }
    private static func envelope(_ payload: Data, type: String, id: String) throws -> Data {
        let value = try JSONDecoder().decode(JSONValue.self, from: payload)
        var object: [String: JSONValue]
        if type == "recognize" { object = ["payload": value] }
        else if case .object(let fields) = value { object = fields }
        else { throw MediaFailure.protocolError }
        object["type"] = .string(type); object["requestId"] = .string(id)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys,.withoutEscapingSlashes]
        return try encoder.encode(object) + Data([10])
    }
    static func requireSuccess(_ data: Data) throws {
        struct Response: Decodable { struct Failure: Decodable { let code: String? }; let ok: Bool; let error: Failure? }
        guard let response = try? JSONDecoder().decode(Response.self, from: data) else { throw MediaFailure.protocolError }
        if !response.ok {
            if ["unsupported_request","unknown_request","invalid_type"].contains(response.error?.code ?? "") { throw SlateSyncError(code: "OCR_SERVER_UNSUPPORTED", message: "OCR 常驻协议不可用") }
            throw MediaFailure.unavailable
        }
    }
}

import Foundation
import SlateSyncDomain

/// The resident worker has exactly one active lease. Its deadline is created
/// before joining the queue; canceling a waiter cannot kill another lease.
public actor OCRProcessSupervisor {
    public struct Snapshot: Sendable { public let active: Int; public let pending: Int; public let launches: Int; public let warmups: Int; public let hasWorker: Bool }
    private let paths: OCRRuntimePaths
    private let clock: any OCRClock
    private let factory: @Sendable (OCRProcessLaunch) -> any OCRProcessTransport
    private let leases = OCRLeaseCoordinator()
    private var worker: (any OCRProcessTransport)?
    private var workerKey: Data?
    private var launches = 0, warmups = 0
    private var closingTask: Task<Void, Never>?
    public init(paths: OCRRuntimePaths, clock: any OCRClock = SystemOCRClock(), factory: (@Sendable (OCRProcessLaunch) -> any OCRProcessTransport)? = nil) {
        self.paths = paths; self.clock = clock
        self.factory = factory ?? { ManagedOCRProcess(launch: $0, clock: clock) }
    }
    public func snapshot() async -> Snapshot {
        let leaseSnapshot = await leases.snapshot()
        return .init(active: leaseSnapshot.active, pending: leaseSnapshot.pending, launches: launches, warmups: warmups, hasWorker: worker != nil)
    }

    public func execute(configuration: PaddleOCRConfiguration, document: PreparedDocument?, operation: MediaOperation, progress: MediaProgressSink? = nil, deadline explicitDeadline: OCRDeadline? = nil) async throws -> Data? {
        let deadline = explicitDeadline ?? OCRDeadline(clock: clock, timeoutMilliseconds: configuration.timeoutMilliseconds(views: document?.viewCount ?? 1))
        return try await withTaskCancellationHandler {
            let lease = try await leases.acquire(operation: operation, deadline: deadline, clock: clock)
            do {
                let result = try await perform(configuration: configuration, document: document, operation: operation, progress: progress, deadline: deadline)
                await leases.release(lease)
                return result
            } catch {
                await leases.release(lease)
                throw error
            }
        } onCancel: { operation.cancel() }
    }

    private func perform(configuration: PaddleOCRConfiguration, document: PreparedDocument?, operation: MediaOperation, progress: MediaProgressSink?, deadline: OCRDeadline) async throws -> Data? {
        do {
            try paths.validate()
            let payload = try Self.payload(configuration, document: document)
            let key = try Self.payload(configuration, document: nil)
            if workerKey != key {
                await shutdownIdleWorker(); worker = nil; workerKey = nil
                try deadline.check(clock: clock, operation: operation)
            }
            if worker == nil {
                worker = makeProcess(server: true)
                let id = UUID().uuidString
                let warmup = try Self.warmupEnvelope(configuration, id: id)
                guard let worker else { throw MediaFailure.closed }
                let response = try await worker.exchange(warmup, requestID: id, oneShot: false, deadline: deadline, operation: operation, progress: progress)
                try Self.requireSuccess(response)
                try deadline.check(clock: clock, operation: operation)
                workerKey = key; warmups += 1
            }
            guard document != nil else { return nil }
            let id = UUID().uuidString
            guard let worker else { throw MediaFailure.closed }
            let response = try await worker.exchange(Self.recognitionEnvelope(payload, id: id), requestID: id, oneShot: false, deadline: deadline, operation: operation, progress: progress)
            try Self.requireSuccess(response)
            try deadline.check(clock: clock, operation: operation)
            return response
        } catch {
            await worker?.close(); worker = nil; workerKey = nil
            if operation.isCanceled || error is CancellationError { throw MediaFailure.canceled }
            try deadline.check(clock: clock, operation: operation)
            let code = (error as? SlateSyncError)?.code ?? ""
            // Only transport startup/exit/unsupported-server faults recover.
            // Malformed evidence, cancellation and expired deadlines do not.
            guard document != nil, ["OCR_PROCESS_START","OCR_PROCESS_EXIT","OCR_SERVER_UNSUPPORTED"].contains(code) else { throw error }
            let fallback = makeProcess(server: false)
            worker = fallback
            do {
                let result = try await fallback.exchange(Self.payload(configuration, document: document), requestID: nil, oneShot: true, deadline: deadline, operation: operation, progress: progress)
                await fallback.close(); worker = nil
                try deadline.check(clock: clock, operation: operation)
                try Self.requireSuccess(result)
                return result
            } catch {
                await fallback.close(); worker = nil
                if operation.isCanceled || error is CancellationError { throw MediaFailure.canceled }
                throw error
            }
        }
    }
    private func makeProcess(server: Bool) -> any OCRProcessTransport {
        launches += 1
        return factory(.init(executable: paths.python, arguments: [paths.runner.path] + (server ? ["--server"] : []), directory: paths.workingDirectory, environment: paths.environment))
    }
    public func close(shutdown permanent: Bool = false) async {
        if let closingTask {
            // A permanent close arriving during a temporary close upgrades the
            // coordinator state before both callers join the same drain task.
            if permanent { await leases.beginClose(permanent: true) }
            await closingTask.value
            return
        }
        let task = Task { await self.drainAndClose(permanent: permanent) }
        closingTask = task
        await task.value
        closingTask = nil
    }
    private func drainAndClose(permanent: Bool) async {
        await leases.beginClose(permanent: permanent)
        let leaseSnapshot = await leases.snapshot()
        if leaseSnapshot.active == 0 { await shutdownIdleWorker() }
        else { await worker?.close() }
        await leases.finishClose()
        worker = nil; workerKey = nil
    }
    private func shutdownIdleWorker() async {
        guard let worker else { return }
        // Idle configuration changes and normal shutdown use the runner's
        // protocol. Active cancellation always uses the bounded signal path.
        let id = UUID().uuidString
        if let request = try? Self.shutdownEnvelope(id: id) {
            _ = try? await worker.exchange(request, requestID: id, oneShot: false, deadline: .init(clock: clock, timeoutMilliseconds: 5000), operation: .init(), progress: nil)
        }
        await worker.close()
    }
    static func payload(_ configuration: PaddleOCRConfiguration, document: PreparedDocument?) throws -> Data {
        try wireEncoder().encode(WirePayload(configuration: configuration, document: document))
    }

    static func recognitionEnvelope(_ payload: Data, id: String) throws -> Data {
        // payload is produced by WirePayload above. Splicing it once avoids
        // decoding and re-encoding tens of MB of Base64 while preserving the
        // sorted-key wire bytes required by the Python server.
        guard payload.first == 123, payload.last == 125 else { throw MediaFailure.protocolError }
        var data = Data("{\"payload\":".utf8)
        data.append(payload)
        data.append(Data(",\"requestId\":".utf8))
        data.append(try wireEncoder().encode(id))
        data.append(Data(",\"type\":\"recognize\"}\n".utf8))
        return data
    }

    static func warmupEnvelope(_ configuration: PaddleOCRConfiguration, id: String) throws -> Data {
        try wireEncoder().encode(WarmupEnvelope(configuration: configuration, requestId: id)) + Data([10])
    }

    static func shutdownEnvelope(id: String) throws -> Data {
        try wireEncoder().encode(ControlEnvelope(requestId: id, type: "shutdown")) + Data([10])
    }

    private static func wireEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    private struct WirePage: Encodable {
        let pageNumber: Int
        let images: [String]
    }

    private struct WirePayload: Encodable {
        let device: String
        let detectionModel: String
        let language: String
        let maxBlocksPerView: Int
        let minimumConfidence: Double
        let modelVersion: String
        let pages: [WirePage]?
        let profile: String
        let recognitionBatchSize: Int
        let recognitionModel: String
        let textDetLimitSideLen: Int

        init(configuration: PaddleOCRConfiguration, document: PreparedDocument?) {
            device = configuration.device
            detectionModel = configuration.detectionModel
            language = configuration.language
            maxBlocksPerView = configuration.maxBlocksPerView
            minimumConfidence = configuration.minimumConfidence
            modelVersion = configuration.modelVersion
            pages = document?.pages.map {
                .init(pageNumber: $0.pageNumber, images: $0.views.map(\.image.dataURL))
            }
            profile = configuration.profile
            recognitionBatchSize = configuration.recognitionBatchSize
            recognitionModel = configuration.recognitionModel
            textDetLimitSideLen = configuration.textDetLimitSideLen
        }
    }

    private struct WarmupEnvelope: Encodable {
        let device: String
        let detectionModel: String
        let language: String
        let maxBlocksPerView: Int
        let minimumConfidence: Double
        let modelVersion: String
        let profile: String
        let recognitionBatchSize: Int
        let recognitionModel: String
        let requestId: String
        let textDetLimitSideLen: Int
        let type = "warmup"

        init(configuration: PaddleOCRConfiguration, requestId: String) {
            device = configuration.device
            detectionModel = configuration.detectionModel
            language = configuration.language
            maxBlocksPerView = configuration.maxBlocksPerView
            minimumConfidence = configuration.minimumConfidence
            modelVersion = configuration.modelVersion
            profile = configuration.profile
            recognitionBatchSize = configuration.recognitionBatchSize
            recognitionModel = configuration.recognitionModel
            self.requestId = requestId
            textDetLimitSideLen = configuration.textDetLimitSideLen
        }
    }

    private struct ControlEnvelope: Encodable { let requestId: String; let type: String }
    static func requireSuccess(_ data: Data) throws {
        struct Response: Decodable { struct Failure: Decodable { let code: String? }; let ok: Bool; let error: Failure? }
        guard let response = try? JSONDecoder().decode(Response.self, from: data) else { throw MediaFailure.protocolError }
        if !response.ok {
            if ["unsupported_request","unknown_request","invalid_type"].contains(response.error?.code ?? "") { throw SlateSyncError(code: "OCR_SERVER_UNSUPPORTED", message: "OCR 常驻协议不可用") }
            throw MediaFailure.unavailable
        }
    }
}

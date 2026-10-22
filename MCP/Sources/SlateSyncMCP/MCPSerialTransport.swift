import Foundation
import Logging
import MCP

/// SDK 0.11's stdio actor suspends between partial writes under backpressure.
/// One writer must own a whole frame, including its newline, across those awaits.
actor MCPSerialTransport: Transport {
    nonisolated let logger: Logger
    private let underlying: any Transport
    private let incoming: AsyncThrowingStream<Data, any Error>
    private struct PendingWrite {
        let id: UUID
        let data: Data
        let completion: CheckedContinuation<Void, any Error>
    }
    private var pending: [PendingWrite] = []
    private var activeWrite: PendingWrite?
    private var writer: Task<Void, Never>?
    private var connected = false
    private var closed = false

    init(_ underlying: any Transport) async {
        self.underlying = underlying
        logger = await underlying.logger
        incoming = await underlying.receive()
    }

    func connect() async throws {
        guard !closed else { throw disconnected() }
        try await underlying.connect()
        // Disconnect is terminal for this server session, even if it races connect.
        guard !closed else { await underlying.disconnect(); throw disconnected() }
        connected = true
    }

    func receive() -> AsyncThrowingStream<Data, any Error> { incoming }

    func send(_ data: Data) async throws {
        try Task.checkCancellation()
        guard connected, !closed else { throw disconnected() }
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (completion: CheckedContinuation<Void, any Error>) in
                guard !Task.isCancelled else { completion.resume(throwing: CancellationError()); return }
                guard connected, !closed else { completion.resume(throwing: disconnected()); return }
                pending.append(PendingWrite(id: id, data: data, completion: completion))
                if writer == nil { writer = Task { await self.writePending() } }
            }
            try Task.checkCancellation()
        } onCancel: {
            Task { await self.cancelPending(id) }
        }
    }

    func disconnect() async {
        closed = true
        connected = false
        failPending(disconnected())
        finishActive(.failure(disconnected()))
        let active = writer
        active?.cancel()
        await underlying.disconnect()
        await active?.value
    }

    private func writePending() async {
        defer { writer = nil }
        while !closed, !pending.isEmpty {
            let next = pending.removeFirst()
            activeWrite = next
            do {
                try Task.checkCancellation()
                try await underlying.send(next.data)
                finishActive(.success(()))
            } catch {
                // A failed write may have emitted a partial frame. Close the
                // session instead of appending another message to that fragment.
                closed = true
                connected = false
                finishActive(.failure(error))
                failPending(error)
                await underlying.disconnect()
            }
        }
    }

    private func cancelPending(_ id: UUID) {
        if activeWrite?.id == id {
            // Release a canceled caller promptly (notably recognition drain),
            // while the independent writer finishes the already-started frame.
            finishActive(.failure(CancellationError()))
            return
        }
        guard let index = pending.firstIndex(where: { $0.id == id }) else { return }
        pending.remove(at: index).completion.resume(throwing: CancellationError())
        // Once writing has started, finish its frame despite caller cancellation.
        // Session disconnect can still cancel the writer and abandon the stream.
    }

    private func finishActive(_ result: Result<Void, any Error>) {
        let write = activeWrite
        activeWrite = nil
        write?.completion.resume(with: result)
    }

    private func failPending(_ error: any Error) {
        let waiting = pending
        pending.removeAll()
        for write in waiting { write.completion.resume(throwing: error) }
    }

    private func disconnected() -> MCPError {
        .internalError("MCP transport is disconnected.")
    }
}

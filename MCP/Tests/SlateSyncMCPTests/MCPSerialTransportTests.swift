import Foundation
import Logging
import MCP
import XCTest
@testable import SlateSyncMCP

/// Suspend after a partial frame to model SDK stdio backpressure without a
/// real client or network. Replies and notifications use this same transport.
@MainActor final class MCPSerialTransportTests: XCTestCase {
    func testConcurrentReplyAndNotificationKeepWholeFrames() async throws {
        let output = PausingTransport()
        let transport = await MCPSerialTransport(output)
        try await transport.connect()
        let reply = Data(#"{"id":1,"result":"large reply"}"#.utf8)
        let notification = Data(#"{"method":"notifications/progress"}"#.utf8)
        let first = Task { try await transport.send(reply) }
        try await waitForWrite(output)
        let second = Task { try await transport.send(notification) }
        try await Task.sleep(for: .milliseconds(25))
        await output.release()
        try await first.value
        try await second.value
        let bytes = await output.bytes, maximum = await output.maximumConcurrent
        XCTAssertEqual(bytes, reply + Data([10]) + notification + Data([10]))
        XCTAssertEqual(maximum, 1)
        await transport.disconnect()
    }

    func testCanceledQueuedSendIsOmittedAndActiveFrameStillFinishes() async throws {
        let output = PausingTransport()
        let transport = await MCPSerialTransport(output)
        try await transport.connect()
        let first = Task { try await transport.send(Data("first".utf8)) }
        try await waitForWrite(output)
        let queued = Task { try await transport.send(Data("canceled".utf8)) }
        try await Task.sleep(for: .milliseconds(25))
        queued.cancel()
        do { try await queued.value; XCTFail("Queued send must cancel") } catch is CancellationError {}
        // Canceling the caller cannot truncate a frame or hold up service drain.
        first.cancel()
        do { try await first.value; XCTFail("Active caller must cancel") } catch is CancellationError {}
        let last = Task { try await transport.send(Data("last".utf8)) }
        await output.release()
        try await last.value
        let bytes = await output.bytes
        XCTAssertEqual(bytes, Data("first\nlast\n".utf8))
        await transport.disconnect()
    }

    func testDisconnectCancelsBlockedWriterAndRejectsQueuedSends() async throws {
        let output = PausingTransport()
        let transport = await MCPSerialTransport(output)
        try await transport.connect()
        let first = Task { try await transport.send(Data("first".utf8)) }
        try await waitForWrite(output)
        let second = Task { try await transport.send(Data("second".utf8)) }
        await transport.disconnect()
        for task in [first, second] {
            do { try await task.value; XCTFail("Disconnected sends must fail") } catch {}
        }
        let active = await output.active, disconnected = await output.disconnected
        XCTAssertEqual(active, 0)
        XCTAssertTrue(disconnected)
        do { try await transport.send(Data()); XCTFail("Closed transport must reject sends") } catch {}
    }

    func testPartialWriteFailureClosesInsteadOfAppendingAnotherFrame() async throws {
        let output = PausingTransport(fails: true)
        let transport = await MCPSerialTransport(output)
        try await transport.connect()
        let first = Task { try await transport.send(Data("first".utf8)) }
        try await waitForWrite(output)
        let second = Task { try await transport.send(Data("second".utf8)) }
        await output.release()
        for task in [first, second] {
            do { try await task.value; XCTFail("Broken stream must fail") } catch {}
        }
        await transport.disconnect()
        let count = await output.started, bytes = await output.bytes
        XCTAssertEqual(count, 1)
        XCTAssertEqual(bytes, Data("fi".utf8))
    }

    private func waitForWrite(_ output: PausingTransport) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while await output.started == 0, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        let started = await output.started
        XCTAssertEqual(started, 1)
    }
}

private actor PausingTransport: Transport {
    nonisolated let logger = Logger(label: "mcp-serial-test", factory: { _ in SwiftLogNoOpLogHandler() })
    private var held = true
    private let fails: Bool
    private(set) var bytes = Data()
    private(set) var active = 0
    private(set) var maximumConcurrent = 0
    private(set) var started = 0
    private(set) var disconnected = false
    init(fails: Bool = false) { self.fails = fails }
    func connect() {}
    func disconnect() { disconnected = true }
    func receive() -> AsyncThrowingStream<Data, any Error> { AsyncThrowingStream { $0.finish() } }
    func release() { held = false }
    func send(_ data: Data) async throws {
        active += 1
        started += 1
        maximumConcurrent = max(maximumConcurrent, active)
        defer { active -= 1 }
        let split = data.count / 2
        bytes.append(data.prefix(split))
        while held { try await Task.sleep(for: .milliseconds(5)) }
        if fails { throw MCPError.internalError("Partial write fixture") }
        bytes.append(data.dropFirst(split))
        bytes.append(10)
    }
}

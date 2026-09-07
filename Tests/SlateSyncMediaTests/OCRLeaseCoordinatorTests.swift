import Foundation
import SlateSyncDomain
@testable import SlateSyncMedia
import XCTest

@MainActor final class OCRLeaseCoordinatorTests: XCTestCase {
    private func waitForPending(_ expected: Int, in coordinator: OCRLeaseCoordinator) async throws {
        for _ in 0..<200 {
            if await coordinator.snapshot().pending == expected { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("queue never reached pending=\(expected)")
    }

    func testFIFOAndCancelingOneWaiterDoesNotAffectAnotherLease() async throws {
        let coordinator = OCRLeaseCoordinator()
        let clock = SystemOCRClock()
        let deadline = OCRDeadline(clock: clock, timeoutMilliseconds: 10_000)
        let firstOperation = MediaOperation()
        let first = try await coordinator.acquire(operation: firstOperation, deadline: deadline, clock: clock)

        let secondOperation = MediaOperation()
        let secondTask = Task { try await coordinator.acquire(operation: secondOperation, deadline: deadline, clock: clock) }
        try await waitForPending(1, in: coordinator)
        let canceledOperation = MediaOperation()
        let canceledTask = Task { try await coordinator.acquire(operation: canceledOperation, deadline: deadline, clock: clock) }
        try await waitForPending(2, in: coordinator)
        let fourthOperation = MediaOperation()
        let fourthTask = Task { try await coordinator.acquire(operation: fourthOperation, deadline: deadline, clock: clock) }
        try await waitForPending(3, in: coordinator)

        canceledOperation.cancel()
        do { _ = try await canceledTask.value; XCTFail("canceled waiter acquired a lease") }
        catch { XCTAssertEqual((error as? SlateSyncError)?.code, "RECOGNITION_CANCELED") }
        var snapshot = await coordinator.snapshot()
        XCTAssertEqual(snapshot.active, 1)
        XCTAssertFalse(firstOperation.isCanceled)

        await coordinator.release(first)
        let second = try await secondTask.value
        snapshot = await coordinator.snapshot()
        XCTAssertEqual(snapshot.pending, 1)
        await coordinator.release(second)
        let fourth = try await fourthTask.value
        snapshot = await coordinator.snapshot()
        XCTAssertEqual(snapshot.pending, 0)
        await coordinator.release(fourth)
        snapshot = await coordinator.snapshot()
        XCTAssertEqual(snapshot.active, 0)
    }

    func testCloseWakesQueueAndDrainsActiveLeaseWithoutPolling() async throws {
        let coordinator = OCRLeaseCoordinator()
        let clock = SystemOCRClock()
        let deadline = OCRDeadline(clock: clock, timeoutMilliseconds: 10_000)
        let activeOperation = MediaOperation()
        let active = try await coordinator.acquire(operation: activeOperation, deadline: deadline, clock: clock)
        let queuedOperation = MediaOperation()
        let queued = Task { try await coordinator.acquire(operation: queuedOperation, deadline: deadline, clock: clock) }
        try await waitForPending(1, in: coordinator)

        await coordinator.beginClose(permanent: true)
        XCTAssertTrue(activeOperation.isCanceled)
        do { _ = try await queued.value; XCTFail("close did not wake queued waiter") }
        catch { XCTAssertEqual((error as? SlateSyncError)?.code, "OCR_CLOSED") }
        let draining = Task { await coordinator.finishClose() }
        await Task.yield()
        XCTAssertFalse(draining.isCancelled)
        await coordinator.release(active)
        await draining.value

        do {
            _ = try await coordinator.acquire(operation: .init(), deadline: deadline, clock: clock)
            XCTFail("permanently closed coordinator reopened")
        } catch { XCTAssertEqual((error as? SlateSyncError)?.code, "OCR_CLOSED") }
    }

    func testProductionLeaseOwnersContainNoBusyWaitLoop() throws {
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        for relative in ["Sources/SlateSyncMedia/OCRProcessSupervisor.swift", "Sources/SlateSyncMedia/VisionOCRService.swift"] {
            let source = try String(contentsOf: repository.appendingPathComponent(relative), encoding: .utf8)
            XCTAssertFalse(source.contains("clock.sleep(milliseconds: 5)"), relative)
            XCTAssertFalse(source.contains("while active != nil"), relative)
        }
    }
}

import Foundation
import SlateSyncDomain
import XCTest

@testable import SlateSyncWorkflow

@MainActor
final class RecognitionRuntimeLifecycleTests: XCTestCase {
    /// A configuration save blocks new coordinators through its last write,
    /// while concurrent requests still share one lazy construction.
    func testSuspensionRejectsAdmissionUntilExplicitResume() async throws {
        let owner = RecognitionRuntimeLifecycle()
        let first = try await owner.coordinator { RecognitionCoordinator() }
        let reused = try await owner.coordinator {
            XCTFail("Must share runtime")
            return RecognitionCoordinator()
        }
        XCTAssertTrue(first === reused)
        await owner.suspend()
        do {
            _ = try await owner.coordinator { RecognitionCoordinator() }
            XCTFail("A configuration transaction still owns admission")
        } catch { XCTAssertEqual((error as? SlateSyncError)?.code, "RECOGNITION_RECONFIGURING") }
        await owner.resume()
        let replacement = try await owner.coordinator { RecognitionCoordinator() }
        XCTAssertFalse(first === replacement)
        await owner.reset()
    }
}

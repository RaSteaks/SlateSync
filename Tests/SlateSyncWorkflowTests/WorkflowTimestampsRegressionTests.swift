import Foundation
import XCTest
@testable import SlateSyncWorkflow

/// Byte freeze for discovery/probe metadata stamps: refreshedAt,
/// valueUpdatedAt and capability checkedAt keep the second-precision shape
/// the old Worker wrote, now rendered from a shared formatter.
final class WorkflowTimestampsRegressionTests: XCTestCase {
    func testStringRendersPlainInternetDateTime() {
        XCTAssertEqual(
            WorkflowTimestamps.string(Date(timeIntervalSinceReferenceDate: 0)),
            "2001-01-01T00:00:00Z"
        )
        XCTAssertEqual(
            WorkflowTimestamps.string(Date(timeIntervalSinceReferenceDate: 1.5)),
            "2001-01-01T00:00:01Z"
        )
    }
}

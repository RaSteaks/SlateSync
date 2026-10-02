import Foundation
import SlateSyncDomain
import XCTest

final class NumericBoundaryTests: XCTestCase {
    /// Large finite values must be rejected or clamped before Int conversion.
    func testWorkflowDepthRejectsOutOfRangeIntegersWithoutTrapping() {
        for value in ["9223372036854775807", "9223372036854775808", "1e300", "-1", "0", "13", "1.5"] {
            XCTAssertThrowsError(
                try JSONDecoder().decode(
                    WorkflowConfig.self,
                    from: Data("{\"slate\":{\"maxDirectoryDepth\":\(value)}}".utf8)))
        }
        XCTAssertEqual(RecognitionRuntimeOptions.timeoutMilliseconds("1e300"), 3_600_000)
    }
}

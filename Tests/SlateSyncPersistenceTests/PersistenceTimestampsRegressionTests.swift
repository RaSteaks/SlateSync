import Foundation
import SlateSyncDomain
import XCTest
@testable import SlateSyncPersistence

/// Byte freeze for persisted timestamps: the shared-formatter refactor must
/// not move a single character of the wire format. ISO8601DateFormatter
/// defaults to GMT, so fixed dates assert exact strings.
final class PersistenceTimestampsRegressionTests: XCTestCase {
    func testTimestampRendersInternetDateTimeWithMilliseconds() {
        XCTAssertEqual(
            PersistenceJSON.timestamp(Date(timeIntervalSinceReferenceDate: 0)),
            "2001-01-01T00:00:00.000Z"
        )
        XCTAssertEqual(
            PersistenceJSON.timestamp(Date(timeIntervalSinceReferenceDate: 1.5)),
            "2001-01-01T00:00:01.500Z"
        )
    }

    func testConcurrentTimestampCallsStayWellFormed() async {
        // Shared instances must serialize access; racy reuse would emit
        // corrupted output under concurrent persistence writes.
        let pattern = #"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z$"#
        await withTaskGroup(of: Bool.self) { group in
            for _ in 0..<64 {
                group.addTask {
                    PersistenceJSON.timestamp().range(of: pattern, options: .regularExpression) != nil
                }
            }
            var malformed = 0
            for await wellFormed in group where !wellFormed { malformed += 1 }
            XCTAssertEqual(malformed, 0, "并发 timestamp 输出存在畸形")
        }
    }

    func testParseAcceptsBothTimestampShapesAndRejectsGarbage() {
        // v1 library import validation must keep accepting second-precision
        // stamps: the fractional formatter alone cannot parse them.
        XCTAssertEqual(PersistenceTimestamps.parse("2001-01-01T00:00:01.500Z"), Date(timeIntervalSinceReferenceDate: 1.5))
        XCTAssertEqual(PersistenceTimestamps.parse("2001-01-01T00:00:01Z"), Date(timeIntervalSinceReferenceDate: 1))
        XCTAssertNil(PersistenceTimestamps.parse(""))
        XCTAssertNil(PersistenceTimestamps.parse("not-a-timestamp"))
        XCTAssertNil(PersistenceTimestamps.parse("2001-01-01"))
    }
}

import XCTest
@testable import SlateSyncDomain

final class SlateSyncErrorTests: XCTestCase {
    func testStableEnvelopeRoundTrips() throws {
        let original = SlateSyncError(code: "BUSY", message: "正在处理", retryable: true)
        let decoded = try JSONDecoder().decode(
            SlateSyncError.self,
            from: JSONEncoder().encode(original)
        )
        XCTAssertEqual(decoded, original)
    }
}

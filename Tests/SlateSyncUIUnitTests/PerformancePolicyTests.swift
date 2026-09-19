import Foundation
import XCTest

/// Only the explicit merge-CI lane delegates elapsed-time budgets. Unknown
/// values fail closed so ordinary tests and release acceptance remain strict.
enum PerformancePolicy {
    static func enforcesTiming(_ environment: [String: String]) -> Bool {
        environment["SLATESYNC_PERFORMANCE_POLICY"] != "functional"
    }
    static var enforcesTiming: Bool { enforcesTiming(ProcessInfo.processInfo.environment) }
}

final class PerformancePolicyTests: XCTestCase {
    func testOnlyExplicitFunctionalLaneDelegatesTiming() {
        XCTAssertTrue(PerformancePolicy.enforcesTiming([:]))
        XCTAssertTrue(PerformancePolicy.enforcesTiming(["SLATESYNC_PERFORMANCE_POLICY": "strict"]))
        XCTAssertTrue(PerformancePolicy.enforcesTiming(["SLATESYNC_PERFORMANCE_POLICY": "typo"]))
        XCTAssertFalse(PerformancePolicy.enforcesTiming(["SLATESYNC_PERFORMANCE_POLICY": "functional"]))
    }
}

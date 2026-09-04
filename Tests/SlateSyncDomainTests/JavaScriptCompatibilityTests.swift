import XCTest
@testable import SlateSyncDomain

final class JavaScriptCompatibilityTests: XCTestCase {
    func testNumberParsingMatchesJavaScriptBoundaryForms() {
        XCTAssertEqual(JavaScriptCompatibility.number(" 0x10 "), 16)
        XCTAssertEqual(JavaScriptCompatibility.number("0b101"), 5)
        XCTAssertEqual(JavaScriptCompatibility.number("0o10"), 8)
        XCTAssertEqual(JavaScriptCompatibility.number("1e2"), 100)
        XCTAssertEqual(JavaScriptCompatibility.number(".5"), 0.5)
        XCTAssertEqual(JavaScriptCompatibility.number("1."), 1)
        XCTAssertEqual(JavaScriptCompatibility.number(""), 0)
        XCTAssertNil(JavaScriptCompatibility.number("1px"))
        XCTAssertNil(JavaScriptCompatibility.number("0x"))
        XCTAssertNil(JavaScriptCompatibility.number("+0x10"))
    }

    func testNumberFormattingUsesECMAScriptNotationThresholds() {
        let cases: [(Double, String)] = [
            (0, "0"),
            (-0.0, "0"),
            (1.0, "1"),
            (100.0, "100"),
            (0.0012, "0.0012"),
            (0.000001, "0.000001"),
            (0.00000012, "1.2e-7"),
            (1e20, "100000000000000000000"),
            (1e21, "1e+21"),
            (-1.2e-7, "-1.2e-7"),
        ]

        for (value, expected) in cases {
            XCTAssertEqual(JavaScriptCompatibility.numberString(value), expected, "value=\(value)")
        }
        XCTAssertNil(JavaScriptCompatibility.numberString(.infinity))
        XCTAssertEqual(JavaScriptCompatibility.integerString("1e2"), "100")
        XCTAssertNil(JavaScriptCompatibility.integerString("1.5"))
    }

    func testTextLimitsUseUTF16CodeUnitsLikeJavaScriptLength() {
        XCTAssertEqual(JavaScriptCompatibility.utf16Length("A😀B"), 4)
        XCTAssertEqual(JavaScriptCompatibility.utf16Length(String(repeating: "😀", count: 32)), 64)
    }
}

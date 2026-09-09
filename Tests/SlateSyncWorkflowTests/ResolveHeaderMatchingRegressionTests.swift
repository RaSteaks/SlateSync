import SlateSyncDomain
@testable import SlateSyncWorkflow
import XCTest

/// Regression freeze for review finding #10: the old `normalizeHeader`
/// (public/resolve-csv.js) trims, lowercases, then strips whitespace,
/// underscore and hyphen runs. It never applies NFKC, so a full-width header
/// such as "Ｓｃｅｎｅ" stays an unknown column instead of colliding with a
/// real "Scene" column and tripping CSV_COLUMNS duplicate detection.
final class ResolveHeaderMatchingRegressionTests: XCTestCase {
    // MARK: - #10 normalizeHeader has no NFKC

    func testNormalizeHeaderKeepsFullWidthLettersUnmatched() {
        // Full-width letters are lowercased but never folded onto ASCII.
        XCTAssertEqual(ResolveCSVNormalization.normalizeHeader("Ｓｃｅｎｅ"), "ｓｃｅｎｅ")
        XCTAssertNotEqual(ResolveCSVNormalization.normalizeHeader("Ｓｃｅｎｅ"), "scene")
        XCTAssertEqual(ResolveCSVNormalization.normalizeHeader("Ｓcene"), "ｓcene")
        // Half-width matching still trims and strips separators like the old rule.
        XCTAssertEqual(ResolveCSVNormalization.normalizeHeader(" Scene "), "scene")
        XCTAssertEqual(ResolveCSVNormalization.normalizeHeader("Shot_List"), "shotlist")
        XCTAssertEqual(ResolveCSVNormalization.normalizeHeader("Take- 2"), "take2")
        // JS trim() and \s both cover U+FEFF and U+3000.
        XCTAssertEqual(ResolveCSVNormalization.normalizeHeader("\u{FEFF}Scene\u{3000}"), "scene")
        XCTAssertEqual(ResolveCSVNormalization.normalizeHeader(""), "")
    }

    func testResolveHeadersDoesNotSeeFullWidthColumnAsDuplicate() throws {
        // A half-width "Scene" plus a full-width lookalike must not read as
        // two writable Scene columns; the full-width column is unknown and
        // preserved as-is.
        let indexes = try ResolveHeaders.resolve(["File Name", "Scene", "Ｓｃｅｎｅ", "Take"])
        XCTAssertEqual(indexes.scene, 1)
        XCTAssertEqual(indexes.take, 3)
    }

    func testResolveHeadersLeavesFullWidthOnlySceneUnbound() throws {
        // Without a real Scene column the full-width lookalike never becomes
        // one: the old app left such a CSV unbound instead of writing to it.
        let indexes = try ResolveHeaders.resolve(["File Name", "Ｓｃｅｎｅ", "Take"])
        XCTAssertEqual(indexes.scene, -1)
        XCTAssertEqual(indexes.take, 2)
    }

    // MARK: - decode-level freeze

    func testDecodeAcceptsTableWithFullWidthHeaderLookalike() async throws {
        let engine = ResolveCSVEngine()
        let csv = "File Name,Scene,Ｓｃｅｎｅ,Take\r\nA001C001.mov,001,,\r\n"
        let table = try await engine.decode(Data(csv.utf8))
        XCTAssertEqual(table.headers, ["File Name", "Scene", "Ｓｃｅｎｅ", "Take"])
        XCTAssertEqual(table.rows.first?.first, "A001C001.mov")
    }
}

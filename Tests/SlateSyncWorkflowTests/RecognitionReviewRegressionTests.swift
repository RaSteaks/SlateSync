import SlateSyncDomain
@testable import SlateSyncWorkflow
import XCTest

/// Regression freeze for the swift-rewrite review findings:
/// duplicate review keys must not trap (old merge tolerated duplicates),
/// and card identity must follow the old `normalizeReel` rule — clean case
/// and separators, never zero-pad — so "A1" and "A01" stay distinct cards.
final class RecognitionReviewRegressionTests: XCTestCase {
    private func record(id: String, card: String, clip: String, scene: String?, shot: String? = nil, take: String? = nil) -> RecognitionRecord {
        .init(id: id, sourcePage: 1, cardNumber: card, videoCode: clip, scene: scene, shot: shot, take: take, confidence: .high)
    }

    // MARK: - #1 applyReview duplicate-key crash

    func testApplyReviewKeepsFirstDuplicateReviewKeyAndWarns() {
        let primary = RecognitionSheet(records: [record(id: "p", card: "A001", clip: "C001", scene: "001", shot: "01", take: "01")])
        let audit = RecognitionSheet(records: [record(id: "a", card: "A001", clip: "C001", scene: "002", shot: "01", take: "01")])
        let merge = RecognitionPostprocessor.mergeHighAccuracy(primary, audit)
        XCTAssertEqual(merge.conflicts.count, 1)
        // The third-pass review echoes the same card+clip twice. Old behavior
        // (mergeHighAccuracy) warns and keeps the first; applyReview must not
        // trap on duplicate dictionary keys and must apply only the first.
        let review = RecognitionSheet(records: [
            record(id: "r1", card: "A001", clip: "C001", scene: "101", shot: "01", take: "01"),
            record(id: "r2", card: "A001", clip: "C001", scene: "202", shot: "01", take: "01"),
        ])
        let reviewed = RecognitionPostprocessor.applyReview(merge, review: review)
        XCTAssertEqual(reviewed.records.first?.scene, "101")
        XCTAssertTrue(reviewed.warnings.contains { $0.contains("重复") && $0.contains("保留第一条") }, "重复复核键应产生警告：\(reviewed.warnings)")
    }

    func testApplyReviewSkipsRecordsWithoutMaterialKeyAndWarns() {
        let primary = RecognitionSheet(records: [record(id: "p", card: "A001", clip: "C001", scene: "001", shot: "01", take: "01")])
        let audit = RecognitionSheet(records: [record(id: "a", card: "A001", clip: "C001", scene: "002", shot: "01", take: "01")])
        let merge = RecognitionPostprocessor.mergeHighAccuracy(primary, audit)
        let review = RecognitionSheet(records: [
            record(id: "r1", card: "", clip: "", scene: "101"),
            record(id: "r2", card: "A001", clip: "C001", scene: "102", shot: "01", take: "01"),
        ])
        let reviewed = RecognitionPostprocessor.applyReview(merge, review: review)
        XCTAssertEqual(reviewed.records.first?.scene, "102")
        XCTAssertTrue(reviewed.warnings.contains { $0.contains("缺少有效卷号或视频码") }, "缺键复核记录应产生警告：\(reviewed.warnings)")
    }

    // MARK: - #2 card identity must not zero-pad

    func testCardIdentityFollowsOldNormalizeReel() {
        XCTAssertEqual(RecognitionNormalizer.normalizeCard("A1"), "A1")
        XCTAssertEqual(RecognitionNormalizer.normalizeCard("A01"), "A01")
        XCTAssertEqual(RecognitionNormalizer.normalizeCard("ａ-10"), "A10")
        XCTAssertEqual(RecognitionNormalizer.normalizeCard("a_01"), "A01")
        XCTAssertEqual(RecognitionNormalizer.normalizeCard("a 1"), "A1")
        XCTAssertNil(RecognitionNormalizer.normalizeCard("///"))
        XCTAssertNil(RecognitionNormalizer.normalizeCard(nil))
    }

    func testMaterialKeyUsesUnpaddedCard() {
        XCTAssertEqual(RecognitionNormalizer.materialKey(record(id: "x", card: "A1", clip: "C001", scene: nil)), "A1C001")
        XCTAssertEqual(RecognitionNormalizer.materialKey(record(id: "x", card: "A01", clip: "C001", scene: nil)), "A01C001")
    }

    func testInheritKeepsA1AndA01AsDistinctCards() {
        let first = record(id: "r1", card: "A1", clip: "C001", scene: "001", shot: "01", take: "01")
        let second = record(id: "r2", card: "A01", clip: "C001", scene: nil, shot: nil)
        let merged = RecognitionPostprocessor.mergePages([(1, .init(records: [first, second]))], accuracy: .standard, formats: .init())
        // mergePages rewrites ids by page position; output order follows input.
        XCTAssertEqual(merged.records.count, 2)
        let a1 = merged.records[0]
        let a01 = merged.records[1]
        XCTAssertEqual(a1.cardNumber, "A1")
        XCTAssertEqual(a01.cardNumber, "A01")
        // Distinct physical cards: the unpadded A01 record must not inherit
        // scene/shot from the A1 record (old normalizeReel kept them apart).
        XCTAssertNil(a01.scene, "A01 与 A1 是不同物理卡，不得跨卡继承场/镜：\(a01)")
        XCTAssertNil(a01.shot)
        XCTAssertFalse(merged.warnings.contains { $0.contains("A01") && $0.contains("继承") }, "不应出现 A01 的继承警告：\(merged.warnings)")
    }

    func testInheritSortTiebreaksBySourceIndex() {
        // Same page, same card, duplicate clip: inheritance must follow input
        // order deterministically (old sort ended with `left.index - right.index`).
        let first = record(id: "r1", card: "A1", clip: "C001", scene: "001", shot: "01", take: "01")
        let duplicate = record(id: "r2", card: "A1", clip: "C001", scene: nil, shot: nil)
        let merged = RecognitionPostprocessor.mergePages([(1, .init(records: [first, duplicate]))], accuracy: .standard, formats: .init())
        let inherited = merged.records[1]
        XCTAssertEqual(inherited.scene, "001", "同键重复记录应按输入顺序继承：\(inherited)")
        XCTAssertEqual(inherited.shot, "01")
    }

    func testRepairGroupsAlsoTiebreakBySourceIndex() {
        // The repair pass groups by card identity and sorts by clip ordinal;
        // duplicate clips must keep input order there too.
        let sandwich = [
            record(id: "r1", card: "A1", clip: "C001", scene: "001", shot: "17", take: "01"),
            record(id: "r2", card: "A1", clip: "C002", scene: "001", shot: "99", take: "99"),
            record(id: "r3", card: "A1", clip: "C003", scene: "001", shot: "17", take: "03"),
        ]
        let merged = RecognitionPostprocessor.mergePages([(1, .init(records: sandwich))], accuracy: .standard, formats: .init())
        let repaired = merged.records.first { $0.videoCode == "C002" }
        XCTAssertEqual(repaired?.shot, "17")
        XCTAssertEqual(repaired?.take, "02")
        XCTAssertTrue(merged.warnings.contains { $0.contains("校正") }, "夹心行应被校正：\(merged.warnings)")
    }
}

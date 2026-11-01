import SlateSyncDomain
@testable import SlateSyncWorkflow
import XCTest

final class MaterialIdentityConsistencyTests: XCTestCase {
    func testConflictingEmbeddedReelCannotCreateHybridMaterialKey() {
        XCTAssertEqual(ResolveCSVNormalization.canonicalMaterialKey(cardNumber: "A025", videoCode: "A026C003"), "")
        XCTAssertNil(ResolveCSVNormalization.materialPrefix(cardNumber: "A025", videoCode: "A026C003"))
        XCTAssertEqual(ResolveCSVNormalization.canonicalMaterialKey(cardNumber: "B026", videoCode: "A026C003"), "")
        XCTAssertEqual(ResolveCSVNormalization.canonicalMaterialKey(cardNumber: "A026", videoCode: "A026C003"), "A:26:3")
        XCTAssertEqual(ResolveCSVNormalization.canonicalMaterialKey(cardNumber: "A026", videoCode: "C003"), "A:26:3")
    }

    func testConflictDoesNotWriteEitherCandidateCSVRow() async throws {
        let source = ResolveCSVTable(headers: ["File Name", "Scene", "Shot", "Take", "Comments"], rows: [
            ["A025C003.mov", "old25", "", "", ""], ["A026C003.mov", "old26", "", "", ""]], format: .init())
        let result = try await ResolveCSVMerger().merge(source: source, records: [
            .init(cardNumber: "A025", videoCode: "A026C003", scene: "89B", shot: "1", take: "2")])
        XCTAssertEqual(result.table.rows, source.rows)
        XCTAssertEqual(result.matchedRecordCount, 0)
        XCTAssertEqual(result.statuses.first??.status, "missing-key")
        XCTAssertTrue(result.warnings.contains { $0.contains("素材标识冲突") })
    }
}

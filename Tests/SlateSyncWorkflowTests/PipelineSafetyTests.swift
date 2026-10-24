import Foundation
import SlateSyncDomain
@testable import SlateSyncWorkflow
import XCTest

/// Cross-stage regressions: material identity and conflicting evidence must
/// remain consistent from directory discovery through the final CSV merge.
final class PipelineSafetyTests: XCTestCase {
    func testUnappliedManualEditCannotBypassExportGuard() async throws {
        let source = Data("File Name,Scene,Shot,Take\nA001C001.mov,keep,keep,keep\n".utf8)
        do {
            _ = try await SM05WorkflowServices().mergeAndEncode(source: source,
                records: [.init(cardNumber: "A001", videoCode: "C001")],
                edits: [.init(rowIndex: 999, columnIndex: 1, value: "1")])
            XCTFail("An ignored edit must not make an incomplete merge exportable")
        } catch let error as SlateSyncError { XCTAssertEqual(error.code, "CSV_NO_EXPORT") }
    }

    func testAutomaticRepairRemainsVisibleAtExportBoundary() async throws {
        let source = Data("File Name,Scene,Shot,Take\nA001C001.mov,,,\n".utf8)
        let result = try await SM05WorkflowServices().previewMerge(source: source, records: [
            .init(cardNumber: "A001", videoCode: "C001", scene: "1", shot: "18", take: "1", reviewRequiredFields: ["shot"])
        ])
        XCTAssertEqual(result.matchedRecordCount, 1)
        XCTAssertEqual(result.statuses[0]?.status, "review-required")
        XCTAssertEqual(result.reviewIssueCount, 1)
        XCTAssertEqual(result.table.rows[0][2], "18", "Advisory review does not discard the proposed correction")
    }

    func testDuplicatePrimaryDisagreementTriggersReviewAndResolvedFieldClearsMarker() throws {
        let records: [RecognitionRecord] = [
            .init(id: "first", cardNumber: "A001", videoCode: "C001", scene: "001", shot: "01", take: "01", confidence: .high),
            .init(id: "second", cardNumber: "A001", videoCode: "C001", scene: "009", shot: "01", take: "01", confidence: .high)
        ]
        let merged = RecognitionPostprocessor.mergeHighAccuracy(.init(records: records), .init(records: [records[0]]))
        XCTAssertEqual(merged.conflicts.first?.fields, ["scene"])
        let reviewed = RecognitionPostprocessor.applyReview(merged, review: .init(records: [records[0]]))
        XCTAssertEqual(reviewed.records.first?.scene, "001")
        XCTAssertFalse(reviewed.records.first?.reviewRequiredFields?.contains("scene") == true)
    }

    func testEditedIdentityIsUsedForRecognitionAndSidecarMatching() async throws {
        let source = ResolveCSVTable(headers: ["File Name", "Scene", "Shot", "Take", "Camera FPS"],
            rows: [["A001C001.mov", "old", "", "", "24"]], format: .init())
        let result = try await ResolveCSVMerger().merge(source: source,
            records: [.init(cardNumber: "B002", videoCode: "C002", scene: "9", shot: "2", take: "1")],
            metadata: [.init(materialKey: "B:2:2", sensorFps: "48")],
            edits: [.init(rowIndex: 0, columnIndex: 0, value: "B002C002.mov")])
        XCTAssertEqual(result.rowKeys, ["B:2:2"])
        XCTAssertEqual(result.matchedRecordCount, 1)
        XCTAssertEqual(result.table.rows[0][1], "009")
        XCTAssertEqual(result.table.rows[0][4], "48")
    }

    func testIncompleteContradictoryDuplicateCannotBeIgnored() async throws {
        let source = ResolveCSVTable(headers: ["File Name", "Scene", "Shot", "Take", "Comments"],
            rows: [["A001C001.mov", "old", "old", "old", "note"]], format: .init())
        let result = try await ResolveCSVMerger().merge(source: source, records: [
            .init(cardNumber: "A001", videoCode: "C001", scene: "1", shot: "2", take: "1"),
            .init(cardNumber: "A001", videoCode: "C001", scene: "9", shot: nil, take: "1")
        ], metadata: [.init(materialKey: "A:1:1", sensorFps: "48")])
        XCTAssertEqual(result.matchedRecordCount, 0)
        XCTAssertEqual(result.statuses.compactMap { $0?.status }, ["conflict", "conflict"])
        XCTAssertEqual(Array(result.table.rows[0][1...4]), ["old", "old", "old", "note"])
        XCTAssertEqual(result.cameraFpsMatchedMaterialCount, 1, "Independent metadata remains valid")
    }

    func testScannerIncludesConflictingSidecarsInsteadOfFirstHit() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appending(path: "A001C001")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("Clip Name: A001C001\nSensor FPS: 24".utf8).write(to: folder.appending(path: "A001C001-slate.txt"))
        try Data("Clip Name: A001C001\nSensor FPS: 48".utf8).write(to: folder.appending(path: "camera-slate.txt"))
        let scan = try await SlateMetadataScanner().scan(directory: root, options: .init(expectedKeys: ["A:1:1"]))
        XCTAssertEqual(scan.metadata.count, 2, "Every sidecar must reach conflict reconciliation")
        let result = try await ResolveCSVMerger().merge(
            source: .init(headers: ["File Name", "Camera FPS"], rows: [["A001C001.mov", "original"]], format: .init()),
            records: [.init(cardNumber: "A001", videoCode: "C001", scene: "1", shot: "1", take: "1")],
            metadata: scan.metadata.map { .init(materialKey: $0.materialKey, sensorFps: $0.sensorFps) })
        XCTAssertEqual(result.table.rows[0][1], "original")
    }

    func testScannerRejectsDirectoryIdentityMismatchAndUnexpectedContents() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appending(path: "A001C001")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("Clip Name: B001C002\nSensor FPS: 48".utf8).write(to: folder.appending(path: "camera-slate.txt"))
        try Data("Clip Name: C001C003\nSensor FPS: 24".utf8).write(to: root.appending(path: "slate.txt"))
        let result = try await SlateMetadataScanner().scan(directory: root, options: .init(expectedKeys: ["A:1:1", "B:1:2"]))
        XCTAssertTrue(result.metadata.isEmpty)
        XCTAssertEqual(result.missingKeys, ["A:1:1", "B:1:2"])
        XCTAssertEqual(result.warnings.count, 2)
        // The same checks apply when the picker chooses the clip directory
        // itself, instead of a parent volume containing it.
        let direct = try await SlateMetadataScanner().scan(directory: folder, options: .init(expectedKeys: ["A:1:1", "B:1:2"]))
        XCTAssertTrue(direct.metadata.isEmpty)
        XCTAssertEqual(direct.warnings.count, 1)
    }

    func testMaterialLikeRootNameDoesNotPruneAnEntireVolume() async throws {
        let temporary = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let root = temporary.appending(path: "A123C456-archive")
        let folder = root.appending(path: "A001C001")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("Clip Name: A001C001\nSensor FPS: 24".utf8).write(to: folder.appending(path: "slate.txt"))
        let result = try await SlateMetadataScanner().scan(directory: root, options: .init(expectedKeys: ["A:1:1"]))
        XCTAssertEqual(result.metadata.map(\.materialKey), ["A:1:1"])
    }

    func testAuditOnlyReviewCannotReviveUnconfirmedValues() {
        let candidate = RecognitionRecord(id: "audit", cardNumber: "A001", videoCode: "C001",
            scene: "1", shot: "18", take: "1", confidence: .high)
        let review = RecognitionRecord(id: "review", cardNumber: "A001", videoCode: "C001",
            scene: "1", shot: nil, take: "1", confidence: .low)
        let merged = RecognitionPostprocessor.mergeHighAccuracy(.init(records: []), .init(records: [candidate]))
        let result = RecognitionPostprocessor.applyReview(merged, review: .init(records: [review]))
        XCTAssertNil(result.records.first?.shot)
        XCTAssertTrue(result.records.first?.reviewRequiredFields?.contains("shot") == true)
    }
}

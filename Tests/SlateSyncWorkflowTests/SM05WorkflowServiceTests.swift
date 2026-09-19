import Foundation
import XCTest
import SlateSyncDomain
@testable import SlateSyncWorkflow

final class SM05WorkflowServiceTests: XCTestCase {
    func testExportPreservesUnmatchedConflictingIncompleteAndManualCells() async throws {
        // Only C001 is writable; every other original cell must survive both
        // the merge preview and final encoding, including nonnumeric text.
        let source = Data("File Name,Scene,Shot,Take,Comments\r\nA001C001.mov,,,,\r\nA001C002.mov,12B,wide,alt,KEEP THIS NOTE\r\nA001C003.mov,003,003,03,conflict note\r\nA001C004.mov,004,004,04,incomplete note\r\n".utf8)
        let records: [ResolveSlateRecord] = [
            .init(cardNumber: "A001", videoCode: "C001", scene: "1", shot: "2", take: "3", takeStatus: .passed),
            .init(cardNumber: "A001", videoCode: "C003", scene: "3", shot: "3", take: "3"),
            .init(cardNumber: "A001", videoCode: "C003", scene: "9", shot: "3", take: "3"),
            .init(cardNumber: "A001", videoCode: "C004", scene: nil, shot: "4", take: "4"),
        ]
        let engine = ResolveCSVEngine()
        let original = try await engine.decode(source)
        let result = try await SM05WorkflowServices().mergeAndEncode(source: source, records: records,
            edits: [.init(rowIndex: 0, columnIndex: 4, value: "manual note"),
                    .init(rowIndex: 0, columnIndex: 2, value: "custom shot")])
        let exported = try await engine.decode(result.data)
        XCTAssertEqual(exported, result.merge.table)
        XCTAssertEqual(Array(exported.rows.dropFirst()), Array(original.rows.dropFirst()))
        XCTAssertEqual(exported.rows[0], ["A001C001.mov", "001", "custom shot", "03", "manual note"])
        XCTAssertEqual(result.merge.updatedRowCount, 1)
        XCTAssertTrue(result.merge.changes.allSatisfy { $0.rowIndex == 0 })
    }

    func testResolveMaterialKeyProjectionMatchesMetadataScanContract() async throws {
        let table = ResolveCSVTable(
            headers: ["File Name", "Reel Name", "Clip Name"],
            rows: [
                ["A001C002.mov", "A001", "C002"],
                ["A001C001.mov", "A001", "C001"],
                ["unmatched.mov", "", ""],
            ],
            format: .init()
        )
        let services = SM05WorkflowServices()
        // The UI metadata model must receive the same canonical ordering used
        // by Resolve merge, including duplicate/invalid rows being excluded.
        let keys = try await services.resolveMaterialKeys(in: table)
        XCTAssertEqual(keys, ["A:1:1", "A:1:2"])
    }

    func testFacadeReturnsImmutableArtifactAndRetryAfterCancellation() async throws {
        let source = Data("File Name,Scene,Shot,Take,Comments\r\nA001C001.mov,,,,\r\n".utf8)
        let records = [ResolveSlateRecord(cardNumber: "A001", videoCode: "C001", scene: "1", shot: "2", take: "3", takeStatus: .passed)]
        let services = SM05WorkflowServices()
        let artifact = try await services.mergeAndEncode(source: source, records: records)
        XCTAssertEqual(artifact.merge.table.rows[0][1...4], ["001", "02", "03", "_OK"])
        XCTAssertGreaterThan(artifact.data.count, source.count)
        XCTAssertGreaterThanOrEqual(artifact.durationMilliseconds, 0)

        let cancelled = Task { () throws -> ResolveExportArtifact in
            try Task.checkCancellation()
            return try await services.mergeAndEncode(source: source, records: records)
        }
        cancelled.cancel()
        do { _ = try await cancelled.value; XCTFail("Expected cancellation") }
        catch is CancellationError { }

        // The cancelled attempt cannot retain mutable table state; a retry is
        // byte-identical to the original successful value snapshot.
        let retry = try await services.mergeAndEncode(source: source, records: records)
        XCTAssertEqual(retry.data, artifact.data)
        XCTAssertEqual(retry.merge, artifact.merge)

        await XCTAssertSM05Error("CSV_NO_EXPORT", try await services.mergeAndEncode(source: source, records: []))
        await XCTAssertSM05Error(
            "CSV_NO_EXPORT",
            try await services.mergeAndEncode(
                source: source,
                records: [.init(cardNumber: "A001", videoCode: "C999", scene: "1", shot: "1", take: "1")]
            )
        )
        // Missing material identity cannot become exportable just because
        // source cells could have been normalized by the old implementation.
        let canonicalizable = "File Name,Scene,Shot,Take,Comments\r\nA001C001.mov,87A,002,03\r\n"
        await XCTAssertSM05Error(
            "CSV_NO_EXPORT",
            try await services.mergeAndEncode(
                source: Data(canonicalizable.utf8),
                records: [.init(cardNumber: nil, videoCode: nil, scene: "A001", shot: "002", take: "03")]
            )
        )
        let editedOnly = try await services.mergeAndEncode(
            source: source,
            records: [.init(cardNumber: "A001", videoCode: "C999", scene: "1", shot: "1", take: "1")],
            edits: [.init(rowIndex: 0, columnIndex: 0, value: "manual.mov")]
        )
        XCTAssertEqual(editedOnly.merge.table.rows[0][0], "manual.mov")
        await XCTAssertSM05Error("CSV_NO_EXPORT", try await services.exportStandalone(records: [.init(scene: nil, shot: "1", take: "1")]))
        let standalone = try await services.exportStandalone(records: records)
        XCTAssertFalse(standalone.isEmpty)
    }
}

private func XCTAssertSM05Error<T>(_ code: String, _ expression: @autoclosure () async throws -> T, file: StaticString = #filePath, line: UInt = #line) async {
    do { _ = try await expression(); XCTFail("Expected \(code)", file: file, line: line) }
    catch { XCTAssertEqual((error as? SlateSyncError)?.code, code, file: file, line: line) }
}

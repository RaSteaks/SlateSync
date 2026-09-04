import Foundation
import XCTest
import SlateSyncDomain
@testable import SlateSyncWorkflow

final class SM05WorkflowServiceTests: XCTestCase {
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

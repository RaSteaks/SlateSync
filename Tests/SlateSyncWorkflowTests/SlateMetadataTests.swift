import Foundation
import XCTest
import SlateSyncDomain
@testable import SlateSyncWorkflow

final class SlateMetadataTests: XCTestCase {
    private let sample = [
        "# SLATE.TXT Revision 2.0",
        "Clip Name...........: A004C004_DEMO001",
        "Sensor FPS..........: 48",
        "Shot Date...........: 2026-08-04",
        "Project FPS.........: 24",
    ].joined(separator: "\r\n")

    func testKinefinityParserAndStructures() throws {
        // Missing reviewed fixtures are contract failures, never skipped coverage.
        let fixtureURL = try XCTUnwrap(Bundle.module.url(forResource: "kinefinity-revision-2", withExtension: "txt"), "Missing SM05 metadata fixture")
        let value = try SlateMetadataParser.parse(Data(contentsOf: fixtureURL), sourceName: "A004C004_DEMO001-slate.txt")
        XCTAssertEqual(value.materialKey, "A:4:4")
        XCTAssertEqual(value.sensorFps, "48")
        XCTAssertEqual(value.shootDay, "26-08-04")
        XCTAssertEqual(MetadataStructure.learn(directoryName: "A004C004", metadataFileNames: ["A004C004-slate.txt"]), [.dirnameSuffix("-slate.txt")])
        XCTAssertEqual(MetadataStructure.probeNames([.dirnameSuffix("-slate.txt"), .fixedName("camera-slate.txt")], directoryName: "B002C007"), ["B002C007-slate.txt", "camera-slate.txt"])
    }

    func testBoundedScannerPrunesAndReportsMissing() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let expected = root.appending(path: "A004C004_DEMO001", directoryHint: .isDirectory)
        let unrelated = root.appending(path: "B001C001", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: expected, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: unrelated, withIntermediateDirectories: true)
        try Data(sample.utf8).write(to: expected.appending(path: "A004C004_DEMO001-slate.txt"))
        try Data(sample.utf8).write(to: unrelated.appending(path: "B001C001-slate.txt"))
        let result = try await SlateMetadataScanner().scan(directory: root, options: .init(expectedKeys: ["A:4:4", "A:4:5"]))
        XCTAssertEqual(result.metadata.map(\.materialKey), ["A:4:4"])
        XCTAssertEqual(result.missingKeys, ["A:4:5"])
        XCTAssertEqual(result.stats.prunedDirectories, 1)
        XCTAssertEqual(result.stats.readSlateFiles, 1)
        let manifestURL = try XCTUnwrap(Bundle.module.url(forResource: "scanner-tree-manifest", withExtension: "json"), "Missing SM05 scanner-tree manifest")
        let manifest = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: manifestURL)) as? [String: Any])
        XCTAssertEqual(manifest["expectedMissingKeys"] as? [String], result.missingKeys)
    }

    func testRegistryBoundsSymlinksAndCancellationFailClosed() async throws {
        XCTAssertTrue(SlateMetadataParser.supports(sourceName: "A001C001-SLATE.TXT"))
        XCTAssertThrowsError(try SlateMetadataParser.parse(Data(sample.utf8), sourceName: "metadata.xml")) {
            XCTAssertEqual(($0 as? SlateSyncError)?.code, "METADATA_UNSUPPORTED")
        }
        XCTAssertEqual(MetadataStructure.learn(directoryName: "A001C001", metadataFileNames: ["camera-slate.txt"]), [.fixedName("camera-slate.txt")])

        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let target = root.appending(path: "A001C001", directoryHint: .isDirectory)
        let deep = root.appending(path: "level-1/level-2/A001C002", directoryHint: .isDirectory)
        let oversized = root.appending(path: "A001C004", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: deep, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: oversized, withIntermediateDirectories: true)
        let boundaryData = Data(sample.replacingOccurrences(of: "A004C004", with: "A001C001").utf8)
        try boundaryData.write(to: target.appending(path: "A001C001-slate.txt"))
        try Data(repeating: 0x41, count: 11).write(to: deep.appending(path: "A001C002-slate.txt"))
        var oversizedData = Data(sample.replacingOccurrences(of: "A004C004", with: "A001C004").utf8)
        oversizedData.append(0x20)
        try oversizedData.write(to: oversized.appending(path: "A001C004-slate.txt"))
        try FileManager.default.createSymbolicLink(at: root.appending(path: "A001C003", directoryHint: .isDirectory), withDestinationURL: target)

        let scanner = SlateMetadataScanner()
        let result = try await scanner.scan(directory: root, options: .init(expectedKeys: ["A:1:1", "A:1:2", "A:1:3", "A:1:4"], maxDepth: 1, maxFileBytes: boundaryData.count))
        XCTAssertEqual(result.metadata.map(\.materialKey), ["A:1:1"])
        XCTAssertEqual(result.missingKeys, ["A:1:2", "A:1:3", "A:1:4"])
        XCTAssertGreaterThanOrEqual(result.stats.skippedDeepDirectories, 1)
        XCTAssertTrue(result.warnings.contains { $0.contains("超过") })
        XCTAssertFalse(result.warnings.joined().contains(target.path))

        await XCTAssertSlateMetadataError("METADATA_EXPECTED_KEYS", try await scanner.scan(directory: root, options: .init(expectedKeys: [])))
        let cancelled = Task { () throws -> ScanResult in
            try Task.checkCancellation()
            return try await scanner.scan(directory: root, options: .init(expectedKeys: ["A:1:1"]))
        }
        cancelled.cancel()
        do { _ = try await cancelled.value; XCTFail("Expected cancellation") }
        catch is CancellationError { }
    }

    func testLearnedFixedNameIsReusedForSameCamera() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        for clip in [1, 2] {
            let prefix = "A001C\(String(format: "%03d", clip))"
            let directory = root.appending(path: prefix, directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let content = sample.replacingOccurrences(of: "A004C004", with: prefix)
            try Data(content.utf8).write(to: directory.appending(path: "camera-slate.txt"))
        }
        let result = try await SlateMetadataScanner().scan(directory: root, options: .init(expectedKeys: ["A:1:1", "A:1:2"]))
        XCTAssertEqual(result.metadata.map(\.materialKey), ["A:1:1", "A:1:2"])
        XCTAssertEqual(result.stats.learnedStructures, 1)
        XCTAssertEqual(result.stats.readSlateFiles, 2)
    }
}

private func XCTAssertSlateMetadataError<T>(_ code: String, _ expression: @autoclosure () async throws -> T, file: StaticString = #filePath, line: UInt = #line) async {
    do { _ = try await expression(); XCTFail("Expected \(code)", file: file, line: line) }
    catch { XCTAssertEqual((error as? SlateSyncError)?.code, code, file: file, line: line) }
}

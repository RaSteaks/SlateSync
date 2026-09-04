import CryptoKit
import Foundation
import XCTest
import SlateSyncDomain
@testable import SlateSyncWorkflow

final class ResolveCSVEngineTests: XCTestCase {
    private let expectedHashes: [String: (source: String, roundTrip: String)] = [
        "resolve-source.csv": ("6d4506de1908529ec73ccd309f66384ca29bd98ad69f62a9dae9e81d7b2cd1c0", "f53f385f9d583ab3c9b7844ebbba0cb47320b944e8cd171266386092f809397c"),
        "resolve-source-utf8.csv": ("7bff366094886aeac6b9ebbd84a40e5d5979e5b03d394660fd56ed435ef73e1e", "7bff366094886aeac6b9ebbd84a40e5d5979e5b03d394660fd56ed435ef73e1e"),
        "resolve-source-utf16le.csv": ("2d19d4bf372203f46428b36a779df6a7d4179dae5e6e62509457aedef217c88b", "2d19d4bf372203f46428b36a779df6a7d4179dae5e6e62509457aedef217c88b"),
        "resolve-source-utf16be.csv": ("c31fd875071678cc7db0278552c6c9a656c46e88b77fa7893f7f883926bbc2ea", "c31fd875071678cc7db0278552c6c9a656c46e88b77fa7893f7f883926bbc2ea"),
        "resolve-source-semicolon.csv": ("a95565d61d2d377d213bc3f3ed3b5d2095e389b807e7b517e2d0d0816e6e842a", "a95565d61d2d377d213bc3f3ed3b5d2095e389b807e7b517e2d0d0816e6e842a"),
    ]

    func testReviewedFixturesMatchSourceAndRoundTripByteGoldens() async throws {
        let engine = ResolveCSVEngine()
        for (name, hashes) in expectedHashes {
            let source = try fixture(name)
            XCTAssertEqual(sha256(source), hashes.source, name)
            let table = try await engine.decode(source)
            let encoded = try await engine.encode(table)
            XCTAssertEqual(sha256(encoded), hashes.roundTrip, name)
            XCTAssertFalse(encoded.isEmpty, name)
        }
        XCTAssertEqual(try fixture("resolve-source.csv").count, 156)
    }

    func testUTF8RoundTripPreservesQuotedNewline() async throws {
        let source = Data("File Name,Comments\r\nA001C001.mov,\"Line 1\nLine 2\"\r\n".utf8)
        let engine = ResolveCSVEngine()
        let table = try await engine.decode(source)
        let encoded = try await engine.encode(table)
        XCTAssertEqual(encoded, source)
    }

    func testRejectsMissingIdentifierAndUnclosedQuote() async throws {
        let engine = ResolveCSVEngine()
        await XCTAssertSlateErrorAsync("CSV_COLUMNS", try await engine.decode(Data("Scene,Shot\n1,2\n".utf8)))
        await XCTAssertSlateErrorAsync("CSV_QUOTES", try await engine.decode(Data("File Name,Notes\nA.mov,\"open".utf8)))
        await XCTAssertSlateErrorAsync("CSV_ENCODING", try await engine.decode(Data([0xFF, 0xFF, 0xFF])))
    }

    func testCROnlyNoFinalNewlineTrailingCellsAndMutationControl() async throws {
        let source = Data("File Name,Scene,Notes,\rA001C001.mov,,,".utf8)
        let engine = ResolveCSVEngine()
        let table = try await engine.decode(source)
        XCTAssertEqual(table.format.lineEnding, "\r")
        XCTAssertFalse(table.format.finalNewline)
        XCTAssertEqual(table.rows[0].count, 4)
        let encoded = try await engine.encode(table)
        XCTAssertEqual(encoded, source)

        var mutation = try fixture("resolve-source-utf8.csv")
        mutation[mutation.startIndex] ^= 0x01
        XCTAssertNotEqual(sha256(mutation), expectedHashes["resolve-source-utf8.csv"]?.source)
    }

    func testFormatValidationAndJavaScriptLineSeparatorCompatibility() async throws {
        let engine = ResolveCSVEngine()
        let source = Data("File Name,Notes\nA001C001.mov,line\u{2028}separator\n".utf8)
        let table = try await engine.decode(source)
        XCTAssertEqual(table.rows.count, 1)
        XCTAssertEqual(table.rows[0][1], "line\u{2028}separator")
        let roundTrip = try await engine.encode(table)
        XCTAssertEqual(roundTrip, source)

        let invalid = ResolveCSVTable(
            headers: ["File Name"], rows: [["A001C001.mov"]],
            format: .init(delimiter: "\n")
        )
        await XCTAssertSlateErrorAsync("CSV_FORMAT_INVALID", try await engine.encode(invalid))
    }

    private func fixture(_ name: String) throws -> Data {
        // Reviewed byte goldens are required inputs; absence must fail CI.
        let url = try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: nil), "Missing fixture \(name)")
        return try Data(contentsOf: url)
    }

    private func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

private func XCTAssertSlateErrorAsync<T>(_ code: String, _ expression: @autoclosure () async throws -> T, file: StaticString = #filePath, line: UInt = #line) async {
    do { _ = try await expression(); XCTFail("Expected \(code)", file: file, line: line) }
    catch { XCTAssertEqual((error as? SlateSyncError)?.code, code, file: file, line: line) }
}

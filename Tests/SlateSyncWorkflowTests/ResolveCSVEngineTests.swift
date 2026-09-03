import Foundation
import XCTest
@testable import SlateSyncWorkflow

final class ResolveCSVEngineTests: XCTestCase {
    func testUTF8RoundTripPreservesQuotedNewline() async throws {
        let source = Data("File Name,Comments\r\nA001.mov,\"Line 1\nLine 2\"\r\n".utf8)
        let engine = ResolveCSVEngine()
        let table = try await engine.decode(source)
        let encoded = try await engine.encode(table)
        XCTAssertEqual(encoded, source)
    }

    func testUTF16LittleEndianBOMRoundTrip() async throws {
        let text = "File Name;Scene\r\nA001.mov;001\r\n"
        let source = Data([0xFF, 0xFE]) + (text.data(using: .utf16LittleEndian) ?? Data())
        let engine = ResolveCSVEngine()
        let table = try await engine.decode(source)
        let encoded = try await engine.encode(table)
        XCTAssertEqual(encoded, source)
    }
}

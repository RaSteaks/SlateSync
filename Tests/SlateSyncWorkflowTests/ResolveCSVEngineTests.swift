import CryptoKit
import Foundation
import XCTest
import SlateSyncDomain
@testable import SlateSyncWorkflow

final class ResolveCSVEngineTests: XCTestCase {
    private let expectedHashes: [String: (source: String, roundTrip: String)] = [
        // Plain encoding preserves nonnumeric source cells; CSV quoting still canonicalizes.
        "resolve-source.csv": ("6d4506de1908529ec73ccd309f66384ca29bd98ad69f62a9dae9e81d7b2cd1c0", "8f16dfe37845c92db08cf078cd771a627b67653899027ef4dd26aa5961d604e0"),
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
            let reopened = try await engine.decode(encoded)
            XCTAssertEqual(reopened.rows, table.rows, "Encoding must not normalize source cells: \(name)")
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

    func testDeliveryFilesCarrySourceIdentityTimingAndEditedMetadata() async throws {
        let source = ResolveCSVTable(headers: ["File Name", "Clip Directory", "FPS", "Duration", "Start TC", "End TC",
            "Reel Name", "Resolution", "Tracks", "Scene", "Shot", "Take", "Comments", "Camera FPS", "Shoot Day"],
            rows: [["A & B.mov", "/Volumes/素材", "30000/1001", "00:00:02;00", "00:01:00;02", "00:01:02;02",
                    "R1", "1920x1080", "VA1A2", "007", "02", "03", "中文<&>\nnext\tnote", "60", "26-11-25"]], format: .init())
        let encoder = MetadataDeliveryEncoder()
        let ale = try await encoder.prepare(source, as: .ale, name: "Day 1")
        XCTAssertEqual(ale.preview, .avid(tape: "R1", start: "00:01:00;02", fps: "29.97"))
        let expected = "Heading\r\nFIELD_DELIM\tTABS\r\nVIDEO_FORMAT\t1080\r\nFPS\t29.97\r\n\r\nColumn\r\n"
            + "Name\tTracks\tStart\tEnd\tTape\tSource File\tScene\tShot\tTake\tComments\tCamera FPS\tShoot Day\r\n\r\nData\r\n"
            + "A & B.mov\tVA1A2\t00:01:00;02\t00:01:02;02\tR1\tA & B.mov\t007\t02\t03\t中文<&> next note\t60\t26-11-25\r\n"
        XCTAssertEqual(ale.data, Data(expected.utf8))

        for format in [MetadataDeliveryFormat.fcpxml, .xmeml] {
            let file = try await encoder.prepare(source, as: format, name: "Day <1>")
            XCTAssertEqual(file.preview, format == .xmeml ? .premiere(scene: "007", shotTake: "02/03") : nil)
            let xml = try XMLDocument(data: file.data)
            func value(_ xpath: String) throws -> String? { try xml.nodes(forXPath: xpath).first?.stringValue }
            let path: String?
            if format == .fcpxml {
                XCTAssertEqual(try value("/fcpxml/@version"), "1.9")
                XCTAssertEqual(try value("//event/@name"), "Day <1>")
                XCTAssertEqual(try value("//asset/@id"), try value("//asset-clip/@ref"))
                XCTAssertEqual(try value("//md[@key='com.apple.proapps.scene']/@value"), "007")
                XCTAssertEqual(try value("//md[@key='com.apple.proapps.reel']/@value"), "R1")
                XCTAssertEqual(try value("//asset-clip/note"), "中文<&>\nnext\tnote")
                path = try value("//media-rep/@src")
            } else {
                XCTAssertEqual(try value("/xmeml/@version"), "5")
                XCTAssertEqual(try value("//project/name"), "Day <1>")
                XCTAssertEqual(try value("//clip/duration"), "60")
                XCTAssertEqual(try value("//clip/rate/timebase"), "30")
                XCTAssertEqual(try value("//clip/rate/ntsc"), "TRUE")
                XCTAssertEqual(try value("//timecode/frame"), "1800")
                XCTAssertEqual(try value("//timecode/displayformat"), "DF")
                XCTAssertEqual(try value("//logginginfo/shottake"), "02/03")
                XCTAssertEqual(try value("//logginginfo/lognote"), "中文<&>\nnext\tnote")
                XCTAssertEqual(try value("//comments/mastercomment1"), "Camera FPS: 60")
                path = try value("//file/pathurl")
            }
            XCTAssertEqual(path.flatMap(URL.init(string:))?.path, "/Volumes/素材/A & B.mov")
        }
    }

    func testDeliveryRejectsUnusableMediaAndPreservesArbitraryColumnsInJSON() async throws {
        let encoder = MetadataDeliveryEncoder()
        var table = ResolveCSVTable(headers: ["File Name", "Tag", "Tag", "Camera FPS"],
            rows: [["A.mov", "", "same header", "120"]], format: .init())
        let data = try await encoder.encode(table, as: .json, name: "Test")
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(json["columns"] as? [String], table.headers)
        XCTAssertEqual(json["rows"] as? [[String]], table.rows)
        await XCTAssertSlateErrorAsync("DELIVERY_FIELD", try await encoder.encode(table, as: .fcpxml, name: "Test"))
        let root = URL(fileURLWithPath: "/Volumes/A")
        let xml = try await encoder.encode(table, as: .fcpxml, name: "Test", mediaDirectory: root)
        XCTAssertEqual(try XMLDocument(data: xml).nodes(forXPath: "//media-rep/@src").first?.stringValue, "file:///Volumes/A/A.mov")
        var network = table
        network.headers.append("File Path")
        network.rows[0].append(#"\\server\share\A.mov"#)
        let shared = try await encoder.encode(network, as: .fcpxml, name: "Test")
        XCTAssertEqual(try XMLDocument(data: shared).nodes(forXPath: "//media-rep/@src").first?.stringValue, "file://server/share/A.mov")
        // A sensor rate alone cannot set the playback timebase.
        await XCTAssertSlateErrorAsync("DELIVERY_FIELD", try await encoder.encode(table, as: .xmeml, name: "Test", mediaDirectory: root))
        table.headers = ["File Name", "FPS", "Video Format", "Start TC", "End TC", "Tracks", "Tape"]
        table.rows = [["A.mov", "29.97", "1080", "00:01:00;01", "00:02:00;02", "V", "R"]]
        await XCTAssertSlateErrorAsync("DELIVERY_FIELD", try await encoder.encode(table, as: .ale, name: "Test"))
        table.rows[0][3] = "00:01:00;02"
        table.rows.append(["B.mov", "25", "1080", "00:00:00:00", "00:00:02:00", "V", "R"])
        do {
            _ = try await encoder.prepare(table, as: .ale, name: "Test")
            XCTFail("Mixed playback rates need a worksheet correction")
        } catch DeliveryInputIssue.field(let row, let column, _) {
            XCTAssertEqual(row, 3)
            XCTAssertEqual(column, 1)
        }
        await XCTAssertSlateErrorAsync("DELIVERY_FIELD", try await encoder.encode(table, as: .ale, name: "Test"))
    }

    func testRejectsMissingIdentifierAndUnclosedQuote() async throws {
        let engine = ResolveCSVEngine()
        await XCTAssertSlateErrorAsync("CSV_COLUMNS", try await engine.decode(Data("Scene,Shot\n1,2\n".utf8)))
        await XCTAssertSlateErrorAsync("CSV_QUOTES", try await engine.decode(Data("File Name,Notes\nA.mov,\"open".utf8)))
        await XCTAssertSlateErrorAsync("CSV_ENCODING", try await engine.decode(Data([0xFF, 0xFF, 0xFF])))
    }

    func testRejectsInputAboveUnifiedBudget() async throws {
        // 统一预算 64 MiB：超限输入必须在解码前 fail-closed（媒体侧为 20 MiB），
        // 解析器不再无界保留字节/字符串/行数组多份拷贝。两个 CSV 入口——
        // Resolve CSV 与场记 CSV——都必须拒绝并返回同一错误码。
        let oversized = Data(count: CSVInputBudget.maximumInputBytes + 1)
        let engine = ResolveCSVEngine()
        await XCTAssertSlateErrorAsync("CSV_INPUT_SIZE", try await engine.decode(oversized))
        let slate = SlateCSVWorkflow()
        await XCTAssertSlateErrorAsync("CSV_INPUT_SIZE", try await slate.decode(oversized))
        // 预算边界内的合法输入不受影响。
        let table = try await engine.decode(Data("File Name,Scene\nA001C001.mov,1\n".utf8))
        XCTAssertEqual(table.rows.count, 1)
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

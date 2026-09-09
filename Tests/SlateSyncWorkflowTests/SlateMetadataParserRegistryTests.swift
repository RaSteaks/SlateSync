import Foundation
import SlateSyncDomain
import XCTest
@testable import SlateSyncWorkflow

/// SM-09 #14: sidecar parsing is registry-backed. Unknown sources fail
/// closed as METADATA_UNSUPPORTED, ambiguous sources as METADATA_AMBIGUOUS
/// (never first-match by registration order), and custom parsers join via
/// injected registries instead of editing the shipped parser.
final class SlateMetadataParserRegistryTests: XCTestCase {
    private let sample = [
        "# SLATE.TXT Revision 2.0",
        "Clip Name...........: A004C004_DEMO001",
        "Sensor FPS..........: 48",
        "Shot Date...........: 2026-08-04",
        "Project FPS.........: 24",
    ].joined(separator: "\r\n")

    /// A second vendor shape claiming `.slate.xml` sidecars.
    private struct XMLSidecarParser: SlateMetadataParsing {
        func supports(sourceName: String) -> Bool { sourceName.lowercased().hasSuffix("slate.xml") }
        func parse(_ data: Data, sourceName: String) throws -> ScannedSlateMetadata {
            let base = sourceName.split(separator: "/").last.map(String.init) ?? sourceName
            let key = ResolveCSVNormalization.extractCombinedMaterialKey(base)
            guard !key.isEmpty else {
                throw SlateSyncError(code: "METADATA_CLIP", message: "\(sourceName) 缺少可识别的 Clip Name")
            }
            return ScannedSlateMetadata(
                sourceName: sourceName,
                clipName: ResolveCSVNormalization.canonicalKeyToMaterialPrefix(key),
                materialKey: key,
                sensorFps: "24",
                shootDay: ""
            )
        }
    }

    /// A greedy parser whose registration order would shadow Kinefinity if
    /// the registry silently picked the first match.
    private struct GreedyParser: SlateMetadataParsing {
        func supports(sourceName: String) -> Bool { true }
        func parse(_ data: Data, sourceName: String) throws -> ScannedSlateMetadata {
            ScannedSlateMetadata(sourceName: sourceName, clipName: "GREEDY", materialKey: "G:9:9", sensorFps: "99", shootDay: "")
        }
    }

    func testDefaultRegistryRoutesKinefinitySlateText() throws {
        let registry = SlateMetadataParserRegistry.default
        XCTAssertTrue(registry.hasParser(matching: "A001C001-SLATE.TXT"))
        XCTAssertFalse(registry.hasParser(matching: "A001C001-slate.xml"))
        XCTAssertTrue(try registry.parser(matching: "camera-slate.txt") is KinefinitySlateTextParser)

        let viaRegistry = try registry.parse(Data(sample.utf8), sourceName: "A004C004_DEMO001-slate.txt")
        let viaFacade = try SlateMetadataParser.parse(Data(sample.utf8), sourceName: "A004C004_DEMO001-slate.txt")
        XCTAssertEqual(viaRegistry, viaFacade)
        XCTAssertEqual(viaRegistry.materialKey, "A:4:4")
    }

    func testUnregisteredSourceFailsClosed() {
        let registry = SlateMetadataParserRegistry.default
        XCTAssertFalse(registry.hasParser(matching: "notes.xml"))
        XCTAssertThrowsError(try registry.parse(Data(sample.utf8), sourceName: "notes.xml")) {
            XCTAssertEqual(($0 as? SlateSyncError)?.code, "METADATA_UNSUPPORTED")
        }
        // An empty registry rejects even Kinefinity-shaped names.
        let empty = SlateMetadataParserRegistry(parsers: [])
        XCTAssertThrowsError(try empty.parse(Data(sample.utf8), sourceName: "a-slate.txt")) {
            XCTAssertEqual(($0 as? SlateSyncError)?.code, "METADATA_UNSUPPORTED")
        }
    }

    func testAmbiguousSourceIsRejectedNotFirstMatch() async throws {
        let registry = SlateMetadataParserRegistry(parsers: [KinefinitySlateTextParser(), GreedyParser()])
        // The name stays discoverable, but resolution must fail closed.
        XCTAssertTrue(registry.hasParser(matching: "A001C001-slate.txt"))
        XCTAssertThrowsError(try registry.parser(matching: "A001C001-slate.txt")) {
            XCTAssertEqual(($0 as? SlateSyncError)?.code, "METADATA_AMBIGUOUS")
        }
        // The rejection must not quietly become the first parser's result.
        do {
            _ = try registry.parse(Data(sample.utf8), sourceName: "A001C001-slate.txt")
            XCTFail("歧义来源必须拒绝解析")
        } catch {
            XCTAssertEqual((error as? SlateSyncError)?.code, "METADATA_AMBIGUOUS")
        }

        // End to end: the scanner discovers the ambiguous file, fails to
        // parse it, and reports the ambiguity as a warning.
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appending(path: "A001C001_DEMO", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(sample.utf8).write(to: directory.appending(path: "A001C001_DEMO-slate.txt"))
        let result = try await SlateMetadataScanner(registry: registry).scan(
            directory: root,
            options: .init(expectedKeys: ["A:1:1"])
        )
        XCTAssertEqual(result.metadata, [])
        XCTAssertTrue(result.warnings.contains { $0.contains("同时识别") }, "\(result.warnings)")
    }

    func testCustomParserRegistryDrivesScannerEndToEnd() async throws {
        let registry = SlateMetadataParserRegistry(parsers: [XMLSidecarParser()])
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appending(path: "A001C001_DEMO", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("<slate/>".utf8).write(to: directory.appending(path: "A001C001_DEMO-slate.xml"))

        let result = try await SlateMetadataScanner(registry: registry).scan(
            directory: root,
            options: .init(expectedKeys: ["A:1:1"])
        )
        XCTAssertEqual(result.metadata.map(\.materialKey), ["A:1:1"])
        XCTAssertEqual(result.metadata.first?.sensorFps, "24")
        XCTAssertEqual(result.missingKeys, [])

        // The shipped registry must not silently adopt the custom name.
        let shipped = try await SlateMetadataScanner().scan(
            directory: root,
            options: .init(expectedKeys: ["A:1:1"])
        )
        XCTAssertEqual(shipped.metadata, [])
        XCTAssertEqual(shipped.stats.discoveredSlateFiles, 0)
        XCTAssertEqual(shipped.missingKeys, ["A:1:1"])
    }
}

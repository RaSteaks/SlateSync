import CryptoKit
import Foundation
import XCTest
import SlateSyncDomain
@testable import SlateSyncWorkflow

final class ResolveCSVMergerTests: XCTestCase {
    func testReviewedMergeAndStandaloneByteGoldens() async throws {
        let engine = ResolveCSVEngine()
        let merger = ResolveCSVMerger()
        let table = try await engine.decode(fixture("resolve-source.csv"))
        let result = try await merger.merge(
            source: table,
            records: [
                .init(cardNumber: "A001", videoCode: "C001", scene: "1 / 2a", shot: "2", take: "3", takeStatus: .passed),
                .init(cardNumber: "A001", videoCode: "C002", scene: "1234", shot: "100", take: "11", takeStatus: .hold),
                .init(cardNumber: "A001", videoCode: "C404", scene: nil, shot: "1", take: "1", takeStatus: .passed),
            ],
            metadata: [.init(materialKey: "A:1:1", sensorFps: "24", shootDay: "26-01-01")],
            comments: ResolveComments(goodTake: "YES", holdTake: "HOLD"),
            edits: [.init(rowIndex: 0, columnIndex: 5, value: "edited note")]
        )
        let merged = try await engine.encode(result.table, fieldFormats: .init(), comments: ResolveComments(goodTake: "YES", holdTake: "HOLD"), canonicalizeComments: true)
        XCTAssertEqual(merged.count, 196)
        XCTAssertEqual(sha256(merged), "c601ab2c779b2b4d474966fef727bb9225cb9c011e61b4f4de282fe4e1a89ab3")
        XCTAssertEqual(result.matchedRecordCount, 2)
        XCTAssertEqual(result.unrecognizedMaterials, ["A001C999"])

        let standalone = try await merger.standaloneTable(records: [
            .init(cardNumber: "A001", videoCode: "C001", scene: "37a", shot: "2", take: "11", comments: "HOLD"),
            .init(cardNumber: "A001", videoCode: "C002", scene: "1234", shot: "100", take: "3", comments: "YES"),
            .init(cardNumber: "A001", videoCode: "C003", scene: nil, shot: "1", take: "1"),
        ])
        let standaloneBytes = try await engine.encode(standalone)
        XCTAssertEqual(standaloneBytes.count, 120)
        XCTAssertEqual(sha256(standaloneBytes), "9e729ca8ad3abf1e7ac13eeca47b39b082463350ab5b207d92ff6733d25a94e9")
    }

    func testNormalizationMaterialKeysAndDuplicateConflictRules() async throws {
        XCTAssertEqual(ResolveCSVNormalization.normalizeScene("８７a"), "87A")
        XCTAssertEqual(ResolveCSVNormalization.normalizeShot("十一"), "11")
        XCTAssertEqual(ResolveCSVNormalization.normalizeTake("二"), "02")
        XCTAssertEqual(ResolveCSVNormalization.canonicalMaterialKey(cardNumber: "D001", videoCode: "C0009"), "D:1:9")
        XCTAssertEqual(ResolveCSVNormalization.canonicalMaterialKey(cardNumber: "Ｄ００１", videoCode: "Ｃ００９"), "")
        XCTAssertEqual(ResolveCSVNormalization.normalizeClipNumber("C1000"), "")

        let table = ResolveCSVTable(headers: ["File Name", "Scene"], rows: [["A001C001.mov", ""]], format: .init(encoding: .utf8, bom: false, delimiter: ",", lineEnding: "\n", finalNewline: true))
        let merger = ResolveCSVMerger()
        let equal = try await merger.merge(source: table, records: [
            .init(cardNumber: "A001", videoCode: "C001", scene: "1", shot: "2", take: "3", takeStatus: .passed),
            .init(cardNumber: "A001", videoCode: "C001", scene: "1", shot: "2", take: "3", takeStatus: .passed),
        ])
        XCTAssertEqual(equal.statuses.map { $0?.status }, ["matched", "duplicate"])
        let conflict = try await merger.merge(source: table, records: [
            .init(cardNumber: "A001", videoCode: "C001", scene: "1", shot: "2", take: "3"),
            .init(cardNumber: "A001", videoCode: "C001", scene: "9", shot: "2", take: "3"),
        ])
        XCTAssertEqual(conflict.statuses.map { $0?.status }, ["conflict", "conflict"])
    }

    func testAliasesIdentityMetadataCommentsEditsAndSequenceAudits() async throws {
        let table = ResolveCSVTable(
            headers: ["备注", "文件名", "Reel Name", "Clip Name", "Camera FPS", "Shoot Day"],
            rows: [
                ["△", "A001C001.mov", "A001", "C001", "23.98", ""],
                ["_KP", "A001C001-copy.mov", "A001", "C001", "", ""],
                ["X", "B001C002.mov", "A001", "C002", "keep", "keep"],
            ],
            format: .init()
        )
        let result = try await ResolveCSVMerger().merge(
            source: table,
            records: [
                .init(cardNumber: "A001", videoCode: "C001", scene: "８７a", shot: "十一", take: "二", takeStatus: .passed),
                .init(cardNumber: "A001", videoCode: "C003", scene: "1", shot: "2", take: "2"),
                .init(cardNumber: "A001", videoCode: "C005", scene: "1", shot: "3", take: "2"),
            ],
            metadata: [.init(materialKey: "A:1:1", sensorFps: "48", shootDay: nil)],
            comments: .init(goodTake: "YES", holdTake: "HOLD"),
            edits: [
                .init(rowIndex: 0, columnIndex: 0, value: "manual"),
                .init(rowIndex: 999, columnIndex: 0, value: "ignored"),
            ]
        )
        XCTAssertEqual(result.addedColumns, ["Shot", "Scene", "Take"])
        XCTAssertEqual(result.statuses[0]?.matchedRows, 2)
        XCTAssertEqual(result.table.rows[0][0], "manual")
        XCTAssertEqual(result.table.rows[1][0], "YES")
        XCTAssertEqual(result.table.rows[0][4], "48")
        XCTAssertEqual(result.table.rows[2][4], "keep")
        XCTAssertEqual(result.rowKeys[2], "")
        XCTAssertEqual(result.missingCameraFPSKeys, [])
        XCTAssertEqual(result.missingShootDayKeys, ["A:1:1"])
        XCTAssertEqual(result.sequenceAnomalies.map(\.type), ["clip-gap", "clip-gap"])
        XCTAssertTrue(result.warnings.contains { $0.contains("卷名与文件名指向不同素材") })

        let conflictMetadata = try await ResolveCSVMerger().merge(
            source: ResolveCSVTable(headers: ["File Name", "Camera FPS", "Shoot Day"], rows: [["A001C001.mov", "keep-fps", "old-day"]], format: .init()),
            records: [.init(cardNumber: "A001", videoCode: "C001", scene: "1", shot: "1", take: "1")],
            metadata: [
                .init(materialKey: "A:1:1", sensorFps: "24", shootDay: "26-09-05"),
                .init(materialKey: "A:1:1", sensorFps: "25", shootDay: "26-09-05"),
            ]
        )
        XCTAssertEqual(conflictMetadata.table.rows[0][1], "keep-fps")
        XCTAssertEqual(conflictMetadata.table.rows[0][2], "26-09-05")
        XCTAssertTrue(conflictMetadata.warnings.contains { $0.contains("互相冲突") })
    }

    func testJavaScriptAuditOrderAndRawSparseEditSemantics() async throws {
        let table = ResolveCSVTable(
            headers: ["File Name", "Reel Name", "Scene", "Shot", "Take", "Comments", "Camera FPS", "Shoot Day", "Notes"],
            rows: [
                ["A001C001.mov", "A001", "1", "1", "1", "legacy", "", "", " note "],
                ["B001C001.mov", "B001", "2", "1", "1", "legacy", "", "", ""],
                ["C001C001.mov", "D001", "3", "1", "1", "legacy", "", "", ""],
            ],
            format: .init()
        )
        let result = try await ResolveCSVMerger().merge(
            source: table,
            records: [
                .init(cardNumber: "B001", videoCode: "C001", scene: "2", shot: "1", take: "1", takeStatus: .passed),
                .init(cardNumber: "A001", videoCode: "C001", scene: "1", shot: "1", take: "1", takeStatus: .passed),
            ],
            metadata: [
                .init(materialKey: "C:1:1", sensorFps: "24", shootDay: nil),
                .init(materialKey: "C:1:1", sensorFps: "25", shootDay: nil),
                .init(materialKey: "B:1:1", sensorFps: "24", shootDay: nil),
                .init(materialKey: "A:1:1", sensorFps: "48", shootDay: nil),
            ],
            edits: [
                .init(rowIndex: 1, columnIndex: 8, value: "first"),
                .init(rowIndex: 0, columnIndex: 8, value: "note"),
            ]
        )
        XCTAssertTrue(result.warnings[0].hasPrefix("C001C001 的 slate.txt"), "metadata conflicts precede row identity warnings")
        XCTAssertEqual(result.table.rows[0][8], "note", "sparse edits compare and replace raw cell values")
        XCTAssertEqual(result.changes.filter { $0.field == "edit" }.map(\.rowIndex), [1, 0], "sparse edit audit follows request order")
        let sidecarRows = result.changes.filter { $0.field == "cameraFps" }.map(\.rowIndex)
        XCTAssertEqual(sidecarRows, [1, 0], "sidecar writes follow record insertion order")

        let sequence = try await ResolveCSVMerger().sequenceAnomalies([
            .init(cardNumber: "B001", videoCode: "C001", scene: "1", shot: "1", take: "1"),
            .init(cardNumber: "B001", videoCode: "C003", scene: "1", shot: "1", take: "2"),
            .init(cardNumber: "A001", videoCode: "C001", scene: "1", shot: "1", take: "1"),
            .init(cardNumber: "A001", videoCode: "C003", scene: "1", shot: "1", take: "2"),
        ])
        XCTAssertEqual(sequence.map(\.key), ["B:1:3", "A:1:3"])

        XCTAssertEqual(
            ResolveCSVNormalization.compactMaterialRanges(["A:1:1", "A:1:2", "A:1:4", "B:2:3"]),
            "A001 C001–C002、A001 C004、B002 C003"
        )
    }

    func testTenThousandRowIndexedMergeTimingAndScaling() async throws {
        // A missing performance manifest invalidates the evidence instead of
        // silently turning the deterministic workload into a skipped test.
        let manifestURL = try XCTUnwrap(Bundle.module.url(forResource: "performance-manifest", withExtension: "json"), "Missing SM05 performance manifest")
        let performanceManifest = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: manifestURL)) as? [String: Any])
        XCTAssertEqual(performanceManifest["seed"] as? String, "sm05-perf-v1")
        XCTAssertEqual(performanceManifest["rows"] as? Int, 10_000)
        XCTAssertEqual(performanceManifest["outputSha256"] as? String, "ad23d3d8236478d658cfa72a45b7703ba5f9ffc3eab8ebf27bcd644cbb7ad227")
        let engine = ResolveCSVEngine()
        let merger = ResolveCSVMerger()
        typealias Workload = (source: Data, records: [ResolveSlateRecord], metadata: [PersistedSlateMetadata], edits: [ResolveSparseEdit])
        func workload(_ count: Int) async throws -> Workload {
            func identity(_ index: Int) -> (camera: String, reel: Int, clip: Int, card: String, video: String, prefix: String) {
                let cameras = ["A", "B", "C", "D"]
                let camera = cameras[index % cameras.count]
                let reel = index / 400 + 1
                let clip = index % 400 + 1
                let card = "\(camera)\(String(format: "%03d", reel))"
                let video = "C\(String(format: "%03d", clip))"
                return (camera, reel, clip, card, video, card + video)
            }
            var rows: [[String]] = []
            var records: [ResolveSlateRecord] = []
            var metadata: [PersistedSlateMetadata] = []
            var edits: [ResolveSparseEdit] = []
            for index in 0..<count {
                let category = index % 20
                let rowIdentity = identity(category == 18 ? index - 3 : index)
                let reel = category == 19 ? "Z999" : rowIdentity.card
                let note = index.isMultiple(of: 97) ? "note, \"quoted\"\nline" : "note-\(index)"
                rows.append(["\(rowIdentity.prefix).mov", reel, rowIdentity.video, "", "", "", "", "", "", note, "u\(index % 7)", "v\(index % 11)"])
                if category < 16 {
                    let item = identity(index)
                    records.append(.init(cardNumber: item.card, videoCode: item.video, scene: "\(index % 250)", shot: "\(index % 80)", take: "\(index % 20)", takeStatus: index.isMultiple(of: 5) ? .hold : .passed))
                    if !index.isMultiple(of: 7) {
                        metadata.append(.init(materialKey: "\(item.camera):\(item.reel):\(item.clip)", sensorFps: index.isMultiple(of: 3) ? "48" : "24", shootDay: index.isMultiple(of: 11) ? nil : "26-09-05"))
                    }
                }
                if index.isMultiple(of: 100) { edits.append(.init(rowIndex: index, columnIndex: 9, value: "edited-\(index)")) }
            }
            let table = ResolveCSVTable(
                headers: ["File Name", "Reel Name", "Clip Name", "Scene", "Shot", "Take", "Comments", "Camera FPS", "Shoot Day", "Notes", "Custom A", "Custom B"],
                rows: rows,
                format: .init()
            )
            return (try await engine.encode(table), records, metadata, edits)
        }
        let small = try await workload(5_000), large = try await workload(10_000)
        let clock = ContinuousClock()

        func run(_ input: Workload) async throws -> (Double, Data, ResolveMergeResult) {
            let start = clock.now
            let decoded = try await engine.decode(input.source)
            let result = try await merger.merge(source: decoded, records: input.records, metadata: input.metadata, edits: input.edits)
            let output = try await engine.encode(result.table)
            return (Self.seconds(start.duration(to: clock.now)), output, result)
        }

        // Normal test runs retain a deterministic 10k semantic check. The
        // dedicated Release gate adds warm-up and five measured samples.
        guard ProcessInfo.processInfo.environment["SM05_PERFORMANCE_GATE"] == "1" else {
            let result = try await run(large)
            XCTAssertEqual(result.2.table.rows.count, 10_000)
            XCTAssertEqual(result.2.table.headers.count, 12)
            XCTAssertEqual(large.records.count, 8_000)
            XCTAssertEqual(large.edits.count, 100)
            XCTAssertEqual(sha256(result.1), "ad23d3d8236478d658cfa72a45b7703ba5f9ffc3eab8ebf27bcd644cbb7ad227")
            return
        }

        _ = try await run(large)
        var smallSamples: [Double] = []
        var largeSamples: [Double] = []
        var lastOutput = Data()
        for _ in 0..<5 {
            smallSamples.append(try await run(small).0)
            let measured = try await run(large)
            largeSamples.append(measured.0)
            lastOutput = measured.1
            XCTAssertEqual(measured.2.table.rows.count, 10_000)
        }
        let smallMedian = Self.median(smallSamples)
        let largeMedian = Self.median(largeSamples)
        print(String(format: "SM05 PERF-01 small=%@ large=%@ medians=%.6f/%.6f", smallSamples.map { String(format: "%.6f", $0) }.joined(separator: ","), largeSamples.map { String(format: "%.6f", $0) }.joined(separator: ","), smallMedian, largeMedian))
        XCTAssertEqual(sha256(lastOutput), "ad23d3d8236478d658cfa72a45b7703ba5f9ffc3eab8ebf27bcd644cbb7ad227")
        XCTAssertLessThanOrEqual(largeMedian, 2.0)
        XCTAssertLessThanOrEqual(largeSamples.max() ?? .infinity, 5.0)
        XCTAssertLessThanOrEqual(largeMedian / max(0.001, smallMedian), 2.5)
    }

    private func fixture(_ name: String) throws -> Data {
        let url = try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: nil), "Missing fixture \(name)")
        return try Data(contentsOf: url)
    }
    private func sha256(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    private static func seconds(_ duration: Duration) -> Double { Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18 }
    private static func median(_ values: [Double]) -> Double { values.sorted()[values.count / 2] }
}

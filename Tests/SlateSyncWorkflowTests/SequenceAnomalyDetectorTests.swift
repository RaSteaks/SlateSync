import SlateSyncDomain
import SlateSyncWorkflow
import XCTest

/// Regression freeze for review finding #9: one shared `SequenceAnomalyDetector`
/// owns the four sequence checks (duplicate, gap, regression, not starting
/// from 1) for both recognition and CSV export, with stable `type:key`
/// identity so the same anomaly is not reported twice across stages.
final class SequenceAnomalyDetectorTests: XCTestCase {
    private func record(
        _ card: String,
        _ clip: String,
        scene: String?,
        shot: String?,
        take: String?,
        reviewRequired: [String]? = nil
    ) -> SequenceAnomalyDetector.Input {
        .init(
            cardNumber: card,
            videoCode: clip,
            scene: scene,
            shot: shot,
            take: take,
            reviewRequiredFields: reviewRequired ?? []
        )
    }

    private func resolveRecord(
        _ card: String,
        _ clip: String,
        scene: String?,
        shot: String?,
        take: String?,
        reviewRequired: [String]? = nil
    ) -> ResolveSlateRecord {
        .init(
            cardNumber: card,
            videoCode: clip,
            scene: scene,
            shot: shot,
            take: take,
            reviewRequiredFields: reviewRequired ?? []
        )
    }

    func testDetectsAllFourAnomalyTypesWithStableKeys() throws {
        let anomalies = try SequenceAnomalyDetector.detect([
            record("A001", "C001", scene: "2", shot: "1", take: "1"),
            // clip gap: C002 missing between A001 C001 and C003.
            record("A001", "C003", scene: "2", shot: "1", take: "2"),
            // duplicate take inside the same shot.
            record("A001", "C004", scene: "2", shot: "1", take: "2"),
            // take jump inside the same shot.
            record("A001", "C005", scene: "2", shot: "1", take: "4"),
            // take regression inside the same shot.
            record("A001", "C006", scene: "2", shot: "1", take: "3"),
            // entering a new shot above take 1.
            record("A001", "C007", scene: "2", shot: "2", take: "2"),
        ])

        XCTAssertEqual(anomalies.map(\.type), [
            "clip-gap", "take-sequence", "take-sequence", "take-sequence", "take-sequence",
        ])
        XCTAssertEqual(anomalies.map(\.key), [
            "A:1:3", "A:1:4", "A:1:5", "A:1:6", "A:1:7",
        ])
        XCTAssertEqual(anomalies.map(\.stableKey), [
            "clip-gap:A:1:3", "take-sequence:A:1:4", "take-sequence:A:1:5", "take-sequence:A:1:6", "take-sequence:A:1:7",
        ])
        XCTAssertTrue(anomalies[0].message.contains("断档"), anomalies[0].message)
        XCTAssertTrue(anomalies[1].message.contains("次序可能重复"), anomalies[1].message)
        XCTAssertTrue(anomalies[2].message.contains("跳到"), anomalies[2].message)
        XCTAssertTrue(anomalies[3].message.contains("回落"), anomalies[3].message)
        XCTAssertTrue(anomalies[4].message.contains("通常应从 1 开始"), anomalies[4].message)
    }

    func testIgnoresUnparsableRecordsAndSortsClipsInsideReel() throws {
        let anomalies = try SequenceAnomalyDetector.detect([
            record("A001", "C003", scene: "2", shot: "1", take: "1"),
            // The unparsable row must not break the reel chain.
            record("B0XX", "C002", scene: "2", shot: "1", take: "9"),
            record("A001", "", scene: "2", shot: "1", take: "9"),
            record("A001", "C001", scene: "2", shot: "1", take: "1"),
        ])
        XCTAssertEqual(anomalies.map(\.type), ["clip-gap"])
        XCTAssertEqual(anomalies.map(\.key), ["A:1:3"])
    }

    func testReviewRequiredFieldsSuppressTakeSequenceButNotClipGap() throws {
        let anomalies = try SequenceAnomalyDetector.detect([
            record("A001", "C001", scene: "2", shot: "1", take: "1"),
            record("A001", "C003", scene: "2", shot: "1", take: "2", reviewRequired: ["take"]),
        ])
        // The clip gap stands on material identity alone; take checks need
        // confirmed scene/shot/take on both sides.
        XCTAssertEqual(anomalies.map(\.type), ["clip-gap"])
    }

    func testExcludingKnownStableKeysDedupesAcrossStages() throws {
        let records = [
            record("A001", "C001", scene: "2", shot: "1", take: "1"),
            record("A001", "C003", scene: "2", shot: "1", take: "2"),
        ]
        let firstStage = try SequenceAnomalyDetector.detect(records)
        XCTAssertEqual(firstStage.count, 1)
        let secondStage = try SequenceAnomalyDetector.detect(
            records,
            excluding: Set(firstStage.map(\.stableKey))
        )
        XCTAssertTrue(secondStage.isEmpty, "同一异常不得在识别与导出阶段重复报告")
    }

    // MARK: - recognition stage uses the shared detector

    private func recognitionRecord(
        _ card: String,
        _ clip: String,
        scene: String?,
        shot: String?,
        take: String?
    ) -> RecognitionRecord {
        .init(id: "\(card)-\(clip)", cardNumber: card, videoCode: clip, scene: scene, shot: shot, take: take, confidence: .high)
    }

    func testMergePagesReportsSharedDetectorMessagesAtRecognitionStage() {
        let sheet = RecognitionSheet(
            records: [
                recognitionRecord("A001", "C001", scene: "2", shot: "1", take: "1"),
                recognitionRecord("A001", "C003", scene: "2", shot: "1", take: "2"),
                recognitionRecord("A001", "C004", scene: "2", shot: "1", take: "2"),
            ],
            warnings: []
        )
        let merged = RecognitionPostprocessor.mergePages([(1, sheet)], accuracy: .standard, formats: .init())

        XCTAssertTrue(
            merged.warnings.contains { $0.contains("断档") && $0.contains("C002") },
            "识别阶段必须给出与导出一致的断档告警：\(merged.warnings)"
        )
        XCTAssertTrue(
            merged.warnings.contains { $0.contains("次序可能重复") },
            "识别阶段必须报告次序重复：\(merged.warnings)"
        )
        XCTAssertFalse(
            merged.warnings.contains { $0.contains("之间存在缺口") },
            "旧的识别专用缺口文案应统一为共享检测器文案：\(merged.warnings)"
        )
    }

    func testFastModeAdvisoryCountsSharedDetectorAnomalies() {
        let sheet = RecognitionSheet(
            records: [
                recognitionRecord("A001", "C001", scene: "2", shot: "1", take: "1"),
                recognitionRecord("A001", "C003", scene: "2", shot: "1", take: "2"),
                recognitionRecord("A001", "C004", scene: "2", shot: "1", take: "2"),
            ],
            warnings: []
        )
        let fast = RecognitionPostprocessor.mergePages([(1, sheet)], accuracy: .standard, formats: .init())
        XCTAssertTrue(fast.warnings.contains { $0.contains("快速模式仅执行单次识别") && $0.contains("2 条序列异常") }, fast.warnings.joined(separator: "；"))

        let high = RecognitionPostprocessor.mergePages([(1, sheet)], accuracy: .high, formats: .init())
        XCTAssertFalse(high.warnings.contains { $0.contains("快速模式仅执行单次识别") })
    }

    // MARK: - CSV export stage shares the detector and honours dedupe

    func testMergerSequenceAnomaliesDelegateToSharedDetector() async throws {
        let records = [
            resolveRecord("A001", "C001", scene: "2", shot: "1", take: "1"),
            resolveRecord("A001", "C003", scene: "2", shot: "1", take: "2"),
        ]
        let merger = ResolveCSVMerger()
        let merged = try await merger.sequenceAnomalies(records)
        XCTAssertEqual(
            merged,
            try SequenceAnomalyDetector.detect(records.map(SequenceAnomalyDetector.Input.init))
        )
    }

    func testMergeExcludesAnomaliesAlreadyReportedAtRecognitionStage() async throws {
        let source = ResolveCSVTable(
            headers: ["File Name", "Scene", "Shot", "Take", "Comments"],
            rows: [
                ["A001C001.mov", "", "", "", ""],
                ["A001C003.mov", "", "", "", ""],
            ],
            format: .init()
        )
        let records = [
            resolveRecord("A001", "C001", scene: "2", shot: "1", take: "1"),
            resolveRecord("A001", "C003", scene: "2", shot: "1", take: "2"),
        ]
        let merger = ResolveCSVMerger()
        let plain = try await merger.merge(source: source, records: records)
        XCTAssertEqual(plain.sequenceAnomalies.count, 1)

        let recognitionKeys = Set(try SequenceAnomalyDetector.detect(records.map(SequenceAnomalyDetector.Input.init)).map(\.stableKey))
        let deduped = try await merger.merge(source: source, records: records, knownAnomalyKeys: recognitionKeys)
        XCTAssertTrue(deduped.sequenceAnomalies.isEmpty, "导出阶段不得重复报告识别阶段已给出的异常")
    }
}

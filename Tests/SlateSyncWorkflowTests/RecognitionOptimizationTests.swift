import CoreGraphics
import Foundation
import SlateSyncDomain
import SlateSyncMedia
@testable import SlateSyncWorkflow
import XCTest

private actor StagedFixtureEngine: StagedLocalOCREngine {
    let cancelDetails: Bool
    let empty: Bool
    var counts: [Int] = []
    var deadlines: [Double] = []
    var formats: [LocalOCRImage.Format] = []
    init(cancelDetails: Bool = false, empty: Bool = false) {
        self.cancelDetails = cancelDetails; self.empty = empty
    }
    var supportsLosslessInput: Bool { true }
    func recognize(_ document: PreparedDocument, operation: MediaOperation, progress: MediaProgressSink?) async throws -> OCREngineResult {
        try await recognize(document, localImages: nil, deadline: nil, operation: operation, progress: progress)
    }
    func recognize(_ document: PreparedDocument, localImages: [[LocalOCRImage]]?, deadline: OCRDeadline?,
                   operation: MediaOperation, progress: MediaProgressSink?) async throws -> OCREngineResult {
        counts.append(document.viewCount)
        if let deadline { deadlines.append(deadline.end) }
        formats += localImages?.flatMap { $0 }.map(\.format) ?? []
        if cancelDetails && counts.count == 2 { operation.cancel(); throw MediaFailure.canceled }
        return .init(engine: .vision, modelVersion: "fixture", pages: document.pages.map { page in
            .init(pageNumber: page.pageNumber, views: page.views.map { view in
                .init(viewIndex: view.viewIndex, viewType: view.viewType, width: view.image.width, height: view.image.height,
                    blocks: empty ? [] : [.init(order: 0, text: "C001", confidence: 0.9,
                                               bbox: [10,10,20,20], bboxNormalized: [0.1,0.1,0.2,0.2])])
            })
        })
    }
    func close() {}
}

@MainActor final class RecognitionOptimizationTests: XCTestCase {
    func testKnownSourceCoordinatesAndStitchedBoundaryAbstention() throws {
        let mapping = RecognitionViewMapping(page: try .init(left: 0.2, top: 0.3, right: 0.6, bottom: 0.9))
        let projected = try XCTUnwrap(mapping.pageRegion(for: .init(left: 0.25, top: 0.25, right: 0.75, bottom: 0.75)))
        // Independent expected landmarks, not another copy of the transform.
        XCTAssertEqual(projected.left, 0.3, accuracy: 0.000001)
        XCTAssertEqual(projected.top, 0.45, accuracy: 0.000001)
        XCTAssertEqual(projected.right, 0.5, accuracy: 0.000001)
        XCTAssertEqual(projected.bottom, 0.75, accuracy: 0.000001)
        let stitched = RecognitionViewMapping(pieces: [
            .init(view: try .init(left: 0, top: 0, right: 1, bottom: 0.2), page: try .init(left: 0, top: 0, right: 1, bottom: 0.1)),
            .init(view: try .init(left: 0, top: 0.2, right: 1, bottom: 1), page: try .init(left: 0, top: 0.5, right: 1, bottom: 1)),
        ])
        XCTAssertNil(stitched.pageRegion(for: try .init(left: 0.1, top: 0.15, right: 0.2, bottom: 0.25)))
    }

    func testMeasuredGridPreservesMergedSceneAndUnassignedCrossColumnText() throws {
        let structure = try layout()
        XCTAssertEqual(structure.rows.count, 3)
        XCTAssertEqual(structure.columns.map(\.field), ["scene", "shot", "take", "videoCode"])
        XCTAssertEqual(structure.cells.first { $0.column == 0 }?.rowSpan, 3)
        XCTAssertTrue(structure.unassigned.contains(8))
        XCTAssertFalse(structure.detailRegions.isEmpty)
        XCTAssertTrue(structure.detailRegions.allSatisfy { $0.right >= 0.9 })
        let hints = RecognitionStructureEvidence.format(structure, fullMapping: .init(page: .full), maximumCharacters: 600)
        XCTAssertLessThanOrEqual(hints.utf16.count, 600)
        XCTAssertFalse(hints.contains("A001"), "Geometry hints must not become recognized field values")
    }

    func testMissingGridFallsBackAndChangedReelPreventsTargeting() throws {
        let missing = try layout(hasRules: false)
        XCTAssertNil(missing.region)
        XCTAssertTrue(missing.detailRegions.isEmpty)
        let record = RecognitionRecord(id: "r", sourcePage: 1, cardNumber: "A001", videoCode: "C001", confidence: .high)
        let located = try XCTUnwrap(RecognitionReviewPlanner.regions(for: [record], structure: layout()))
        XCTAssertEqual(located.count, 1)
        XCTAssertLessThanOrEqual(located[0].top, 0.2)
        XCTAssertGreaterThanOrEqual(located[0].bottom, 0.8)
        XCTAssertNil(try RecognitionReviewPlanner.regions(for: [record], structure: layout(extraReel: true)))
    }

    func testStagedFallbackUsesSameJPEGViewsAndSingleDeadline() async throws {
        let input = try pdf()
        let baseline = try await MediaPreparationService().prepare(input)
        let engine = StagedFixtureEngine()
        let ocr = LocalOCRService(vision: engine, paddle: nil, settings: .init(), visionAvailable: true, paddleAvailable: false, cacheByView: true)
        let workflow = MediaOCRWorkflow(ocr: ocr, policy: .init(dynamicCrops: true, losslessLocalOCR: true))
        let result = try await workflow.run(input: input, session: "stage", cacheEnabled: false)
        XCTAssertEqual(result.document, baseline)
        let counts = await engine.counts, deadlines = await engine.deadlines, formats = await engine.formats
        XCTAssertEqual(counts, [1, 2], "Full view must not be inferred twice")
        XCTAssertEqual(deadlines.count, 2)
        XCTAssertEqual(Set(deadlines).count, 1)
        XCTAssertEqual(formats, [.png, .png, .png])
        await workflow.close()
    }

    func testCancellationInDetailStageDoesNotPublishArtifact() async throws {
        let engine = StagedFixtureEngine(cancelDetails: true)
        let workflow = MediaOCRWorkflow(ocr: LocalOCRService(vision: engine, paddle: nil, settings: .init(),
            visionAvailable: true, paddleAvailable: false), policy: .init(dynamicCrops: true))
        do {
            _ = try await workflow.run(input: pdf(), session: "cancel", cacheEnabled: false,
                consume: { _, _ in XCTFail("Canceled work must not reach downstream") })
            XCTFail("Expected cancellation")
        } catch { XCTAssertEqual((error as? SlateSyncError)?.code, "RECOGNITION_CANCELED") }
        await workflow.close()
    }

    func testRequiredEmptyDocumentAndRestoredViewFallback() async throws {
        let emptyEngine = StagedFixtureEngine(empty: true)
        let required = MediaOCRWorkflow(ocr: LocalOCRService(vision: emptyEngine, paddle: nil,
            settings: .init([.visionOCRRequired: "true"]), visionAvailable: true, paddleAvailable: false),
            policy: .init(dynamicCrops: true))
        do { _ = try await required.run(input: pdf(), session: "empty"); XCTFail("Required empty evidence must fail") }
        catch { XCTAssertEqual((error as? SlateSyncError)?.code, "OCR_REQUIRED") }
        await required.close()
        let saved = try await MediaPreparationService().prepare(pdf())
        let restored = MediaOCRWorkflow(ocr: LocalOCRService(vision: StagedFixtureEngine(), paddle: nil, settings: .init(),
            visionAvailable: true, paddleAvailable: false), policy: .init(dynamicCrops: true, targetedReview: true))
        let result = try await restored.run(input: .bytes(Data(), filename: "missing.pdf"), session: "restored", preparedDocument: saved)
        XCTAssertEqual(result.document, saved)
        XCTAssertNil(result.optimization?.source)
        XCTAssertFalse(result.optimization?.diagnostics.isEmpty ?? true)
        await restored.close()
    }

    func testReviewRecropPreservesFullImageAndDropsOldDetailCoordinates() async throws {
        let source = try await MediaPreparationService().recognitionSource(pdf(), operation: .init())
        let images = try await source.compatibleViews(pageNumber: 1, includesDetails: true, lossless: false, operation: .init())
        let page = PreparedMediaPage(pageNumber: 1, views: images.enumerated().map {
            .init(viewIndex: $0.offset, viewType: $0.offset == 0 ? .full : .coreDetail, image: $0.element.image)
        })
        let context = RecognitionMediaContext(policy: .init(targetedReview: true), source: source,
            structures: [1: try layout()], fullMappings: [1: images[0].mapping], diagnostics: [])
        let evidence = OCRViewEvidence(viewIndex: 0, viewType: .full, width: page.views[0].image.width,
            height: page.views[0].image.height, blocks: [.init(order: 0, text: "C001", confidence: 0.9,
                bbox: [1,1,2,2], bboxNormalized: [0.1,0.1,0.2,0.2])])
        let provider = try XCTUnwrap(context.reviewProvider(page: page, fullEvidence: evidence,
                                                          originalEvidence: "old_detail_marker"))
        let selected = try await provider([.init(id: "r", cardNumber: "A001", videoCode: "C001", confidence: .high)])
        XCTAssertEqual(selected.images.first, page.views.first?.image)
        XCTAssertEqual(selected.images.count, 2)
        XCTAssertNil(selected.warning)
        XCTAssertTrue(selected.evidence.contains("C001"))
        XCTAssertFalse(selected.evidence.contains("old_detail_marker"))
        let missing = try await provider([.init(id: "missing", cardNumber: "A001", videoCode: "C099", confidence: .high)])
        XCTAssertEqual(missing.images, page.views.map(\.image))
        XCTAssertEqual(missing.evidence, "old_detail_marker")
        XCTAssertNotNil(missing.warning)
    }

    private func layout(hasRules: Bool = true, extraReel: Bool = false) throws -> RecognitionTableStructure {
        // Explicit physical fixture: scene spans three rows; the other columns
        // have separators at .4 and .6. One text box straddles the scene/shot edge.
        var entries: [(String, [Double])] = [
            ("场次", [0.13,0.16,0.20,0.18]), ("镜", [0.28,0.16,0.34,0.18]),
            ("次", [0.43,0.16,0.49,0.18]), ("视频码", [0.62,0.16,0.75,0.18]),
            ("A机", [0.60,0.09,0.70,0.12]), ("A001", [0.40,0.03,0.50,0.07]),
            ("037", [0.13,0.22,0.20,0.27]), ("C001", [0.63,0.23,0.73,0.27]),
            ("跨格", [0.23,0.43,0.28,0.47]),
        ]
        if extraReel { entries.append(("A002", [0.55,0.03,0.65,0.07])) }
        let view = OCRViewEvidence(viewIndex: 0, viewType: .full, width: 1000, height: 1000,
            blocks: entries.enumerated().map { .init(order: $0.offset, text: $0.element.0, confidence: 0.99,
                                                   bbox: [0,0,1,1], bboxNormalized: $0.element.1) })
        let vertical = [0.1,0.25,0.4,0.55,0.9].map { TableRule(axis: .vertical, position: $0, start: 0.12, end: 0.8) }
        let horizontal = [TableRule(axis: .horizontal, position: 0.2, start: 0.1, end: 0.9),
            .init(axis: .horizontal, position: 0.4, start: 0.25, end: 0.9),
            .init(axis: .horizontal, position: 0.6, start: 0.25, end: 0.9),
            .init(axis: .horizontal, position: 0.8, start: 0.1, end: 0.9)]
        return try RecognitionLayoutPlanner.plan(full: view, mapping: .init(page: .full),
            geometry: .init(rules: hasRules ? vertical + horizontal : [], sampleWidth: 1000, sampleHeight: 1000))
    }

    private func pdf() throws -> MediaInput {
        let bytes = NSMutableData()
        let consumer = try XCTUnwrap(CGDataConsumer(data: bytes as CFMutableData))
        var box = CGRect(x: 0, y: 0, width: 200, height: 250)
        let context = try XCTUnwrap(CGContext(consumer: consumer, mediaBox: &box, nil))
        context.beginPDFPage(nil)
        context.setFillColor(CGColor(gray: 0, alpha: 1))
        context.fill(CGRect(x: 10, y: 80, width: 100, height: 120))
        context.endPDFPage(); context.closePDF()
        return .bytes(bytes as Data, filename: "fixture.pdf")
    }
}

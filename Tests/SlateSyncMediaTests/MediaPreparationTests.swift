import CoreGraphics
import Foundation
import ImageIO
import SlateSyncDomain
@testable import SlateSyncMedia
import XCTest

// Fixtures come exclusively from Bundle.module; files/races use temporary roots.
func mediaFixture(_ name: String) throws -> Data {
    let url = try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: nil))
    return try Data(contentsOf: url)
}
func mediaFixtureURL(_ name: String) throws -> URL { try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: nil)) }

@MainActor final class MediaPreparationTests: XCTestCase {
    func testIndependentGeometryOracles() throws {
        struct Bands: Decodable { let width: Int; let height: Int; let rows: [Int]; let expected: ImagePreprocessing.Band }
        struct Segments: Decodable { let height: Int; let expected: ImagePreprocessing.Layout }
        struct Widths: Decodable { let width: Int; let expected: Int }
        struct Oracle: Decodable { let bands: [Bands]; let segments: [Segments]; let widths: [Widths] }
        let oracle = try JSONDecoder().decode(Oracle.self, from: mediaFixture("geometry.json"))
        for sample in oracle.bands {
            var rgba = [UInt8](repeating: 255, count: sample.width * sample.height * 4)
            for y in sample.rows { for x in 0..<sample.width { for c in 0..<3 { rgba[(y * sample.width + x) * 4 + c] = 0 } } }
            XCTAssertEqual(try ImagePreprocessing.denseRowBand(rgba: rgba, width: sample.width, height: sample.height), sample.expected)
        }
        for sample in oracle.segments { XCTAssertEqual(ImagePreprocessing.detailSegments(height: sample.height), sample.expected) }
        for sample in oracle.widths { XCTAssertEqual(ImagePreprocessing.coreColumnWidth(sample.width), sample.expected) }
    }
    func testRasterKindsOrientationAlphaAndRepeatedHeaders() async throws {
        let service = MediaPreparationService()
        for name in ["slate-alpha.png", "slate.jpg", "slate.webp", "slate-exif6.jpg", "tiny.png"] {
            let document = try await service.prepare(.bytes(mediaFixture(name), filename: "no-extension"))
            let views = document.pages[0].views
            try exportViews(views, prefix:name)
            XCTAssertEqual(views.map(\.viewIndex), [0,1,2]); XCTAssertEqual(views.map(\.viewType), [.full,.coreDetail,.coreDetail])
            for view in views { XCTAssertNoThrow(try ImageRasterizer.decode(view.image.jpeg, maximum: 3000)) }
            if name == "tiny.png" { XCTAssertEqual(views[0].image.width, 1); continue }
            let rotated = name == "slate-exif6.jpg"
            XCTAssertEqual(views[0].image.width, rotated ? 1000 : 800)
            XCTAssertEqual(views[0].image.height, rotated ? 800 : 1000)
            let red = try pixel(views[0].image.jpeg, x: rotated ? 0.94 : 0.08, y: 0.07)
            XCTAssertGreaterThanOrEqual(red[0], 180); XCTAssertLessThanOrEqual(red[1], 80); XCTAssertLessThanOrEqual(red[2], 80)
            if !rotated {
                for view in views.dropFirst() {
                    let header = try pixel(view.image.jpeg, x: 0.1, y: 0.06)
                    XCTAssertGreaterThanOrEqual(header[0], 180); XCTAssertLessThanOrEqual(header[1], 80)
                    XCTAssertEqual(max(view.image.width, view.image.height), 3000)
                }
            }
            if name == "slate-alpha.png" {
                let white = try pixel(views[0].image.jpeg, x: 0.95, y: 0.1)
                XCTAssertTrue(white.prefix(3).allSatisfy { $0 >= 240 })
            }
        }
    }
    func testPDFPageLimitsBoxesRotationAndErrors() async throws {
        let service = MediaPreparationService()
        for count in [1,20] {
            let document = try await service.prepare(.bytes(mediaFixture("pages-\(count).pdf"), filename: "pages.pdf"))
            XCTAssertEqual(document.pages.map(\.pageNumber), Array(1...count))
            if count == 1 { try exportViews(document.pages[0].views,prefix:"pages-1.pdf") }
            if let root = ProcessInfo.processInfo.environment["SM06_ARTIFACT_ROOT"] {
                // Opt-in diagnostic images use the Gate's explicit temporary root.
                try document.pages[0].views[0].image.jpeg.write(to: URL(fileURLWithPath: root).appendingPathComponent("pdf-full.jpg"))
                let raw = try PDFRasterizer.render(XCTUnwrap(PDFRasterizer.document(mediaFixture("pages-1.pdf")).page(at: 0)))
                try PreparedImageEncoder.encode(raw, maximum: 2600, quality: 0.92).jpeg.write(to: URL(fileURLWithPath: root).appendingPathComponent("pdf-raw.jpg"))
            }
            XCTAssertTrue(document.pages.allSatisfy { $0.views.count == 3 && $0.views[0].image.width == 800 && $0.views[0].image.height == 1000 })
        }
        for (name, code) in [("pages-21.pdf","PDF_PAGE_LIMIT"),("empty.pdf","PDF_EMPTY"),("locked.pdf","PDF_PASSWORD"),("broken.pdf","PDF_INVALID")] {
            do { _ = try await service.prepare(.bytes(mediaFixture(name), filename: name)); XCTFail(name) }
            catch { XCTAssertEqual((error as? SlateSyncError)?.code, code, name) }
        }
        let rotated = try await service.prepare(.bytes(mediaFixture("rotated.pdf"), filename: "rotated.pdf"))
        try exportViews(rotated.pages[0].views,prefix:"rotated.pdf")
        XCTAssertEqual(rotated.pages[0].views[0].image.width, 1000); XCTAssertEqual(rotated.pages[0].views[0].image.height, 800)
        let red = try pixel(rotated.pages[0].views[0].image.jpeg, x: 0.94, y: 0.07)
        XCTAssertGreaterThanOrEqual(red[0], 180); XCTAssertLessThanOrEqual(red[2], 80)
        let crop = try PDFRasterizer.render(XCTUnwrap(PDFRasterizer.document(mediaFixture("crop.pdf")).page(at: 0)))
        XCTAssertEqual(crop.width, 640); XCTAssertEqual(crop.height, 800)
        let huge = try PDFRasterizer.render(XCTUnwrap(PDFRasterizer.document(mediaFixture("huge-bounds.pdf")).page(at: 0)))
        XCTAssertEqual(huge.width,3000);XCTAssertEqual(huge.height,3000)
        XCTAssertThrowsError(try PDFRasterizer.render(XCTUnwrap(PDFRasterizer.document(mediaFixture("invalid-bounds.pdf")).page(at:0))))
    }
    func testInputByteBoundaryRegularFileAndCancellation() async throws {
        let service = MediaPreparationService(), bytes = try mediaFixture("tiny.png")
        var maximum = bytes
        maximum.append(Data(repeating:0,count:20 * 1024 * 1024 - bytes.count))
        _ = try await service.prepare(.bytes(maximum,filename:"maximum.png"))
        maximum.append(0)
        do { _ = try await service.prepare(.bytes(maximum,filename:"oversized.png"));XCTFail() }
        catch { XCTAssertEqual((error as? SlateSyncError)?.code,"MEDIA_SIZE") }
        _ = try await service.prepare(.bytes(bytes, filename: "disguised.pdf"), options: .init(maximumInputBytes: bytes.count))
        do { _ = try await service.prepare(.bytes(bytes, filename: "tiny.png"), options: .init(maximumInputBytes: bytes.count - 1)); XCTFail() }
        catch { XCTAssertEqual((error as? SlateSyncError)?.code, "MEDIA_SIZE") }
        for data in [Data(), Data("not an image".utf8), Data(bytes.prefix(16))] {
            do { _ = try await service.prepare(.bytes(data, filename: "fake.png")); XCTFail() } catch {}
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("中文 image.png"), link = root.appendingPathComponent("link.png")
        try bytes.write(to: file); try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
        _ = try await service.prepare(.file(file))
        for url in [link,root] { do { _ = try await service.prepare(.file(url)); XCTFail() } catch {} }
        let op = MediaOperation()
        do { _ = try await service.prepare(.bytes(mediaFixture("pages-20.pdf"), filename: "pages.pdf"), operation: op, progress: { _ in op.cancel() }); XCTFail() }
        catch { XCTAssertEqual((error as? SlateSyncError)?.code, "RECOGNITION_CANCELED") }
        _ = try await service.prepare(.bytes(bytes, filename: "retry.png"))
        // Analysis/encoding and compression receive the same cancellation
        // latch, including a cancellation triggered by the request serializer.
        let canceled = MediaOperation();canceled.cancel()
        XCTAssertThrowsError(try ImagePreprocessing.denseRowBand(rgba:[255,255,255,255],width:1,height:1,operation:canceled))
        let prepared = try await service.prepare(.bytes(bytes,filename:"retry.png"))
        do { _ = try await service.recompress(prepared,profile:ImageCompressionProfile.requestProfiles[0],operation:canceled);XCTFail() }
        catch { XCTAssertEqual((error as? SlateSyncError)?.code,"RECOGNITION_CANCELED") }
        let measuring = MediaOperation()
        do {
            _ = try await MediaRequestBudget.fit(prepared,compressor:service,operation:measuring) { _ in measuring.cancel();return 0 }
            XCTFail()
        } catch { XCTAssertEqual((error as? SlateSyncError)?.code,"RECOGNITION_CANCELED") }
    }
    func testSelectionCompressionUTF8BudgetAndLegacyPDF() async throws {
        let service = MediaPreparationService()
        let original = try await service.prepare(.bytes(mediaFixture("slate.jpg"), filename: "slate.jpg"))
        XCTAssertEqual(original.selected(.standard).viewCount, 1); XCTAssertEqual(original.selected(.high).viewCount, 3)
        var candidate = original
        for profile in ImageCompressionProfile.requestProfiles {
            candidate = try await service.recompress(candidate, profile: profile)
            XCTAssertEqual(candidate.viewCount, 3)
            XCTAssertTrue(candidate.pages.flatMap(\.views).allSatisfy { max($0.image.width,$0.image.height) <= profile.maxDimension })
        }
        XCTAssertEqual(original.pages[0].views[1].image.height, 3000)
        let fitted = try await MediaRequestBudget.fit(original, maxRequestBytes: 100, compressor: service) { _ in 94 }
        XCTAssertEqual(fitted, original)
        do { _ = try await MediaRequestBudget.fit(original, maxRequestBytes: 100, compressor: service) { _ in 95 }; XCTFail() }
        catch { XCTAssertEqual((error as? SlateSyncError)?.code, "MEDIA_REQUEST_SIZE") }
        let prompt = "中文😀"
        XCTAssertEqual(prompt.utf8.count, 10)
        let measured = try await MediaRequestBudget.fit(original, maxRequestBytes: 11, compressor: service) { _ in prompt.utf8.count }
        XCTAssertEqual(measured, original)
        XCTAssertThrowsError(try PreparedDocument.rejectLegacyPDF(in: Data(#"{"pdfDataUrl":null}"#.utf8)))
        XCTAssertThrowsError(try PreparedImage(jpeg: Data("%PDF-1.7".utf8), width: 1, height: 1))
        let roundtrip = try JSONDecoder().decode(PreparedDocument.self, from: JSONEncoder().encode(original))
        XCTAssertEqual(roundtrip, original)
        let measure: @Sendable (PreparedDocument) throws -> Int = { document in
            let body:JSONValue = .object(["customPrompt":.string("中文😀"),"scenarioId":.string("场记结构"),"slateCsvRecords":.array([.object(["scene":.string("12A")])]),"imageDataGroups":.array(document.pages.map { .array($0.views.map { .string($0.image.dataURL) }) })])
            return try JSONEncoder().encode(body).count
        }
        let completeBytes = try measure(original)
        let complete = try await MediaRequestBudget.fit(original,maxRequestBytes:Int(ceil(Double(completeBytes)/0.94)),compressor:service,measure:measure)
        XCTAssertEqual(complete,original)
        let compressed = try await MediaRequestBudget.fit(original,maxRequestBytes:Int(floor(Double(completeBytes)/0.94))-1,compressor:service,measure:measure)
        XCTAssertEqual(compressed.pages.count,original.pages.count);XCTAssertEqual(compressed.viewCount,3)
        XCTAssertNotEqual(compressed,original)
    }
    private func pixel(_ data: Data, x: Double, y: Double) throws -> [UInt8] {
        let image = try ImageRasterizer.decode(data, maximum: 3000)
        let ctx = try PreparedImageEncoder.context(width: image.width, height: image.height)
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let pointer = try XCTUnwrap(ctx.data).assumingMemoryBound(to: UInt8.self)
        let offset = (Int(Double(image.height) * y) * image.width + Int(Double(image.width) * x)) * 4
        return Array(UnsafeBufferPointer(start: pointer + offset, count: 4))
    }
    private func exportViews(_ views: [PreparedMediaView], prefix: String) throws {
        // Review artifacts are opt-in and never become native-generated goldens.
        guard let path = ProcessInfo.processInfo.environment["SM06_ARTIFACT_ROOT"] else { return }
        for view in views {
            try view.image.jpeg.write(to:URL(fileURLWithPath:path).appendingPathComponent("\(prefix)-view-\(view.viewIndex).jpg"))
        }
    }
}

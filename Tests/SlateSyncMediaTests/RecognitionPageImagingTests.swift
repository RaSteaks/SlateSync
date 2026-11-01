import CoreGraphics
import Foundation
import ImageIO
import SlateSyncDomain
@testable import SlateSyncMedia
import XCTest

final class RecognitionPageImagingTests: XCTestCase {
    func testPixelRulesRetainKnownTableBoundaries() throws {
        let context = try PreparedImageEncoder.context(width: 800, height: 800)
        context.setStrokeColor(CGColor(gray: 0, alpha: 1))
        context.setLineWidth(3)
        for x in [160, 640] {
            context.move(to: CGPoint(x: x, y: 200)); context.addLine(to: CGPoint(x: x, y: 600))
        }
        for y in [200, 600] {
            context.move(to: CGPoint(x: 160, y: y)); context.addLine(to: CGPoint(x: 640, y: y))
        }
        context.strokePath()
        let geometry = try TableRuleDetector.detect(PreparedImageEncoder.image(context), operation: .init())
        for y in [0.25, 0.75] {
            XCTAssertTrue(geometry.rules.contains { $0.axis == .horizontal && abs($0.position - y) < 0.01 && $0.start < 0.21 && $0.end > 0.79 })
        }
        for x in [0.2, 0.8] {
            XCTAssertTrue(geometry.rules.contains { $0.axis == .vertical && abs($0.position - x) < 0.01 })
        }
    }

    func testPNGUsesOriginalPixelsAndSeparateCacheIdentity() throws {
        let context = try PreparedImageEncoder.context(width: 400, height: 400)
        context.setFillColor(CGColor(gray: 0, alpha: 1))
        context.fill(CGRect(x: 100, y: 100, width: 200, height: 200))
        let raster = try PreparedImageEncoder.image(context)
        let region = try PageRegion(left: 0.25, top: 0.25, right: 0.75, bottom: 0.75)
        let png = try RecognitionPageImaging.makeView(raster, region: region, maximum: 3000, quality: 0.92,
                                                    lossless: true, operation: .init())
        let jpeg = try RecognitionPageImaging.makeView(raster, region: region, maximum: 3000, quality: 0.92,
                                                     lossless: false, operation: .init())
        XCTAssertEqual(png.image, jpeg.image)
        XCTAssertEqual(png.localOCR.format, .png)
        let decoded = try ImageRasterizer.decode(png.localOCR.bytes)
        XCTAssertEqual(decoded.width, 200); XCTAssertEqual(decoded.height, 200)
        XCTAssertEqual(png.mapping.pageRegion(for: .full), region)
        let pixels = try PreparedImageEncoder.context(width: 200, height: 200)
        pixels.draw(decoded, in: CGRect(x: 0, y: 0, width: 200, height: 200))
        let data = try XCTUnwrap(pixels.data).assumingMemoryBound(to: UInt8.self)
        let center = 100 * pixels.bytesPerRow + 100 * 4
        XCTAssertEqual(data[center], 0); XCTAssertEqual(data[center + 1], 0); XCTAssertEqual(data[center + 2], 0)
        XCTAssertNotEqual(try OCRResultCache.key(image: png.localOCR, engine: .vision, settings: .init(), session: "A"),
                          try OCRResultCache.key(image: jpeg.localOCR, engine: .vision, settings: .init(), session: "A"))
        let canceled = MediaOperation(); canceled.cancel()
        XCTAssertThrowsError(try RecognitionPageImaging.makeView(raster, region: region, maximum: 3000,
                                                                quality: 0.92, lossless: true, operation: canceled))
    }
}

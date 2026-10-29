import CoreGraphics
import CryptoKit
import Foundation
import SlateSyncDomain

/// Immutable, bounded input bytes let review re-render a page without keeping
/// all decoded pages alive or rereading a file changed during a cloud request.
public actor RecognitionPageSource {
    private let data: Data
    public nonisolated let filename: String
    public nonisolated let digest: String
    public nonisolated let pageCount: Int
    private let isPDF: Bool

    // Creation belongs to MediaPreparationService's bounded file reader.
    init(data: Data, filename: String) throws {
        self.data = data; self.filename = filename
        digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        isPDF = data.starts(with: Array("%PDF-".utf8))
        if isPDF {
            pageCount = try PDFRasterizer.document(data).pageCount
        } else {
            // Reject malformed images at the source boundary, then release the
            // decoded raster rather than retaining it throughout recognition.
            _ = try autoreleasepool { try ImageRasterizer.decode(data) }
            pageCount = 1
        }
    }

    public func views(pageNumber: Int, regions: [PageRegion], lossless: Bool = false, includesFullView: Bool = true,
                      operation: MediaOperation) throws -> [RecognitionImageView] {
        guard (1...pageCount).contains(pageNumber), !regions.isEmpty,
              regions.count <= (includesFullView ? 3 : 2) else {
            throw MediaFailure.invalidInput
        }
        try operation.check()
        // Render a single page once per batch. Only encoded values escape this
        // autorelease pool; regions are relative to the displayed source page.
        return try autoreleasepool {
            let source = try render(pageNumber: pageNumber)
            return try regions.enumerated().map { index, region in
                try RecognitionPageImaging.makeView(source, region: region,
                    maximum: includesFullView && index == 0 ? 2600 : 3000,
                    quality: includesFullView && index == 0 ? 0.92 : 0.93,
                    lossless: lossless, operation: operation)
            }
        }
    }

    public func tableGeometry(pageNumber: Int, operation: MediaOperation) throws -> TablePageGeometry {
        guard (1...pageCount).contains(pageNumber) else { throw MediaFailure.invalidInput }
        try operation.check()
        return try autoreleasepool {
            try TableRuleDetector.detect(render(pageNumber: pageNumber), operation: operation)
        }
    }

    /// Same crops, resize and JPEG bytes as normal preparation. The callback
    /// captures pre-JPEG pixels only for the explicitly requested local format.
    public func compatibleViews(pageNumber: Int, includesDetails: Bool, lossless: Bool,
                                operation: MediaOperation) throws -> [RecognitionImageView] {
        guard (1...pageCount).contains(pageNumber) else { throw MediaFailure.invalidInput }
        return try autoreleasepool {
            var captured: [RecognitionImageView] = []
            _ = try PreparedImageEncoder.views(render(pageNumber: pageNumber), operation: operation,
                includesDetails: includesDetails, capture: { raster, view, mapping in
                    captured.append(.init(image: view.image,
                        localOCR: try RecognitionPageImaging.localImage(raster, jpeg: view.image, lossless: lossless), mapping: mapping))
                })
            return captured
        }
    }

    private func render(pageNumber: Int) throws -> CGImage {
        if isPDF {
            let document = try PDFRasterizer.document(data)
            guard let page = document.page(at: pageNumber - 1) else { throw MediaFailure.invalidInput }
            return try PDFRasterizer.render(page)
        }
        return try ImageRasterizer.decode(data)
    }

    /// Replay uses the exact accepted bytes, including when comparing legacy
    /// preparation with staged preparation. Data storage is copy-on-write.
    public func inputSnapshot() -> MediaInput { .bytes(data, filename: filename) }
}

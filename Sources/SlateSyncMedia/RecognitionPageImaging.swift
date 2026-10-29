import CoreGraphics
import Foundation
import ImageIO
import SlateSyncDomain
import UniformTypeIdentifiers

/// Runtime-only output: the JPEG remains suitable for existing persistence,
/// while lossless OCR bytes and source mappings never enter historical tasks.
public struct RecognitionImageView: Sendable {
    public let image: PreparedImage
    public let localOCR: LocalOCRImage
    public let mapping: RecognitionViewMapping
}

public enum RecognitionPageImaging {
    /// Produces a matched JPEG/PNG pair from the same resized pixels. Callers
    /// supply an original rendered page, never a previously compressed JPEG
    /// when claiming a lossless comparison.
    static func makeView(_ source: CGImage, region: PageRegion, maximum: Int,
                         quality: Double, lossless: Bool, operation: MediaOperation) throws -> RecognitionImageView {
        try operation.check()
        let left = max(0, Int(floor(region.left * Double(source.width))))
        let top = max(0, Int(floor(region.top * Double(source.height))))
        let right = min(source.width, Int(ceil(region.right * Double(source.width))))
        let bottom = min(source.height, Int(ceil(region.bottom * Double(source.height))))
        guard let crop = source.cropping(to: CGRect(x: left, y: top, width: right - left, height: bottom - top)) else {
            throw MediaFailure.invalidInput
        }
        let resized = try PreparedImageEncoder.resize(crop, maximum: maximum)
        let jpeg = try PreparedImageEncoder.encodeResized(resized, quality: quality)
        let local = try localImage(resized, jpeg: jpeg, lossless: lossless)
        // Record the actual outward-rounded crop, not the requested fractional
        // rectangle, so later OCR projection agrees with the pixels sent.
        let actual = try PageRegion(left: Double(left) / Double(source.width), top: Double(top) / Double(source.height),
                                    right: Double(right) / Double(source.width), bottom: Double(bottom) / Double(source.height))
        try operation.check()
        return .init(image: jpeg, localOCR: local, mapping: .init(page: actual))
    }
    static func localImage(_ raster: CGImage, jpeg: PreparedImage, lossless: Bool) throws -> LocalOCRImage {
        let local: LocalOCRImage
        if lossless {
            let bytes = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(bytes, UTType.png.identifier as CFString, 1, nil) else {
                throw MediaFailure.invalidInput
            }
            CGImageDestinationAddImage(destination, raster, nil)
            guard CGImageDestinationFinalize(destination) else {
                throw SlateSyncError(code: "MEDIA_ENCODE", message: "PNG 编码失败")
            }
            local = try .init(bytes: bytes as Data, format: .png, width: raster.width, height: raster.height)
        } else {
            local = try .init(bytes: jpeg.jpeg, format: .jpeg, width: jpeg.width, height: jpeg.height)
        }
        return local
    }

}

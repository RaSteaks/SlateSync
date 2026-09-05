import CoreGraphics
import Foundation
import ImageIO
import SlateSyncDomain
import UniformTypeIdentifiers

enum ImageRasterizer {
    static func decode(_ data: Data, maximum: Int = 2600) throws -> CGImage {
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let type = CGImageSourceGetType(source) as String?,
              [UTType.jpeg.identifier, UTType.png.identifier, UTType.webP.identifier].contains(type),
              CGImageSourceGetStatus(source) == .statusComplete,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
              let height = properties[kCGImagePropertyPixelHeight] as? NSNumber,
              width.doubleValue.isFinite, height.doubleValue.isFinite, width.doubleValue > 0, height.doubleValue > 0 else {
            throw SlateSyncError(code: "MEDIA_IMAGE_DECODE", message: "无法解码 JPEG、PNG 或 WebP 图像")
        }
        // EXIF is applied during bounded first-frame decoding; no source-sized
        // bitmap is allocated. Framework property dictionaries stay local here.
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceThumbnailMaxPixelSize: maximum, kCGImageSourceShouldCacheImmediately: true]
        guard let decoded = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { throw SlateSyncError(code: "MEDIA_IMAGE_DECODE", message: "图像内容损坏") }
        let orientation = (properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
        let swapped = (5...8).contains(orientation)
        let originalWidth = swapped ? height.doubleValue : width.doubleValue
        let originalHeight = swapped ? width.doubleValue : height.doubleValue
        let scale = min(1, Double(maximum) / max(originalWidth, originalHeight))
        let w = max(1, ImagePreprocessing.round(originalWidth * scale)), h = max(1, ImagePreprocessing.round(originalHeight * scale))
        let ctx = try PreparedImageEncoder.context(width: w, height: h)
        ctx.draw(decoded, in: CGRect(x: 0, y: 0, width: w, height: h))
        return try PreparedImageEncoder.image(ctx)
    }
}

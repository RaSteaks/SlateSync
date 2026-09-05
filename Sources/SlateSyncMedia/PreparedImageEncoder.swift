import CoreGraphics
import Foundation
import ImageIO
import SlateSyncDomain
import UniformTypeIdentifiers

/// CG objects stay local to preparation's synchronous call. Only encoded values
/// leave the actor; full/detail intermediates are released before the next page.
enum PreparedImageEncoder {
    static func context(width: Int, height: Int) throws -> CGContext {
        guard width > 0, height > 0, width <= Int.max / 4 / height,
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw SlateSyncError(code: "MEDIA_DIMENSIONS", message: "无法分配页面图像")
        }
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.interpolationQuality = .high
        return context
    }
    static func image(_ context: CGContext) throws -> CGImage {
        guard let result = context.makeImage() else { throw SlateSyncError(code: "MEDIA_ENCODE", message: "无法生成页面图像") }
        return result
    }
    static func resize(_ source: CGImage, maximum: Int, upscale: Bool = false) throws -> CGImage {
        guard maximum > 0, maximum <= 3000 else { throw MediaFailure.invalidInput }
        let scale = min(upscale ? .infinity : 1, Double(maximum) / Double(max(source.width, source.height)))
        let w = max(1, ImagePreprocessing.round(Double(source.width) * scale)), h = max(1, ImagePreprocessing.round(Double(source.height) * scale))
        let ctx = try context(width: w, height: h)
        ctx.draw(source, in: CGRect(x: 0, y: 0, width: w, height: h))
        return try image(ctx)
    }
    static func encode(_ source: CGImage, maximum: Int, quality: Double, upscale: Bool = false) throws -> PreparedImage {
        guard quality.isFinite, (0...1).contains(quality) else { throw MediaFailure.invalidInput }
        let image = try resize(source, maximum: maximum, upscale: upscale)
        let bytes = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(bytes, UTType.jpeg.identifier as CFString, 1, nil) else { throw MediaFailure.invalidInput }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw SlateSyncError(code: "MEDIA_ENCODE", message: "JPEG 编码失败") }
        return try .init(jpeg: bytes as Data, width: image.width, height: image.height)
    }
    static func cropped(_ source: CGImage, operation: MediaOperation) throws -> CGImage {
        let w = min(512, source.width), h = max(1, ImagePreprocessing.round(Double(source.height) * Double(w) / Double(source.width)))
        let ctx = try context(width: w, height: h)
        ctx.draw(source, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let data = ctx.data else { throw MediaFailure.invalidInput }
        let pixels = Array(UnsafeBufferPointer(start: data.assumingMemoryBound(to: UInt8.self), count: w * h * 4))
        let bounds = try ImagePreprocessing.denseRowBand(rgba: pixels, width: w, height: h, operation: operation)
        guard bounds.cropped else { return source }
        let top = max(0, Int(floor(Double(bounds.top) * Double(source.height) / Double(h))))
        let bottom = min(source.height, Int(ceil(Double(bounds.bottom) * Double(source.height) / Double(h))))
        guard let output = source.cropping(to: CGRect(x: 0, y: top, width: source.width, height: max(1, bottom - top))) else { throw MediaFailure.invalidInput }
        return output
    }
    static func views(_ source: CGImage, operation: MediaOperation) throws -> [PreparedMediaView] {
        try operation.check()
        let cropped = try cropped(source, operation: operation)
        let layout = ImagePreprocessing.detailSegments(height: cropped.height)
        var output = [PreparedMediaView(viewIndex: 0, viewType: .full, image: try encode(cropped, maximum: 2600, quality: 0.92))]
        for (index, segment) in layout.segments.enumerated() {
            try operation.check()
            let w = ImagePreprocessing.coreColumnWidth(cropped.width)
            let headerHeight = max(1, layout.header.bottom), bodyHeight = max(1, segment.bottom - segment.top)
            let ctx = try context(width: w, height: headerHeight + bodyHeight)
            // Crops use top-left pixels; drawing uses bottom-left coordinates.
            // Tiny out-of-range body rows remain white, matching canvas clipping.
            if let header = cropped.cropping(to: CGRect(x: 0, y: 0, width: w, height: headerHeight)) {
                ctx.draw(header, in: CGRect(x: 0, y: bodyHeight, width: w, height: headerHeight))
            }
            let available = min(bodyHeight, cropped.height - segment.top)
            if available > 0, let body = cropped.cropping(to: CGRect(x: 0, y: segment.top, width: w, height: available)) {
                ctx.draw(body, in: CGRect(x: 0, y: bodyHeight - available, width: w, height: available))
            }
            output.append(.init(viewIndex: index + 1, viewType: .coreDetail, image: try encode(image(ctx), maximum: 3000, quality: 0.93, upscale: true)))
        }
        try operation.check()
        return output
    }
}

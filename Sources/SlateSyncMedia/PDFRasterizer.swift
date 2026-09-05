import CoreGraphics
import Foundation
import PDFKit
import SlateSyncDomain

/// PDFDocument/pages stay on preparation's executor and are released per page.
enum PDFRasterizer {
    static func document(_ data: Data) throws -> PDFDocument {
        // PDFKit may reject a structurally valid zero-page catalog outright.
        if let provider = CGDataProvider(data: data as CFData), let probe = CGPDFDocument(provider), !probe.isEncrypted, probe.numberOfPages == 0 {
            throw SlateSyncError(code: "PDF_EMPTY", message: "PDF 中没有可识别的页面")
        }
        guard let document = PDFDocument(data: data) else {
            // Quartz rejects empty catalogs before exposing their page count.
            // This fallback only refines an already-rejected file's diagnostic;
            // it can never make an invalid PDF enter the rendering pipeline.
            let text = String(decoding: data, as: UTF8.self)
            if text.range(of: #"(?s)/Type\s*/Pages\b(?:(?!endobj).)*?/Count\s+0\b(?:(?!endobj).)*?/Kids\s*\[\s*\]"#, options: .regularExpression) != nil {
                throw SlateSyncError(code: "PDF_EMPTY", message: "PDF 中没有可识别的页面")
            }
            throw SlateSyncError(code: "PDF_INVALID", message: "无法读取 PDF 文件")
        }
        guard !document.isLocked else { throw SlateSyncError(code: "PDF_PASSWORD", message: "PDF 已加密，请先移除密码") }
        guard document.pageCount > 0 else { throw SlateSyncError(code: "PDF_EMPTY", message: "PDF 中没有可识别的页面") }
        guard document.pageCount <= 20 else { throw SlateSyncError(code: "PDF_PAGE_LIMIT", message: "PDF 最多支持 20 页") }
        return document
    }
    static func render(_ page: PDFPage) throws -> CGImage {
        guard let ref = page.pageRef else { throw SlateSyncError(code: "PDF_PAGE", message: "无法读取 PDF 页面") }
        if let dictionary = ref.dictionary {
            var array: CGPDFArrayRef?
            if CGPDFDictionaryGetArray(dictionary, "MediaBox", &array), let array {
                var coordinates = [CGPDFReal](repeating: 0, count: 4)
                guard CGPDFArrayGetCount(array) == 4 else { throw SlateSyncError(code: "PDF_BOUNDS", message: "PDF 页面尺寸无效") }
                for index in 0..<4 {
                    guard CGPDFArrayGetNumber(array, index, &coordinates[index]), coordinates[index].isFinite else { throw SlateSyncError(code: "PDF_BOUNDS", message: "PDF 页面尺寸无效") }
                }
                // Reject an explicitly degenerate box before Quartz substitutes
                // its default Letter page and hides the malformed dimensions.
                guard coordinates[2] != coordinates[0], coordinates[3] != coordinates[1] else { throw SlateSyncError(code: "PDF_BOUNDS", message: "PDF 页面尺寸无效") }
            }
        }
        // pdf.js intersects crop/media boxes before applying UserUnit/rotation.
        // getDrawingTransform does not upscale small pages on this SDK, so map
        // the four quarter-turns explicitly to preserve the frozen scale=4 rule.
        let media = ref.getBoxRect(.mediaBox), crop = ref.getBoxRect(.cropBox)
        let intersection = media.intersection(crop)
        let box = intersection.isNull || intersection.isEmpty ? media : intersection
        guard [box.minX, box.minY, box.width, box.height].allSatisfy(\.isFinite), box.width > 0, box.height > 0 else { throw SlateSyncError(code: "PDF_BOUNDS", message: "PDF 页面尺寸无效") }
        var userUnit: CGPDFReal = 1
        if let dictionary = ref.dictionary { CGPDFDictionaryGetNumber(dictionary, "UserUnit", &userUnit) }
        guard userUnit.isFinite, userUnit > 0 else { throw SlateSyncError(code: "PDF_BOUNDS", message: "PDF 页面比例无效") }
        let rotation = ((page.rotation % 360) + 360) % 360
        guard rotation % 90 == 0 else { throw SlateSyncError(code: "PDF_BOUNDS", message: "PDF 页面旋转无效") }
        let width = (rotation % 180 == 0 ? box.width : box.height) * userUnit
        let height = (rotation % 180 == 0 ? box.height : box.width) * userUnit
        guard width.isFinite, height.isFinite else { throw SlateSyncError(code: "PDF_BOUNDS", message: "PDF 页面尺寸溢出") }
        let scale = min(4, 3000 / max(width, height))
        let w = max(1, Int(ceil(width * scale))), h = max(1, Int(ceil(height * scale)))
        let context = try PreparedImageEncoder.context(width: w, height: h)
        let sx = Double(w) / (rotation % 180 == 0 ? box.width : box.height)
        let sy = Double(h) / (rotation % 180 == 0 ? box.height : box.width)
        let transform: CGAffineTransform
        switch rotation {
        case 90: transform = .init(a: 0, b: -sy, c: sx, d: 0, tx: -box.minY * sx, ty: box.maxX * sy)
        case 180: transform = .init(a: -sx, b: 0, c: 0, d: -sy, tx: box.maxX * sx, ty: box.maxY * sy)
        case 270: transform = .init(a: 0, b: sy, c: -sx, d: 0, tx: box.maxY * sx, ty: -box.minX * sy)
        default: transform = .init(a: sx, b: 0, c: 0, d: sy, tx: -box.minX * sx, ty: -box.minY * sy)
        }
        context.concatenate(transform)
        context.drawPDFPage(ref)
        return try PreparedImageEncoder.image(context)
    }
}

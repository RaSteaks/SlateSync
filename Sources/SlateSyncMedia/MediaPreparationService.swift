import AppKit
import Foundation
import PDFKit
import SlateSyncDomain

public struct PreparedSlatePage: Sendable {
    public let page: Int
    public let pngData: Data
    public let pixelWidth: Int
    public let pixelHeight: Int
}

public actor MediaPreparationService {
    public static let maximumPages = 20

    public init() {}

    public func preparePDF(data: Data, scale: CGFloat = 2) throws -> [PreparedSlatePage] {
        guard let document = PDFDocument(data: data) else {
            throw SlateSyncError(code: "PDF_INVALID", message: "无法读取 PDF 文件")
        }
        guard !document.isLocked else {
            throw SlateSyncError(code: "PDF_PASSWORD", message: "PDF 已加密，请先移除密码")
        }
        guard document.pageCount <= Self.maximumPages else {
            throw SlateSyncError(code: "PDF_PAGE_LIMIT", message: "PDF 最多支持 20 页")
        }
        return try (0..<document.pageCount).map { index in
            guard let page = document.page(at: index) else {
                throw SlateSyncError(code: "PDF_PAGE", message: "无法读取第 \(index + 1) 页")
            }
            let bounds = page.bounds(for: .mediaBox)
            let size = NSSize(width: bounds.width * scale, height: bounds.height * scale)
            let image = page.thumbnail(of: size, for: .mediaBox)
            guard let tiff = image.tiffRepresentation,
                  let bitmap = NSBitmapImageRep(data: tiff),
                  let png = bitmap.representation(using: .png, properties: [:]) else {
                throw SlateSyncError(code: "PDF_RENDER", message: "无法渲染第 \(index + 1) 页")
            }
            return PreparedSlatePage(
                page: index + 1,
                pngData: png,
                pixelWidth: bitmap.pixelsWide,
                pixelHeight: bitmap.pixelsHigh
            )
        }
    }
}

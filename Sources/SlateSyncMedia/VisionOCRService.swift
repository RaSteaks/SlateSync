import CoreGraphics
import Foundation
import ImageIO
import SlateSyncDomain
import Vision

public actor VisionOCRService: OCRServing {
    public init() {}

    public func recognize(images: [Data]) async throws -> [OCRPageResult] {
        try await withThrowingTaskGroup(of: OCRPageResult.self) { group in
            for (index, data) in images.enumerated() {
                group.addTask { try await Self.recognizePage(data: data, page: index + 1) }
            }
            var pages: [OCRPageResult] = []
            for try await page in group { pages.append(page) }
            return pages.sorted { $0.page < $1.page }
        }
    }

    private static func recognizePage(data: Data, page: Int) async throws -> OCRPageResult {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw SlateSyncError(code: "OCR_IMAGE", message: "无法读取第 \(page) 页图像")
        }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.recognitionLanguages = ["zh-Hans", "en-US"]
        try VNImageRequestHandler(cgImage: image).perform([request])
        let blocks = (request.results ?? []).compactMap { observation -> OCRBlock? in
            guard let candidate = observation.topCandidates(1).first else { return nil }
            let box = observation.boundingBox
            return OCRBlock(
                text: candidate.string,
                confidence: Double(candidate.confidence),
                boundingBox: .init(
                    x: box.origin.x,
                    y: box.origin.y,
                    width: box.width,
                    height: box.height
                )
            )
        }
        return OCRPageResult(page: page, blocks: blocks)
    }

import Foundation
import SlateSyncDomain

public struct RawVisionObservation: Sendable {
    public let text: String
    public let confidence: Double
    public let box: CGRectValue
    public init(text: String, confidence: Double, box: CGRectValue) { self.text = text; self.confidence = confidence; self.box = box }
}

public enum VisionObservationNormalizer {
    public static func normalize(_ observations: [RawVisionObservation], view: PreparedMediaView, configuration: VisionOCRConfiguration) -> OCRViewEvidence {
        func clamp(_ value: Double) -> Double { max(0,min(1,value)) }
        func rounded(_ value: Double) -> Double { (value * 100_000).rounded() / 100_000 }
        var blocks = observations.compactMap { observation -> OCRTextBlock? in
            let text = observation.text.trimmingCharacters(in: .whitespacesAndNewlines), box = observation.box
            guard !text.isEmpty, observation.confidence.isFinite, observation.confidence >= configuration.minimumConfidence,
                  [box.x,box.y,box.width,box.height,box.x + box.width,box.y + box.height].allSatisfy(\.isFinite), box.width >= 0, box.height >= 0 else { return nil }
            let b = [clamp(box.x),clamp(1 - (box.y + box.height)),clamp(box.x + box.width),clamp(1 - box.y)]
            return .init(order: 0, text: text, confidence: rounded(observation.confidence), bbox: [Int((b[0] * Double(view.image.width)).rounded()),Int((b[1] * Double(view.image.height)).rounded()),Int((b[2] * Double(view.image.width)).rounded()),Int((b[3] * Double(view.image.height)).rounded())], bboxNormalized: b.map(rounded))
        }
        // Preserve the old helper's stable Swift comparator, including its
        // 0.02 near-row rule; do not quantize into invented row buckets.
        blocks.sort { a,b in
            let ay = a.bboxNormalized[1] + (a.bboxNormalized[3] - a.bboxNormalized[1]) / 2
            let by = b.bboxNormalized[1] + (b.bboxNormalized[3] - b.bboxNormalized[1]) / 2
            if abs(ay - by) > 0.02 { return ay < by }
            return a.bboxNormalized[0] < b.bboxNormalized[0]
        }
        let cap = configuration.maxBlocksPerView
        let truncated = cap > 0 && blocks.count > cap
        if truncated {
            if cap == 1 { blocks = [blocks[blocks.count / 2]] }
            else {
                let source = blocks
                blocks = (0..<cap).map { source[Int((Double($0) * Double(source.count - 1) / Double(cap - 1)).rounded())] }
            }
        }
        blocks = blocks.enumerated().map { index, b in .init(order: index, text: b.text, confidence: b.confidence, bbox: b.bbox, bboxNormalized: b.bboxNormalized) }
        return .init(viewIndex: view.viewIndex, viewType: view.viewType, width: view.image.width, height: view.image.height, truncated: truncated, blocks: blocks)
    }
}

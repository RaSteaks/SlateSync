import Foundation
import SlateSyncDomain

/// Targeting requires an observed reel and a unique clip cell in its camera
/// column. Sequence numbers and model-generated coordinates cannot locate a row.
public enum RecognitionReviewPlanner {
    private static let reelPattern = try? NSRegularExpression(pattern: #"(?<![A-Z0-9])[A-Z][0-9]{1,4}(?![A-Z0-9])"#)
    public static func regions(for records: [RecognitionRecord], structure: RecognitionTableStructure) throws -> [PageRegion]? {
        guard let table = structure.region, let reelPattern, !records.isEmpty else { return nil }
        var regions: [PageRegion] = []
        for record in records {
            try Task.checkCancellation()
            guard let reel = RecognitionNormalizer.normalizeCard(record.cardNumber),
                  let camera = reel.first.map(String.init),
                  let clip = RecognitionNormalizer.normalizeVideo(record.videoCode) else { return nil }
            let observedReels = Set(structure.witnesses.flatMap { witness in
                let text = witness.text.uppercased()
                return reelPattern.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { match in
                    Range(match.range, in: text).map { String(text[$0]) }
                }
            }.filter { $0.hasPrefix(camera) })
            // More than one reel for this camera could mean a mid-page change.
            // Without reliable change-marker semantics, use whole-page review.
            guard observedReels == Set([reel]) else { return nil }
            let hasReliableReel = structure.witnesses.contains { witness in
                let text = witness.text.uppercased()
                return witness.confidence >= 0.65 && reelPattern.matches(in: text, range: NSRange(text.startIndex..., in: text)).contains { match in
                    Range(match.range, in: text).map { String(text[$0]) == reel } ?? false
                }
            }
            guard hasReliableReel else { return nil }
            let matching = structure.cells.filter { cell in
                guard structure.columns.indices.contains(cell.column), cell.rowSpan == 1 else { return false }
                let column = structure.columns[cell.column]
                guard column.field == "videoCode", column.camera == camera else { return false }
                let words = structure.witnesses.filter { cell.witnesses.contains($0.index) }.sorted {
                    ($0.region.top, $0.region.left) < ($1.region.top, $1.region.left)
                }
                // Low-confidence digits can identify the wrong physical row.
                // They remain usable as OCR evidence, but never direct recrops.
                guard !words.isEmpty, words.allSatisfy({ $0.confidence >= 0.65 }) else { return false }
                let text = words.map(\.text).joined().filter { !$0.isWhitespace }.uppercased()
                guard text.wholeMatch(of: /C?[0-9]{1,3}/) != nil else { return false }
                return RecognitionNormalizer.normalizeVideo(text) == clip
            }
            guard matching.count == 1, let cell = matching.first,
                  structure.rows.indices.contains(cell.firstRow) else { return nil }
            let first = max(0, cell.firstRow - 1), last = min(structure.rows.count - 1, cell.firstRow + 1)
            var top = structure.rows[first].top, bottom = structure.rows[last].bottom
            // Shared merged fields may start well above the target row. Keep
            // their complete source span along with all camera/status columns.
            for shared in structure.cells where shared.firstRow <= cell.firstRow && shared.firstRow + shared.rowSpan > cell.firstRow {
                top = min(top, shared.region.top); bottom = max(bottom, shared.region.bottom)
            }
            regions.append(try .init(left: max(0, table.left - 0.012), top: max(0, top - 0.012),
                                     right: min(1, table.right + 0.012), bottom: min(1, bottom + 0.012)))
        }
        var merged: [PageRegion] = []
        for region in regions.sorted(by: { $0.top < $1.top }) {
            if let previous = merged.last, previous.bottom >= region.top {
                merged[merged.count - 1] = previous.union(region)
            } else { merged.append(region) }
        }
        // Widely dispersed targets use the existing full/detail views. Never
        // drop a target to fit the two-detail limit or issue per-record calls.
        guard merged.count <= 2, merged.allSatisfy({ $0.height < 0.85 }) else { return nil }
        return merged
    }
}

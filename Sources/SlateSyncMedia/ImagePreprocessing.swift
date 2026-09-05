import Foundation
import SlateSyncDomain

/// Exact positive-number Math.round/ceil/floor geometry from image-preprocess.js.
/// Retain the outer envelope of separated title/table bands, not just the largest.
public enum ImagePreprocessing {
    public struct Band: Codable, Equatable, Sendable { public let top: Int; public let bottom: Int; public let cropped: Bool }
    public struct Segment: Codable, Equatable, Sendable { public let top: Int; public let bottom: Int }
    public struct Layout: Codable, Equatable, Sendable { public let header: Segment; public let segments: [Segment] }
    static func round(_ value: Double) -> Int { Int(floor(value + 0.5)) }
    public static func denseRowBand(rgba: [UInt8], width: Int, height: Int, operation: MediaOperation = .init()) throws -> Band {
        let unchanged = Band(top: 0, bottom: max(0, height), cropped: false)
        guard width > 0, height > 0, width <= Int.max / 4 / height, rgba.count >= width * height * 4 else { return unchanged }
        let minimum = max(4, round(Double(width) * 0.02))
        var active: [Int] = []
        for y in 0..<height {
            if y % 32 == 0 { try operation.check() }
            var dark = 0
            for x in 0..<width {
                let i = (y * width + x) * 4
                if Double(rgba[i]) * 0.299 + Double(rgba[i + 1]) * 0.587 + Double(rgba[i + 2]) * 0.114 < 225 { dark += 1 }
            }
            if dark >= minimum { active.append(y) }
        }
        guard let first = active.first else { return unchanged }
        let gap = max(3, round(Double(height) * 0.025))
        var bands: [(Int, Int, Int)] = []
        var start = first, end = first, count = 1
        for row in active.dropFirst() {
            if row - end <= gap { end = row; count += 1 }
            else { bands.append((start, end, count)); start = row; end = row; count = 1 }
        }
        bands.append((start, end, count))
        let content = bands.filter { $0.2 >= 3 }
        guard let firstBand = content.first, let lastBand = content.last,
              lastBand.1 - firstBand.0 + 1 >= max(8, round(Double(height) * 0.12)) else { return unchanged }
        let padding = max(4, round(Double(height) * 0.025))
        let top = max(0, firstBand.0 - padding), bottom = min(height, lastBand.1 + padding + 1)
        guard Double(height - (bottom - top)) >= Double(height) * 0.08 else { return unchanged }
        return Band(top: top, bottom: bottom, cropped: true)
    }
    public static func detailSegments(height: Int) -> Layout {
        let height = max(1, height)
        let header = max(1, min(height, round(Double(height) * 0.22)))
        let midpoint = header + round(Double(max(1, height - header)) / 2)
        let overlap = max(1, round(Double(height) * 0.045))
        return .init(header: .init(top: 0, bottom: header), segments: [.init(top: header, bottom: min(height, midpoint + overlap)), .init(top: max(header, midpoint - overlap), bottom: height)])
    }
    public static func coreColumnWidth(_ width: Int) -> Int { max(1, round(Double(max(1, width)) * 0.62)) }
}

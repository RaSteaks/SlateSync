import CoreGraphics
import Foundation
import SlateSyncDomain

/// Bounded pixel scan for long ruled-table segments. Broken or tilted rules
/// may remain undetected; the workflow must abstain rather than invent a grid.
enum TableRuleDetector {
    static func detect(_ source: CGImage, operation: MediaOperation) throws -> TablePageGeometry {
        let image = try PreparedImageEncoder.resize(source, maximum: 1000)
        let context = try PreparedImageEncoder.context(width: image.width, height: image.height)
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        guard let data = context.data else { throw MediaFailure.invalidInput }
        let pixels = data.assumingMemoryBound(to: UInt8.self)
        var ink = [Bool](repeating: false, count: image.width * image.height)
        for y in 0..<image.height {
            if y % 32 == 0 { try operation.check() }
            for x in 0..<image.width {
                let offset = y * context.bytesPerRow + x * 4
                ink[y * image.width + x] = Int(pixels[offset]) + Int(pixels[offset + 1]) + Int(pixels[offset + 2]) < 510
            }
        }
        var rules: [TableRule] = []
        for axis in [TableRule.Axis.horizontal, .vertical] {
            let across = axis == .horizontal ? image.width : image.height
            let count = axis == .horizontal ? image.height : image.width
            let minimum = max(12, Int(Double(across) * (axis == .horizontal ? 0.12 : 0.08)))
            var segments: [(position: Int, start: Int, end: Int)] = []
            for line in 0..<count {
                if line % 32 == 0 { try operation.check() }
                var start: Int?, last = 0, gap = 0
                for position in 0...across {
                    let dark = position < across && ink[axis == .horizontal ? line * image.width + position : position * image.width + line]
                    if dark {
                        if start == nil { start = position }
                        last = position; gap = 0
                    } else if let first = start {
                        gap += 1
                        // Two sample pixels bridge antialiasing gaps, but never
                        // infer a missing cell separator from a large blank.
                        if gap > 2 || position == across {
                            if last - first + 1 >= minimum { segments.append((line, first, last + 1)) }
                            start = nil
                        }
                    }
                }
            }
            // Collapse stroke thickness only when endpoints agree. Parallel
            // segments with different spans can encode merged-cell boundaries.
            guard segments.count <= 4096 else {
                // Dense texture is not reliable ruled-table evidence. Bound
                // grouping work and let the caller select compatibility crops.
                return .init(rules: [], sampleWidth: image.width, sampleHeight: image.height)
            }
            var groups: [(first: Int, last: Int, start: Int, end: Int)] = []
            for segment in segments {
                if let index = groups.lastIndex(where: {
                    segment.position - $0.last <= 2 && abs(segment.start - $0.start) <= 3 && abs(segment.end - $0.end) <= 3
                }) {
                    groups[index].last = segment.position
                } else { groups.append((segment.position, segment.position, segment.start, segment.end)) }
            }
            rules += groups.map {
                .init(axis: axis, position: Double($0.first + $0.last + 1) / (2 * Double(count)),
                      start: Double($0.start) / Double(across), end: Double($0.end) / Double(across))
            }
        }
        try operation.check()
        return .init(rules: rules, sampleWidth: image.width, sampleHeight: image.height)
    }
}

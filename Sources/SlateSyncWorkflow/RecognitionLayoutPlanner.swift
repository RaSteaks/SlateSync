import Foundation
import SlateSyncDomain

/// Combines printed labels with measured rules. A missing line by itself is
/// never enough to assign a merged cell or claim that a page region is empty.
public enum RecognitionLayoutPlanner {
    public static func plan(full: OCRViewEvidence, mapping: RecognitionViewMapping,
                            geometry: TablePageGeometry) throws -> RecognitionTableStructure {
        try Task.checkCancellation()
        let witnesses = full.blocks.enumerated().compactMap { index, block -> RecognitionTableStructure.Witness? in
            let box = block.bboxNormalized
            guard box.count == 4, block.confidence.isFinite,
                  let local = try? PageRegion(left: box[0], top: box[1], right: box[2], bottom: box[3]),
                  let region = mapping.pageRegion(for: local) else { return nil }
            return .init(index: index, text: block.text, confidence: block.confidence, region: region)
        }
        let observation = ScenarioOCRView(width: full.width, height: full.height, blocks: witnesses.map {
            .init(text: $0.text, confidence: $0.confidence, bboxNormalized: $0.region.coordinates)
        })
        let header = ScenarioStructureMatcher.describe(observation)
        guard ScenarioStructureMatcher.isSufficient(header),
              let headerBottom = header.anchors.map({ $0.box[3] }).max() else {
            return fallback(witnesses, reason: "表头证据不足，保留兼容裁图。")
        }
        let vertical = geometry.rules.filter {
            $0.axis == .vertical && $0.start <= headerBottom && $0.end > headerBottom + 0.15
        }
        guard vertical.count >= 4 else { return fallback(witnesses, reason: "没有足够的连续列边界。") }
        // Shared lower endpoints identify a ruled table rather than unrelated
        // page decorations. Require at least two agreeing long vertical rules.
        let bottomCandidates = vertical.map { candidate in
            (position: candidate.end, support: vertical.filter { abs($0.end - candidate.end) < 0.015 }.count)
        }
        guard let bottom = bottomCandidates.max(by: {
            ($0.support, $0.position) < ($1.support, $1.position)
        }), bottom.support >= 2 else { return fallback(witnesses, reason: "表格下边界不明确。") }
        let boundaries = clustered(vertical.filter { $0.end >= bottom.position - 0.015 }.map(\.position))
        guard boundaries.count >= 4, let left = boundaries.first, let right = boundaries.last,
              header.anchors.allSatisfy({ $0.box[0] >= left - 0.01 && $0.box[2] <= right + 0.01 }) else {
            return fallback(witnesses, reason: "列边界未覆盖全部已识别表头。")
        }
        let horizontal = geometry.rules.filter {
            $0.axis == .horizontal && $0.position >= headerBottom && $0.position <= bottom.position + 0.015
                && $0.end - $0.start >= (right - left) * 0.4
        }
        guard let top = horizontal.map(\.position).min(), top - headerBottom < 0.08 else {
            return fallback(witnesses, reason: "无法确定表头与正文的分隔线。")
        }
        let rowEdges = clustered(horizontal.map(\.position))
        guard rowEdges.count >= 2, let last = rowEdges.last, abs(last - bottom.position) < 0.02 else {
            return fallback(witnesses, reason: "正文行边界不完整。")
        }
        let region = try PageRegion(left: left, top: top, right: right, bottom: last)
        let rows = try zip(rowEdges, rowEdges.dropFirst()).map {
            try PageRegion(left: left, top: $0.0, right: right, bottom: $0.1)
        }
        let cameras = witnesses.compactMap { witness -> (String, PageRegion)? in
            guard witness.confidence >= 0.5, witness.region.bottom <= top + 0.01,
                  witness.region.top >= max(0, headerBottom - 0.15),
                  let field = ScenarioStructureMatcher.fieldIdentifier(for: witness.text),
                  field.hasPrefix("camera:") else { return nil }
            return (String(field.dropFirst(7)), witness.region)
        }.sorted { $0.1.left < $1.1.left }
        let cameraGroups = cameras.compactMap { camera -> (String, Double, Double)? in
            // A spanning camera header is bounded by rules reaching above that
            // label. Inner video/status dividers commonly start below it.
            let edges = geometry.rules.filter {
                $0.axis == .vertical && $0.start <= camera.1.top && $0.end >= last - 0.015
            }.map(\.position)
            guard let a = edges.filter({ $0 <= camera.1.left }).max(),
                  let b = edges.filter({ $0 >= camera.1.right }).min(),
                  cameras.filter({ $0.1.left >= a && $0.1.right <= b }).count == 1 else { return nil }
            return (camera.0, a, b)
        }
        var columns: [RecognitionTableStructure.Column] = []
        for (a, b) in zip(boundaries, boundaries.dropFirst()) {
            let labels = header.anchors.filter {
                !$0.field.hasPrefix("camera:") && ($0.box[0] + $0.box[2]) / 2 >= a && ($0.box[0] + $0.box[2]) / 2 < b
            }
            let roles = Set(labels.map(\.field))
            let field = roles.count == 1 ? roles.first : nil
            // Camera grouping is a hint only; shared scene/shot/take columns
            // never acquire a camera because of nearby printed labels.
            let camera: String?
            if ["videoCode", "takeStatus", "shotSize", "cameraPosition"].contains(field ?? "") {
                let groups = cameraGroups.filter { a >= $0.1 - 0.006 && b <= $0.2 + 0.006 }
                let labels = cameras.filter { $0.1.left >= a && $0.1.right <= b }
                if groups.count == 1 { camera = groups.first?.0 }
                else if groups.isEmpty && labels.count == 1 { camera = labels.first?.0 }
                else { camera = nil }
            } else { camera = nil }
            columns.append(.init(region: try .init(left: a, top: top, right: b, bottom: last), field: field, camera: camera))
        }
        let core = columns.compactMap(\.field).filter { ["scene", "shot", "take"].contains($0) }
        guard core == ["scene", "shot", "take"], columns.contains(where: { $0.field == "videoCode" }) else {
            return fallback(witnesses, reason: "场镜次列顺序或视频码列不明确。")
        }
        var cells: [RecognitionTableStructure.Cell] = []
        for (columnIndex, column) in columns.enumerated() {
            try Task.checkCancellation()
            var first = 0
            while first < rows.count {
                guard separator(at: rowEdges[first], column: column.region, rules: horizontal) == .present else {
                    first += 1; continue
                }
                var end = first + 1
                while end < rows.count && separator(at: rowEdges[end], column: column.region, rules: horizontal) == .merged {
                    end += 1
                }
                if separator(at: rowEdges[end], column: column.region, rules: horizontal) == .present {
                    let box = try PageRegion(left: column.region.left, top: rowEdges[first], right: column.region.right, bottom: rowEdges[end])
                    cells.append(.init(column: columnIndex, firstRow: first, rowSpan: end - first,
                                       region: box, witnesses: witnesses.filter { box.contains($0.region) }.map(\.index)))
                }
                first = end
            }
        }
        let assigned = Set(cells.flatMap(\.witnesses))
        let unassigned = witnesses.filter { !assigned.contains($0.index) }.map(\.index)
        let details = try detailRegions(region: region, rows: rows, cells: cells)
        return .init(region: region, columns: columns, rows: rows, cells: cells, witnesses: witnesses,
                     unassigned: unassigned, detailRegions: details,
                     warnings: unassigned.isEmpty ? [] : ["部分文字未能唯一归入单元格，仍须核对全页。"])
    }

    private enum Separator { case present, merged, unknown }
    private static func separator(at y: Double, column: PageRegion, rules: [TableRule]) -> Separator {
        let near = rules.filter { abs($0.position - y) < 0.004 }
        if near.contains(where: { $0.start <= column.left + 0.006 && $0.end >= column.right - 0.006 }) { return .present }
        if near.contains(where: { min($0.end, column.right) - max($0.start, column.left) > 0.012 }) { return .unknown }
        // A separator terminating on this column's border supplies positive
        // evidence of a spanning cell. Faded/missing entire rules remain unknown.
        if near.contains(where: { abs($0.end - column.left) < 0.006 || abs($0.start - column.right) < 0.006 }) { return .merged }
        return .unknown
    }

    private static func clustered(_ values: [Double]) -> [Double] {
        var groups: [[Double]] = []
        for value in values.sorted() {
            if let previous = groups.last?.first, value - previous < 0.004 {
                groups[groups.count - 1].append(value)
            } else { groups.append([value]) }
        }
        return groups.map { $0.reduce(0, +) / Double($0.count) }
    }

    private static func detailRegions(region: PageRegion, rows: [PageRegion], cells: [RecognitionTableStructure.Cell]) throws -> [PageRegion] {
        guard rows.count > 1 else { return [try padded(region)] }
        let center = (region.top + region.bottom) / 2
        let split = rows.dropLast().map(\.bottom).min(by: { abs($0 - center) < abs($1 - center) }) ?? center
        // Keep crossing merged cells visible in both crops rather than slicing
        // their value away from a row. Duplicate crops collapse to one view.
        let crossing = cells.filter { $0.region.top < split && $0.region.bottom > split }
        let upper = try PageRegion(left: region.left, top: region.top, right: region.right,
                                   bottom: max(split, crossing.map { $0.region.bottom }.max() ?? split))
        let lower = try PageRegion(left: region.left, top: min(split, crossing.map { $0.region.top }.min() ?? split),
                                   right: region.right, bottom: region.bottom)
        let a = try padded(upper), b = try padded(lower)
        return a == b ? [a] : [a, b]
    }

    private static func padded(_ region: PageRegion) throws -> PageRegion {
        try .init(left: max(0, region.left - 0.012), top: max(0, region.top - 0.012),
                  right: min(1, region.right + 0.012), bottom: min(1, region.bottom + 0.012))
    }

    private static func fallback(_ witnesses: [RecognitionTableStructure.Witness], reason: String) -> RecognitionTableStructure {
        .init(region: nil, columns: [], rows: [], cells: [], witnesses: witnesses,
              unassigned: witnesses.map(\.index), detailRegions: [], warnings: [reason])
    }
}

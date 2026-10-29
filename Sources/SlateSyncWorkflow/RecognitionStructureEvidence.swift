import Foundation
import SlateSyncDomain

/// Geometry hints contain no inferred field values. Audit requests keep their
/// independent full-page inventory rather than sharing primary-pass answers.
public enum RecognitionStructureEvidence {
    public static func format(_ structure: RecognitionTableStructure, fullMapping: RecognitionViewMapping,
                              maximumCharacters: Int = 6000) -> String {
        guard structure.region != nil, maximumCharacters >= 500 else { return "" }
        var lines = ["<table_geometry>",
                     "Coordinates refer to the attached full view, normalized [left,top,right,bottom].",
                     "Geometry is tentative evidence. Verify all row boundaries and merged cells against the image. Scan outside suggested regions; never fill values from geometry alone."]
        var length = lines.joined(separator: "\n").utf16.count
        var omitted = false
        func append(_ line: String) {
            guard length + line.utf16.count + 160 <= maximumCharacters else { omitted = true; return }
            lines.append(line); length += line.utf16.count + 1
        }
        func box(_ region: PageRegion) -> String? {
            guard let view = fullMapping.viewRegion(for: region) else { return nil }
            return view.coordinates.map { String(format: "%.4f", locale: Locale(identifier: "en_US_POSIX"), $0) }.joined(separator: ",")
        }
        for (index, column) in structure.columns.enumerated() {
            guard let coordinates = box(column.region) else { continue }
            append("column=\(index) field=\(column.field ?? "unknown") camera_hint=\(column.camera ?? "unknown") box=[\(coordinates)]")
        }
        for (index, row) in structure.rows.enumerated() {
            guard let coordinates = box(row) else { continue }
            append("row=\(index) box=[\(coordinates)]")
        }
        for cell in structure.cells where cell.rowSpan > 1 {
            guard let coordinates = box(cell.region) else { continue }
            append("candidate_merged_cell column=\(cell.column) first_row=\(cell.firstRow) row_span=\(cell.rowSpan) box=[\(coordinates)]")
        }
        append("unassigned_ocr_blocks=\(structure.unassigned.count); unassigned does not mean blank")
        if omitted { lines.append("geometry_truncated=true; omitted regions must still be inspected in the full image") }
        lines.append("</table_geometry>")
        return lines.joined(separator: "\n")
    }
}

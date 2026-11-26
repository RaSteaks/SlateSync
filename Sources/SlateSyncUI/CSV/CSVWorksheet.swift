import AppKit
import SlateSyncWorkflow

/// Presentation coordinates always address the full source table, including
/// when several visible columns are separated by hidden Resolve metadata.
struct CSVWorksheetCell: Hashable {
    let row: Int
    let column: Int
}

struct CSVWorksheetJump: Equatable {
    let id = UUID()
    let tableID: UUID
    let row: Int?
    let column: Int?
}

struct CSVWorksheet {
    var reviewColumns: Bool
    var jump: CSVWorksheetJump?
    var diagnosticsGeneration: Int
    var warnings: Set<CSVWorksheetCell>
    var onActiveCell: (CSVWorksheetCell?) -> Void

    /// Import validates the headers. Retained tasks with an older or ambiguous
    /// schema can still be inspected using their original columns.
    static func layout(headers: [String], review: Bool) -> (identity: Int?, columns: [Int]) {
        guard let fields = try? ResolveHeaders.resolve(headers) else { return (nil, Array(headers.indices)) }
        let identity = fields.fileName.first ?? fields.clipName.first ?? fields.reelName.first
        let editable = [fields.scene, fields.shot, fields.take, fields.cameraFPS, fields.shootDay, fields.comments]
            .filter { $0 >= 0 }
        // The fixed gutter identifies each material. All Columns also exposes
        // its original editable cell, along with every passthrough column.
        return (identity, review && !editable.isEmpty ? editable : Array(headers.indices))
    }
}

/// A native scroll-view ruler stays fixed horizontally. Drawing only visible
/// labels uses the same row geometry as the editor, including after resizing.
final class CSVWorksheetRuler: NSRulerView {
    var materialHeader: String?
    var labelForRow: ((Int) -> String?)?
    override func menu(for event: NSEvent) -> NSMenu? {
        guard let table = scrollView?.documentView as? NSTableView else { return nil }
        let point = table.convert(event.locationInWindow, from: nil)
        let row = table.row(at: NSPoint(x: table.visibleRect.midX, y: point.y))
        guard row >= 0, let name = labelForRow?(row), !name.isEmpty else { return nil }
        let menu = NSMenu()
        menu.addItem(withTitle: name, action: nil, keyEquivalent: "")
        let copy = menu.addItem(withTitle: L10n.tr("复制完整素材名"), action: #selector(copyName(_:)), keyEquivalent: "")
        copy.target = self; copy.representedObject = name
        return menu
    }

    @objc private func copyName(_ item: NSMenuItem) {
        guard let name = item.representedObject as? String else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(name, forType: .string)
    }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        guard let table = scrollView?.documentView as? NSTableView else { return }
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byTruncatingTail
        let font = NSFont.monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        if let header = table.headerView {
            let frame = convert(header.bounds, from: header)
            let titleStyle: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize, weight: .medium),
                .foregroundColor: NSColor.labelColor, .paragraphStyle: style]
            let y = frame.midY - ceil(font.ascender - font.descender) / 2
            ("#" as NSString).draw(at: .init(x: 28, y: y), withAttributes: titleStyle)
            (materialHeader as NSString?)?.draw(in: .init(x: 46, y: y, width: bounds.width - 50, height: frame.height), withAttributes: titleStyle)
            NSColor.separatorColor.setFill()
            NSRect(x: 0, y: frame.maxY - 1, width: bounds.width, height: 1).fill()
            // Partially scrolled rows must never paint across the pinned header.
            NSBezierPath(rect: NSRect(x: 0, y: frame.maxY, width: bounds.width,
                                      height: max(0, bounds.maxY - frame.maxY))).addClip()
        }
        let visible = table.rows(in: table.visibleRect)
        guard visible.location != NSNotFound else { return }
        for row in visible.location..<NSMaxRange(visible) {
            let frame = convert(table.rect(ofRow: row), from: table)
            guard frame.intersects(rect) else { continue }
            // Native borderless text fields lay out from the top of each row.
            let y = frame.minY + 1
            let number = String(row + 2) as NSString
            let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.secondaryLabelColor]
            number.draw(at: .init(x: 38 - number.size(withAttributes: attrs).width, y: y), withAttributes: attrs)
            if let name = labelForRow?(row) {
                (name as NSString).draw(in: .init(x: 46, y: y, width: max(0, bounds.width - 50), height: frame.height),
                    withAttributes: [.font: font, .foregroundColor: NSColor.labelColor, .paragraphStyle: style])
            }
        }
    }
}

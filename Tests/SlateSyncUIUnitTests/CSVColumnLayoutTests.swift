import AppKit
import SlateSyncDomain
import SlateSyncWorkflow
import SwiftUI
import XCTest

@testable import SlateSyncUI

/// Exercise the real table bridge in an unordered window. Task switches must
/// resample content, while edits/resizes preserve user-owned column geometry.
@MainActor
final class CSVColumnLayoutTests: XCTestCase {
    /// Row binding does no eager localization. AX reads still return the full
    /// current label after reuse or a language change, including on an editor.
    func testAccessibilityLabelIsLazyAndTracksReuseAndLanguage() throws {
        let suiteName = "SlateSync.CellAX.\(UUID().uuidString)"
        let preferences = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        let previousLanguage = L10n.language
        defer {
            AppLanguage.save(previousLanguage, in: preferences)
            L10n.configure(preferences: preferences)
            preferences.removePersistentDomain(forName: suiteName)
        }
        AppLanguage.save(.english, in: preferences)
        L10n.configure(preferences: preferences)
        let coordinator = Fixture.surface(id: UUID(), value: "1").makeCoordinator()
        let field = CSVTableTextField()
        field.delegate = coordinator
        field.bindAccessibility(row: 0, header: "Notes")
        XCTAssertEqual(coordinator.cellWork.accessibilityFormats, 0)
        XCTAssertEqual(field.accessibilityLabel(), "Row 1, Notes")
        XCTAssertEqual(field.accessibilityLabel(), "Row 1, Notes")
        XCTAssertEqual(coordinator.cellWork.accessibilityFormats, 1)
        field.bindAccessibility(row: 99, header: "Scene")
        XCTAssertEqual(coordinator.cellWork.accessibilityFormats, 1)
        XCTAssertEqual(field.accessibilityLabel(), "Row 100, Scene")
        AppLanguage.save(.simplifiedChinese, in: preferences)
        L10n.configure(preferences: preferences)
        XCTAssertEqual(field.accessibilityLabel(), "第 100 行，Scene")
        XCTAssertEqual(coordinator.cellWork.accessibilityFormats, 3)
    }

    /// Prepared column bindings must follow source identity, not the mutable
    /// visual index: dragging Notes ahead of Clip must never edit Clip's data.
    func testReorderedColumnsDisplayAndCommitTheirOriginalSourceColumn() async throws {
        let commits = CommitRecorder()
        let fixture = Fixture(value: "Camera_A", onCommit: { commits.values.append($0) })
        defer { fixture.close() }
        try await fixture.settle()
        let table = try XCTUnwrap(fixture.table)
        table.moveColumn(1, toColumn: 0)
        table.reloadData()
        try await fixture.settle()
        let notes = try XCTUnwrap(table.view(atColumn: 0, row: 0, makeIfNecessary: true) as? NSTextField)
        let clip = try XCTUnwrap(table.view(atColumn: 1, row: 0, makeIfNecessary: true) as? NSTextField)
        XCTAssertEqual(table.tableColumns[0].title, "Notes")
        XCTAssertEqual(notes.stringValue, "")
        XCTAssertEqual(clip.stringValue, "Camera_A")
        XCTAssertEqual(notes.accessibilityLabel(), L10n.tr("第 {0} 行，{1}", ["1", "Notes"]))
        let coordinator = try XCTUnwrap(notes.delegate as? EditableCSVTableRepresentable.Coordinator)
        coordinator.controlTextDidBeginEditing(Notification(name: NSControl.textDidBeginEditingNotification, object: notes))
        notes.stringValue = "changed notes"
        try coordinator.flushEdit()
        XCTAssertEqual(commits.values.last?.columnID, 1)
        XCTAssertEqual(commits.values.last?.value, "changed notes")
        XCTAssertFalse(table.usesAutomaticRowHeights)
        XCTAssertFalse(fixture.window.isVisible)
    }

    func testWorksheetJumpAndEditExportIntoOriginalTemplate() async throws {
        // A bilingual, reordered template has no Shot, Take or Shoot Day. Only
        // the selected source FPS may change; preserve BOM, delimiters and CRLF.
        let original = "\u{feff}Notes;摄影机帧率;文件名;场景\r\nkeep;25;A001C001.mov;001\r\nother;30;B001C001.mov;old\r\n"
        let bytes = Data(original.utf8)
        let source = try await ResolveCSVEngine().decode(bytes)
        let id = UUID()
        let fps = CSVWorksheetCell(row: 0, column: 1)
        let commits = CommitRecorder()
        let bridge = EditableCSVTableRepresentable(tableID: id, table: source, revision: 0,
            onCommit: { commits.values.append($0) })
        var sheet = CSVWorksheet(reviewColumns: true, jump: .init(tableID: id, row: 0, column: 1),
            diagnosticsGeneration: 1, warnings: [fps], onActiveCell: { _ in })
        let fixture = Fixture(rootView: bridge.worksheet(sheet))
        defer { fixture.close() }
        try await fixture.settle()
        let table = try XCTUnwrap(fixture.table)
        XCTAssertEqual(table.tableColumns.map(\.title), ["场景", "摄影机帧率"])
        XCTAssertEqual(table.selectedRow, 0)
        let ruler = try XCTUnwrap(table.enclosingScrollView?.verticalRulerView as? CSVWorksheetRuler)
        XCTAssertEqual(ruler.labelForRow?(1), "B001C001.mov")
        let field = try XCTUnwrap(table.view(atColumn: 1, row: 0, makeIfNecessary: true) as? CSVTableTextField)
        XCTAssertTrue(field.active)
        XCTAssertTrue(field.warns)
        XCTAssertEqual(field.accessibilityLabel(), L10n.tr("第 {0} 行，{1}", ["2", "摄影机帧率"]))
        let coordinator = try XCTUnwrap(field.delegate as? EditableCSVTableRepresentable.Coordinator)
        coordinator.controlTextDidBeginEditing(.init(name: NSControl.textDidBeginEditingNotification, object: field))
        field.stringValue = "24"
        try coordinator.flushEdit()
        let edit = try XCTUnwrap(commits.values.last)
        sheet.reviewColumns = false
        fixture.host.rootView = bridge.worksheet(sheet)
        try await fixture.settle()
        XCTAssertEqual(table.tableColumns.map(\.title), source.headers)
        let exported = try await SM05WorkflowServices().mergeAndEncode(source: bytes,
            records: [.init(cardNumber: "A001", videoCode: "C001", scene: "1", shot: "1", take: "1")],
            metadata: [.init(materialKey: "A:1:1", sensorFps: "50", shootDay: "2026-01-02")],
            edits: [.init(rowIndex: edit.rowID, columnIndex: edit.columnID, value: edit.value)],
            preserveTemplate: true)
        XCTAssertEqual(exported.data, Data("\u{feff}Notes;摄影机帧率;文件名;场景\r\nkeep;24;A001C001.mov;001\r\nother;30;B001C001.mov;old\r\n".utf8))
        XCTAssertTrue(exported.merge.addedColumns.isEmpty)
        XCTAssertFalse(fixture.window.isVisible)
    }

    func testSameHeadersWithNewIdentityRefreshWidthsAndReusedCellAlignment() async throws {
        let fixture = Fixture(value: "1")
        defer { fixture.close() }
        try await fixture.settle()
        let table = try XCTUnwrap(fixture.table)
        let numericWidth = table.tableColumns[0].width
        XCTAssertEqual(try fixture.cell().alignment, .right)

        fixture.host.rootView = surface(id: UUID(), value: "Camera_A_20261023_Long_Clip_Name")
        try await fixture.settle()
        XCTAssertTrue(fixture.table === table, "The native editor remains mounted across tasks")
        XCTAssertGreaterThan(table.tableColumns[0].width, numericWidth + 100)
        XCTAssertEqual(table.tableColumns[0].headerCell.alignment, .left)
        XCTAssertEqual(try fixture.cell().alignment, .left)

        // Reverse the transition too: cells formerly used by text must adopt
        // numeric alignment even when AppKit retrieves them from its reuse pool.
        fixture.host.rootView = surface(id: UUID(), value: "2")
        try await fixture.settle()
        XCTAssertEqual(table.tableColumns[0].width, numericWidth, accuracy: 1)
        XCTAssertEqual(table.tableColumns[0].headerCell.alignment, .right)
        XCTAssertEqual(try fixture.cell().alignment, .right)
        XCTAssertFalse(fixture.window.isVisible)
    }

    func testEditsAndResizeKeepUserColumnWidth() async throws {
        let fixture = Fixture(value: "1")
        defer { fixture.close() }
        try await fixture.settle()
        let table = try XCTUnwrap(fixture.table)
        let column = table.tableColumns[0]
        column.width = 220
        let chosenWidth = column.width
        let id = fixture.host.rootView.tableID
        fixture.host.rootView = surface(id: id, value: "123456789", revision: 1)
        try await fixture.settle()
        fixture.window.setContentSize(CGSize(width: 800, height: 400))
        try await fixture.settle()
        XCTAssertTrue(table.tableColumns[0] === column)
        XCTAssertEqual(column.width, chosenWidth, accuracy: 1)
        XCTAssertEqual(try fixture.cell().stringValue, "123456789")
        XCTAssertFalse(fixture.window.isVisible)
    }

    private func surface(id: UUID, value: String, revision: Int = 0) -> EditableCSVTableRepresentable {
        Fixture.surface(id: id, value: value, revision: revision)
    }

    @MainActor private final class CommitRecorder {
        var values: [CSVCellCommit] = []
    }

    @MainActor private final class Fixture {
        let host: NSHostingView<EditableCSVTableRepresentable>
        let window: NSWindow

        convenience init(value: String, onCommit: @escaping @MainActor @Sendable (CSVCellCommit) -> Void = { _ in }) {
            self.init(rootView: Self.surface(id: UUID(), value: value, onCommit: onCommit))
        }

        init(rootView: EditableCSVTableRepresentable) {
            host = NSHostingView(rootView: rootView)
            window = NSWindow(contentRect: NSRect(x: -20_000, y: -20_000, width: 640, height: 400),
                styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = host
        }

        static func surface(id: UUID, value: String, revision: Int = 0,
                            onCommit: @escaping @MainActor @Sendable (CSVCellCommit) -> Void = { _ in }) -> EditableCSVTableRepresentable {
            EditableCSVTableRepresentable(tableID: id, table: .init(
                headers: ["Clip", "Notes"], rows: [[value, ""]], format: .init()),
                revision: revision, onCommit: onCommit)
        }

        var table: NSTableView? { findTable(host) }

        func cell() throws -> NSTextField {
            try XCTUnwrap(table?.view(atColumn: 0, row: 0, makeIfNecessary: true) as? NSTextField)
        }

        func settle() async throws {
            for _ in 0..<5 {
                host.layoutSubtreeIfNeeded()
                try await Task.sleep(for: .milliseconds(30))
            }
        }

        func close() { window.contentView = nil; window.close() }

        private func findTable(_ view: NSView) -> NSTableView? {
            (view as? NSTableView) ?? view.subviews.lazy.compactMap { self.findTable($0) }.first
        }
    }
}

import AppKit
import SlateSyncDomain
import SwiftUI

/// Pure grid navigation keeps keyboard semantics deterministic even when an
/// AppKit field editor is recreated by NSTableView's virtualization layer.
/// The coordinator applies the returned destination only after committing the
/// current cell, so selection never outruns the persisted table snapshot.
enum CSVKeyboardNavigation {
    enum Movement { case next, previous, up, down, left, right, firstColumn, lastColumn }

    static func destination(
        row: Int,
        column: Int,
        rows: Int,
        columns: Int,
        movement: Movement
    ) -> (row: Int, column: Int)? {
        guard rows > 0, columns > 0, (0..<rows).contains(row), (0..<columns).contains(column) else { return nil }
        switch movement {
        case .next:
            let index = row * columns + column + 1
            return index < rows * columns ? (index / columns, index % columns) : nil
        case .previous:
            let index = row * columns + column - 1
            return index >= 0 ? (index / columns, index % columns) : nil
        case .up:
            return row > 0 ? (row - 1, column) : nil
        case .down:
            return row + 1 < rows ? (row + 1, column) : nil
        case .left:
            return column > 0 ? (row, column - 1) : nil
        case .right:
            return column + 1 < columns ? (row, column + 1) : nil
        case .firstColumn:
            return (row, 0)
        case .lastColumn:
            return (row, columns - 1)
        }
    }
}

/// The single SM-08 AppKit data-surface bridge. NSTableView supplies row reuse
/// for 10k editable rows; the coordinator owns only AppKit edit/scroll state
/// and reports immutable identities back to the MainActor model.
public struct EditableCSVTableRepresentable: NSViewRepresentable {
    @Environment(\.isEnabled) private var isEnabled
    public let tableID: UUID
    public let table: ResolveCSVTable
    public let revision: Int
    public let accessibilityLabel: String
    public let onCommit: @MainActor @Sendable (CSVCellCommit) -> Void
    public var editorRegistration: (@MainActor ((@MainActor () throws -> Void)?) -> Void)?

    public init(
        tableID: UUID,
        table: ResolveCSVTable,
        revision: Int,
        accessibilityLabel: String = "可编辑 Resolve CSV",
        onCommit: @escaping @MainActor @Sendable (CSVCellCommit) -> Void,
        editorRegistration: (@MainActor ((@MainActor () throws -> Void)?) -> Void)? = nil
    ) {
        self.tableID = tableID
        self.table = table
        self.revision = revision
        self.accessibilityLabel = accessibilityLabel
        self.onCommit = onCommit
        self.editorRegistration = editorRegistration
    }

    public func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    public func makeNSView(context: Context) -> NSScrollView {
        let tableView = NSTableView()
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.allowsMultipleSelection = false
        tableView.allowsEmptySelection = true
        tableView.columnAutoresizingStyle = .noColumnAutoresizing
        tableView.rowSizeStyle = .medium
        tableView.setAccessibilityLabel(accessibilityLabel)
        context.coordinator.tableView = tableView
        context.coordinator.rebuildColumns(for: tableView)
        editorRegistration?({ [weak coordinator = context.coordinator] in try coordinator?.flushEdit() })

        // Install columns before exposing rows, then attach a finite clip
        // viewport before setting the data source. An unattached table can
        // eagerly create all 10k rows while addTableColumn recalculates layout.
        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 640, height: 400))
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        tableView.delegate = context.coordinator
        tableView.dataSource = context.coordinator
        return scrollView
    }

    public func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSScrollView, context: Context) -> CGSize? {
        // The scroll surface sizes to its container, never the document's
        // intrinsic 10k-row height during SwiftUI's unconstrained sizing pass.
        CGSize(width: proposal.width ?? 640, height: proposal.height ?? 400)
    }

    public func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let tableView = context.coordinator.tableView else { return }
        context.coordinator.parent = self
        // AppKit controls must explicitly honor SwiftUI's shared mutation/
        // termination freeze. Preserve the field editor until flush consumes it.
        let visible = tableView.rows(in: tableView.visibleRect)
        let visibleRows = visible.location == NSNotFound ? 0..<0 : visible.location..<NSMaxRange(visible)
        for row in visibleRows {
            for column in tableView.tableColumns.indices {
                (tableView.view(atColumn: column, row: row, makeIfNecessary: false) as? NSTextField)?.isEditable = isEnabled
            }
        }
        if context.coordinator.headers != table.headers {
            context.coordinator.rebuildColumns(for: tableView)
        }
        // Different result tables may both start at revision zero. Identity
        // changes must invalidate native rows even when the revision matches.
        guard context.coordinator.renderedRevision != revision ||
                context.coordinator.renderedTableID != tableID else { return }
        let origin = scrollView.contentView.bounds.origin
        let selected = tableView.selectedRowIndexes
        tableView.reloadData()
        tableView.selectRowIndexes(selected, byExtendingSelection: false)
        scrollView.contentView.scroll(to: origin)
        scrollView.reflectScrolledClipView(scrollView.contentView)
        context.coordinator.renderedRevision = revision
        context.coordinator.renderedTableID = tableID
    }

    public static func dismantleNSView(_ scrollView: NSScrollView, coordinator: Coordinator) {
        coordinator.timer?.cancel()
        coordinator.parent.editorRegistration?(nil)
        // Break AppKit delegate cycles and finish the edit session explicitly;
        // no database or timer is retained by this bridge.
        coordinator.tableView?.abortEditing()
        coordinator.tableView?.delegate = nil
        coordinator.tableView?.dataSource = nil
        scrollView.documentView = nil
        coordinator.tableView = nil
    }

    @MainActor
    public final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate {
        fileprivate var parent: EditableCSVTableRepresentable
        fileprivate weak var tableView: NSTableView?
        fileprivate var renderedRevision = -1
        fileprivate var renderedTableID: UUID?
        fileprivate var headers: [String] = []
        fileprivate var timer: Task<Void, Never>?
        private weak var editingField: NSTextField?
        private var editingIdentity: CSVCellCommit?
        private var lastCommittedValue: String?

        public func controlTextDidBeginEditing(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            let cell = cellIdentity(for: field)
            editingField = field
            lastCommittedValue = field.stringValue
            editingIdentity = CSVCellCommit(tableID: parent.tableID, rowID: cell.row,
                columnID: cell.column, revision: parent.revision, value: field.stringValue)
        }

        public func controlTextDidChange(_ notification: Notification) {
            timer?.cancel()
            guard let field = notification.object as? NSTextField,
                  !((field.currentEditor() as? NSTextView)?.hasMarkedText() ?? false) else { return }
            timer = Task { [weak self, weak field] in
                do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
                guard let self, let field, !Task.isCancelled else { return }
                self.commit(field)
            }
        }

        /// Navigation/close invokes this while the editor is still mounted.
        /// Composition is a recoverable barrier failure, never a forced submit.
        public func flushEdit() throws {
            guard let field = editingField else { return }
            if (field.currentEditor() as? NSTextView)?.hasMarkedText() == true {
                throw SlateSyncError(code: "EDIT_COMPOSITION", message: "请先完成当前文字输入，再切换或关闭")
            }
            timer?.cancel()
            commit(field)
        }

        fileprivate init(parent: EditableCSVTableRepresentable) { self.parent = parent }

        public func numberOfRows(in tableView: NSTableView) -> Int { parent.table.rows.count }

        public func tableView(
            _ tableView: NSTableView,
            viewFor tableColumn: NSTableColumn?,
            row: Int
        ) -> NSView? {
            guard let tableColumn,
                  let column = tableView.tableColumns.firstIndex(of: tableColumn) else { return nil }
            let identifier = NSUserInterfaceItemIdentifier("csv.cell.\(column)")
            let field: NSTextField
            if let reused = tableView.makeView(withIdentifier: identifier, owner: nil) as? NSTextField {
                field = reused
            } else {
                field = NSTextField()
                field.identifier = identifier
                field.isBordered = false
                field.drawsBackground = false
                field.lineBreakMode = .byTruncatingTail
                field.delegate = self
            }
            field.tag = row * max(1, parent.table.headers.count) + column
            field.isEditable = parent.isEnabled
            field.stringValue = value(row: row, column: column)
            field.setAccessibilityLabel("第 \(row + 1) 行，\(parent.table.headers[column])")
            return field
        }

        public func controlTextDidEndEditing(_ notification: Notification) {
            guard let field = notification.object as? NSTextField,
                  !((field.currentEditor() as? NSTextView)?.hasMarkedText() ?? false) else { return }
            commit(field)
            timer?.cancel()
            editingField = nil
            editingIdentity = nil
            lastCommittedValue = nil
        }

        public func control(
            _ control: NSControl,
            textView: NSTextView,
            doCommandBy commandSelector: Selector
        ) -> Bool {
            guard let field = control as? NSTextField else { return false }
            if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
                guard !textView.hasMarkedText() else { return true }
                timer?.cancel()
                let identity = cellIdentity(for: field)
                field.stringValue = value(row: identity.row, column: identity.column)
                editingField = nil
                editingIdentity = nil
                lastCommittedValue = nil
                tableView?.abortEditing()
                return true
            }
            // Enter, Tab, arrows and Home/End are cell commands, not text
            // mutations. A marked Chinese composition consumes the command so
            // no destructive navigation can submit its unfinished candidate.
            guard !textView.hasMarkedText() else { return true }
            switch commandSelector {
            case #selector(NSResponder.insertNewline(_:)):
                finishEditing(field)
                return true
            case #selector(NSResponder.insertTab(_:)):
                return moveEditing(field, movement: .next)
            case #selector(NSResponder.insertBacktab(_:)):
                return moveEditing(field, movement: .previous)
            case #selector(NSResponder.moveUp(_:)):
                return moveEditing(field, movement: .up)
            case #selector(NSResponder.moveDown(_:)):
                return moveEditing(field, movement: .down)
            case #selector(NSResponder.moveLeft(_:)):
                return moveEditing(field, movement: .left)
            case #selector(NSResponder.moveRight(_:)):
                return moveEditing(field, movement: .right)
            case #selector(NSResponder.moveToBeginningOfLine(_:)):
                return moveEditing(field, movement: .firstColumn)
            case #selector(NSResponder.moveToEndOfLine(_:)):
                return moveEditing(field, movement: .lastColumn)
            default:
                // Copy and paste remain NSTextView's native responder-chain
                // actions, preserving standard macOS shortcuts and services.
                return false
            }
        }

        fileprivate func rebuildColumns(for tableView: NSTableView) {
            tableView.tableColumns.forEach(tableView.removeTableColumn)
            headers = parent.table.headers
            for (index, title) in headers.enumerated() {
                let column = NSTableColumn(identifier: .init("csv.column.\(index)"))
                column.title = title.isEmpty ? "第 \(index + 1) 列" : title
                column.width = 160
                column.minWidth = 88
                column.maxWidth = 480
                tableView.addTableColumn(column)
            }
            renderedRevision = -1
        }

        private func commit(_ field: NSTextField) {
            guard let identity = editingIdentity,
                  identity.tableID == parent.tableID, identity.revision == parent.revision,
                  parent.table.rows.indices.contains(identity.rowID),
                  parent.table.headers.indices.contains(identity.columnID) else { return }
            let text = field.currentEditor()?.string ?? field.stringValue
            // Debounce and a synchronous route/merge flush can precede the
            // next SwiftUI update. Deduplicate against this editing session.
            guard text != lastCommittedValue else { return }
            lastCommittedValue = text
            parent.onCommit(CSVCellCommit(
                tableID: identity.tableID,
                rowID: identity.rowID,
                columnID: identity.columnID,
                revision: identity.revision,
                value: text
            ))
        }

        private func finishEditing(_ field: NSTextField) {
            timer?.cancel()
            commit(field)
            editingField = nil
            editingIdentity = nil
            lastCommittedValue = nil
            // The value has already crossed the MainActor callback boundary;
            // returning focus to the table lets AppKit complete its edit cycle
            // without retaining a field editor or creating a duplicate draft.
            _ = tableView?.window?.makeFirstResponder(tableView)
        }

        private func moveEditing(_ field: NSTextField, movement: CSVKeyboardNavigation.Movement) -> Bool {
            guard let tableView else {
                finishEditing(field)
                return true
            }
            let cell = cellIdentity(for: field)
            let destination = CSVKeyboardNavigation.destination(
                row: cell.row,
                column: cell.column,
                rows: tableView.numberOfRows,
                columns: tableView.tableColumns.count,
                movement: movement
            )
            finishEditing(field)
            guard let destination else { return true }
            tableView.selectRowIndexes(IndexSet(integer: destination.row), byExtendingSelection: false)
            tableView.editColumn(destination.column, row: destination.row, with: nil, select: true)
            return true
        }

        private func cellIdentity(for field: NSTextField) -> (row: Int, column: Int) {
            let count = max(1, parent.table.headers.count)
            return (field.tag / count, field.tag % count)
        }

        private func value(row: Int, column: Int) -> String {
            guard parent.table.rows.indices.contains(row),
                  parent.table.rows[row].indices.contains(column) else { return "" }
            return parent.table.rows[row][column]
        }
    }
}

import AppKit
import SlateSyncDomain
import SwiftUI

// Product copy uses the shared launch language; user content stays verbatim.

/// Pure grid navigation keeps keyboard semantics deterministic even when an
/// AppKit field editor is recreated by NSTableView's virtualization layer.
/// The coordinator applies the returned destination only after committing the
/// current cell, so selection never outruns the persisted table snapshot.
enum CSVKeyboardNavigation {
    enum Movement: Equatable { case next, previous, up, down, left, right, firstColumn, lastColumn }
    enum CommandAction: Equatable {
        case native
        case consumeComposition
        case cancel
        case finish
        case move(Movement)
    }

    /// Keep selector ownership testable without mounting a visible window.
    /// Unknown commands, including copy/paste, remain with NSTextView; only
    /// cell navigation is consumed while Chinese marked text is active.
    static func action(for selector: Selector, hasMarkedText: Bool) -> CommandAction {
        let action: CommandAction = switch selector {
        case #selector(NSResponder.cancelOperation(_:)): .cancel
        case #selector(NSResponder.insertNewline(_:)): .finish
        case #selector(NSResponder.insertTab(_:)): .move(.next)
        case #selector(NSResponder.insertBacktab(_:)): .move(.previous)
        case #selector(NSResponder.moveUp(_:)): .move(.up)
        case #selector(NSResponder.moveDown(_:)): .move(.down)
        case #selector(NSResponder.moveLeft(_:)): .move(.left)
        case #selector(NSResponder.moveRight(_:)): .move(.right)
        case #selector(NSResponder.moveToBeginningOfLine(_:)): .move(.firstColumn)
        case #selector(NSResponder.moveToEndOfLine(_:)): .move(.lastColumn)
        default: .native
        }
        return hasMarkedText && action != .native ? .consumeComposition : action
    }

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

    /// NSTableView can preserve selection while SwiftUI replaces the backing
    /// snapshot. Keep only rows that still exist before reapplying selection.
    static func validSelection(_ selection: IndexSet, rows: Int) -> IndexSet {
        guard rows > 0 else { return [] }
        return IndexSet(selection.filter { $0 >= 0 && $0 < rows })
    }
}

/// Counts binding work without observing SwiftUI state or retaining row views.
/// These diagnostics supplement FPS; they never change the rendering workload.
struct CSVCellWorkMetrics: Sendable {
    var bindings = 0
    var creations = 0
    var valueWrites = 0
    var styleWrites = 0
    var accessibilityFormats = 0
}

/// Keep native text editing/layout intact, but format the contextual AX label
/// only when a client requests it. Scrolling must not eagerly localize a label
/// for every reused cell. The cache belongs to this cell, not the whole table.
@MainActor
final class CSVTableTextField: NSTextField {
    private var representedRow = -1
    private var representedHeader = ""
    private var cachedLabel: String?
    private var cachedLanguage: AppLanguage?

    func bindAccessibility(row: Int, header: String) {
        guard representedRow != row || representedHeader != header else { return }
        representedRow = row
        representedHeader = header
        cachedLabel = nil
    }

    override func accessibilityLabel() -> String? {
        guard representedRow >= 0 else { return super.accessibilityLabel() }
        let language = L10n.language
        if let cachedLabel, cachedLanguage == language { return cachedLabel }
        let label = L10n.tr("第 {0} 行，{1}", [String(representedRow + 1), representedHeader], language: language)
        cachedLabel = label
        cachedLanguage = language
        (delegate as? EditableCSVTableRepresentable.Coordinator)?.recordAccessibilityFormat()
        return label
    }
}

/// The single SM-08 AppKit data-surface bridge. NSTableView supplies row reuse
/// for 10k editable rows; the coordinator owns only AppKit edit/scroll state
/// and reports immutable identities back to the MainActor model.
public struct EditableCSVTableRepresentable: NSViewRepresentable {
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.slateSyncDensity) private var sceneDensity
    private let density: SlateSyncDensity?
    private var effectiveDensity: SlateSyncDensity { density ?? sceneDensity }
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
        accessibilityLabel: String = L10n.tr("可编辑 Resolve CSV"),
        density: SlateSyncDensity? = nil,
        onCommit: @escaping @MainActor @Sendable (CSVCellCommit) -> Void,
        editorRegistration: (@MainActor ((@MainActor () throws -> Void)?) -> Void)? = nil
    ) {
        self.tableID = tableID
        self.table = table
        self.revision = revision
        self.accessibilityLabel = accessibilityLabel
        self.density = density
        self.onCommit = onCommit
        self.editorRegistration = editorRegistration
    }

    public func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    public func makeNSView(context: Context) -> NSScrollView {
        let tableView = NSTableView()
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.allowsMultipleSelection = false
        tableView.allowsEmptySelection = true
        // Content-sized columns; only the last one stretches to fill the width.
        tableView.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        tableView.rowSizeStyle = .custom
        // Density owns fixed row heights; do not ask every reused text field
        // to determine automatic row geometry while traversing a large table.
        tableView.usesAutomaticRowHeights = false
        tableView.rowHeight = effectiveDensity.tableRowHeight
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
        context.coordinator.applyDensity()
        // AppKit controls must explicitly honor SwiftUI's shared mutation/
        // termination freeze. Preserve the field editor until flush consumes it.
        // The sweep touches every visible cell (rows × columns) and SwiftUI calls
        // this method on each layout-driven update — for example every frame of
        // a sidebar collapse — so run it only when the freeze state flips. Cells
        // created later (reload, scrolling) read `isEnabled` in viewFor.
        if context.coordinator.appliedEnabled != isEnabled {
            let visible = tableView.rows(in: tableView.visibleRect)
            let visibleRows = visible.location == NSNotFound ? 0..<0 : visible.location..<NSMaxRange(visible)
            for row in visibleRows {
                for column in tableView.tableColumns.indices {
                    (tableView.view(atColumn: column, row: row, makeIfNecessary: false) as? NSTextField)?.isEditable = isEnabled
                }
            }
            context.coordinator.appliedEnabled = isEnabled
        }
        // A new task/import can keep the same headers but have entirely
        // different content. Resample once per table identity; ordinary edits
        // and layout updates preserve the user's manually resized columns.
        if context.coordinator.headers != table.headers || context.coordinator.columnTableID != tableID {
            context.coordinator.rebuildColumns(for: tableView)
        }
        // Different result tables may both start at revision zero. Identity
        // changes must invalidate native rows even when the revision matches.
        guard context.coordinator.renderedRevision != revision ||
                context.coordinator.renderedTableID != tableID else { return }
        let origin = scrollView.contentView.bounds.origin
        let selected = CSVKeyboardNavigation.validSelection(
            tableView.selectedRowIndexes,
            rows: table.rows.count
        )
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
        /// Last editability pushed to the visible cells; nil until the first update.
        fileprivate var appliedEnabled: Bool?
        fileprivate var headers: [String] = []
        fileprivate var columnTableID: UUID?
        private struct ColumnBinding {
            let sourceIndex: Int
            let reuseIdentifier: NSUserInterfaceItemIdentifier
            let header: String
            let alignment: NSTextAlignment
        }
        // Prepared once per schema/table identity. Avoid bridging and searching
        // tableColumns for every cell request; native visual order can change.
        private var columnBindings: [ObjectIdentifier: ColumnBinding] = [:]
        private var sourceColumnIdentifiers: [NSUserInterfaceItemIdentifier] = []
        private(set) var cellWork = CSVCellWorkMetrics()
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
                throw SlateSyncError(code: "EDIT_COMPOSITION", message: L10n.tr("请先完成当前文字输入，再切换或关闭"))
            }
            timer?.cancel()
            commit(field)
        }

        fileprivate init(parent: EditableCSVTableRepresentable) { self.parent = parent }

        /// Geometry updates never reload rows. Defer while a field editor is
        /// active, then apply after its commit so marked text is not disrupted.
        fileprivate func applyDensity() {
            guard editingField == nil, let tableView else { return }
            let height = parent.effectiveDensity.tableRowHeight
            guard tableView.rowHeight != height else { return }
            let selected = tableView.selectedRowIndexes
            let origin = tableView.enclosingScrollView?.contentView.bounds.origin
            tableView.rowHeight = height
            tableView.selectRowIndexes(selected, byExtendingSelection: false)
            if let origin, let scrollView = tableView.enclosingScrollView {
                scrollView.contentView.scroll(to: origin)
                scrollView.reflectScrolledClipView(scrollView.contentView)
            }
        }

        public func numberOfRows(in tableView: NSTableView) -> Int { parent.table.rows.count }

        public func tableView(
            _ tableView: NSTableView,
            viewFor tableColumn: NSTableColumn?,
            row: Int
        ) -> NSView? {
            guard let tableColumn,
                  let binding = columnBindings[ObjectIdentifier(tableColumn)],
                  parent.table.headers.indices.contains(binding.sourceIndex) else { return nil }
            let column = binding.sourceIndex
            cellWork.bindings += 1
            let field: CSVTableTextField
            if let reused = tableView.makeView(withIdentifier: binding.reuseIdentifier, owner: nil) as? CSVTableTextField {
                field = reused
            } else {
                field = CSVTableTextField()
                field.identifier = binding.reuseIdentifier
                cellWork.creations += 1
                field.isBordered = false
                // Table cells do not need the standalone text-input bezel's
                // appearance layers. Limit display layout to the fixed-height
                // row without single-line editing mode, which would strip
                // pasted newlines from the original CSV value.
                field.isBezeled = false
                field.maximumNumberOfLines = 1
                field.drawsBackground = false
                field.lineBreakMode = .byTruncatingTail
                // Digits are tabular so numeric columns line up; numeric
                // columns are right-aligned.
                field.font = Self.cellFont
                field.delegate = self
            }
            field.tag = row * max(1, parent.table.headers.count) + column
            field.bindAccessibility(row: row, header: binding.header)
            // AppKit reuses cells across tables; alignment belongs to the
            // current sampled column, not to the cell's creation-time table.
            // AppKit setters may invalidate text/layout/display even for an
            // unchanged value. Apply only actual differences on cell reuse.
            if field.alignment != binding.alignment {
                field.alignment = binding.alignment
                cellWork.styleWrites += 1
            }
            if field.isEditable != parent.isEnabled {
                field.isEditable = parent.isEnabled
                cellWork.styleWrites += 1
            }
            let text = value(row: row, column: column)
            if field.stringValue != text {
                field.stringValue = text
                cellWork.valueWrites += 1
            }
            return field
        }

        fileprivate func recordAccessibilityFormat() { cellWork.accessibilityFormats += 1 }

        public func controlTextDidEndEditing(_ notification: Notification) {
            guard let field = notification.object as? NSTextField,
                  !((field.currentEditor() as? NSTextView)?.hasMarkedText() ?? false) else { return }
            commit(field)
            timer?.cancel()
            editingField = nil
            editingIdentity = nil
            lastCommittedValue = nil
            applyDensity()
        }

        public func control(
            _ control: NSControl,
            textView: NSTextView,
            doCommandBy commandSelector: Selector
        ) -> Bool {
            guard let field = control as? NSTextField else { return false }
            switch CSVKeyboardNavigation.action(
                for: commandSelector,
                hasMarkedText: textView.hasMarkedText()
            ) {
            case .native:
                // Copy, paste and text-system commands remain on NSTextView's
                // responder chain, including during an IME composition.
                return false
            case .consumeComposition:
                return true
            case .cancel:
                timer?.cancel()
                let identity = cellIdentity(for: field)
                field.stringValue = value(row: identity.row, column: identity.column)
                editingField = nil
                editingIdentity = nil
                lastCommittedValue = nil
                tableView?.abortEditing()
                applyDensity()
                return true
            case .finish:
                finishEditing(field)
                return true
            case .move(let movement):
                return moveEditing(field, movement: movement)
            }
        }

        private static let cellFont = NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        private static let headerFont = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize, weight: .medium)
        /// Rows sampled to size a column; sizing never walks all 10k rows.
        private static let sampleRows = 200

        /// A column is as wide as its widest sampled value (or its title) plus
        /// cell padding, so single-digit columns stay narrow and identifiers such
        /// as clip names are not truncated.
        fileprivate func rebuildColumns(for tableView: NSTableView) {
            columnBindings.removeAll(keepingCapacity: true)
            sourceColumnIdentifiers.removeAll(keepingCapacity: true)
            tableView.tableColumns.forEach(tableView.removeTableColumn)
            headers = parent.table.headers
            columnTableID = parent.tableID
            let rows = parent.table.rows.prefix(Self.sampleRows)
            for (index, title) in headers.enumerated() {
                let shown = title.isEmpty ? L10n.tr("第 {0} 列", [String(describing: index + 1)]) : title
                let values = rows.compactMap { $0.indices.contains(index) ? $0[index] : nil }.filter { !$0.isEmpty }
                let numeric = !values.isEmpty && values.allSatisfy { $0.allSatisfy { $0.isNumber || $0 == "." || $0 == "-" } }
                func width(_ text: String, _ font: NSFont) -> CGFloat {
                    ceil((text as NSString).size(withAttributes: [.font: font]).width)
                }
                let content = values.map { width($0, Self.cellFont) }.max() ?? 0
                let natural = max(content, width(shown, Self.headerFont)) + 22
                let column = NSTableColumn(identifier: .init("csv.column.\(index)"))
                column.title = shown
                column.minWidth = numeric ? 40 : 52
                column.maxWidth = index == headers.count - 1 ? 10_000 : 480
                column.width = min(max(natural, column.minWidth), 360)
                column.headerCell.alignment = numeric ? .right : .left
                column.headerCell.font = Self.headerFont
                columnBindings[ObjectIdentifier(column)] = ColumnBinding(
                    sourceIndex: index, reuseIdentifier: .init("csv.cell.\(index)"),
                    header: title, alignment: numeric ? .right : .left)
                sourceColumnIdentifiers.append(column.identifier)
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
            applyDensity()
        }

        private func moveEditing(_ field: NSTextField, movement: CSVKeyboardNavigation.Movement) -> Bool {
            guard let tableView else {
                finishEditing(field)
                return true
            }
            let cell = cellIdentity(for: field)
            // Cell tags/commits use source columns. Keyboard movement uses the
            // current visual order, including a native header drag reorder.
            guard sourceColumnIdentifiers.indices.contains(cell.column) else {
                finishEditing(field)
                return true
            }
            let visualColumn = tableView.column(withIdentifier: sourceColumnIdentifiers[cell.column])
            guard visualColumn >= 0 else {
                finishEditing(field)
                return true
            }
            let destination = CSVKeyboardNavigation.destination(
                row: cell.row,
                column: visualColumn,
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

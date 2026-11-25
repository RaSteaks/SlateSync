import SlateSyncDomain
import SlateSyncWorkflow
import SwiftUI
import UniformTypeIdentifiers

// Product copy uses the shared launch language; user content stays verbatim.

public struct ResolveCSVView: View {
    // A retained CSV page must relinquish its window actions immediately,
    // including when an ancestor workspace route is leaving the screen.
    @Environment(\.contentRevealIsActive) private var revealIsActive
    @Environment(\.slateSyncDensity) private var density
    @Bindable private var model: ResolveCSVModel
    @State private var importsCSV = false
    @State private var showsSavePanel = false
    @State private var selectsMediaDirectory = false
    @State private var mediaDirectory: (tableID: UUID, url: URL)?
    @State private var directoryRequest: DirectoryRequest?
    @State private var failedCell: CSVWorksheetJump?
    @State private var preparing = false
    @State private var reviewColumns = true
    @State private var issues: [DiagnosticRow] = []
    @State private var indexedGeneration = 0
    @State private var warningCells: Set<CSVWorksheetCell> = []
    @State private var issueIndex: Int?
    @State private var showsIssue = false
    @State private var jump: CSVWorksheetJump?
    @State private var activeCell: CSVWorksheetCell?
    @State private var requestsExport = false
    @State private var exportDocument: MetadataDocument?
    @State private var diagnosticReport: WorkflowDiagnosticReport?
    private let recognition: RecognitionModel?
    private let workspace: WorkspaceModel?
    private let onImport: (@MainActor () -> Void)?

    private let onShowResults: (() -> Void)?

    private struct DirectoryRequest: Identifiable {
        let id = UUID()
        let tableID: UUID
        let destination: DeliveryDestination
    }

    struct DiagnosticRow {
        let message: String
        var row: Int?
        var column: Int?
    }

    public init(
        model: ResolveCSVModel, recognition: RecognitionModel? = nil, workspace: WorkspaceModel? = nil,
        onImport: (@MainActor () -> Void)? = nil, onShowResults: (() -> Void)? = nil
    ) {
        self.model = model
        self.recognition = recognition
        self.workspace = workspace
        self.onImport = onImport
        self.onShowResults = onShowResults
    }

    public var body: some View {
        VStack(spacing: 0) {
            // Import, merge and export live in the window toolbar (below); the
            // editor keeps one stable structural position and its native
            // selection/scroll owner. The strip is the page's scope line.
            if model.table != nil {
                diagnosticsStrip
                    .fileImporter(isPresented: $selectsMediaDirectory, allowedContentTypes: [.folder], allowsMultipleSelection: false) { [request = directoryRequest] result in
                        guard let request, directoryRequest?.id == request.id, request.tableID == model.tableID else { return }
                        directoryRequest = nil
                        switch result {
                        case .success(let urls):
                            guard let url = urls.first else { return }
                            mediaDirectory = (request.tableID, url)
                            performExport(request.destination, directory: url)
                        case .failure(let error): model.report(error)
                        }
                    } onCancellation: { [request = directoryRequest] in
                        if directoryRequest?.id == request?.id { directoryRequest = nil }
                    }
                    .fileDialogMessage(Text(L10n.tr("选择源素材所在目录，以继续本次 XML 导出。")))
                Divider()
            }
            if let table = model.table {
                EditableCSVTableRepresentable(
                    tableID: model.tableID,
                    table: table,
                    revision: model.revision,
                    onCommit: model.receive,
                    editorRegistration: { model.flushEditor = $0 }
                )
                .worksheet(.init(reviewColumns: reviewColumns, jump: jump, diagnosticsGeneration: indexedGeneration, warnings: warningCells, onActiveCell: { cell in
                    activeCell = cell
                    // Editing elsewhere dismisses the detail but preserves the
                    // review cursor so Next continues from the last finding.
                    showsIssue = false
                }))
                .accessibilityIdentifier(AccessibilityID.csvTable)
                .disabled(model.operation.isRunning)
                worksheetStatus(table)
            } else {
                SlateEmptyState(
                    title: L10n.tr("未导入 Resolve CSV"), symbol: "tablecells",
                    message: L10n.tr("导入后可直接编辑并保留原始字节格式。")
                ) { importAction }
            }
        }
        .disabled(recognition?.operation.isRunning == true)
        .toolbar {
            if revealIsActive {
                // Import is an icon (with a help tag); merge and export carry titles.
                ToolbarItemGroup(placement: .primaryAction) {
                    // AppKit collapses trailing toolbar items into the overflow chevron
                    // first when the window is narrow, so the order is by importance:
                    // the accent-filled export, then merge (a bordered secondary).
                    // Import is in the More menu; the empty state also offers it.
                    exportAction.slateToolbarPrimaryStyle().labelStyle(.titleAndIcon)
                    mergeButton.buttonStyle(.bordered).labelStyle(.titleAndIcon)
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            // Import, encode and save-panel failures retain the table and a
            // visible recovery message; cancellation never reports success.
            if case .running(let label) = model.operation {
                // Export/merge share visible progress and the same awaited
                // cancellation path used by task switches and window close.
                SlateStatusBar(message: label, busy: true) {
                    Button(L10n.tr("取消")) { Task { await model.drain() } }
                }
            } else if case .failed(let error) = model.operation {
                SlateStatusBar(message: error.message, tone: .error) {
                    // Keep recovery with the failed table. Users can retry an
                    // export or replace the source without dismissing errors.
                    if error.code == "DELIVERY_FIELD", let failedCell, failedCell.tableID == model.tableID {
                        Button(L10n.tr("返回校对")) {
                            do { try model.flushEditor?() } catch { model.report(error); return }
                            // Technical fields such as Tracks can be hidden in the compact view.
                            reviewColumns = false
                            jump = CSVWorksheetJump(tableID: failedCell.tableID, row: failedCell.row, column: failedCell.column)
                        }
                    } else {
                        Menu(L10n.tr("恢复操作")) {
                            importAction
                            mergeActions
                            deliveryItems
                        }.fixedSize()
                    }
                }
            } else if case .succeeded(let message) = model.operation {
                SlateStatusBar(message, tone: .success)
            }
        }
        .fileImporter(isPresented: $importsCSV, allowedContentTypes: [.commaSeparatedText, .plainText]) { result in
            Task {
                do {
                    let url = try result.get()
                    let data = try await SecurityScopedFileReader.read(url)
                    await model.importData(data, filename: url.lastPathComponent)
                } catch { model.report(error) }
            }
        }
        .fileExporter(
            isPresented: $showsSavePanel,
            document: exportDocument,
            contentType: exportDocument?.format.contentType ?? .commaSeparatedText,
            defaultFilename: exportDocument?.filename
        ) { result in
            guard let delivery = exportDocument, delivery.tableID == model.tableID else { return }
            exportDocument = nil
            switch result {
            case .success: model.exported(format: delivery.format)
            case .failure(let error): model.report(error)
            }
        }
        .fileDialogMessage(exportDocument.map { Text(verbatim: $0.saveMessage) })
        .confirmationDialog(
            exportDocument?.format == .ale ? L10n.tr("核对 Avid 匹配信息") : L10n.tr("仍有未解决的合并告警"), isPresented: $requestsExport, titleVisibility: .visible
        ) {
            Button(confirmationActionTitle) {
                if exportDocument?.tableID == model.tableID { showsSavePanel = true }
            }
            Button(L10n.tr("返回校对"), role: .cancel) { exportDocument = nil }
        } message: {
            Text(verbatim: exportDocument?.confirmationMessage ?? "")
        }
        .sheet(item: $diagnosticReport) { WorkflowDiagnosticsSheet(report: $0) }
        .onChange(of: model.diagnosticsGeneration, initial: true) {
            indexedGeneration = model.diagnosticsGeneration
            issues = model.lastMergeDiagnostics.map(Self.diagnosticsRows) ?? []
            warningCells = Set(issues.compactMap { issue in
                guard let row = issue.row, let column = issue.column else { return nil }
                return CSVWorksheetCell(row: row, column: column)
            })
            issueIndex = nil
            jump = nil
            activeCell = nil
        }
        .onChange(of: model.tableID) { _, _ in
            // Confirmation artifacts belong to the original table, never the
            // task selected while an async merge or save panel was pending.
            showsSavePanel = false
            exportDocument = nil
            selectsMediaDirectory = false
            directoryRequest = nil
            failedCell = nil
            preparing = false
            mediaDirectory = nil
            requestsExport = false
            diagnosticReport = nil
        }
    }

    // MARK: Reconciliation diagnostics

    private var unresolvedCount: Int {
        guard let diagnostics = model.lastMergeDiagnostics else { return 0 }
        return diagnostics.reviewIssueCount
    }

    private var diagnosticsStrip: some View {
        HStack(spacing: 8) {
            Picker(L10n.tr("显示列"), selection: Binding(get: { reviewColumns }, set: { choice in
                do {
                    try model.flushEditor?()
                    reviewColumns = choice
                    activeCell = nil
                    issueIndex = nil
                    jump = nil
                } catch { model.report(error) }
            })) {
                Text(L10n.tr("回填字段")).tag(true)
                Text(L10n.tr("全部列")).tag(false)
            }
            .pickerStyle(.segmented).labelsHidden().fixedSize()
            if !issues.isEmpty {
                Label(L10n.tr("待核对 {0} 项", [String(issues.count)]), systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(SlateSyncTheme.warning)
                ControlGroup {
                    Button(L10n.tr("上一项"), systemImage: "chevron.left") { if let issueIndex { visitIssue(issueIndex - 1) } }
                        .help(L10n.tr("上一项"))
                        .disabled(issueIndex == nil || issueIndex == 0)
                    Button(L10n.tr("下一项"), systemImage: "chevron.right") { visitIssue((issueIndex ?? -1) + 1) }
                        .help(L10n.tr("下一项"))
                        .disabled(issueIndex == issues.count - 1)
                }.labelStyle(.iconOnly).controlSize(.small).fixedSize()
                if let issueIndex {
                    Text("\(issueIndex + 1)/\(issues.count)").monospacedDigit().font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 4)
            reportButton.buttonStyle(.borderless).font(.caption)
            tableSummary
        }
        .disabled(model.operation.isRunning)
        .padding(.horizontal, density.panelPadding)
        .padding(.vertical, 6)
    }

    private func visitIssue(_ index: Int) {
        guard issues.indices.contains(index) else { return }
        do { try model.flushEditor?() } catch { model.report(error); return }
        issueIndex = index
        showsIssue = true
        let issue = issues[index]
        activeCell = nil
        jump = CSVWorksheetJump(tableID: model.tableID, row: issue.row, column: issue.column)
    }

    @ViewBuilder private func worksheetStatus(_ table: ResolveCSVTable) -> some View {
        let issue = issueIndex.flatMap { showsIssue && issues.indices.contains($0) ? issues[$0] : nil }
        let row = activeCell?.row ?? issue?.row
        let column = activeCell?.column ?? issue?.column
        if row != nil || issue != nil {
            Divider()
            HStack(spacing: 8) {
                if let row, table.rows.indices.contains(row) {
                    Text(L10n.tr("CSV 第 {0} 行", [String(row + 2)])).monospacedDigit()
                    if let column, table.headers.indices.contains(column), table.rows[row].indices.contains(column) {
                        Text(table.headers[column]).fontWeight(.medium)
                        Text(table.rows[row][column]).lineLimit(1).truncationMode(.middle)
                    }
                }
                if let issue {
                    Label(issue.message, systemImage: "exclamationmark.triangle").lineLimit(2).help(issue.message)
                    if issue.row == nil, let onShowResults {
                        Button(L10n.tr("查看识别结果"), action: onShowResults).buttonStyle(.link)
                    }
                } else if let activeCell, warningCells.contains(activeCell) {
                    Label(L10n.tr("此字段需要核对"), systemImage: "exclamationmark.triangle")
                }
                Spacer(minLength: 0)
            }
            .font(.caption).padding(.horizontal, density.panelPadding).padding(.vertical, 5)
        }
    }

    static func diagnosticsRows(_ diagnostics: ResolveMergeResult) -> [DiagnosticRow] {
        // Keep every occurrence when a material occupies several source rows.
        // Recognition-only findings deliberately have no invented CSV address.
        let byKey = Dictionary(grouping: diagnostics.rowKeys.indices.filter { !diagnostics.rowKeys[$0].isEmpty },
                               by: { diagnostics.rowKeys[$0] })
        let columns = try? ResolveHeaders.resolve(diagnostics.table.headers)
        func findings(_ message: String, rows: [Int]?, column: Int? = nil) -> [DiagnosticRow] {
            guard let rows, !rows.isEmpty else { return [DiagnosticRow(message: message)] }
            return rows.map { DiagnosticRow(message: message, row: $0, column: column.flatMap { $0 >= 0 ? $0 : nil }) }
        }
        let statusRows = diagnostics.unresolvedStatuses.flatMap { status in
            let subject = status.fileName ?? L10n.tr("第 {0} 条", [String(describing: status.recordIndex + 1)])
            let message: String
            switch status.status {
            case "missing-key":
                message = L10n.tr("{0} 缺少素材标识，未写入 CSV", [String(describing: subject)])
            case "incomplete":
                let fields = status.missingFields?.map { L10n.message($0) }.joined(separator: L10n.language == .english ? ", " : "、") ?? L10n.tr("场记字段")
                message = L10n.tr("{0} 缺少{1}，未写入场记字段", [String(describing: subject), String(describing: fields)])
            case "conflict":
                message = L10n.tr("{0} 的识别结果冲突，场记字段未写入", [String(describing: subject)])
            case "unmatched":
                message = L10n.tr("{0} 未匹配到 Resolve CSV 行，未写入", [String(describing: subject)])
            case "duplicate":
                message = L10n.tr("{0} 是重复识别记录，未写入", [String(describing: subject)])
            case "review-required":
                message = L10n.tr("{0} 包含自动修正字段，已回填但仍需核对", [subject])
            default:
                message = L10n.tr("{0} 的识别结果未写入 CSV", [String(describing: subject)])
            }
            let rows = status.rowIndexes ?? byKey[ResolveCSVNormalization.extractCombinedMaterialKey(status.fileName)]
            let fields = (status.missingFields ?? []).compactMap { columns?.reviewColumn(for: $0) }
            if rows != nil, !fields.isEmpty {
                return fields.flatMap { findings(message, rows: rows, column: $0) }
            }
            return findings(message, rows: rows)
        }
        let materials = diagnostics.unrecognizedMaterials.flatMap { material in
            findings(L10n.tr("素材 {0} 未在识别结果中匹配", [material]),
                     rows: byKey[ResolveCSVNormalization.extractCombinedMaterialKey(material)])
        }
        let fps = diagnostics.missingCameraFPSKeys.flatMap { key in
            findings(L10n.tr("素材 {0} 缺少相机帧率信息", [ResolveCSVNormalization.canonicalKeyToMaterialPrefix(key)]),
                     rows: byKey[key], column: columns?.cameraFPS)
        }
        let days = diagnostics.missingShootDayKeys.flatMap { key in
            findings(L10n.tr("素材 {0} 缺少拍摄日信息", [ResolveCSVNormalization.canonicalKeyToMaterialPrefix(key)]),
                     rows: byKey[key], column: columns?.shootDay)
        }
        let sequence = diagnostics.sequenceAnomalies.flatMap { findings(L10n.message($0.message), rows: byKey[$0.key]) }
        let unidentified = diagnostics.rowKeys.indices.filter { diagnostics.rowKeys[$0].isEmpty }.map { row in
            DiagnosticRow(message: L10n.tr("CSV 第 {0} 行的素材标识无法确认，未自动回填", [String(row + 2)]), row: row)
        }
        return statusRows + materials + fps + days + sequence + unidentified
    }

    @ViewBuilder private var deliveryItems: some View {
        ForEach(DeliveryDestination.allCases, id: \.self) { destination in
            Button(destination.title) { performExport(destination) }
        }
    }

    private var confirmationActionTitle: String {
        guard let document = exportDocument else { return L10n.tr("保存…") }
        if document.warningCount == 0 { return L10n.tr("保存 ALE…") }
        return document.format == .csv ? L10n.tr("仍要导出 CSV") : L10n.tr("仍要导出文件")
    }

    private func performExport(_ destination: DeliveryDestination = .resolveCSV, directory: URL? = nil) {
        guard !preparing, !model.operation.isRunning, directoryRequest == nil else { return }
        preparing = true
        failedCell = nil
        let format = destination.format
        let identity = model.tableID
        let folder = directory ?? (mediaDirectory?.tableID == identity ? mediaDirectory?.url : nil)
        Task {
            defer { if identity == model.tableID { preparing = false } }
            do {
                let payload: PreparedMetadata
                if let recognition, let workspace {
                    try await workspace.flush()
                    guard identity == model.tableID else { return }
                    // Canonical merged export: re-merge from the raw
                    // table with the latest records, apply manual
                    // field edits last, preserving every unrelated source cell.
                    // Old naming: <baseName(metadataFile)>_场记已回填.csv.
                    payload = try await model.prepareExport(
                        records: recognition.resolveRecords,
                        metadata: workspace.selectedTask?.slateMetadata ?? [],
                        settings: workspace.projectSettings.resolve, format: format, mediaDirectory: folder)
                } else {
                    payload = try await model.preparedTable(format: format, mediaDirectory: folder)
                }
                guard identity == model.tableID else { return }
                let csvName = recognition != nil && workspace != nil
                    ? ResolveCSVModel.suggestedFilename(model.filename, fallback: "Resolve", suffix: L10n.tr("场记已回填"))
                    : model.filename ?? "Resolve.csv"
                let filename = format == .csv ? csvName : (csvName as NSString).deletingPathExtension + "." + format.fileExtension
                // The save panel and warning confirmation share immutable bytes,
                // format and filename from this table's canonical merge.
                exportDocument = MetadataDocument(payload: payload, tableID: identity, destination: destination, filename: filename,
                    scope: scopeDescription, warningCount: unresolvedCount)
                if format == .ale || unresolvedCount > 0 { requestsExport = true } else { showsSavePanel = true }
            } catch is CancellationError { }
            catch let issue as DeliveryInputIssue {
                guard identity == model.tableID else { return }
                switch issue {
                case .relativeMedia:
                    // Resume the original recipient after choosing the folder.
                    // A retry revalidates the current task and its edits before saving.
                    directoryRequest = DirectoryRequest(tableID: identity, destination: destination)
                    selectsMediaDirectory = true
                case .field(let row, let column, _):
                    if row >= 2 { failedCell = CSVWorksheetJump(tableID: identity, row: row - 2, column: column) }
                    model.report(issue.error)
                }
            }
            catch { if identity == model.tableID { model.report(error) } }
        }
    }

    private var importAction: some View {
        Button(L10n.tr("导入 CSV…"), systemImage: "square.and.arrow.down") {
            // Embedded workspace imports use its single presentation owner;
            // standalone surfaces retain the original local file importer.
            if let onImport { onImport() } else { importsCSV = true }
        }
        .disabled(workspace?.selectedTaskID == nil || model.operation.isRunning)
    }

    /// Merge plus the report entry, for the recovery menu. The window toolbar
    /// shows only `mergeButton`: an extra toolbar item that appears after a merge
    /// or failed export pushes the primary Export action into the overflow chevron
    /// on a normal-width window, so the report lives in the scope line instead.
    @ViewBuilder private var mergeActions: some View {
        mergeButton
        reportButton
    }

    @ViewBuilder private var mergeButton: some View {
        if let recognition, let workspace {
            Button(L10n.tr("合并识别结果"), systemImage: "arrow.triangle.merge") {
                Task {
                    do {
                        try await workspace.flush()
                        await model.merge(
                            records: recognition.resolveRecords,
                            metadata: workspace.selectedTask?.slateMetadata ?? [],
                            settings: workspace.projectSettings.resolve)
                    } catch { model.report(error) }
                }
            }
            .help(L10n.tr("把识别结果合并进 Resolve CSV"))
            .disabled(
                model.table == nil || recognition.resolveRecords.isEmpty || model.operation.isRunning)
        }
    }

    @ViewBuilder private var reportButton: some View {
        if recognition != nil, workspace != nil,
           let diagnostics = model.lastMergeDiagnostics, (!diagnostics.warnings.isEmpty || !issues.isEmpty) {
            // Overwrite/normalization notes remain reachable even when no
            // unresolved-status badge is needed.
            Button(L10n.tr("查看合并报告")) {
                diagnosticReport = WorkflowDiagnosticReport(title: L10n.tr("完整合并报告"),
                    messages: issues.map(\.message) + diagnostics.warnings.map { L10n.message($0) })
            }
        }
    }

    private var exportAction: some View {
        Menu {
            deliveryItems
        } label: {
            Label(L10n.tr("导出 Resolve CSV…"), systemImage: "square.and.arrow.up")
        } primaryAction: {
            // The main half always writes the Resolve template, independently
            // of the recipient used by the previous delivery.
            performExport()
        }
        .accessibilityIdentifier(AccessibilityID.csvExportDelivery)
        .help(L10n.tr("导出 Resolve 原模板，或从菜单选择交付对象"))
        .disabled(model.table == nil || model.operation.isRunning || preparing || directoryRequest != nil)
    }

    private var scopeDescription: String {
        L10n.tr("{0} · 全部 {1} 行", [model.filename ?? "Resolve CSV", String(model.table?.rows.count ?? 0)])
    }

    private var tableSummary: some View {
        Text(verbatim: scopeDescription)
            .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            .lineLimit(1).truncationMode(.middle).help(scopeDescription)
    }
}

/// Resolve and Premiere use the same XMEML bytes but expose different import workflows.
private enum DeliveryDestination: CaseIterable {
    case resolveCSV, resolveMediaPool, premiereBin, finalCutEvent, avid, json

    var title: String {
        switch self {
        case .resolveCSV: L10n.tr("DaVinci Resolve · 回填已有素材（CSV）")
        case .resolveMediaPool: L10n.tr("DaVinci Resolve · 导入素材到媒体池（XML）")
        case .premiereBin: L10n.tr("Premiere Pro · 导入素材箱（XML）")
        case .finalCutEvent: L10n.tr("Final Cut Pro · 导入事件（FCPXML）")
        case .avid: L10n.tr("Avid Media Composer · 合并场记（ALE）")
        case .json: L10n.tr("通用数据 · 完整工作表（JSON）")
        }
    }

    var format: MetadataDeliveryFormat {
        switch self {
        case .resolveCSV: .csv
        case .resolveMediaPool, .premiereBin: .xmeml
        case .finalCutEvent: .fcpxml
        case .avid: .ale
        case .json: .json
        }
    }
}

private struct MetadataDocument: FileDocument {
    static var readableContentTypes: [UTType] { MetadataDeliveryFormat.allCases.map(\.contentType) }
    let data: Data
    let tableID: UUID?
    let format: MetadataDeliveryFormat
    let filename: String?
    let saveMessage: String
    let confirmationMessage: String
    let warningCount: Int

    init(payload: PreparedMetadata, tableID: UUID, destination: DeliveryDestination, filename: String, scope: String, warningCount: Int) {
        data = payload.data
        self.tableID = tableID
        format = destination.format
        self.filename = filename
        self.warningCount = warningCount
        var lines = [scope]
        switch (destination, payload.preview) {
        case let (.avid, .avid(tape, start, fps)):
            lines.append(L10n.tr("首条素材按卷名 {0} 和起始时码 {1} 匹配，播放帧率 {2} fps。", [tape, start, fps]))
        case let (.premiereBin, .premiere(scene, shotTake)):
            lines.append(L10n.tr("首条素材在 Premiere 中显示为 Scene「{0}」、Shot「{1}」。", [scene, shotTake]))
        default: break
        }
        saveMessage = lines.joined(separator: "\n")
        if warningCount > 0 {
            lines.append(L10n.tr("当前合并结果包含 {0} 项告警，导出文件会保留这些行的当前值。", [String(warningCount)]))
        }
        confirmationMessage = lines.joined(separator: "\n")
    }

    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
        format = MetadataDeliveryFormat.allCases.first { $0.contentType == configuration.contentType } ?? .csv
        filename = configuration.file.preferredFilename
        tableID = nil
        warningCount = 0
        saveMessage = ""
        confirmationMessage = ""
    }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

private extension MetadataDeliveryFormat {
    var contentType: UTType {
        switch self {
        case .csv: .commaSeparatedText
        case .json: .json
        case .xmeml: .xml
        case .ale: UTType(filenameExtension: fileExtension, conformingTo: .plainText) ?? .plainText
        case .fcpxml: UTType(filenameExtension: fileExtension, conformingTo: .xml) ?? .xml
        }
    }
}

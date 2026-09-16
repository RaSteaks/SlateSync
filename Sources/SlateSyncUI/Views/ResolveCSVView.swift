import SlateSyncDomain
import SwiftUI
import UniformTypeIdentifiers

public struct ResolveCSVView: View {
    @Environment(\.slateSyncDensity) private var density
    @Bindable private var model: ResolveCSVModel
    @State private var importsCSV = false
    @State private var exportsCSV = false
    @State private var showsDiagnostics = false
    @State private var requestsExport = false
    @State private var exportDocument = CSVDocument(data: Data())
    @State private var pendingExportData: Data?
    @State private var exportDefaultName = "Resolve.csv"
    private let recognition: RecognitionModel?
    private let workspace: WorkspaceModel?
    private let onImport: (@MainActor () -> Void)?

    private struct DiagnosticRow: Identifiable {
        let id: String
        let message: String
        let symbol: String
    }

    public init(
        model: ResolveCSVModel, recognition: RecognitionModel? = nil, workspace: WorkspaceModel? = nil,
        onImport: (@MainActor () -> Void)? = nil
    ) {
        self.model = model
        self.recognition = recognition
        self.workspace = workspace
        self.onImport = onImport
    }

    public var body: some View {
        VStack(spacing: 0) {
            // Only toolbar presentation adapts; the editor stays at one stable
            // structural position and keeps its native selection/scroll owner.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) {
                    importAction
                    Divider().frame(height: 18)
                    mergeActions
                    Spacer(minLength: 8)
                    exportAction
                    tableSummary
                }
                HStack {
                    importAction
                    Spacer(minLength: 4)
                    Menu("结果操作", systemImage: "ellipsis.circle") { mergeActions }
                        .tint(Color.secondary)
                    exportAction
                }
            }.padding(density.panelPadding)
            Divider()
            if unresolvedCount > 0 {
                diagnosticsStrip
                Divider()
            }
            if showsDiagnostics, unresolvedCount > 0, let diagnostics = model.lastMergeDiagnostics {
                diagnosticsDetails(diagnostics)
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
                .accessibilityIdentifier(AccessibilityID.csvTable)
                .disabled(model.operation.isRunning)
            } else {
                SlateEmptyState(
                    title: "未导入 Resolve CSV", symbol: "tablecells",
                    message: "导入后可直接编辑并保留原始字节格式。"
                ) { importAction }
            }
        }
        .disabled(recognition?.operation.isRunning == true)
        .safeAreaInset(edge: .bottom) {
            // Import, encode and save-panel failures retain the table and a
            // visible recovery message; cancellation never reports success.
            if case .failed(let error) = model.operation {
                SlateStatusBar(message: error.message, tone: .error) {
                    // Keep recovery with the failed table. Users can retry an
                    // export or replace the source without dismissing errors.
                    Menu("恢复操作") {
                        importAction
                        mergeActions
                        exportAction
                    }.fixedSize()
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
            isPresented: $exportsCSV,
            document: exportDocument,
            contentType: .commaSeparatedText,
            defaultFilename: exportDefaultName
        ) { result in
            switch result {
            case .success: model.exported()
            case .failure(let error): model.report(error)
            }
        }
        .confirmationDialog(
            "仍有未解决的合并告警", isPresented: $requestsExport, titleVisibility: .visible
        ) {
            Button("仍要导出 CSV") { confirmPendingExport() }
            Button("返回校对", role: .cancel) { pendingExportData = nil }
        } message: {
            Text("当前合并结果包含 \(unresolvedCount) 项告警，导出文件会保留这些行的当前值。")
        }
    }

    // MARK: Reconciliation diagnostics

    private var unresolvedCount: Int {
        guard let diagnostics = model.lastMergeDiagnostics else { return 0 }
        return diagnostics.unrecognizedMaterials.count
            + diagnostics.missingCameraFPSKeys.count
            + diagnostics.missingShootDayKeys.count
            + diagnostics.sequenceAnomalies.count
            + diagnostics.unresolvedStatuses.count
    }

    /// Merge-time reconciliation badges. They only summarize; the canonical
    /// table is never filtered or reordered (NSTableView identity contract) —
    /// details expand inline instead.
    private var diagnosticsStrip: some View {
        HStack(spacing: 8) {
            if let diagnostics = model.lastMergeDiagnostics {
                if !diagnostics.unrecognizedMaterials.isEmpty {
                    diagnosticBadge(
                        "未匹配素材 \(diagnostics.unrecognizedMaterials.count)",
                        symbol: "exclamationmark.triangle")
                }
                let missingKeys = diagnostics.missingCameraFPSKeys.count + diagnostics.missingShootDayKeys.count
                if missingKeys > 0 {
                    diagnosticBadge("关键信息缺失 \(missingKeys)", symbol: "questionmark.circle")
                }
                if !diagnostics.sequenceAnomalies.isEmpty {
                    diagnosticBadge(
                        "次序异常 \(diagnostics.sequenceAnomalies.count)",
                        symbol: "exclamationmark.arrow.triangle")
                }
                if !diagnostics.unresolvedStatuses.isEmpty {
                    diagnosticBadge(
                        "未写入记录 \(diagnostics.unresolvedStatuses.count)", symbol: "nosign")
                }
            }
            Spacer(minLength: 8)
            Button(showsDiagnostics ? "收起详情" : "详情") { showsDiagnostics.toggle() }
                .font(.caption)
        }
        .padding(.horizontal, density.panelPadding)
        .padding(.vertical, 6)
    }

    private func diagnosticBadge(_ title: String, symbol: String) -> some View {
        // Pills stay reserved for short status badges (DESIGN.md Shapes).
        Label(title, systemImage: symbol)
            .font(.caption.weight(.medium))
            .foregroundStyle(SlateSyncTheme.warning)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(SlateSyncTheme.warning.opacity(0.14), in: Capsule())
            .help(title)
    }

    /// Inline (non-scrolling) detail rows so the CSV editor keeps the only
    /// scroll region on this page. Long lists cap at eight rows.
    private func diagnosticsDetails(_ diagnostics: ResolveMergeResult) -> some View {
        // Record-level statuses are included alongside material and sequence
        // audits so rows skipped by the merger cannot disappear from review.
        let rows = diagnosticsRows(diagnostics)
        let visible = rows.prefix(8)
        return VStack(alignment: .leading, spacing: 6) {
            ForEach(visible) { row in
                WarnRow(severity: .warning) {
                    Label(row.message, systemImage: row.symbol).font(.callout).lineLimit(2)
                }
            }
            if rows.count > visible.count {
                Text("其余 \(rows.count - visible.count) 项见日志。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Text("在识别结果中修正后重新合并；手动编辑会保留。")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(density.panelPadding)
    }

    private func diagnosticsRows(_ diagnostics: ResolveMergeResult) -> [DiagnosticRow] {
        let statusRows = diagnostics.unresolvedStatuses.map { status in
            let subject = status.fileName ?? "第 \(status.recordIndex + 1) 条"
            let message: String
            switch status.status {
            case "missing-key":
                message = "\(subject) 缺少素材标识，未写入 CSV"
            case "incomplete":
                let fields = status.missingFields?.joined(separator: "、") ?? "场记字段"
                message = "\(subject) 缺少\(fields)，未写入场记字段"
            case "conflict":
                message = "\(subject) 的识别结果冲突，场记字段未写入"
            case "unmatched":
                message = "\(subject) 未匹配到 Resolve CSV 行，未写入"
            case "duplicate":
                message = "\(subject) 是重复识别记录，未写入"
            default:
                message = "\(subject) 的识别结果未写入 CSV"
            }
            return DiagnosticRow(
                id: "status-\(status.recordIndex)-\(status.status)",
                message: message,
                symbol: "nosign")
        }
        let materialRows = diagnostics.unrecognizedMaterials.enumerated().map { index, material in
            DiagnosticRow(
                id: "material-\(index)-\(material)",
                message: "素材 \(material) 未在识别结果中匹配",
                symbol: "square.slash")
        }
        let fpsRows = diagnostics.missingCameraFPSKeys.enumerated().map { index, material in
            DiagnosticRow(
                id: "fps-\(index)-\(material)",
                message: "素材 \(material) 缺少相机帧率信息",
                symbol: "questionmark.circle")
        }
        let dayRows = diagnostics.missingShootDayKeys.enumerated().map { index, material in
            DiagnosticRow(
                id: "day-\(index)-\(material)",
                message: "素材 \(material) 缺少拍摄日信息",
                symbol: "questionmark.circle")
        }
        let sequenceRows = diagnostics.sequenceAnomalies.enumerated().map { index, anomaly in
            DiagnosticRow(
                id: "sequence-\(index)-\(anomaly.stableKey)",
                message: anomaly.message,
                symbol: "exclamationmark.arrow.triangle")
        }
        return statusRows + materialRows + fpsRows + dayRows + sequenceRows
    }

    private func performExport() {
        Task {
            do {
                pendingExportData = nil
                let data: Data
                if let recognition, let workspace {
                    try await workspace.flush()
                    // Canonical merged export: re-merge from the raw
                    // table with the latest records, apply manual
                    // edits last, canonicalize the whole table.
                    // Old naming: <baseName(metadataFile)>_场记已回填.csv.
                    exportDefaultName = ResolveCSVModel.suggestedFilename(
                        model.filename, fallback: "Resolve", suffix: "场记已回填")
                    data = try await model.exportData(
                        records: recognition.resolveRecords,
                        metadata: workspace.selectedTask?.slateMetadata ?? [],
                        settings: workspace.projectSettings.resolve)
                } else {
                    exportDefaultName = model.filename ?? "Resolve.csv"
                    data = try await model.encodedData()
                }
                // The guard runs after the same merge that produced these
                // bytes. Cache that artifact for confirmation so accepting the
                // dialog cannot re-merge against a changed diagnostic state.
                if unresolvedCount > 0 {
                    pendingExportData = data
                    requestsExport = true
                } else {
                    beginFileExport(data)
                }
            } catch { model.report(error) }
        }
    }

    private func confirmPendingExport() {
        guard let data = pendingExportData else { return }
        beginFileExport(data)
    }

    private func beginFileExport(_ data: Data) {
        pendingExportData = nil
        exportDocument = CSVDocument(data: data)
        exportsCSV = true
    }
    private var importAction: some View {
        Button("导入 CSV…", systemImage: "square.and.arrow.down") {
            // Embedded workspace imports use its single presentation owner;
            // standalone surfaces retain the original local file importer.
            if let onImport { onImport() } else { importsCSV = true }
        }
        .tint(Color.secondary)
        .disabled(workspace?.selectedTaskID == nil || model.operation.isRunning)
    }

    @ViewBuilder private var mergeActions: some View {
        if let recognition, let workspace {
            Button("合并识别结果") {
                Task {
                    do {
                        try await workspace.flush()
                        await model.merge(
                            records: recognition.resolveRecords,
                            metadata: workspace.selectedTask?.slateMetadata ?? [],
                            settings: workspace.projectSettings.resolve)
                    } catch { model.report(error) }
                }
            }.disabled(
                model.table == nil || recognition.resolveRecords.isEmpty || model.operation.isRunning)
            Button("独立导出…") {
                Task {
                    do {
                        try await workspace.flush()
                        // Old naming: <baseName(sheetTitle || 场记单)>_场记识别.csv.
                        exportDefaultName = ResolveCSVModel.suggestedFilename(
                            recognition.result?.result.sheetTitle, fallback: "场记单", suffix: "场记识别")
                        exportDocument = CSVDocument(
                            data: try await model.standaloneData(
                                records: recognition.resolveRecords, settings: workspace.projectSettings.resolve))
                        exportsCSV = true
                    } catch { model.report(error) }
                }
            }.disabled(recognition.resolveRecords.isEmpty || model.operation.isRunning)
        }
    }

    private var exportAction: some View {
        Button("导出 CSV…", systemImage: "square.and.arrow.up") {
            // The canonical preflight decides whether unresolved warnings need
            // confirmation; stale diagnostics are never used to bypass it.
            performExport()
        }
        .tint(Color.secondary)
        .disabled(model.table == nil || model.operation.isRunning)
    }

    @ViewBuilder private var tableSummary: some View {
        if let table = model.table {
            Text("\(table.rows.count) 行 · \(table.headers.count) 列")
                .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                .fixedSize()
        }
    }

}

private struct CSVDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.commaSeparatedText, .plainText] }
    var data: Data
    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
    }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

import SlateSyncDomain
import SwiftUI
import UniformTypeIdentifiers

public struct ResolveCSVView: View {
    @Environment(\.slateSyncDensity) private var density
    @Bindable private var model: ResolveCSVModel
    @State private var importsCSV = false
    @State private var exportsCSV = false
    @State private var exportDocument = CSVDocument(data: Data())
    @State private var exportDefaultName = "Resolve.csv"
    private let recognition: RecognitionModel?
    private let workspace: WorkspaceModel?
    private let onImport: (@MainActor () -> Void)?

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
                    exportAction
                }
            }.padding(density.panelPadding)
            Divider()
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
    }
    private var importAction: some View {
        Button("导入 CSV…", systemImage: "square.and.arrow.down") {
            // Embedded workspace imports use its single presentation owner;
            // standalone surfaces retain the original local file importer.
            if let onImport { onImport() } else { importsCSV = true }
        }
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
            Task {
                do {
                    if let recognition, let workspace {
                        try await workspace.flush()
                        // Canonical merged export: re-merge from the raw
                        // table with the latest records, apply manual
                        // edits last, canonicalize the whole table.
                        // Old naming: <baseName(metadataFile)>_场记已回填.csv.
                        exportDefaultName = ResolveCSVModel.suggestedFilename(
                            model.filename, fallback: "Resolve", suffix: "场记已回填")
                        exportDocument = CSVDocument(
                            data: try await model.exportData(
                                records: recognition.resolveRecords,
                                metadata: workspace.selectedTask?.slateMetadata ?? [],
                                settings: workspace.projectSettings.resolve))
                    } else {
                        exportDefaultName = model.filename ?? "Resolve.csv"
                        exportDocument = CSVDocument(data: try await model.encodedData())
                    }
                    exportsCSV = true
                } catch { model.report(error) }
            }
        }.disabled(model.table == nil)
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

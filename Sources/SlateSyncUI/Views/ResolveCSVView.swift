import SlateSyncDomain
import SwiftUI
import UniformTypeIdentifiers

public struct ResolveCSVView: View {
    @Bindable private var model: ResolveCSVModel
    @State private var importsCSV = false
    @State private var exportsCSV = false
    @State private var exportDocument = CSVDocument(data: Data())
    @State private var exportDefaultName = "Resolve.csv"
    private let recognition: RecognitionModel?
    private let workspace: WorkspaceModel?

    public init(model: ResolveCSVModel, recognition: RecognitionModel? = nil, workspace: WorkspaceModel? = nil) {
        self.model = model
        self.recognition = recognition
        self.workspace = workspace
    }

    public var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button("导入 CSV…", systemImage: "square.and.arrow.down") { importsCSV = true }
                    .disabled(workspace?.selectedTaskID == nil || model.operation.isRunning)
                if let recognition, let workspace {
                    Button("合并识别结果") {
                        Task {
                            do {
                                try await workspace.flush()
                                await model.merge(records: recognition.resolveRecords,
                                    metadata: workspace.selectedTask?.slateMetadata ?? [], settings: workspace.projectSettings.resolve)
                            } catch { model.report(error) }
                        }
                    }.disabled(model.table == nil || recognition.resolveRecords.isEmpty || model.operation.isRunning)
                    Button("独立导出…") {
                        Task {
                            do {
                                try await workspace.flush()
                                // Old naming: <baseName(sheetTitle || 场记单)>_场记识别.csv.
                                exportDefaultName = ResolveCSVModel.suggestedFilename(
                                    recognition.result?.result.sheetTitle, fallback: "场记单", suffix: "场记识别")
                                exportDocument = CSVDocument(data: try await model.standaloneData(records: recognition.resolveRecords, settings: workspace.projectSettings.resolve))
                                exportsCSV = true
                            } catch { model.report(error) }
                        }
                    }.disabled(recognition.resolveRecords.isEmpty || model.operation.isRunning)
                }
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
                                exportDocument = CSVDocument(data: try await model.exportData(
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
                Spacer()
                if let table = model.table {
                    Text("\(table.rows.count) 行 · \(table.headers.count) 列")
                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
            }.padding(10)
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
                ContentUnavailableView("未导入 Resolve CSV", systemImage: "tablecells", description: Text("导入后可直接编辑并保留原始字节格式。"))
            }
        }
        .disabled(recognition?.operation.isRunning == true)
        .safeAreaInset(edge: .bottom) {
            // Import, encode and save-panel failures retain the table and a
            // visible recovery message; cancellation never reports success.
            if case .failed(let error) = model.operation {
                Label(error.message, systemImage: "exclamationmark.triangle").padding(10)
            } else if case .succeeded(let message) = model.operation {
                Text(message).font(.caption).padding(8)
            }
        }
        .fileImporter(isPresented: $importsCSV, allowedContentTypes: [.commaSeparatedText, .plainText]) { result in
            guard case .success(let url) = result else {
                if case .failure(let error) = result { model.report(error) }
                return
            }
            let accessed = url.startAccessingSecurityScopedResource()
            defer { if accessed { url.stopAccessingSecurityScopedResource() } }
            do {
                let data = try Data(contentsOf: url)
                Task { await model.importData(data, filename: url.lastPathComponent) }
            } catch { model.report(error) }
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

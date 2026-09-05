import SlateSyncDomain
import SwiftUI
import UniformTypeIdentifiers

public struct WorkspaceView: View {
    @Bindable private var workspace: WorkspaceModel
    @Bindable private var recognition: RecognitionModel
    @Bindable private var csv: ResolveCSVModel
    @Bindable private var metadata: MetadataScanModel
    @Bindable private var media: MediaInputModel
    @State private var importsMedia = false
    @State private var importsMetadataDirectory = false
    @State private var importsSlateCSV = false
    @State private var section = WorkspaceSection.input
    @State private var providerID = ""
    @State private var modelID = ""
    @State private var scenarioID = ""
    @State private var accuracy = ProjectSettings.AccuracyMode.high

    private enum WorkspaceSection: String, CaseIterable, Identifiable {
        case input = "输入"
        case result = "识别结果"
        case csv = "Resolve CSV"
        var id: String { rawValue }
    }

    public init(
        workspace: WorkspaceModel,
        recognition: RecognitionModel,
        csv: ResolveCSVModel,
        metadata: MetadataScanModel,
        media: MediaInputModel
    ) {
        self.workspace = workspace
        self.recognition = recognition
        self.csv = csv
        self.metadata = metadata
        self.media = media
    }

    public var body: some View {
        HSplitView {
            TaskRailView(model: workspace).frame(minWidth: 190, idealWidth: 230, maxWidth: 300)
            VStack(spacing: 0) {
                Picker("工作区", selection: sectionBinding) {
                    ForEach(WorkspaceSection.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .padding()
                Divider()
                detail
            }
        }
        .navigationTitle("工作台")
        .accessibilityIdentifier(AccessibilityID.workspaceHeading)
        .safeAreaInset(edge: .bottom) { autosaveBanner }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button("保存", systemImage: "square.and.arrow.down") {
                    Task { try? await workspace.flush() }
                }
                .keyboardShortcut("s", modifiers: .command)
                Button("开始识别", systemImage: "viewfinder") { startRecognition() }
                    .disabled(!canRecognize || recognition.operation.isRunning)
                    .accessibilityIdentifier(AccessibilityID.recognize)
                if recognition.operation.isRunning {
                    Button("取消识别", systemImage: "xmark.circle") { recognition.cancel() }
                        .accessibilityIdentifier(AccessibilityID.recognitionCancel)
                }
            }
        }
        .fileImporter(isPresented: $importsMedia, allowedContentTypes: [.pdf, .image]) { result in
            switch result {
            case .success(let url): chooseMedia(url)
            case .failure(let error): media.report(error)
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            guard media.canAcceptInput, let url = urls.first, urls.count == 1 else { return false }
            chooseMedia(url)
            return true
        }
        .fileImporter(isPresented: $importsMetadataDirectory, allowedContentTypes: [.folder]) { result in
            switch result {
            case .success(let url): scanMetadata(url)
            case .failure(let error): metadata.report(error)
            }
        }
        .fileImporter(isPresented: $importsSlateCSV, allowedContentTypes: [.commaSeparatedText, .plainText]) { result in
            do {
                let url = try result.get()
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                let data = try Data(contentsOf: url)
                guard let projectID = workspace.projectID else { return }
                recognition.importSlateCSV(data, filename: url.lastPathComponent, projectID: projectID) { try await workspace.flush() }
            } catch { media.report(error) }
        }
        .task {
            await recognition.loadOptions()
            adoptTaskRecognitionOptions()
        }
        .onChange(of: workspace.selectedTaskID) {
            adoptTaskRecognitionOptions()
        }
        .onChange(of: providerID) {
            let available = recognition.availableModels(providerID: providerID)
            if !available.contains(where: { $0.id == modelID }) {
                modelID = available.first?.id ?? ""
            }
        }
    }

    @ViewBuilder private var detail: some View {
        switch section {
        case .input: inputView
        case .result: RecognitionResultView(model: recognition, workspace: workspace)
        case .csv: ResolveCSVView(model: csv, recognition: recognition, workspace: workspace)
        }
    }

    private var inputView: some View {
        Form {
            Section("场记单") {
                LabeledContent("输入文件", value: media.document?.filename ?? "未选择")
                Button("选择 PDF 或图像…") { importsMedia = true }
                if media.operation.isRunning {
                    ProgressView("正在准备场记单…")
                    Button("取消准备", role: .cancel) { media.cancel() }
                }
                if case .failed(let error) = media.operation { Text(error.message).foregroundStyle(.red) }
                if let document = media.document {
                    MediaPreviewView(document: document, pageIndex: $media.pageIndex)
                }
            }
            Section("本地场记 CSV") {
                Button("载入场记 CSV…") { importsSlateCSV = true }
                    .disabled(workspace.selectedTaskID == nil)
                if !recognition.slateCSVRecords.isEmpty {
                    LabeledContent(recognition.slateCSVFilename ?? "场记 CSV", value: "\(recognition.slateCSVRecords.count) 条")
                    Button("从场记 CSV 生成结果") {
                        recognition.generateLocalRecords(flush: { try await workspace.flush() }, commit: workspace.stageLocalRecords)
                    }
                }
            }
            Section("识别") {
                Picker("Provider", selection: providerSelection) {
                    Text("请选择").tag("")
                    ForEach(recognition.providers, id: \.id) { Text($0.label).tag($0.id) }
                }
                Picker("模型", selection: modelSelection) {
                    Text("请选择").tag("")
                    ForEach(recognition.availableModels(providerID: providerID), id: \.id) {
                        Text($0.label).tag($0.id)
                    }
                }
                if case .failed(let error) = recognition.optionsOperation {
                    LabeledContent("选项读取失败") {
                        HStack { Text(error.message); Button("重试") { Task { await recognition.loadOptions() } } }
                    }
                }
                Picker("精度", selection: accuracySelection) {
                    Text("标准").tag(ProjectSettings.AccuracyMode.standard)
                    Text("高精度").tag(ProjectSettings.AccuracyMode.high)
                }
                Picker("场记版式（Scenario）", selection: scenarioSelection) {
                    Text("自动匹配").tag("")
                    ForEach(workspace.scenarios, id: \.id) { Text($0.label).tag($0.id) }
                }
                TextField("自定义提示词", text: $workspace.customPrompt, axis: .vertical)
                    .lineLimit(3...8)
                if let progress = recognition.progress {
                    ProgressView(value: Double(progress.completed), total: Double(max(1, progress.total))) {
                        Text(progress.message)
                    }
                }
            }
            Section("场记元数据") {
                Button("选择目录并扫描…") { importsMetadataDirectory = true }
                    .disabled(workspace.selectedTaskID == nil || csv.table == nil)
                if case .failed(let error) = metadata.operation { Text(error.message).foregroundStyle(.red) }
                if metadata.operation.isRunning {
                    Button("取消扫描", role: .cancel) { metadata.cancel() }
                }
                if let result = metadata.result {
                    LabeledContent("已读取", value: "\(result.metadata.count) 条")
                    LabeledContent("警告", value: "\(result.warnings.count) 条")
                    LabeledContent("缺少素材", value: "\(result.missingKeys.count) 条")
                    if !result.missingKeys.isEmpty {
                        Text(result.missingKeys.prefix(8).joined(separator: "、"))
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .disabled(recognition.operation.isRunning)
    }

    private var sectionBinding: Binding<WorkspaceSection> {
        Binding(get: { section }, set: { destination in
            Task {
                // Changing editor tabs uses the same pre-unmount barrier as
                // route navigation; an IME composition keeps its tab mounted.
                do { try await workspace.flush(); section = destination }
                catch { /* Workspace exposes the retained draft error banner. */ }
            }
        })
    }

    private var canRecognize: Bool {
        workspace.projectID != nil && workspace.selectedTaskID != nil && media.document != nil && !media.operation.isRunning &&
            recognition.canRecognize(providerID: providerID, modelID: modelID)
    }

    @ViewBuilder private var autosaveBanner: some View {
        if let error = workspace.autosaveError {
            HStack {
                Label("自动保存失败：\(error.message)", systemImage: "exclamationmark.triangle")
                Spacer()
                Button("重试") { Task { await workspace.retryAutosave() } }
            }
            .padding(10).background(.bar)
        }
    }

    private func startRecognition() {
        guard let projectID = workspace.projectID, let document = media.document,
              let firstImage = document.pages.first?.views.first?.image else { return }
        var settings = workspace.projectSettings
        workspace.stageRecognitionOptions(
            providerID: providerID,
            modelID: modelID,
            accuracyMode: accuracy,
            scenarioID: scenarioID
        )
        settings.providerId = providerID.isEmpty ? nil : providerID
        settings.modelId = modelID.isEmpty ? nil : modelID
        settings.accuracyMode = accuracy
        settings.customPrompt = workspace.customPrompt
        settings.scenarioId = scenarioID.isEmpty ? nil : scenarioID
        let request = NativeRecognitionRequest(
            projectID: projectID,
            input: .bytes(firstImage.jpeg, filename: document.filename),
            filename: document.filename,
            taskID: workspace.selectedTaskID,
            providerID: providerID,
            modelID: modelID,
            settings: settings,
            slateCSVRecords: recognition.slateCSVRecords,
            preparedDocument: document
        )
        recognition.recognize(request) {
            // Recognition patches and autosave cannot be concurrent writers.
            // Join already-started local inputs, then flush their final state;
            // all task editor surfaces remain disabled during recognition.
            await csv.drain()
            await metadata.drain()
            await media.drain()
            try await workspace.flush()
        }
    }

    private func chooseMedia(_ url: URL) {
        // Button and drop share task creation, validation and scope ownership.
        guard media.canAcceptInput else { return }
        Task {
            guard media.canAcceptInput else { return }
            if workspace.selectedTaskID == nil { await workspace.createTask() }
            guard workspace.selectedTaskID != nil else { return }
            media.select(url)
        }
    }

    private func scanMetadata(_ directory: URL) {
        // Matching is intentionally derived from the canonical Resolve table;
        // scanning an arbitrary directory without expected keys would either
        // miss the user’s material set or violate the bounded scanner contract.
        Task {
            do {
                let keys = try await csv.materialKeys()
                metadata.scan(directory, expectedKeys: keys)
            } catch {
                metadata.report(error)
            }
        }
    }

    private var providerSelection: Binding<String> {
        Binding(get: { providerID }, set: { value in
            providerID = value
            let available = recognition.availableModels(providerID: value)
            if !available.contains(where: { $0.id == modelID }) {
                modelID = available.first?.id ?? ""
            }
            persistRecognitionOptions()
        })
    }

    private var modelSelection: Binding<String> {
        Binding(get: { modelID }, set: { value in
            modelID = value
            persistRecognitionOptions()
        })
    }

    private var accuracySelection: Binding<ProjectSettings.AccuracyMode> {
        Binding(get: { accuracy }, set: { value in
            accuracy = value
            persistRecognitionOptions()
        })
    }

    private var scenarioSelection: Binding<String> {
        Binding(get: { scenarioID }, set: { value in
            scenarioID = value
            persistRecognitionOptions()
        })
    }

    private func persistRecognitionOptions() {
        workspace.stageRecognitionOptions(
            providerID: providerID,
            modelID: modelID,
            accuracyMode: accuracy,
            scenarioID: scenarioID
        )
    }

    private func adoptTaskRecognitionOptions() {
        scenarioID = workspace.selectedTask?.scenarioId ?? workspace.projectSettings.scenarioId ?? ""
        accuracy = workspace.selectedTask?.accuracyMode ?? workspace.projectSettings.accuracyMode
        let taskProvider = workspace.selectedTask?.provider ?? workspace.projectSettings.providerId ?? providerID
        providerID = recognition.providers.contains(where: { $0.id == taskProvider })
            ? taskProvider
            : (recognition.providers.first?.id ?? "")
        let taskModel = workspace.selectedTask?.model ?? workspace.projectSettings.modelId ?? modelID
        let available = recognition.availableModels(providerID: providerID)
        modelID = available.contains(where: { $0.id == taskModel }) ? taskModel : (available.first?.id ?? "")
    }
}

private struct RecognitionResultView: View {
    @Bindable var model: RecognitionModel
    let workspace: WorkspaceModel

    var body: some View {
        if !model.editableRecords.isEmpty {
            EditableCSVTableRepresentable(tableID: model.resultTableID, table: model.resultTable, revision: 0,
                accessibilityLabel: "可编辑识别结果",
                onCommit: { model.receiveResult($0, commit: workspace.stageEditedRecords) },
                editorRegistration: { model.flushEditor = $0 })
                .disabled(model.operation.isRunning)

        } else if case .failed(let error) = model.operation {
            ContentUnavailableView("识别失败", systemImage: "exclamationmark.triangle", description: Text(error.message))
        } else {
            ContentUnavailableView("暂无识别结果", systemImage: "text.viewfinder", description: Text("请先在输入页选择场记单并开始识别。"))
        }
    }

}

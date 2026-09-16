import SlateSyncDomain
import SwiftUI
import UniformTypeIdentifiers

/// A route hint for Help shortcuts and status-bar actions. The workspace
/// keeps ownership of its segmented selection; the hint only chooses the
/// initial/target section and never changes task data.
public enum WorkspaceEntryPoint: String, Hashable, Sendable {
    case input
    case result
    case resolveCSV
}

/// The stable pages shared by the workspace picker and its window-owned
/// unread-content ledger. Keeping this identity outside the view lets a dot
/// survive route changes without mixing one task's results into another's.
public enum WorkspaceSection: String, CaseIterable, Identifiable, Hashable, Sendable {
    case input = "输入"
    case result = "识别结果"
    case csv = "Resolve CSV"

    public var id: String { rawValue }
}

public struct WorkspaceView: View {
    @Bindable private var workspace: WorkspaceModel
    @Bindable private var recognition: RecognitionModel
    @Bindable private var csv: ResolveCSVModel
    @Bindable private var metadata: MetadataScanModel
    @Bindable private var media: MediaInputModel
    @Environment(\.slateSyncDensity) private var density
    @State private var showsTasks = true
    @State private var showsConfiguration: Bool?
    @State private var availableWidth: CGFloat = 0
    @State private var editorBoundary = WorkspaceEditorBoundary()
    @State private var showsOriginal = false
    @State private var showsAdvanced = false
    @State private var layoutError: String?
    @State private var changingLayout = false
    // A route hint can arrive while another editor transition owns the
    // barrier; retain the latest target until that transition succeeds.
    @State private var pendingEntryPoint: WorkspaceEntryPoint?
    @State private var importsFile = false
    @State private var importKind = ImportKind.media
    // The parent owns this ledger so completion events are not lost when the
    // workspace route is replaced by Projects, Logs, or Help.
    @Binding private var unseenSections: Set<WorkspaceSection>

    private enum ImportKind {
        case media, metadata, slateCSV, resolveCSV
        var types: [UTType] {
            switch self {
            case .media: [.pdf, .image]
            case .metadata: [.folder]
            case .slateCSV, .resolveCSV: [.commaSeparatedText, .plainText]
            }
        }
    }
    @State private var section: WorkspaceSection
    @State private var providerID = ""
    @State private var modelID = ""
    @State private var scenarioID = ""
    @State private var accuracy = ProjectSettings.AccuracyMode.high
    private let settingsRevision: Int
    private let entryPoint: WorkspaceEntryPoint
    private let onSectionChanged: (WorkspaceSection) -> Void
    private let onEntryPointConsumed: () -> Void

    public init(
        workspace: WorkspaceModel,
        recognition: RecognitionModel,
        csv: ResolveCSVModel,
        metadata: MetadataScanModel,
        media: MediaInputModel,
        settingsRevision: Int = 0,
        entryPoint: WorkspaceEntryPoint = .input,
        unseenSections: Binding<Set<WorkspaceSection>> = .constant([]),
        onSectionChanged: @escaping (WorkspaceSection) -> Void = { _ in },
        onEntryPointConsumed: @escaping () -> Void = {}
    ) {
        self.workspace = workspace
        self.recognition = recognition
        self.csv = csv
        self.metadata = metadata
        self.media = media
        self.settingsRevision = settingsRevision
        self.entryPoint = entryPoint
        self._unseenSections = unseenSections
        self.onSectionChanged = onSectionChanged
        self.onEntryPointConsumed = onEntryPointConsumed
        _section = State(initialValue: {
            switch entryPoint {
            case .input: .input
            case .result: .result
            case .resolveCSV: .csv
            }
        }())
    }

    public var body: some View {
        HStack(spacing: 0) {
            // Width/visibility change without removing the list or editor tree.
            TaskRailView(model: workspace)
                .frame(width: showsTasks ? 210 : 0)
                .clipped().opacity(showsTasks ? 1 : 0)
                .allowsHitTesting(showsTasks).accessibilityHidden(!showsTasks)
            if showsTasks { Divider() }
            VStack(spacing: 0) {
                workspaceHeader
                Divider()
                detail
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(WorkspaceEditorProbe(boundary: editorBoundary).frame(width: 0, height: 0))
        .navigationTitle("工作台")
        .safeAreaInset(edge: .bottom) {
            autosaveBanner
            if let layoutError {
                SlateStatusBar(message: layoutError, tone: .warning) {
                    if entryPoint != .input {
                        Button("重试") { routeToEntryPoint(entryPoint) }
                    }
                    Button("关闭") { self.layoutError = nil }
                }
            }
        }
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button(showsTasks ? "隐藏任务列表" : "显示任务列表", systemImage: "sidebar.left") {
                    changeLayout { showsTasks.toggle() }
                }
                .tint(Color.secondary)
                .help("显示或隐藏当前项目的任务")
                .accessibilityIdentifier("workspace.tasks.toggle")
            }
            ToolbarItemGroup(placement: .primaryAction) {
                Button("保存", systemImage: "square.and.arrow.down") {
                    Task { try? await workspace.flush() }
                }
                .tint(Color.secondary)
                // The File menu owns the single ⌘S registration; this toolbar
                // button invokes the same workspace owner without competing.
                Button("开始识别", systemImage: "viewfinder") { startRecognition() }
                    .slatePrimaryActionStyle()
                    .labelStyle(.titleAndIcon)
                    .help(recognitionUnavailableReason ?? "识别当前场记单")
                    .disabled(!canRecognize || recognition.operation.isRunning)
                    .accessibilityIdentifier(AccessibilityID.recognize)
                if recognition.operation.isRunning {
                    Button("取消识别", systemImage: "xmark.circle") { recognition.cancel() }
                        .tint(Color.secondary)
                        .accessibilityIdentifier(AccessibilityID.recognitionCancel)
                }
            }
        }
        // A single importer owns the workspace presentation. Multiple
        // fileImporter modifiers on the same native host can mask each other.
        .fileImporter(isPresented: $importsFile, allowedContentTypes: importKind.types) { result in
            switch importKind {
            case .media:
                switch result {
                case .success(let url): chooseMedia(url)
                case .failure(let error): media.report(error)
                }
            case .metadata:
                switch result {
                case .success(let url): scanMetadata(url)
                case .failure(let error): metadata.report(error)
                }
            case .resolveCSV:
                Task {
                    do {
                        let url = try result.get()
                        let data = try await SecurityScopedFileReader.read(url)
                        await csv.importData(data, filename: url.lastPathComponent)
                    } catch { csv.report(error) }
                }
            case .slateCSV:
                Task {
                    do {
                        let url = try result.get()
                        let data = try await SecurityScopedFileReader.read(url)
                        guard let projectID = workspace.projectID else { return }
                        recognition.importSlateCSV(data, filename: url.lastPathComponent, projectID: projectID) {
                            try await workspace.flush()
                        }
                    } catch { recognition.report(error) }
                }
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            guard media.canAcceptInput, let url = urls.first, urls.count == 1 else { return false }
            chooseMedia(url)
            return true
        }
        .task {
            await recognition.loadOptions()
            adoptTaskRecognitionOptions()
        }
        .onChange(of: workspace.selectedTaskID) {
            adoptTaskRecognitionOptions()
        }
        .onAppear {
            // Consume the entry hint once the workspace is mounted so a later
            // sidebar visit does not unexpectedly reopen a specific tab.
            let initialSection: WorkspaceSection = switch entryPoint {
            case .input: .input
            case .result: .result
            case .resolveCSV: .csv
            }
            visit(initialSection)
            if entryPoint != .input {
                onEntryPointConsumed()
            }
        }
        .onChange(of: entryPoint) { _, destination in
            // The status-bar action can retarget the section while this view
            // is already mounted. Route it through the guarded transition so
            // a live field editor keeps its draft.
            guard destination != .input else {
                pendingEntryPoint = nil
                return
            }
            routeToEntryPoint(destination)
        }
        .onChange(of: section) { _, newValue in
            unseenSections.remove(newValue)
            onSectionChanged(newValue)
        }
        .onChange(of: settingsRevision) {
            // Settings is a separate scene and does not remount this view.
            // Reload its workflow projection on each shared publication while
            // preserving any still-unavailable persisted task selection.
            Task {
                await recognition.loadOptions()
                adoptTaskRecognitionOptions()
            }
        }
    }

    private func presentImport(_ kind: ImportKind) {
        importKind = kind
        importsFile = true
    }

    private var workspaceHeader: some View {
        VStack(alignment: .leading, spacing: density.sectionSpacing) {
            // A stronger task heading anchors all three work pages without
            // replacing their native segmented navigation or editor identity.
            SlatePageHeading(
                title: workspace.selectedTask?.filename ?? "当前任务",
                subtitle: workspace.selectedTaskID == nil ? "新建任务或导入场记单以开始" : "导入场记 · 校对结果 · 整理 Resolve CSV",
                symbol: "doc.viewfinder"
            )
            // A container identifier propagates to every HStack child on
            // macOS; scope the heading identifier to the actual heading.
            .accessibilityIdentifier(AccessibilityID.workspaceHeading)
            HStack(spacing: 12) {
                Picker("工作区", selection: sectionBinding) {
                    ForEach(WorkspaceSection.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden()
                .frame(maxWidth: 360)
                // "New content" dots ride over the native segmented control
                // without replacing it: selection, keyboard and VoiceOver
                // behavior stay platform-owned; dots never steal focus and
                // clear on the next visit to their section.
                .overlay(alignment: .top) {
                    GeometryReader { proxy in
                        let segmentWidth = proxy.size.width / CGFloat(WorkspaceSection.allCases.count)
                        ForEach(Array(WorkspaceSection.allCases.enumerated()), id: \.element) { index, tab in
                            if unseenSections.contains(tab) {
                                Circle()
                                    .fill(SlateSyncTheme.accent)
                                    .frame(width: 6, height: 6)
                                    .offset(x: segmentWidth * (CGFloat(index) + 0.82), y: 3)
                            }
                        }
                    }
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
                }
                // Keep the selected section in the value and announce unread
                // sections as a hint; replacing the value with only the dot
                // message hides the Picker's current selection from VoiceOver.
                .accessibilityValue(section.rawValue)
                .accessibilityHint(pendingSectionsAccessibilityHint)
                Spacer(minLength: 0)
                if section == .input {
                    Button("识别配置", systemImage: "slider.horizontal.3") {
                        changeLayout { showsConfiguration = !(showsConfiguration ?? (availableWidth >= 900)) }
                    }
                    .tint(Color.secondary)
                    .accessibilityIdentifier("workspace.configuration.toggle")
                } else if section == .result {
                    Toggle("原稿对照", isOn: originalBinding)
                        .toggleStyle(.button)
                        .disabled(media.document == nil)
                        .accessibilityIdentifier("workspace.original.toggle")
                }
            }
        }
        .padding(density.panelPadding)
        // The heading and section controls form one shared floating surface;
        // the workbench canvas below remains an opaque evidence surface.
        .slateGlassSurface(.panel, shape: .rectangle)
    }

    @ViewBuilder private var detail: some View {
        switch section {
        case .input: inputView
        case .result: resultView
        case .csv:
            VStack(spacing: 0) {
                ResolveCSVView(
                    model: csv, recognition: recognition, workspace: workspace,
                    onImport: { presentImport(.resolveCSV) })
                Divider()
                metadataPanel
            }
        }
    }

    private var inputView: some View {
        GeometryReader { geometry in
            let wide = geometry.size.width >= 900
            let visible = showsConfiguration ?? wide
            ZStack(alignment: .trailing) {
                VStack(spacing: 0) {
                    HStack {
                        SlatePanelHeading(
                            title: "场记单", subtitle: media.document?.filename ?? "支持 PDF 和图像，也可拖入文件")
                        Button("选择 PDF 或图像…") { presentImport(.media) }
                            .disabled(!media.canAcceptInput || workspace.projectID == nil)
                    }.padding(density.panelPadding)
                    if media.operation.isRunning {
                        SlateStatusBar(message: "正在准备场记单…", busy: true) {
                            Button("取消准备", role: .cancel) { media.cancel() }
                        }
                    }
                    if case .failed(let error) = media.operation {
                        SlateStatusBar(message: error.message, tone: .error) {
                            Button("重新选择…") { presentImport(.media) }
                        }
                    }
                    Group {
                        if let document = media.document {
                            MediaPreviewView(document: document, pageIndex: $media.pageIndex)
                        } else {
                            SlateEmptyState(
                                title: "导入场记单", symbol: "doc.viewfinder",
                                message: "选择或拖入 PDF、图像，然后配置识别。"
                            ) {
                                Button("选择 PDF 或图像…") { presentImport(.media) }
                                    .disabled(!media.canAcceptInput || workspace.projectID == nil)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(SlateSyncTheme.canvas)
                    localCSVPanel
                    if let reason = recognitionUnavailableReason {
                        SlateStatusBar(reason)
                    }
                }
                .padding(.trailing, wide && visible ? 300 : 0)
                // The same form stays mounted as the window crosses 900 pt;
                // only its placement changes, preserving native IME drafts.
                configurationPanel
                    .frame(width: 300)
                    .frame(maxHeight: .infinity)
                    // This panel contains live controls, so the shared surface
                    // opts into interaction while keeping the editor mounted.
                    .slateGlassSurface(.panel, shape: .rectangle, interactive: true, border: .none)
                    // Overlay layout needs an explicit vertical rule; retain full
                    // separator opacity between the controls and evidence canvas.
                    .overlay(alignment: .leading) {
                        Rectangle().fill(SlateSyncTheme.separator).frame(width: 0.5)
                            .allowsHitTesting(false)
                    }
                    .opacity(visible ? 1 : 0)
                    .allowsHitTesting(visible)
                    .accessibilityHidden(!visible)
                // The leader dial is the single "recognition in progress"
                // trace and reports the real page stream from the workflow.
                if recognition.operation.isRunning {
                    recognitionProgressCard
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                        .padding(density.panelPadding)
                }
            }
        }
        .onGeometryChange(for: CGFloat.self) {
            $0.size.width
        } action: {
            availableWidth = $0
        }
        .disabled(recognition.operation.isRunning)
    }

    /// Academy-leader card for the running recognition. The dial advances
    /// only with real page completions from the workflow stream; a total of
    /// zero (or unknown) falls back to the named phase instead of a fake
    /// fraction. The card sits bottom-leading so evidence stays visible.
    private var recognitionProgressCard: some View {
        HStack(alignment: .center, spacing: 14) {
            if let progress = recognition.progress, progress.total > 0 {
                LeaderProgress(completedPages: progress.completed, totalPages: progress.total)
            } else {
                LeaderProgress(phaseText: progressPhaseFallback)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(recognition.progress?.message ?? "正在识别场记单…")
                    .font(.callout).lineLimit(2)
                Text("输入页在识别期间暂停编辑")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .frame(maxWidth: 360, alignment: .leading)
        // Progress is a floating application-specific panel, so it uses one
        // shared glass surface while the evidence canvas remains opaque.
        .slateGlassSurface(.panel)
        .shadow(color: .black.opacity(0.15), radius: 12, x: 0, y: 4)
        .accessibilityElement(children: .combine)
    }

    private var progressPhaseFallback: String {
        let phase = recognition.progress?.phase ?? ""
        return phase.isEmpty ? "识别中" : phase
    }

    private var configurationPanel: some View {
        VStack(spacing: 0) {
            HStack {
                SlatePanelHeading(title: "识别配置")
                Button("收起", systemImage: "chevron.right") {
                    changeLayout { showsConfiguration = false }
                }
                .tint(Color.secondary)
                .help("收起识别配置，扩大预览区域")
                    .accessibilityIdentifier("workspace.configuration.close")
            }.padding(density.panelPadding)
            Form {
                Section {
                    Picker("服务商", selection: providerSelection) {
                        Text("请选择").tag("")
                        if unavailableProvider {
                            Text("不可用：\(providerID)").tag(providerID)
                        }
                        ForEach(recognition.providers, id: \.id) { Text($0.label).tag($0.id) }
                    }
                    Picker("模型", selection: modelSelection) {
                        Text("请选择").tag("")
                        if unavailableModel {
                            Text("不可用：\(modelID)").tag(modelID)
                        }
                        ForEach(recognition.availableModels(providerID: providerID), id: \.id) {
                            Text($0.label).tag($0.id)
                        }
                    }
                    if unavailableProvider || unavailableModel || providerID.isEmpty || modelID.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("请选择可用项，或先配置服务商。")
                                .font(.caption).foregroundStyle(.secondary)
                            SettingsLink { Text("打开全局设置") }
                        }
                    }
                    if case .failed(let error) = recognition.optionsOperation {
                        LabeledContent("选项读取失败") {
                            HStack {
                                Text(error.message)
                                Button("重试") { Task { await recognition.loadOptions() } }
                            }
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
                    VStack(alignment: .leading, spacing: 12) {
                        // Own the full heading hit target while keeping the
                        // same flush barrier before the prompt is collapsed.
                        Button {
                            changeLayout { showsAdvanced.toggle() }
                        } label: {
                            HStack {
                                Image(systemName: showsAdvanced ? "chevron.down" : "chevron.right")
                                    .font(.caption).accessibilityHidden(true)
                                Text("高级设置")
                                Spacer()
                            }.contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("高级设置")
                        .accessibilityValue(showsAdvanced ? "已展开" : "已收起")
                        .accessibilityIdentifier("workspace.advanced.toggle")
                        if showsAdvanced {
                            TextField("自定义提示词", text: $workspace.customPrompt, axis: .vertical)
                                .lineLimit(3...8)
                                .accessibilityLabel("自定义提示词")
                                .accessibilityIdentifier(AccessibilityID.workspaceCustomPrompt)
                        }
                    }
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
        }
    }

    private var localCSVPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider()
            HStack {
                SlatePanelHeading(
                    title: "本地场记 CSV",
                    subtitle: recognition.slateCSVRecords.isEmpty
                        ? "已有结构化场记时，可直接生成结果"
                        : "\(recognition.slateCSVFilename ?? "场记 CSV") · \(recognition.slateCSVRecords.count) 条"
                )
                Menu("CSV 操作", systemImage: "tablecells") {
                    Button("载入场记 CSV…") { presentImport(.slateCSV) }
                        .disabled(workspace.selectedTaskID == nil)
                    if !recognition.slateCSVRecords.isEmpty {
                        Button("从场记 CSV 生成结果") {
                            recognition.generateLocalRecords(
                                flush: { try await workspace.flush() }, commit: workspace.stageLocalRecords,
                                taskID: workspace.selectedTaskID)
                        }
                    }
                }
                .tint(Color.secondary)
                .fixedSize()
            }.padding(.horizontal, density.panelPadding).padding(.bottom, 12)
        }
    }

    private var metadataPanel: some View {
        VStack(alignment: .leading) {
            DisclosureGroup(metadata.operation.isRunning ? "场记元数据 · 扫描中…" : "场记元数据 · 扫描与回填") {
                Button("选择目录并扫描…") { presentImport(.metadata) }
                    .disabled(workspace.selectedTaskID == nil || csv.table == nil)
                if case .failed(let error) = metadata.operation {
                    Text(error.message).foregroundStyle(SlateSyncTheme.danger)
                }
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
                    // Scanner warnings share the reconciliation alert language:
                    // dim severity background with a leading edge, capped inline
                    // so the disclosure never grows a second scroller.
                    ForEach(result.warnings.prefix(6), id: \.self) { warning in
                        WarnRow(severity: .warning) {
                            Text(warning).font(.caption).lineLimit(2)
                        }
                    }
                    if result.warnings.count > 6 {
                        Text("其余 \(result.warnings.count - 6) 条警告已记录在日志中。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding(density.panelPadding)
        .disabled(recognition.operation.isRunning)
    }

    /// Single-point confirmation traces for the result page. The canonical
    /// NSTableView keeps its frozen cell identity, so the pencil circle and
    /// grease strike summarize row statuses beside the table instead of
    /// rewriting its cells (deviation recorded in AGENT.md 2026-09-14).
    @ViewBuilder private var takeMarkSummary: some View {
        let records = recognition.resolveRecords
        if !records.isEmpty {
            let circled = records.filter { $0.takeStatus == .passed || $0.takeStatus == .hold }.count
            let struck = records.filter { $0.takeStatus == .rejected }.count
            HStack(spacing: 16) {
                takeMarkCount(mark: TakeMark(phase: .circled), label: "过 / 保", count: circled)
                takeMarkCount(mark: TakeMark(phase: .struck), label: "废条", count: struck)
                takeMarkCount(mark: TakeMark(phase: .pending), label: "待定", count: records.count - circled - struck)
                Spacer(minLength: 0)
            }
            .font(.caption).foregroundStyle(.secondary)
            .padding(.horizontal, density.panelPadding)
            .padding(.vertical, 8)
            Divider()
        }
    }

    private func takeMarkCount(mark: TakeMark, label: String, count: Int) -> some View {
        HStack(spacing: 6) {
            mark
            Text("\(label) \(count)").monospacedDigit()
        }
    }

    private var resultView: some View {
        GeometryReader { geometry in
            let wide = geometry.size.width >= 900
            let previewWidth = wide ? min(420, geometry.size.width * 0.4) : min(420, geometry.size.width)
            ZStack(alignment: .leading) {
                // Never switch the result table between separate layout branches:
                // padding changes preserve its field editor, selection and scroll.
                VStack(spacing: 0) {
                    takeMarkSummary
                    RecognitionResultView(
                        model: recognition, workspace: workspace,
                        onInput: { changeLayout { visit(.input) } }
                    )
                }
                .padding(.leading, wide && showsOriginal ? previewWidth : 0)
                if let document = media.document {
                    VStack(spacing: 0) {
                        HStack {
                            SlatePanelHeading(title: "原稿对照", subtitle: "翻页仅切换原稿，不改变结果选择")
                            Button("关闭", systemImage: "xmark") { changeLayout { showsOriginal = false } }
                                .tint(Color.secondary)
                                .accessibilityIdentifier("workspace.original.close")
                        }.padding(density.panelPadding)
                        MediaPreviewView(document: document, pageIndex: $media.pageIndex)
                    }
                    .frame(width: previewWidth).frame(maxHeight: .infinity)
                    .background(SlateSyncTheme.canvas)
                    .overlay(alignment: .trailing) {
                        Rectangle().fill(SlateSyncTheme.separator).frame(width: 0.5)
                    }
                    .opacity(showsOriginal ? 1 : 0).allowsHitTesting(showsOriginal)
                    .accessibilityHidden(!showsOriginal)
                }
            }
        }
    }

    private var recognitionUnavailableReason: String? {
        if workspace.projectID == nil { return "请先从项目库打开项目。" }
        if workspace.selectedTaskID == nil { return "请选择任务，或导入场记单自动创建任务。" }
        if media.operation.isRunning { return "场记单准备完成后即可识别。" }
        if media.document == nil { return "请先导入 PDF 或图像；本地 CSV 可直接生成结果。" }
        if providerID.isEmpty || modelID.isEmpty { return "请在识别配置中选择服务商和模型。" }
        if !recognition.canRecognize(providerID: providerID, modelID: modelID) {
            return "识别配置不可用，请选择可用模型或打开全局设置配置服务商。"
        }
        return nil
    }

    private var originalBinding: Binding<Bool> {
        Binding(get: { showsOriginal }, set: { value in changeLayout { showsOriginal = value } })
    }

    private func routeToEntryPoint(_ destination: WorkspaceEntryPoint) {
        guard destination != .input else { return }
        if changingLayout {
            pendingEntryPoint = destination
            return
        }
        let target = destination == .resolveCSV ? WorkspaceSection.csv : .result
        pendingEntryPoint = nil
        changeLayout {
            visit(target)
            // The callback is deliberately inside the guarded update: a
            // failed transition leaves the parent hint available for Retry.
            onEntryPointConsumed()
        }
    }

    private func changeLayout(_ update: @escaping @MainActor () -> Void) {
        guard !changingLayout else { return }
        changingLayout = true
        var succeeded = false
        Task {
            defer {
                changingLayout = false
                if succeeded, let pendingEntryPoint {
                    self.pendingEntryPoint = nil
                    routeToEntryPoint(pendingEntryPoint)
                }
            }
            do {
                try editorBoundary.prepare()
                try await workspace.flush()
                layoutError = nil
                update()
                succeeded = true
            } catch { layoutError = "请完成当前编辑并重试：\(error.localizedDescription)" }
        }
    }

    private var sectionBinding: Binding<WorkspaceSection> {
        Binding(
            get: { section },
            set: { destination in
                changeLayout { visit(destination) }
            })
    }

    private var pendingSectionsAccessibilityHint: String {
        let pending = WorkspaceSection.allCases.filter { unseenSections.contains($0) }
        return pending.isEmpty ? "" : pending.map { "\($0.rawValue)有新内容" }.joined(separator: "、")
    }

    private func visit(_ destination: WorkspaceSection) {
        section = destination
        unseenSections.remove(destination)
        onSectionChanged(destination)
    }

    private var canRecognize: Bool {
        workspace.projectID != nil && workspace.selectedTaskID != nil && media.document != nil
            && !media.operation.isRunning
            && recognition.canRecognize(providerID: providerID, modelID: modelID)
    }

    private var unavailableProvider: Bool {
        !providerID.isEmpty && !recognition.providers.contains(where: { $0.id == providerID })
    }

    private var unavailableModel: Bool {
        !modelID.isEmpty
            && !recognition.availableModels(providerID: providerID).contains(where: { $0.id == modelID })
    }

    @ViewBuilder private var autosaveBanner: some View {
        if let error = workspace.autosaveError {
            SlateStatusBar(message: "自动保存失败：\(error.message)", tone: .error) {
                Button("重试") { Task { await workspace.retryAutosave() } }
            }
        }
    }

    private func startRecognition() {
        guard let projectID = workspace.projectID, let document = media.document,
            let firstImage = document.pages.first?.views.first?.image
        else { return }
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
        Binding(
            get: { providerID },
            set: { value in
                // Only an explicit Picker change may clear an incompatible model;
                // restoring a task preserves stale IDs for visible recovery.
                let selection = RecognitionOptionSelection.selectingProvider(
                    value,
                    currentModelID: modelID,
                    availableModels: recognition.availableModels(providerID: value)
                )
                providerID = selection.providerID
                modelID = selection.modelID
                persistRecognitionOptions()
            })
    }

    private var modelSelection: Binding<String> {
        Binding(
            get: { modelID },
            set: { value in
                modelID = value
                persistRecognitionOptions()
            })
    }

    private var accuracySelection: Binding<ProjectSettings.AccuracyMode> {
        Binding(
            get: { accuracy },
            set: { value in
                accuracy = value
                persistRecognitionOptions()
            })
    }

    private var scenarioSelection: Binding<String> {
        Binding(
            get: { scenarioID },
            set: { value in
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
        let selection = RecognitionOptionSelection.restored(
            task: workspace.selectedTask,
            project: workspace.projectSettings
        )
        providerID = selection.providerID
        modelID = selection.modelID
    }
}

private struct RecognitionResultView: View {
    @Bindable var model: RecognitionModel
    let workspace: WorkspaceModel
    let onInput: () -> Void

    var body: some View {
        if !model.editableRecords.isEmpty {
            EditableCSVTableRepresentable(
                tableID: model.resultTableID, table: model.resultTable, revision: 0,
                accessibilityLabel: "可编辑识别结果",
                onCommit: { model.receiveResult($0, commit: workspace.stageEditedRecords) },
                editorRegistration: { model.flushEditor = $0 }
            )
            .disabled(model.operation.isRunning)

        } else if case .failed(let error) = model.operation {
            SlateEmptyState(title: "识别失败", symbol: "exclamationmark.triangle", message: error.message) {
                Button("返回输入检查配置", action: onInput)
            }
        } else {
            // Empty results return through the same guarded tab transition.
            SlateEmptyState(
                title: "暂无识别结果", symbol: "text.viewfinder",
                message: "请先在输入页选择场记单并开始识别。"
            ) {
                Button("前往输入", action: onInput)
            }
        }
    }

}

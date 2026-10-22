import SlateSyncDomain
import SwiftUI
import UniformTypeIdentifiers

// Product copy uses the shared launch language; user content stays verbatim.

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
    // Persisted section identity stays unchanged across interface languages.
    public var title: String { L10n.message(rawValue) }
}

public struct WorkspaceView: View {
    @Bindable private var workspace: WorkspaceModel
    @Bindable private var recognition: RecognitionModel
    @Bindable private var csv: ResolveCSVModel
    @Bindable private var metadata: MetadataScanModel
    @Bindable private var media: MediaInputModel
    @Environment(\.slateSyncDensity) private var density
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var showsTasks = true
    @State private var showsConfiguration: Bool?
    // Only input breakpoints enter view state. Result comparison geometry is
    // handled directly by WorkspaceResultLayout without publishing widths.
    @State private var inputLayout = InputLayout()
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
    @State private var metadataReport: WorkflowDiagnosticReport?
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
    private static let configurationPanelWidth: CGFloat = 300

    // Widths below are measured on the detail column (window minus the sidebar
    // and task rail), not on the window. The layout types are nonisolated value
    // types so the geometry callback can build them off the main actor, which
    // is why their breakpoints live on them instead of on the view.

    /// Input-page width classes. Equatable on purpose: `onGeometryChange` only
    /// fires when a class flips, so animating the split view's sidebar (or
    /// dragging the window edge) does not write state — and re-evaluate this
    /// large view — on every frame the way a raw width would.
    private struct InputLayout: Equatable {
        /// The configuration panel opens by default from this width.
        static let defaultWidth: CGFloat = 900
        /// From this width a visible panel docks (the preview makes room for
        /// it); narrower columns overlay it on top of the preview instead.
        static let dockWidth: CGFloat = 700

        var opensConfiguration = false
        var docksConfiguration = false
        init() {}
        init(width: CGFloat) {
            opensConfiguration = width >= Self.defaultWidth
            docksConfiguration = width >= Self.dockWidth
        }
    }

    @State private var section: WorkspaceSection
    // A native segmented Picker must read back its new value synchronously.
    // Keep that feedback separate from the page, which stays mounted until
    // the editor/save barrier succeeds; rapid clicks share the same barrier.
    @State private var pendingSection: WorkspaceSection?
    @State private var providerID = ""
    @State private var modelID = ""
    @State private var scenarioID = ""
    @State private var accuracy = ProjectSettings.AccuracyMode.high
    private let settingsRevision: Int
    private let globalSettings: GlobalSettingsModel?
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
        globalSettings: GlobalSettingsModel? = nil,
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
        self.globalSettings = globalSettings
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
        // A single animated layout places both panes; native descendants do
        // not inherit the split animation or retain intermediate rectangles.
        WorkspaceTaskSplit(showsTasks: showsTasks, reduceMotion: reduceMotion) {
            TaskRailView(model: workspace)
        } detail: {
            VStack(spacing: 0) {
                workspaceHeader
                Divider()
                detail
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(WorkspaceEditorProbe(boundary: editorBoundary).frame(width: 0, height: 0))
        .navigationTitle(L10n.tr("工作台"))
        .sheet(item: $metadataReport) { WorkflowDiagnosticsSheet(report: $0) }
        .onChange(of: workspace.selectedTaskID) { _, _ in metadataReport = nil }
        .safeAreaInset(edge: .bottom) {
            autosaveBanner
            if let layoutError {
                SlateStatusBar(message: layoutError, tone: .warning) {
                    if entryPoint != .input {
                        Button(L10n.tr("重试")) { routeToEntryPoint(entryPoint) }
                    }
                    Button(L10n.tr("关闭")) { self.layoutError = nil }
                }
            }
        }
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button(showsTasks ? L10n.tr("隐藏任务列表") : L10n.tr("显示任务列表"), systemImage: "sidebar.left") {
                    changeLayout { showsTasks.toggle() }
                }
                .tint(Color.secondary)
                .help(L10n.tr("显示或隐藏当前项目的任务"))
                .accessibilityIdentifier("workspace.tasks.toggle")
            }
            ToolbarItemGroup(placement: .primaryAction) {
                Button(L10n.tr("保存"), systemImage: "square.and.arrow.down") {
                    Task { try? await workspace.flush() }
                }
                .tint(Color.secondary)
                // The File menu owns the single ⌘S registration; this toolbar
                // button invokes the same workspace owner without competing.
                Button(L10n.tr("开始识别"), systemImage: "viewfinder") { startRecognition() }
                    .slatePrimaryActionStyle()
                    .labelStyle(.titleAndIcon)
                    .help(recognitionUnavailableReason ?? L10n.tr("识别当前场记单"))
                    .disabled(!canRecognize || recognition.operation.isRunning)
                    .accessibilityIdentifier(AccessibilityID.recognize)
                if recognition.operation.isRunning {
                    Button(L10n.tr("取消识别"), systemImage: "xmark.circle") { recognition.cancel() }
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
            await globalSettings?.load()
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

    /// One compact row: task identity on the left, section picker and the
    /// page's contextual control on the right. When the detail column is too
    /// narrow the picker row drops below the title instead of squeezing it.
    /// The bar is docked chrome, so it uses an opaque surface (glass is kept
    /// for floating elements); the Divider in `body` draws its lower edge.
    private var workspaceHeader: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 16) {
                headerTitle
                sectionPicker
                headerAccessory
            }
            VStack(alignment: .leading, spacing: 8) {
                headerTitle
                HStack(spacing: 12) {
                    sectionPicker
                    Spacer(minLength: 0)
                    headerAccessory
                }
            }
        }
        .padding(.horizontal, density.panelPadding)
        .padding(.vertical, 12)
        .slateDockedSurface(.header)
    }

    /// Task name plus live facts (pages · records · status) instead of a
    /// fixed tagline; falls back to the start hint without a loaded task.
    private var headerTitle: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(workspace.selectedTask?.filename ?? L10n.tr("当前任务"))
                .font(.title3.weight(.semibold)).lineLimit(1)
                .help(workspace.selectedTask?.filename ?? L10n.tr("当前任务"))
            Text(headerFacts)
                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
        // A small ideal width lets ViewThatFits keep the one-row layout for
        // long file names; the name truncates instead of forcing the stack.
        .frame(minWidth: 120, idealWidth: 160, maxWidth: .infinity, alignment: .leading)
        // A container identifier propagates to every HStack child on
        // macOS; scope the heading identifier to the actual heading.
        .accessibilityIdentifier(AccessibilityID.workspaceHeading)
    }

    private var headerFacts: String {
        guard let id = workspace.selectedTaskID,
              let item = workspace.tasks.first(where: { $0.id == id })
        else { return L10n.tr("新建任务或导入场记单以开始") }
        var facts: [String] = []
        if let pages = item.pageCount, pages > 0 {
            facts.append(L10n.tr("{0} 页", [String(describing: pages)]))
        }
        facts.append(L10n.tr("{0} 条", [String(describing: item.recordCount)]))
        facts.append(item.statusTitle)
        return facts.joined(separator: " · ")
    }

    private var sectionPicker: some View {
        Picker(L10n.tr("工作区"), selection: sectionBinding) {
            ForEach(WorkspaceSection.allCases) { Text($0.title).tag($0) }
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
        .accessibilityValue((pendingSection ?? section).title)
        .accessibilityHint(pendingSectionsAccessibilityHint)
    }

    @ViewBuilder private var headerAccessory: some View {
        if section == .input {
            Button(L10n.tr("识别配置"), systemImage: "slider.horizontal.3") {
                changeLayout { showsConfiguration = !(showsConfiguration ?? inputLayout.opensConfiguration) }
            }
            .tint(Color.secondary)
            .accessibilityIdentifier("workspace.configuration.toggle")
        } else if section == .result {
            Toggle(L10n.tr("原稿对照"), isOn: originalBinding)
                .toggleStyle(.button)
                .disabled(media.document == nil)
                .accessibilityIdentifier("workspace.original.toggle")
        }
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
        // Width classes are published only when a breakpoint flips, so the
        // sidebar collapse animation does not re-evaluate this subtree (the
        // configuration form included) on every animated frame.
        let visible = showsConfiguration ?? inputLayout.opensConfiguration
        // A visible panel pushes the preview once there is room for both;
        // below that it floats over the evidence with a soft edge shadow.
        let docked = visible && inputLayout.docksConfiguration
        return ZStack(alignment: .trailing) {
            VStack(spacing: 0) {
                HStack {
                    SlatePanelHeading(
                        title: L10n.tr("场记单"), subtitle: media.document?.filename ?? L10n.tr("支持 PDF 和图像，也可拖入文件"))
                    Button(L10n.tr("选择 PDF 或图像…")) { presentImport(.media) }
                        .disabled(!media.canAcceptInput || workspace.projectID == nil)
                }.padding(density.panelPadding)
                if media.operation.isRunning {
                    SlateStatusBar(message: L10n.tr("正在准备场记单…"), busy: true) {
                        Button(L10n.tr("取消准备"), role: .cancel) { media.cancel() }
                    }
                }
                if case .failed(let error) = media.operation {
                    SlateStatusBar(message: error.message, tone: .error) {
                        Button(L10n.tr("重新选择…")) { presentImport(.media) }
                    }
                }
                Group {
                    if let document = media.document {
                        MediaPreviewView(document: document, pageIndex: $media.pageIndex)
                    } else {
                        SlateEmptyState(
                            title: L10n.tr("导入场记单"), symbol: "doc.viewfinder",
                            message: L10n.tr("选择或拖入 PDF、图像，然后配置识别。")
                        ) {
                            Button(L10n.tr("选择 PDF 或图像…")) { presentImport(.media) }
                                .disabled(!media.canAcceptInput || workspace.projectID == nil)
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(SlateSyncTheme.canvas)
                localCSVPanel
                if let block = recognitionBlock {
                    SlateStatusBar(message: block.message) {
                        // Provider and model are required inputs; when the
                        // panel is closed the status bar opens it directly.
                        if block.needsConfiguration, !visible {
                            Button(L10n.tr("打开识别配置")) {
                                changeLayout { showsConfiguration = true }
                            }
                            .accessibilityIdentifier("workspace.configuration.open")
                        }
                    }
                }
            }
            .padding(.trailing, docked ? Self.configurationPanelWidth : 0)
            // The same form stays mounted as the column crosses the dock
            // width; only its placement changes, preserving native IME
            // drafts. The panel is always the same opaque surface so its
            // identity never depends on docked/overlay state.
            configurationPanel
                .frame(width: Self.configurationPanelWidth)
                .frame(maxHeight: .infinity)
                .slateDockedSurface(.panel)
                // Overlay layout needs an explicit vertical rule; retain full
                // separator opacity between the controls and evidence canvas.
                .overlay(alignment: .leading) {
                    Rectangle().fill(SlateSyncTheme.separator).frame(width: 0.5)
                        .allowsHitTesting(false)
                }
                // Only a floating (overlaid) panel casts a shadow; docked
                // chrome stays flat (DESIGN.md: shadows are for overlays).
                .shadow(color: .black.opacity(visible && !docked ? 0.22 : 0),
                        radius: visible && !docked ? 10 : 0, x: -3, y: 0)
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
        .onGeometryChange(for: InputLayout.self) {
            InputLayout(width: $0.size.width)
        } action: {
            inputLayout = $0
            // Choose the initial default once. Crossing 900 pt during either
            // sidebar animation must not also open/close a 300 pt panel and
            // reverse the preview's resize midway through that animation.
            if showsConfiguration == nil { showsConfiguration = $0.opensConfiguration }
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
                Text(recognition.progress.map { L10n.message($0.message) } ?? L10n.tr("正在识别场记单…"))
                    .font(.callout).lineLimit(2)
                Text(L10n.tr("输入页在识别期间暂停编辑"))
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
        return phase.isEmpty ? L10n.tr("识别中") : phase
    }

    private var configurationPanel: some View {
        VStack(spacing: 0) {
            HStack {
                SlatePanelHeading(title: L10n.tr("识别配置"))
                Button(L10n.tr("收起"), systemImage: "chevron.right") {
                    changeLayout { showsConfiguration = false }
                }
                .tint(Color.secondary)
                .help(L10n.tr("收起识别配置，扩大预览区域"))
                    .accessibilityIdentifier("workspace.configuration.close")
            }.padding(density.panelPadding)
            Form {
                Section {
                    Picker(L10n.tr("服务商"), selection: providerSelection) {
                        Text(L10n.tr("请选择")).tag("")
                        if unavailableProvider {
                            Text(L10n.tr("不可用：{0}", [String(describing: providerID)])).tag(providerID)
                        }
                        ForEach(recognition.providers, id: \.id) { Text(L10n.providerLabel($0)).tag($0.id) }
                    }
                    Picker(L10n.tr("模型"), selection: modelSelection) {
                        Text(L10n.tr("请选择")).tag("")
                        if unavailableModel {
                            Text(L10n.tr("不可用：{0}", [String(describing: modelID)])).tag(modelID)
                        }
                        ForEach(recognition.availableModels(providerID: providerID), id: \.id) {
                            Text($0.label).tag($0.id)
                        }
                    }
                    HStack {
                        if globalSettings?.live?.values[.defaultProviderID] == providerID,
                           globalSettings?.live?.values[.defaultModelID] == modelID,
                           !providerID.isEmpty {
                            Text(L10n.tr("默认")).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Menu(L10n.tr("设为默认…")) {
                            Button(L10n.tr("将当前服务商和模型设为全局默认")) {
                                guard let globalSettings else { return }
                                Task { _ = await globalSettings.setDefaultPair(providerID: providerID, modelID: modelID) }
                            }
                            .disabled(globalSettings == nil || globalSettings?.operation.isRunning == true
                                || !recognition.canRecognize(providerID: providerID, modelID: modelID))
                        }
                    }
                    if unavailableProvider || unavailableModel || providerID.isEmpty || modelID.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(L10n.tr("请选择可用项，或先配置服务商。"))
                                .font(.caption).foregroundStyle(.secondary)
                            SettingsLink { Text(L10n.tr("打开全局设置")) }
                        }
                    }
                    if case .failed(let error) = recognition.optionsOperation {
                        LabeledContent(L10n.tr("选项读取失败")) {
                            HStack {
                                Text(L10n.message(error.message))
                                Button(L10n.tr("重试")) { Task { await recognition.loadOptions() } }
                            }
                        }
                    }
                    Picker(L10n.tr("精度"), selection: accuracySelection) {
                        Text(L10n.tr("标准")).tag(ProjectSettings.AccuracyMode.standard)
                        Text(L10n.tr("高精度")).tag(ProjectSettings.AccuracyMode.high)
                    }
                    Picker(L10n.tr("场记版式（Scenario）"), selection: scenarioSelection) {
                        Text(L10n.tr("自动匹配")).tag("")
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
                                Text(L10n.tr("高级设置"))
                                Spacer()
                            }.contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(L10n.tr("高级设置"))
                        .accessibilityValue(showsAdvanced ? L10n.tr("已展开") : L10n.tr("已收起"))
                        .accessibilityIdentifier("workspace.advanced.toggle")
                        if showsAdvanced {
                            TextField(L10n.tr("自定义提示词"), text: $workspace.customPrompt, axis: .vertical)
                                .lineLimit(3...8)
                                .accessibilityLabel(L10n.tr("自定义提示词"))
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
                    title: L10n.tr("本地场记 CSV"),
                    subtitle: recognition.slateCSVRecords.isEmpty
                        ? L10n.tr("已有结构化场记时，可直接生成结果")
                        : L10n.tr("{0} · {1} 条", [String(describing: recognition.slateCSVFilename ?? L10n.tr("场记 CSV")), String(describing: recognition.slateCSVRecords.count)])
                )
                Menu(L10n.tr("CSV 操作"), systemImage: "tablecells") {
                    Button(L10n.tr("载入场记 CSV…")) { presentImport(.slateCSV) }
                        .disabled(workspace.selectedTaskID == nil)
                    if !recognition.slateCSVRecords.isEmpty {
                        Button(L10n.tr("从场记 CSV 生成结果")) {
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
            DisclosureGroup(metadata.operation.isRunning ? L10n.tr("场记元数据 · 扫描中…") : L10n.tr("场记元数据 · 扫描与回填")) {
                Button(L10n.tr("选择目录并扫描…")) { presentImport(.metadata) }
                    .disabled(workspace.selectedTaskID == nil || csv.table == nil)
                if case .failed(let error) = metadata.operation {
                    SlateInlineError(error.message)
                }
                if metadata.operation.isRunning {
                    Button(L10n.tr("取消扫描"), role: .cancel) { metadata.cancel() }
                }
                if let result = metadata.result {
                    LabeledContent(L10n.tr("已读取"), value: L10n.tr("{0} 条", [String(describing: result.metadata.count)]))
                    LabeledContent(L10n.tr("警告"), value: L10n.tr("{0} 条", [String(describing: result.warnings.count)]))
                    LabeledContent(L10n.tr("缺少素材"), value: L10n.tr("{0} 条", [String(describing: result.missingKeys.count)]))
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
                            Text(L10n.message(warning)).font(.caption).lineLimit(2)
                        }
                    }
                    if !result.warnings.isEmpty || !result.missingKeys.isEmpty {
                        // Logs intentionally contain counts only. Full warning
                        // text and every missing clip remain in this local report.
                        Button(L10n.tr("查看完整扫描报告")) {
                            let missing = result.missingKeys.map {
                                L10n.tr("素材 {0} 缺少元数据", [$0])
                            }
                            metadataReport = WorkflowDiagnosticReport(title: L10n.tr("元数据扫描报告"),
                                messages: result.warnings.map { L10n.message($0) } + missing)
                        }.font(.caption)
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
                takeMarkCount(mark: TakeMark(phase: .circled), label: L10n.tr("过 / 保"), count: circled)
                takeMarkCount(mark: TakeMark(phase: .struck), label: L10n.tr("废条"), count: struck)
                takeMarkCount(mark: TakeMark(phase: .pending), label: L10n.tr("待定"), count: records.count - circled - struck)
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
        // Layout places the mounted panes at the exact proposed width. A
        // sidebar animation no longer feeds stepped widths back into this
        // view's state or rebuilds the surrounding workspace and toolbar.
        WorkspaceResultLayout(showsOriginal: showsOriginal) {
            // Never switch the result table between separate layout branches:
            // layout changes preserve its field editor, selection and scroll.
            VStack(spacing: 0) {
                takeMarkSummary
                RecognitionResultView(
                    model: recognition, workspace: workspace,
                    onInput: { changeLayout { visit(.input) } }
                )
            }
            if let document = media.document {
                VStack(spacing: 0) {
                    HStack {
                        SlatePanelHeading(title: L10n.tr("原稿对照"), subtitle: L10n.tr("翻页仅切换原稿，不改变结果选择"))
                        Button(L10n.tr("关闭"), systemImage: "xmark") { changeLayout { showsOriginal = false } }
                            .tint(Color.secondary)
                            .accessibilityIdentifier("workspace.original.close")
                    }.padding(density.panelPadding)
                    MediaPreviewView(document: document, pageIndex: $media.pageIndex)
                }
                .frame(maxHeight: .infinity)
                .background(SlateSyncTheme.canvas)
                .overlay(alignment: .trailing) {
                    Rectangle().fill(SlateSyncTheme.separator).frame(width: 0.5)
                }
                .opacity(showsOriginal ? 1 : 0).allowsHitTesting(showsOriginal)
                .accessibilityHidden(!showsOriginal)
            }
        }
    }

    /// Why recognition cannot start, plus whether the fix lives in the
    /// recognition configuration panel (so the status bar can offer to open it).
    private struct RecognitionBlock {
        let message: String
        var needsConfiguration = false
    }

    private var recognitionBlock: RecognitionBlock? {
        if workspace.projectID == nil { return RecognitionBlock(message: L10n.tr("请先从项目库打开项目。")) }
        if workspace.selectedTaskID == nil { return RecognitionBlock(message: L10n.tr("请选择任务，或导入场记单自动创建任务。")) }
        if media.operation.isRunning { return RecognitionBlock(message: L10n.tr("场记单准备完成后即可识别。")) }
        if media.document == nil { return RecognitionBlock(message: L10n.tr("请先导入 PDF 或图像；本地 CSV 可直接生成结果。")) }
        if providerID.isEmpty || modelID.isEmpty {
            return RecognitionBlock(message: L10n.tr("请在识别配置中选择服务商和模型。"), needsConfiguration: true)
        }
        if !recognition.canRecognize(providerID: providerID, modelID: modelID) {
            return RecognitionBlock(
                message: L10n.tr("识别配置不可用，请选择可用模型或打开全局设置配置服务商。"), needsConfiguration: true)
        }
        return nil
    }

    private var recognitionUnavailableReason: String? { recognitionBlock?.message }

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
                // Success has published the destination; failure restores the
                // original selection without unmounting its unsaved editor.
                pendingSection = nil
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
                // A tab click can arrive during any layout save, including
                // sidebar/configuration/original toggles. Apply the last click
                // only after that same editor barrier succeeds.
                if let pendingSection { visit(pendingSection) }
                succeeded = true
            } catch { layoutError = L10n.tr("请完成当前编辑并重试：{0}", [String(describing: error.localizedDescription)]) }
        }
    }

    private var sectionBinding: Binding<WorkspaceSection> {
        Binding(
            get: { pendingSection ?? section },
            set: { destination in
                guard destination != (pendingSection ?? section) else { return }
                pendingSection = destination
                guard !changingLayout else { return }
                changeLayout {}
            })
    }

    private var pendingSectionsAccessibilityHint: String {
        let pending = WorkspaceSection.allCases.filter { unseenSections.contains($0) }
        return pending.isEmpty ? "" : pending.map { L10n.tr("{0}有新内容", [String(describing: $0.title)]) }.joined(separator: "、")
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
            SlateStatusBar(message: L10n.tr("自动保存失败：{0}", [String(describing: L10n.message(error.message))]), tone: .error) {
                Button(L10n.tr("重试")) { Task { await workspace.retryAutosave() } }
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
        let tableID = csv.tableID, taskID = workspace.selectedTaskID
        Task {
            do {
                let keys = try await csv.materialKeys()
                guard tableID == csv.tableID, taskID == workspace.selectedTaskID else { return }
                metadata.scan(directory, expectedKeys: keys)
            } catch {
                if tableID == csv.tableID, taskID == workspace.selectedTaskID { metadata.report(error) }
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
        if providerID.isEmpty, modelID.isEmpty,
           let defaultProvider = globalSettings?.live?.values[.defaultProviderID],
           let defaultModel = globalSettings?.live?.values[.defaultModelID],
           recognition.canRecognize(providerID: defaultProvider, modelID: defaultModel) {
            // A global default seeds an empty task without persisting a task
            // override or mixing its fields with an incomplete project pair.
            providerID = defaultProvider
            modelID = defaultModel
        }
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
                accessibilityLabel: L10n.tr("可编辑识别结果"),
                onCommit: { model.receiveResult($0, commit: workspace.stageEditedRecords) },
                editorRegistration: { model.flushEditor = $0 }
            )
            .disabled(model.operation.isRunning)

        } else if case .failed(let error) = model.operation {
            SlateEmptyState(title: L10n.tr("识别失败"), symbol: "exclamationmark.triangle", message: error.message) {
                Button(L10n.tr("返回输入检查配置"), action: onInput)
            }
        } else {
            // Empty results return through the same guarded tab transition.
            SlateEmptyState(
                title: L10n.tr("暂无识别结果"), symbol: "text.viewfinder",
                message: L10n.tr("请先在输入页选择场记单并开始识别。")
            ) {
                Button(L10n.tr("前往输入"), action: onInput)
            }
        }
    }

}

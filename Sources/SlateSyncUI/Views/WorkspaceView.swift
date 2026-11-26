import SlateSyncDomain
import SwiftUI
import UniformTypeIdentifiers

// Product copy uses the shared launch language; user content stays verbatim.

/// A route hint for Help shortcuts and status-bar actions. The workspace
/// keeps ownership of its segmented selection; the hint only chooses the
/// initial/target section and never changes task data.
public enum WorkspaceEntryPoint: String, Hashable, Sendable {
    case retryInput
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
    // The outgoing live page keeps its colors but relinquishes window chrome.
    @Environment(\.contentRevealIsActive) private var revealIsActive
    @Bindable private var workspace: WorkspaceModel
    @Bindable private var recognition: RecognitionModel
    @Bindable private var csv: ResolveCSVModel
    @Bindable private var metadata: MetadataScanModel
    @Bindable private var media: MediaInputModel
    @Environment(\.slateSyncDensity) private var density
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    // Initial width defaults and page reveals never also animate a panel.
    @State private var animatesPanelChanges = false
    @State private var showsConfiguration: Bool?
    // Only input breakpoints enter view state. Result comparison geometry is
    // handled directly by WorkspaceResultLayout without publishing widths.
    @State private var inputLayout = InputLayout()
    @State private var editorBoundary = WorkspaceEditorBoundary()
    @State private var showsOriginal = false
    // Results opens beside the original sheet once, when the column is wide
    // enough to show both inline; after that the toolbar toggle owns it.
    @State private var appliedResultDefault = false
    @State private var showsAdvanced = false
    @State private var layoutError: String?
    @State private var changingLayout = false
    // A route hint can arrive while another editor transition owns the
    // barrier; retain the latest target until that transition succeeds.
    @State private var pendingEntryPoint: WorkspaceEntryPoint?
    @State private var importsFile = false
    @State private var importKind = ImportKind.media
    @State private var importTaskID: String?
    @State private var importProjectID: String?
    @State private var importTableID: UUID?
    @State private var intakeParts: [MediaIntakePart] = []
    @State private var showsBatch = false
    @State private var receivingMedia = false
    @State private var resumeDelivery: ((URL?) -> Void)?
    @State private var showsHandoff = false
    @State private var confirmRerun = false
    @State private var confirmCSVReplacement = false
    @State private var metadataReport: WorkflowDiagnosticReport?
    // The parent owns this ledger so completion events are not lost when the
    // workspace route is replaced by Projects, Logs, or Help.
    @Binding private var unseenSections: Set<WorkspaceSection>

    private enum ImportKind {
        case media, metadata, slateCSV, resolveCSV, deliveryFolder
        var types: [UTType] {
            switch self {
            case .media: [.pdf, .jpeg, .png, .webP]
            case .metadata, .deliveryFolder: [.folder]
            case .slateCSV, .resolveCSV: [.commaSeparatedText, .plainText]
            }
        }
    }
    private static let configurationPanelWidth: CGFloat = 300
    private static let sectionPickerWidth: CGFloat = 360

    // Widths below are measured on the detail column (the window minus the
    // sidebar, which also holds the task list), not on the window. The layout
    // types are nonisolated value types so the geometry callback can build them
    // off the main actor, which is why their breakpoints live on them instead
    // of on the view.

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
        /// The window's 960 pt minimum leaves the detail column at least ~680 pt,
        /// so a narrower report is the first layout pass (the column's ideal
        /// width, not its real one) and must not decide the panel's default.
        static let minimumMeasuredWidth: CGFloat = 600
        var isMeasured = false
        init() {}
        init(width: CGFloat) {
            opensConfiguration = width >= Self.defaultWidth
            docksConfiguration = width >= Self.dockWidth
            isMeasured = width >= Self.minimumMeasuredWidth
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
            case .input, .retryInput: .input
            case .result: .result
            case .resolveCSV: .csv
            }
        }())
    }

    public var body: some View {
        // Tasks live in the app sidebar (SidebarView), so the workspace is one
        // detail column: the window toolbar carries identity, the section
        // picker and the page's actions; no in-page header bar remains.
        ContentRevealRegion(value: section, origin: .topSegment(
            index: WorkspaceSection.allCases.firstIndex(of: section) ?? 0,
            count: WorkspaceSection.allCases.count, width: Self.sectionPickerWidth
        )) { destination in
            detail(for: destination)
        }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(WorkspaceEditorProbe(boundary: editorBoundary).frame(width: 0, height: 0))
        .contentRevealNavigationTitle(workspace.selectedTask?.production?.title.flatMap { $0.isEmpty ? nil : $0 } ?? workspace.selectedTask?.filename ?? L10n.tr("当前任务"), subtitle: headerFacts)
        .confirmationDialog(L10n.tr("重新识别并保留当前校对版本？"), isPresented: $confirmRerun) {
            Button(L10n.tr("保存当前版本并重新识别")) { startRecognition() }
        }
        .confirmationDialog(L10n.tr("替换已有人工编辑的工作表？"), isPresented: $confirmCSVReplacement) {
            Button(L10n.tr("选择替换文件…")) { openImporter(.resolveCSV) }
            Button(L10n.tr("取消"), role: .cancel) {}
        } message: { Text(L10n.tr("现有 {0} 处人工编辑。需要保留时，请先导出当前工作表。", [String(csv.manualEditCount)])) }
        .sheet(isPresented: $showsBatch) {
            VStack(alignment: .leading) {
                Text(L10n.tr("确认场记导入顺序")).font(.headline)
                List {
                    ForEach(Array(intakeParts.enumerated()), id: \.element) { index, part in
                        HStack {
                            Text(part.filename)
                            Spacer()
                            Button { intakeParts.swapAt(index, index - 1) } label: { Image(systemName: "arrow.up") }
                                .disabled(index == 0).accessibilityLabel(L10n.tr("上移"))
                            Button { intakeParts.swapAt(index, index + 1) } label: { Image(systemName: "arrow.down") }
                                .disabled(index + 1 == intakeParts.count).accessibilityLabel(L10n.tr("下移"))
                        }
                    }
                }
                HStack {
                    Spacer()
                    Button(L10n.tr("取消")) { showsBatch = false }
                    Button(L10n.tr("按顺序建任务")) {
                        showsBatch = false
                        receiveMedia(intakeParts)
                    }.keyboardShortcut(.defaultAction)
                }
            }.padding().frame(minWidth: 450, minHeight: 320)
        }
        .sheet(isPresented: $showsHandoff) { TaskHandoffView(workspace: workspace) }
        .sheet(item: $metadataReport) { WorkflowDiagnosticsSheet(report: $0) }
        .onChange(of: workspace.selectedTaskID) { _, _ in metadataReport = nil }
        .safeAreaInset(edge: .bottom) {
            autosaveBanner
            switch recognition.localOperation {
            case .running(let label): SlateStatusBar(message: label, busy: true) {}
            case .failed(let error): SlateInlineError(error.message)
            case .succeeded(let message): SlateStatusBar(message, tone: .success)
            default: EmptyView()
            }
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
            if revealIsActive {
                ToolbarItem(placement: .principal) {
                    sectionPicker
                }
                // Fixed order on every page: [primary] [More] [panel toggle], so the
                // panel toggle always sits at the trailing edge.
                ToolbarItemGroup(placement: .primaryAction) {
                    recognitionAction
                    Menu(L10n.tr("更多"), systemImage: "ellipsis.circle") {
                        if section == .input {
                            Button(L10n.tr("选择 PDF 或图像…")) { presentImport(.media) }
                                .disabled(!media.canAcceptInput || workspace.projectID == nil)
                            Button(L10n.tr("载入场记 CSV…")) { presentImport(.slateCSV) }
                                .disabled(workspace.projectID == nil)
                            if !recognition.slateCSVRecords.isEmpty {
                                Button(L10n.tr("从场记 CSV 生成结果")) {
                                    recognition.generateLocalRecords(
                                        flush: { try await workspace.flush() }, commit: workspace.stageLocalRecords,
                                        taskID: workspace.selectedTaskID)
                                }
                            }
                            Divider()
                        }
                        if section == .csv {
                            // Importing a Resolve CSV is rare and replaces the table,
                            // so it lives here (and in the empty state) rather than
                            // as a toolbar glyph that reads like a Save button.
                            Button(L10n.tr("导入 CSV…")) { presentImport(.resolveCSV) }
                                .disabled(workspace.projectID == nil || csv.operation.isRunning)
                            Divider()
                        }
                        // The File menu owns the single ⌘S registration; this item
                        // invokes the same workspace owner without competing.
                        Button(L10n.tr("任务与交班记录…")) { showsHandoff = true }
                            .disabled(workspace.selectedTaskID == nil)
                        Button(L10n.tr("保存")) { Task { try? await workspace.flush() } }
                    }
                    // A bare ellipsis: the menu indicator would be an unexplained
                    // second glyph, and the icon stays neutral like its neighbors.
                    .menuIndicator(.hidden)
                    .foregroundStyle(.secondary)
                    .help(L10n.tr("更多操作"))
                    .accessibilityIdentifier("workspace.more")
                    headerAccessory
                }
            }
        }
        // A single importer owns the workspace presentation. Multiple
        // fileImporter modifiers on the same native host can mask each other.
        .fileImporter(isPresented: $importsFile, allowedContentTypes: importKind.types, allowsMultipleSelection: importKind == .media) { selection in
            let result = selection.flatMap { urls -> Result<URL, Error> in
                guard let first = urls.first else { return .failure(CancellationError()) }; return .success(first)
            }
            let taskID = importTaskID, projectID = importProjectID, tableID = importTableID
            @MainActor func stillOwnsImport() -> Bool {
                workspace.selectedTaskID == taskID && workspace.projectID == projectID && csv.tableID == tableID && !workspace.isTransitioning
            }
            if importKind == .deliveryFolder {
                let resume = resumeDelivery
                resumeDelivery = nil
                resume?(stillOwnsImport() ? try? result.get() : nil)
                return
            }
            guard stillOwnsImport() else { return }
            switch importKind {
            case .deliveryFolder: break
            case .media:
                switch result {
                case .success: chooseMedia((try? selection.get()) ?? [])
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
                        guard stillOwnsImport() else { return }
                        await csv.importData(data, filename: url.lastPathComponent)
                    } catch { if stillOwnsImport() { csv.report(error) } }
                }
            case .slateCSV:
                Task {
                    do {
                        let url = try result.get()
                        let data = try await SecurityScopedFileReader.read(url)
                        guard stillOwnsImport(), let projectID else { return }
                        recognition.importSlateCSV(data, filename: url.lastPathComponent, projectID: projectID) {
                            try await workspace.flush()
                        }
                    } catch { if stillOwnsImport() { recognition.report(error) } }
                }
            }
        } onCancellation: {
            if importKind == .deliveryFolder { resumeDelivery?(nil); resumeDelivery = nil }
        }
        .dropDestination(for: URL.self) { urls, _ in
            guard media.canAcceptInput, !urls.isEmpty, !receivingMedia else { return false }
            chooseMedia(urls)
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
            case .input, .retryInput: .input
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
        if (kind == .slateCSV || kind == .resolveCSV), workspace.selectedTaskID == nil {
            Task {
                await workspace.createTask()
                if workspace.selectedTaskID != nil { openImporter(kind) }
            }
            return
        }
        if kind == .resolveCSV {
            do { try csv.flushEditor?() } catch { csv.report(error); return }
            if csv.manualEditCount > 0 { confirmCSVReplacement = true; return }
        }
        openImporter(kind)
    }

    private func openImporter(_ kind: ImportKind) {
        // Capture the document which opened the panel; a network volume read
        // may complete after another project, task, or CSV has been selected.
        importTaskID = workspace.selectedTaskID
        importProjectID = workspace.projectID
        importTableID = csv.tableID
        importKind = kind
        importsFile = true
    }

    /// Live task facts for the toolbar subtitle (pages · records · status);
    /// falls back to the start hint without a loaded task.
    private var headerFacts: String {
        guard let id = workspace.selectedTaskID,
              let item = workspace.tasks.first(where: { $0.id == id })
        else { return L10n.tr("新建任务或导入场记单以开始") }
        var facts: [String] = []
        if let pages = item.pageCount, pages > 0 {
            facts.append(L10n.tr("{0} 页", [String(describing: pages)]))
        }
        facts.append(L10n.tr("{0} 条", [String(describing: item.recordCount)]))
        // The subtitle follows the live operation, not the last saved status.
        if recognition.locksDisplayedTask, id == workspace.selectedTaskID {
            if let progress = recognition.progress, progress.total > 0 {
                facts.append(L10n.tr("识别中 {0}/{1}", [String(progress.completed), String(progress.total)]))
            } else {
                facts.append(L10n.tr("识别中"))
            }
        } else {
            facts.append(item.statusTitle)
        }
        return facts.joined(separator: " · ")
    }

    private var sectionPicker: some View {
        Picker(L10n.tr("工作区"), selection: sectionBinding) {
            ForEach(WorkspaceSection.allCases) { Text($0.title).tag($0) }
        }
        .pickerStyle(.segmented).labelsHidden()
        .frame(maxWidth: Self.sectionPickerWidth)
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

    /// One primary slot on the input page: start becomes cancel in the same
    /// place, both icon + label. Results have no primary action; Resolve CSV
    /// supplies its own (export) from the CSV view.
    @ViewBuilder private var recognitionAction: some View {
        if section == .input {
            if let running = recognition.runningTaskID, running != workspace.selectedTaskID {
                Button(L10n.tr("返回后台识别任务")) { Task { try? await workspace.selectTask(running) } }
            } else if recognition.operation.isRunning {
                Button(L10n.tr("取消识别"), systemImage: "xmark.circle") { recognition.cancel() }
                    .labelStyle(.titleAndIcon)
                    .help(L10n.tr("停止当前的识别"))
                    .accessibilityIdentifier(AccessibilityID.recognitionCancel)
            } else {
                Button(L10n.tr("开始识别"), systemImage: "viewfinder") {
                    if recognition.editableRecords.isEmpty { startRecognition() } else { confirmRerun = true }
                }
                    .slateToolbarPrimaryStyle()
                    .labelStyle(.titleAndIcon)
                    .help(recognitionUnavailableReason ?? L10n.tr("识别当前场记单"))
                    .disabled(!canRecognize)
                    .accessibilityIdentifier(AccessibilityID.recognize)
            }
        }
    }

    /// The page's one panel toggle, always drawn with the same trailing-panel
    /// glyph: recognition configuration on input, original comparison on results.
    @ViewBuilder private var headerAccessory: some View {
        if section == .input {
            Button(L10n.tr("识别配置"), systemImage: "sidebar.trailing") {
                changeLayout { showsConfiguration = !(showsConfiguration ?? inputLayout.opensConfiguration) }
            }
            .help(L10n.tr("显示或隐藏识别配置"))
            .accessibilityIdentifier("workspace.configuration.toggle")
        } else if section == .result {
            Toggle(L10n.tr("原稿对照"), systemImage: "sidebar.trailing", isOn: originalBinding)
                .toggleStyle(.button)
                .help(L10n.tr("显示或隐藏原稿对照"))
                .disabled(media.document == nil)
                .accessibilityIdentifier("workspace.original.toggle")
        }
    }

    @ViewBuilder private func detail(for destination: WorkspaceSection) -> some View {
        switch destination {
        case .input: inputView
        case .result: resultView
        case .csv:
            VStack(spacing: 0) {
                ResolveCSVView(
                    model: csv, recognition: recognition, workspace: workspace,
                    onImport: { presentImport(.resolveCSV) },
                    onChooseMediaDirectory: { resume in
                        resumeDelivery = resume
                        presentImport(.deliveryFolder)
                    },
                    onShowResults: { sectionBinding.wrappedValue = .result })
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
                if media.operation.isRunning {
                    SlateStatusBar(message: L10n.tr("正在准备场记单…"), busy: true) {
                        Button(L10n.tr("取消准备"), role: .cancel) { media.cancel() }
                    }
                }
                if case .failed(let error) = media.operation {
                    SlateStatusBar(message: error.message, tone: .error) {
                        Button(L10n.tr("重新选择…")) { presentImport(.media) }
                            // Recovery uses the same admission as the toolbar;
                            // recognition may still own the previous document.
                            .disabled(!media.canAcceptInput || workspace.projectID == nil)
                    }
                }
                Group {
                    if let document = media.document {
                        MediaPreviewView(document: document, pageIndex: $media.pageIndex)
                    } else {
                        SlateEmptyState(
                            title: L10n.tr("导入场记单"), symbol: "doc.viewfinder",
                            message: L10n.tr("选择或拖入 PDF、JPEG、PNG 或 WebP。每个任务最多 20 页、20 MiB；长 PDF 可分段导入。")
                        ) {
                            Button(L10n.tr("选择 PDF 或图像…")) { presentImport(.media) }
                                .disabled(!media.canAcceptInput || workspace.projectID == nil)
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
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
            // The preview follows the container's changing space; its controls
            // do not start their own inherited frame animations.
            .transaction { $0.animation = nil }
            .padding(.trailing, docked ? Self.configurationPanelWidth : 0)
            // The same form stays mounted as the column crosses the dock
            // width; only its placement changes, preserving native IME
            // drafts. The panel is always the same opaque surface so its
            // identity never depends on docked/overlay state.
            // Recognition pauses editing: only the form is frozen. The page
            // stays at full strength so the evidence is never dimmed.
            configurationPanel
                .disabled(recognition.locksDisplayedTask)
                .transaction { $0.animation = nil }
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
                // chrome stays flat.
                .shadow(color: .black.opacity(visible && !docked ? 0.22 : 0),
                        radius: visible && !docked ? 10 : 0, x: -3, y: 0)
                .offset(x: visible ? 0 : Self.configurationPanelWidth)
                .opacity(visible ? 1 : 0)
                .allowsHitTesting(visible)
                .accessibilityHidden(!visible)
        }
        .clipped()
        .animation(panelAnimation, value: visible)
        .onGeometryChange(for: InputLayout.self) {
            InputLayout(width: $0.size.width)
        } action: {
            inputLayout = $0
            // Choose the initial default once. Crossing 900 pt during either
            // sidebar animation must not also open/close a 300 pt panel and
            // reverse the preview's resize midway through that animation.
            if showsConfiguration == nil, $0.isMeasured { showsConfiguration = $0.opensConfiguration }
        }
    }

    private var configurationPanel: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                SlatePanelHeading(title: L10n.tr("识别配置"))
                // Recognition pauses editing; the lock names why the form is
                // inert without inserting a row that would move the controls.
                if recognition.operation.isRunning {
                    Image(systemName: "lock.fill").foregroundStyle(.secondary)
                        .help(L10n.tr("输入页在识别期间暂停编辑"))
                        .accessibilityLabel(L10n.tr("输入页在识别期间暂停编辑"))
                }
                Button(L10n.tr("收起"), systemImage: "chevron.right") {
                    changeLayout { showsConfiguration = false }
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .help(L10n.tr("收起识别配置，扩大预览区域"))
                    .accessibilityIdentifier("workspace.configuration.close")
            }.padding(.horizontal, density.panelPadding).padding(.vertical, 12)
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
                    // Under the model picker: a quiet, leading, borderless menu
                    // (not a second popup) with the default marker beside it.
                    HStack(spacing: 8) {
                        Menu(L10n.tr("设为默认…")) {
                            Button(L10n.tr("将当前服务商和模型设为全局默认")) {
                                guard let globalSettings else { return }
                                Task { _ = await globalSettings.setDefaultPair(providerID: providerID, modelID: modelID) }
                            }
                            .disabled(globalSettings == nil || globalSettings?.operation.isRunning == true
                                || !recognition.canRecognize(providerID: providerID, modelID: modelID))
                        }
                        .menuStyle(.borderlessButton)
                        .fixedSize()
                        if globalSettings?.live?.values[.defaultProviderID] == providerID,
                           globalSettings?.live?.values[.defaultModelID] == modelID,
                           !providerID.isEmpty {
                            Label(L10n.tr("默认"), systemImage: "checkmark").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
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
                    LabeledContent(L10n.tr("本地场记 CSV")) {
                        VStack(alignment: .leading, spacing: 4) {
                            Menu(L10n.tr("CSV 操作")) {
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
                            .fixedSize()
                            Text(recognition.slateCSVRecords.isEmpty
                                ? L10n.tr("已有结构化场记时，可直接生成结果")
                                : L10n.tr("{0} · {1} 条", [String(describing: recognition.slateCSVFilename ?? L10n.tr("场记 CSV")), String(describing: recognition.slateCSVRecords.count)]))
                                .font(.caption).foregroundStyle(.secondary)
                                .multilineTextAlignment(.leading)
                        }
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
                                .transition(.opacity.combined(with: .offset(y: 6)))
                        }
                    }
                    .animation(panelAnimation, value: showsAdvanced)
                }
            }
            .formStyle(.columns)
            .padding(.horizontal, density.panelPadding)
            .padding(.bottom, density.panelPadding)
            .frame(maxHeight: .infinity, alignment: .top)
        }
    }

    private var metadataPanel: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 10) {
                Label(L10n.tr("场记元数据"), systemImage: "folder").fontWeight(.medium)
                if metadata.operation.isRunning {
                    ProgressView().controlSize(.small)
                    if let stats = metadata.progress { Text(L10n.tr("已检查 {0} 个目录", [String(stats.visitedDirectories)])) }
                    Button(L10n.tr("取消扫描"), role: .cancel) { metadata.cancel() }
                } else {
                    Button(L10n.tr("选择目录并扫描…")) { presentImport(.metadata) }
                        .disabled(workspace.selectedTaskID == nil || csv.table == nil)
                }
                Spacer(minLength: 4)
                if let result = metadata.result {
                    Text(L10n.tr("已读取 {0} 条 · 缺少素材 {1} · 警告 {2}",
                                 [String(result.metadata.count), String(result.missingKeys.count), String(result.warnings.count)]))
                        .foregroundStyle(.secondary)
                    if result.stats.visitedDirectories > 0 {
                        Text(L10n.tr("已检查 {0} 个目录", [String(result.stats.visitedDirectories)]))
                    }
                    if !result.warnings.isEmpty || !result.missingKeys.isEmpty {
                        // Keep every finding reachable without consuming grid rows.
                        Button(L10n.tr("查看完整扫描报告")) {
                            let missing = result.missingKeys.map { L10n.tr("素材 {0} 缺少元数据", [$0]) }
                            metadataReport = WorkflowDiagnosticReport(title: L10n.tr("元数据扫描报告"),
                                messages: result.warnings.map { L10n.message($0) } + missing)
                        }
                    }
                }
            }
            if metadata.result == nil, !metadata.operation.isRunning { Text(L10n.tr("未扫描 · 支持 Kinefinity slate.txt")).foregroundStyle(.secondary) }
            if let directory = workspace.selectedTask?.slateDirectoryName {
                Text(L10n.tr("扫描来源：{0}", [directory])).textSelection(.enabled)
            }
            if case .failed(let error) = metadata.operation { SlateInlineError(error.message) }
        }
        .font(.caption).buttonStyle(.borderless)
        .padding(.horizontal, density.panelPadding).padding(.vertical, 6)
        .disabled(recognition.locksDisplayedTask)
    }

    /// A status filter keeps stable record identities while the operator edits a row.
    @ViewBuilder private var takeMarkSummary: some View {
        let records = recognition.editableRecords
        if !records.isEmpty {
            let counts: [(TakeMark.Phase, Int)] = [
                (.passed, records.count { $0.takeStatus == TakeStatus.passed.rawValue }),
                (.hold, records.count { $0.takeStatus == TakeStatus.hold.rawValue }),
                (.rejected, records.count { $0.takeStatus == TakeStatus.rejected.rawValue }),
                (.pending, records.count { $0.takeStatus.isEmpty }),
            ]
            HStack(spacing: 22) {
                ForEach(counts, id: \.0) { phase, count in
                    let status: String = switch phase { case .passed: TakeStatus.passed.rawValue; case .hold: TakeStatus.hold.rawValue; case .rejected: TakeStatus.rejected.rawValue; case .pending: "" }
                    Button { recognition.filterStatus(recognition.selectedStatus == status ? nil : status) } label: {
                        takeMarkCount(phase: phase, count: count)
                    }.buttonStyle(.borderless).foregroundStyle(recognition.selectedStatus == status ? Color.accentColor : Color.primary)
                }
                Spacer(minLength: 0)
            }
            .font(.callout)
            .padding(.horizontal, density.panelPadding)
            .padding(.vertical, 8)
            Divider()
        }
    }

    private func takeMarkCount(phase: TakeMark.Phase, count: Int) -> some View {
        HStack(spacing: 6) {
            TakeMark(phase: phase)
            Text(TakeMark.label(for: phase))
            Text(count, format: .number).foregroundStyle(.secondary).monospacedDigit()
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(L10n.tr("{0} {1}", [TakeMark.label(for: phase), String(count)]))
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
                    showPage: { page in
                        guard let count = media.document?.pages.count, (1...count).contains(page) else { return }
                        media.pageIndex = page - 1
                    },
                    onInput: { changeLayout { visit(.input) } }
                )
            }
            .transaction { $0.animation = nil }
            if let document = media.document {
                // Paging only switches the original; it never changes the result
                // selection. The close button keeps its identifier; the toolbar
                // toggle is the primary way to hide the panel.
                MediaPreviewView(document: document, pageIndex: $media.pageIndex)
                .transaction { $0.animation = nil }
                .frame(maxHeight: .infinity)
                .overlay(alignment: .topTrailing) {
                    Button(L10n.tr("关闭"), systemImage: "xmark") { changeLayout { showsOriginal = false } }
                        .labelStyle(.iconOnly).buttonStyle(.borderless)
                        .padding(8)
                        .help(L10n.tr("关闭原稿对照"))
                        .accessibilityIdentifier("workspace.original.close")
                }
                .overlay(alignment: .leading) {
                    Rectangle().fill(SlateSyncTheme.separator).frame(width: 0.5)
                }
                .opacity(showsOriginal ? 1 : 0).allowsHitTesting(showsOriginal)
                .accessibilityHidden(!showsOriginal)
            }
        }
        .clipped()
        .animation(panelAnimation, value: showsOriginal)
        .onGeometryChange(for: Int.self) {
            // 0 = first-pass ideal width (not measured), 1 = narrow, 2 = inline.
            $0.size.width >= 900 ? 2 : ($0.size.width >= 600 ? 1 : 0)
        } action: { bucket in
            guard !appliedResultDefault, bucket > 0 else { return }
            appliedResultDefault = true
            if bucket == 2, media.document != nil { showsOriginal = true }
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

    private var panelAnimation: Animation? {
        animatesPanelChanges && !reduceMotion ? SlateMotion.handoff : nil
    }

    private func routeToEntryPoint(_ destination: WorkspaceEntryPoint) {
        guard destination != .input else { return }
        if changingLayout {
            pendingEntryPoint = destination
            return
        }
        let target: WorkspaceSection = switch destination { case .resolveCSV: .csv; case .result: .result; case .input, .retryInput: .input }
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
                animatesPanelChanges = true
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
        // A feature change uses the reveal only; initial panel placement is
        // already part of that new page and must not perform a second handoff.
        animatesPanelChanges = false
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
        do { try recognition.flushEditor?() } catch { recognition.report(error); return }
        let prior = recognition.editableRecords.map(\.persisted)
        if !prior.isEmpty { workspace.updateProduction { $0.previousRecords = prior } }
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
            input: .bytes(media.originalBytes ?? firstImage.jpeg, filename: document.filename),
            filename: document.filename,
            taskID: workspace.selectedTaskID,
            providerID: providerID,
            modelID: modelID,
            settings: settings,
            slateCSVRecords: recognition.slateCSVRecords,
            preparedDocument: accuracy == .high && media.originalBytes != nil ? nil : document
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

    private func chooseMedia(_ urls: [URL]) {
        guard media.canAcceptInput, !receivingMedia, !urls.isEmpty else { return }
        let project = workspace.projectID, taskID = workspace.selectedTaskID
        receivingMedia = true
        Task {
            defer { receivingMedia = false }
            do {
                let parts = try await media.plan(urls)
                guard project == workspace.projectID, taskID == workspace.selectedTaskID else { return }
                if parts.count == 1 { receiveMedia(parts) }
                else { intakeParts = parts; showsBatch = true }
            } catch { media.report(error) }
        }
    }

    private func receiveMedia(_ parts: [MediaIntakePart]) {
        let project = workspace.projectID
        var expectedTask = workspace.selectedTaskID
        Task {
            receivingMedia = true
            defer { receivingMedia = false }
            for part in parts {
                guard project != nil, workspace.projectID == project, workspace.selectedTaskID == expectedTask,
                      media.canAcceptInput, !workspace.isTransitioning else { return }
                // Never attach a second original to an existing completed task.
                if expectedTask == nil || workspace.selectedTask?.imageDataGroups?.isEmpty == false
                    || workspace.selectedTask?.result != nil || workspace.selectedTask?.editedRecords?.isEmpty == false {
                    await workspace.createTask()
                    guard workspace.selectedTaskID != expectedTask else { return }
                }
                guard let id = workspace.selectedTaskID else { return }
                expectedTask = id
                media.select(part)
                await media.waitForPreparation()
                guard case .succeeded = media.operation, workspace.selectedTaskID == id else { return }
                do { try await workspace.flush() } catch { return }
            }
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
    let showPage: (Int) -> Void
    let onInput: () -> Void
    @State private var selected: CSVWorksheetCell?
    @State private var confirmsRemoval = false

    var body: some View {
        if !model.editableRecords.isEmpty {
            HStack {
                if let previous = workspace.selectedTask?.production?.previousRecords {
                    Menu(L10n.tr("上次校对版本")) {
                        Button(L10n.tr("恢复整个版本")) {
                            let current = model.editableRecords.map(\.persisted)
                            model.restoreReview(previous, commit: workspace.stageEditedRecords)
                            workspace.updateProduction { $0.previousRecords = current }
                        }
                        if let selected, let index = model.sourceIndex(selected.row) {
                            let current = model.editableRecords[index]
                            let matching = previous.filter { $0.cardNumber == current.cardNumber && $0.videoCode == current.videoCode }
                            if matching.count == 1, let old = matching.first {
                                Text([old.scene, old.shot, old.take, old.comments].compactMap { $0 }.joined(separator: " / "))
                                Button(L10n.tr("采用这条旧记录")) {
                                    var records = model.editableRecords.map(\.persisted)
                                    records[index] = old
                                    model.restoreReview(records, commit: workspace.stageEditedRecords)
                                }
                            }
                        }
                    }
                }
                Button(L10n.tr("补一条")) { model.addRecord(commit: workspace.stageEditedRecords) }
                    .accessibilityIdentifier("workspace.result.add")
                if let selected, let index = model.sourceIndex(selected.row) {
                    let record = model.editableRecords[index]
                    if let page = record.sourcePage { Text(L10n.tr("第 {0} 页", [String(page)])) }
                    if let confidence = record.confidence { Text(L10n.message(confidence.rawValue)) }
                    Button(L10n.tr("确认此字段")) { model.accept(selected, commit: workspace.stageEditedRecords) }
                        .disabled(!(2...5).contains(selected.column))
                    Menu(L10n.tr("条次状态")) {
                        ForEach(["", TakeStatus.passed.rawValue, TakeStatus.hold.rawValue, TakeStatus.rejected.rawValue], id: \.self) { value in
                            Button(value.isEmpty ? L10n.tr("待定") : L10n.message(value)) {
                                model.update(recordID: record.id, path: \.takeStatus, value: value, commit: workspace.stageEditedRecords)
                                model.filterStatus(model.selectedStatus)
                            }
                        }
                    }
                    Button(L10n.tr("移除此条")) { confirmsRemoval = true }
                }
                Spacer()
            }.padding(.horizontal).buttonStyle(.borderless)
             .disabled(model.locksDisplayedTask)
             .confirmationDialog(L10n.tr("移除选中的场记？"), isPresented: $confirmsRemoval) {
                 Button(L10n.tr("移除"), role: .destructive) {
                     if let selected { model.removeRecord(selected.row, commit: workspace.stageEditedRecords) }
                 }
             }
            EditableCSVTableRepresentable(
                tableID: model.resultTableID, table: model.resultTable, revision: 0,
                accessibilityLabel: L10n.tr("可编辑识别结果"),
                onCommit: { model.receiveResult($0, commit: workspace.stageEditedRecords) },
                editorRegistration: { model.flushEditor = $0 }
            )
            .onCellSelection(jump: model.resultJump) { cell in
                selected = cell
                if let cell, let index = model.sourceIndex(cell.row), let page = model.editableRecords[index].sourcePage { showPage(page) }
            }
            .onChange(of: model.resultTableID) { selected = nil }
            .onChange(of: model.resultJump, initial: true) {
                if let jump = model.resultJump, jump.tableID == model.resultTableID, let row = jump.row,
                   let index = model.sourceIndex(row) {
                    selected = .init(row: row, column: jump.column ?? 0)
                    if let page = model.editableRecords[index].sourcePage { showPage(page) }
                }
            }
            .disabled(model.locksDisplayedTask)

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
                if workspace.selectedTaskID != nil {
                    Button(L10n.tr("补一条")) { model.addRecord(commit: workspace.stageEditedRecords) }
                    .accessibilityIdentifier("workspace.result.add")
                        .disabled(model.locksDisplayedTask)
                }
            }
        }
    }

}

/// Operator labels and receipts are scoped to the same task as its source evidence.
private struct TaskHandoffView: View {
    let workspace: WorkspaceModel
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var day = ""
    @State private var unit = ""
    @State private var operatorName = ""

    var body: some View {
        Form {
            if let task = workspace.selectedTask {
                if let routes = task.pageRoutes, !routes.isEmpty {
                    DisclosureGroup(L10n.tr("逐页识别模型")) { Text(routes.joined(separator: "\n")).textSelection(.enabled) }
                }
                if let warnings = task.result?.warnings, !warnings.isEmpty {
                    DisclosureGroup(L10n.tr("识别警告")) { Text(warnings.joined(separator: "\n")).textSelection(.enabled) }
                }
            }
            LabeledContent(L10n.tr("源文件"), value: workspace.selectedTask?.filename ?? "—")
            TextField(L10n.tr("任务名称"), text: $title)
            TextField(L10n.tr("拍摄日"), text: $day)
            TextField(L10n.tr("机组"), text: $unit)
            TextField(L10n.tr("交付人"), text: $operatorName)
            Section(L10n.tr("交付记录")) {
                let receipts = workspace.selectedTask?.production?.deliveries ?? []
                if receipts.isEmpty { Text(L10n.tr("尚未交付")) }
                ForEach(receipts.reversed()) { receipt in
                    DisclosureGroup(receipt.filename) {
                        Text(receipt.date.formatted())
                        Text([receipt.source, receipt.format, receipt.operatorName].compactMap { $0 }.joined(separator: " · "))
                        Text(L10n.tr("{0} 行", [String(receipt.rows)]))
                        Text(receipt.sha256).textSelection(.enabled)
                        ShareLink(item: ([receipt.filename, receipt.date.formatted(), receipt.source ?? "", receipt.format,
                                         receipt.operatorName ?? "", String(receipt.rows), receipt.sha256] + receipt.warnings).joined(separator: "\n")) {
                            Label(L10n.tr("分享交付清单"), systemImage: "square.and.arrow.up")
                        }
                        Text(receipt.warnings.joined(separator: "\n")).textSelection(.enabled)
                    }
                }
            }
            HStack {
                Button(L10n.tr("取消")) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(L10n.tr("保存")) {
                    workspace.updateProduction { $0.title = title; $0.shootDay = day; $0.unit = unit; $0.operatorName = operatorName }
                    dismiss()
                }.keyboardShortcut(.defaultAction)
            }
        }
        .formStyle(.grouped).frame(minWidth: 460, minHeight: 360)
        .onAppear {
            let details = workspace.selectedTask?.production
            title = details?.title ?? ""; day = details?.shootDay ?? ""
            unit = details?.unit ?? ""; operatorName = details?.operatorName ?? ""
        }
    }
}

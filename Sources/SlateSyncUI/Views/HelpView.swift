import SwiftUI

public struct HelpView: View {
    @Environment(\.slateSyncDensity) private var density
    @Environment(\.openSettings) private var openSettings
    @Bindable private var model: HelpModel
    private let settingsNavigation: SettingsNavigationModel
    private let hasProject: Bool
    private let hasTask: Bool
    private let onOpenProjectLibrary: () -> Void
    private let onOpenProjectSettings: () -> Void
    private let onEnterCurrentTask: () -> Void
    private let onOpenLogs: () -> Void
    private let onOpenCSV: () -> Void

    public init(
        model: HelpModel,
        settingsNavigation: SettingsNavigationModel,
        hasProject: Bool,
        hasTask: Bool,
        onOpenProjectLibrary: @escaping () -> Void,
        onOpenProjectSettings: @escaping () -> Void,
        onEnterCurrentTask: @escaping () -> Void,
        onOpenLogs: @escaping () -> Void,
        onOpenCSV: @escaping () -> Void
    ) {
        self.model = model
        self.settingsNavigation = settingsNavigation
        self.hasProject = hasProject
        self.hasTask = hasTask
        self.onOpenProjectLibrary = onOpenProjectLibrary
        self.onOpenProjectSettings = onOpenProjectSettings
        self.onEnterCurrentTask = onEnterCurrentTask
        self.onOpenLogs = onOpenLogs
        self.onOpenCSV = onOpenCSV
    }

    public var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                // Search and language controls share one sampling group while
                // the help List remains a native navigation surface.
                SlateGlassContainer(spacing: density.rowPadding) {
                    VStack(spacing: density.rowPadding) {
                        Picker("语言 / Language", selection: $model.english) {
                            Text("简体中文").tag(false)
                            Text("English").tag(true)
                        }
                        .padding(4)
                        .slateGlassSurface(.control, interactive: true)
                        SlateSearchField(title: "搜索帮助", text: $model.query, identifier: AccessibilityID.helpSearch)
                    }
                    .padding(10)
                }
                Divider()
                List(model.results, selection: $model.selection) { section in
                    Label(model.title(section), systemImage: section.symbol)
                        .tag(section.id)
                        .padding(.vertical, density.rowPadding)
                }
            }
            .frame(minWidth: 210, idealWidth: 240, maxWidth: 300)
            Group {
                if let id = model.canonicalSectionID(model.selection),
                   let section = model.sections.first(where: { $0.id == id }) {
                    ScrollView {
                        sectionContent(section)
                            .padding(28)
                            .frame(maxWidth: 820, alignment: .leading)
                    }
                } else {
                    ContentUnavailableView(
                        model.english ? "No help found" : "未找到内容",
                        systemImage: "magnifyingglass",
                        description: Text(model.english ? "Try Provider, OCR, CSV, or logs." : "请尝试 Provider、OCR、CSV 或日志。")
                    )
                }
            }
            .frame(minWidth: 420)
        }
        .navigationTitle("帮助")
        // The help model remains mounted while Settings opens, preserving the
        // search query, selected chapter, and native scroll position.
        .safeAreaInset(edge: .bottom) {
            if let error = model.resourceError { SlateStatusBar(error, tone: .error) }
        }
        .onChange(of: model.results) {
            if !model.results.contains(where: { $0.id == model.canonicalSectionID(model.selection) }) {
                model.selection = model.results.first?.id
            }
        }
    }

    @ViewBuilder
    private func sectionContent(_ section: HelpSection) -> some View {
        VStack(alignment: .leading, spacing: 20) {
            Label(model.title(section), systemImage: section.symbol)
                .font(.title2.bold())

            ForEach(Array(model.paragraphs(section).enumerated()), id: \.offset) { _, paragraph in
                Text(paragraph)
                    .font(.body)
                    .lineSpacing(5)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if !section.steps.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    Text(model.english ? "Steps" : "操作步骤")
                        .font(.headline)
                    ForEach(Array(section.steps.enumerated()), id: \.element.id) { index, step in
                        HStack(alignment: .top, spacing: 10) {
                            Text("\(index + 1)")
                                .font(.caption.weight(.bold).monospacedDigit())
                                .foregroundStyle(.secondary)
                                .frame(width: 22, height: 22)
                                .background(SlateSyncTheme.secondary.opacity(0.12), in: .circle)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(model.stepTitle(step)).font(.subheadline.weight(.semibold))
                                Text(model.stepDetail(step))
                                    .font(.callout).foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .textSelection(.enabled)
                            }
                        }
                    }
                }
            }

            if !section.tips.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text(model.english ? "Tips" : "提示")
                        .font(.headline)
                    ForEach(section.tips) { tip in
                        Label(model.tipText(tip), systemImage: "lightbulb")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                    }
                }
            }

            if !section.faqs.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text(model.english ? "Frequently asked questions" : "常见问题")
                        .font(.headline)
                    ForEach(section.faqs) { faq in
                        DisclosureGroup(model.faqQuestion(faq)) {
                            Text(model.faqAnswer(faq))
                                .font(.callout).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                                .textSelection(.enabled)
                                .padding(.top, 4)
                        }
                    }
                }
            }

            if !section.actions.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text(model.english ? "Shortcuts" : "快捷操作")
                        .font(.headline)
                    ForEach(section.actions, id: \.self) { action in
                        actionView(action)
                    }
                }
            }

            if !section.externalLinks.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text(model.english ? "External documentation" : "外部文档")
                        .font(.headline)
                    ForEach(section.externalLinks) { link in
                        if let url = URL(string: link.url) {
                            Link("\(model.linkTitle(link)) ↗", destination: url)
                                .help(model.english ? "Open in browser" : "在浏览器中打开")
                        }
                    }
                    Text(model.english ? "External links open in your browser." : "外部链接将在浏览器中打开。")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            Divider()
            Text(model.english ? "This help is bundled with SlateSync and works offline." : "本帮助内容随 SlateSync 安装，无需网络。")
                .font(.caption).foregroundStyle(.secondary)
        }
        .textSelection(.enabled)
    }

    @ViewBuilder
    private func actionView(_ action: HelpActionID) -> some View {
        switch action {
        case .openProjectLibrary:
            Button(model.english ? "Open project library" : "打开项目库", systemImage: "square.grid.2x2", action: onOpenProjectLibrary)
        case .openProviderSettings:
            Button(model.english ? "Open Provider settings" : "打开 Provider 设置", systemImage: "slider.horizontal.3") {
                openSettingsDestination(category: .providers)
            }
        case .configureOpenRouter:
            Button(model.english ? "Configure OpenRouter" : "配置 OpenRouter", systemImage: "key") {
                openSettingsDestination(category: .providers, providerID: "openrouter")
            }
        case .openRecognitionSettings:
            Button(model.english ? "Open recognition settings" : "打开识别设置", systemImage: "slider.horizontal.3") {
                openSettingsDestination(category: .recognition)
            }
        case .openOCRSettings:
            Button(model.english ? "Open OCR settings" : "打开 OCR 设置", systemImage: "doc.text.viewfinder") {
                openSettingsDestination(category: .ocr)
            }
        case .openVisionOCR:
            Button(model.english ? "Locate Vision OCR" : "定位 Vision OCR", systemImage: "viewfinder") {
                openSettingsDestination(category: .ocr, subregion: .vision)
            }
        case .openPaddleOCR:
            Button(model.english ? "Locate PaddleOCR" : "定位 PaddleOCR", systemImage: "shippingbox") {
                openSettingsDestination(category: .ocr, subregion: .paddleOCR)
            }
        case .openProjectSettings:
            if hasProject {
                Button(model.english ? "Open current project settings" : "打开当前项目设置", systemImage: "slider.horizontal.3", action: onOpenProjectSettings)
            } else {
                unavailableAction(
                    message: model.english ? "Current project settings are unavailable until a project is open." : "当前项目设置不可用：请先打开一个项目。"
                )
            }
        case .enterCurrentTask:
            if hasTask {
                Button(model.english ? "Enter current task" : "进入当前任务", systemImage: "rectangle.3.group", action: onEnterCurrentTask)
            } else {
                unavailableAction(
                    message: model.english ? "Current task is unavailable until a project and task are open." : "当前任务不可用：请先打开项目和任务。"
                )
            }
        case .openCurrentTaskCSV:
            if hasTask {
                Button(model.english ? "Open current task Resolve CSV" : "打开当前任务的 Resolve CSV", systemImage: "tablecells", action: onOpenCSV)
            } else {
                unavailableAction(
                    message: model.english ? "Resolve CSV is unavailable until a task is open." : "Resolve CSV 不可用：请先打开一个任务。"
                )
            }
        case .openLogs:
            Button(model.english ? "Open run logs" : "打开运行日志", systemImage: "doc.text.magnifyingglass", action: onOpenLogs)
        }
    }

    private func unavailableAction(message: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Label(message, systemImage: "lock")
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button(model.english ? "Open project library" : "打开项目库", systemImage: "square.grid.2x2", action: onOpenProjectLibrary)
        }
    }

    private func openSettingsDestination(
        category: SettingsCategory,
        subregion: SettingsSubregion? = nil,
        providerID: String? = nil
    ) {
        // The app-level target is published before openSettings activates the
        // existing scene, so the Settings view has no timing guess to make.
        settingsNavigation.navigate(to: category, subregion: subregion, providerID: providerID)
        openSettings()
    }
}

import SlateSyncDomain
import SwiftUI

// Product copy uses the shared launch language; user content stays verbatim.

public struct ProjectSettingsView: View {
    @Environment(\.slateSyncDensity) private var density
    @Bindable private var model: ProjectSettingsModel
    @Bindable private var recognition: RecognitionModel
    private let projectID: String?
    private let settingsRevision: Int

    public init(
        model: ProjectSettingsModel,
        recognition: RecognitionModel,
        projectID: String?,
        settingsRevision: Int = 0
    ) {
        self.model = model
        self.recognition = recognition
        self.projectID = projectID
        self.settingsRevision = settingsRevision
    }

    public var body: some View {
        Group {
            if model.project != nil {
                Form {
                    Section(L10n.tr("项目")) {
                        TextField(L10n.tr("名称"), text: $model.name)
                            .accessibilityIdentifier("project.settings.name")
                        TextField(L10n.tr("描述"), text: $model.description, axis: .vertical)
                            .lineLimit(2...5)
                            // Vertical Form fields need an explicit accessible
                            // name because AppKit exposes the title separately.
                            .accessibilityLabel(L10n.tr("描述"))
                    }
                    Section(L10n.tr("识别上下文")) {
                        Picker("Provider", selection: providerBinding) {
                            Text(L10n.tr("请选择")).tag("")
                            if let unavailableProviderID {
                                Text(L10n.tr("不可用：{0}", [String(describing: unavailableProviderID)])).tag(unavailableProviderID)
                            }
                            ForEach(recognition.providers, id: \.id) { Text(L10n.providerLabel($0)).tag($0.id) }
                        }
                        Picker(L10n.tr("模型"), selection: optionalBinding(\.modelId)) {
                            Text(L10n.tr("请选择")).tag("")
                            if let unavailableModelID {
                                Text(L10n.tr("不可用：{0}", [String(describing: unavailableModelID)])).tag(unavailableModelID)
                            }
                            ForEach(
                                recognition.availableModels(
                                    providerID: model.settings.providerId ?? ""
                                ), id: \.id
                            ) { Text($0.label).tag($0.id) }
                        }
                        if unavailableProviderID != nil || unavailableModelID != nil {
                            LabeledContent(L10n.tr("已保存的识别选项不可用"), value: L10n.tr("请选择可用项或先在全局设置中完成配置"))
                        }
                        Picker(L10n.tr("精度"), selection: $model.settings.accuracyMode) {
                            Text(L10n.tr("标准")).tag(ProjectSettings.AccuracyMode.standard)
                            Text(L10n.tr("高精度")).tag(ProjectSettings.AccuracyMode.high)
                        }
                        Picker(L10n.tr("场记版式（Scenario）"), selection: optionalBinding(\.scenarioId)) {
                            Text(L10n.tr("自动匹配")).tag("")
                            ForEach(model.scenarios, id: \.id) { Text($0.label).tag($0.id) }
                        }
                        TextField(L10n.tr("自定义提示词"), text: $model.settings.customPrompt, axis: .vertical)
                            .lineLimit(3...8)
                            .accessibilityLabel(L10n.tr("自定义提示词"))
                    }
                    Section(L10n.tr("Resolve 格式")) {
                        TextField(L10n.tr("场"), text: $model.settings.resolve.fieldFormats.scene)
                        TextField(L10n.tr("镜"), text: $model.settings.resolve.fieldFormats.shot)
                        TextField(L10n.tr("条"), text: $model.settings.resolve.fieldFormats.take)
                        TextField(L10n.tr("好条标记"), text: $model.settings.resolve.comments.goodTake)
                        TextField(L10n.tr("保条标记"), text: $model.settings.resolve.comments.holdTake)
                    }
                }
                // Keep long project forms scrollable at the minimum height.
                .formStyle(.grouped)
                .padding(.horizontal, density == .compact ? 0 : 8)
                .disabled(model.operation.isRunning)
            } else if projectID != nil {
                // A project already exists while its options are loading;
                // avoid flashing the unrelated "no open project" empty state.
                if case .failed = model.operation {
                    ContentUnavailableView(L10n.tr("无法读取项目设置"), systemImage: "exclamationmark.triangle")
                        .tint(Color.secondary)
                } else {
                    ProgressView(L10n.tr("正在读取项目设置…"))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            } else {
                ContentUnavailableView(
                    L10n.tr("未打开项目"), systemImage: "slider.horizontal.3", description: Text(L10n.tr("请先从项目库打开一个活跃项目。")))
                    .tint(Color.secondary)
            }
        }
        .navigationTitle(L10n.tr("项目设置"))
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button(L10n.tr("保存"), systemImage: "square.and.arrow.down") { Task { await model.save() } }
                    .slatePrimaryActionStyle()
                    .disabled(model.project == nil || model.operation.isRunning)
            }
        }
        .safeAreaInset(edge: .bottom) {
            if case .failed(let error) = model.operation {
                SlateStatusBar(message: error.message, tone: .error) {
                    Button(model.project == nil ? L10n.tr("重试读取") : L10n.tr("重试保存")) {
                        Task {
                            if model.project == nil {
                                await model.load(projectID: projectID)
                            } else {
                                await model.save()
                            }
                        }
                    }.disabled(model.operation.isRunning)
                }
            } else if case .succeeded(let message) = model.operation,
                let project = model.project, model.name == project.name,
                model.description == project.description, model.settings == project.settings
            {
                // A successful save describes only that snapshot; hide the
                // acknowledgement as soon as the user creates another draft.
                SlateStatusBar(message, tone: .success)
            }
        }
        .task(id: projectID) {
            await recognition.loadOptions()
            await model.load(projectID: projectID)
        }
        .onChange(of: settingsRevision) {
            // Global Settings is an independent scene, so this route remains
            // mounted while Provider availability changes in another window.
            Task { await recognition.loadOptions() }
        }
    }

    private var unavailableProviderID: String? {
        guard let id = model.settings.providerId, !id.isEmpty,
            !recognition.providers.contains(where: { $0.id == id })
        else { return nil }
        return id
    }

    private var unavailableModelID: String? {
        guard let id = model.settings.modelId, !id.isEmpty,
            !recognition.availableModels(providerID: model.settings.providerId ?? "")
                .contains(where: { $0.id == id })
        else { return nil }
        return id
    }

    private var providerBinding: Binding<String> {
        Binding(
            get: { model.settings.providerId ?? "" },
            set: { value in
                // A deliberate Provider change clears an incompatible model;
                // loading a stale draft never substitutes a different choice.
                let selection = RecognitionOptionSelection.selectingProvider(
                    value,
                    currentModelID: model.settings.modelId ?? "",
                    availableModels: recognition.availableModels(providerID: value)
                )
                model.settings.providerId = selection.providerID.isEmpty ? nil : selection.providerID
                model.settings.modelId = selection.modelID.isEmpty ? nil : selection.modelID
            }
        )
    }

    private func optionalBinding(_ path: WritableKeyPath<ProjectSettings, String?>) -> Binding<String> {
        Binding(
            get: { model.settings[keyPath: path] ?? "" },
            set: { model.settings[keyPath: path] = $0.isEmpty ? nil : $0 }
        )
    }
}

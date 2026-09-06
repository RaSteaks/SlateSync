import SlateSyncDomain
import SwiftUI

public struct ProjectSettingsView: View {
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
                    Section("项目") {
                        TextField("名称", text: $model.name)
                        TextField("描述", text: $model.description, axis: .vertical).lineLimit(2...5)
                    }
                    Section("识别上下文") {
                        Picker("Provider", selection: providerBinding) {
                            Text("请选择").tag("")
                            if let unavailableProviderID {
                                Text("不可用：\(unavailableProviderID)").tag(unavailableProviderID)
                            }
                            ForEach(recognition.providers, id: \.id) { Text($0.label).tag($0.id) }
                        }
                        Picker("模型", selection: optionalBinding(\.modelId)) {
                            Text("请选择").tag("")
                            if let unavailableModelID {
                                Text("不可用：\(unavailableModelID)").tag(unavailableModelID)
                            }
                            ForEach(recognition.availableModels(
                                providerID: model.settings.providerId ?? ""
                            ), id: \.id) { Text($0.label).tag($0.id) }
                        }
                        if unavailableProviderID != nil || unavailableModelID != nil {
                            LabeledContent("已保存的识别选项不可用", value: "请选择可用项或先在全局设置中完成配置")
                        }
                        Picker("精度", selection: $model.settings.accuracyMode) {
                            Text("标准").tag(ProjectSettings.AccuracyMode.standard)
                            Text("高精度").tag(ProjectSettings.AccuracyMode.high)
                        }
                        Picker("场记版式（Scenario）", selection: optionalBinding(\.scenarioId)) {
                            Text("自动匹配").tag("")
                            ForEach(model.scenarios, id: \.id) { Text($0.label).tag($0.id) }
                        }
                        TextField("自定义提示词", text: $model.settings.customPrompt, axis: .vertical)
                            .lineLimit(3...8)
                    }
                    Section("Resolve 格式") {
                        TextField("场", text: $model.settings.resolve.fieldFormats.scene)
                        TextField("镜", text: $model.settings.resolve.fieldFormats.shot)
                        TextField("条", text: $model.settings.resolve.fieldFormats.take)
                        TextField("好条标记", text: $model.settings.resolve.comments.goodTake)
                        TextField("保条标记", text: $model.settings.resolve.comments.holdTake)
                    }
                }
                .formStyle(.grouped)
                .disabled(model.operation.isRunning)
            } else {
                ContentUnavailableView("未打开项目", systemImage: "slider.horizontal.3", description: Text("请先从项目库打开一个活跃项目。"))
            }
        }
        .navigationTitle("项目设置")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("保存", systemImage: "square.and.arrow.down") { Task { await model.save() } }
                    .disabled(model.project == nil || model.operation.isRunning)
            }
        }
        .safeAreaInset(edge: .bottom) {
            if case .failed(let error) = model.operation {
                Label(error.message, systemImage: "exclamationmark.triangle")
                    .padding(10).frame(maxWidth: .infinity, alignment: .leading).background(.bar)
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
              !recognition.providers.contains(where: { $0.id == id }) else { return nil }
        return id
    }

    private var unavailableModelID: String? {
        guard let id = model.settings.modelId, !id.isEmpty,
              !recognition.availableModels(providerID: model.settings.providerId ?? "")
                .contains(where: { $0.id == id }) else { return nil }
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

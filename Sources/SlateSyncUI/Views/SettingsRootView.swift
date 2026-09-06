import SlateSyncDomain
import SwiftUI

public struct SettingsRootView: View {
    @AppStorage("appearance") private var appearance = "system"
    @AppStorage("density") private var density = "comfortable"
    @Bindable private var settings: GlobalSettingsModel
    @Bindable private var paddleInstaller: PaddleInstallerModel
    @State private var credentialProvider: ProviderSummary?
    @State private var showsCustomProvider = false
    @State private var providerPendingDeletion: CustomProviderConfiguration?
    @State private var providerEditing: CustomProviderConfiguration?

    public init(settings: GlobalSettingsModel, paddleInstaller: PaddleInstallerModel) {
        self.settings = settings
        self.paddleInstaller = paddleInstaller
    }

    public var body: some View {
        TabView {
            general.tabItem { Label("通用", systemImage: "gearshape") }
            providers.tabItem { Label("Provider", systemImage: "network") }
            recognition.tabItem { Label("识别", systemImage: "viewfinder") }
            ocr.tabItem { Label("OCR", systemImage: "text.viewfinder") }
            advanced.tabItem { Label("高级", systemImage: "externaldrive") }
        }
        .padding()
        .frame(width: 700, height: 540)
        .preferredColorScheme(appearance == "dark" ? .dark : appearance == "light" ? .light : nil)
        .controlSize(density == "compact" ? .small : .regular)
        .task { await settings.load() }
        .onChange(of: paddleInstaller.operation) {
            // Installation changes the persisted Python path outside this
            // form; merge that result without replacing unrelated user edits.
            if case .succeeded = paddleInstaller.operation { Task { await settings.refresh() } }
        }
        .sheet(isPresented: Binding(
            get: { credentialProvider != nil },
            set: { if !$0 { credentialProvider = nil } }
        )) {
            if let provider = credentialProvider {
                CredentialSheet(settings: settings, provider: provider)
            }
        }
        .sheet(isPresented: $showsCustomProvider) {
            CustomProviderSheet(settings: settings)
        }
        .sheet(isPresented: Binding(
            get: { providerEditing != nil },
            set: { if !$0 { providerEditing = nil } }
        )) {
            if let providerEditing {
                CustomProviderSheet(settings: settings, provider: providerEditing)
            }
        }
        .confirmationDialog(
            "删除自定义 Provider？",
            isPresented: Binding(
                get: { providerPendingDeletion != nil },
                set: { if !$0 { providerPendingDeletion = nil } }
            ),
            titleVisibility: .visible
        ) {
            if let provider = providerPendingDeletion {
                Button("删除“\(provider.name)”", role: .destructive) {
                    providerPendingDeletion = nil
                    Task { await settings.removeCustomProvider(id: provider.id) }
                }
            }
            Button("取消", role: .cancel) { providerPendingDeletion = nil }
        } message: {
            Text("删除后需要保存 Provider 设置才会持久化。")
        }
        .safeAreaInset(edge: .bottom) {
            if case .failed(let error) = settings.operation {
                Label(error.message, systemImage: "exclamationmark.triangle")
                    .padding(10).frame(maxWidth: .infinity, alignment: .leading).background(.bar)
            }
        }
    }

    private var general: some View {
        Form {
            Picker("外观", selection: $appearance) {
                Text("跟随系统").tag("system"); Text("浅色").tag("light"); Text("深色").tag("dark")
            }
            Picker("界面密度", selection: $density) {
                Text("舒适").tag("comfortable"); Text("紧凑").tag("compact")
            }
        }.formStyle(.grouped)
    }

    private var providers: some View {
        VStack(spacing: 0) {
            List {
                Section("内建 Provider") {
                    ForEach((settings.live?.providers ?? []).filter { $0.type != .custom }, id: \.id) { provider in
                        HStack {
                            VStack(alignment: .leading) {
                                Text(provider.label)
                                Text(provider.id).font(.caption.monospaced()).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Label(
                                settings.live?.configuredCredentialProviderIDs.contains(provider.id) == true ? "已配置" : "缺失",
                                systemImage: settings.live?.configuredCredentialProviderIDs.contains(provider.id) == true ? "checkmark.circle.fill" : "exclamationmark.circle"
                            ).foregroundStyle(settings.live?.configuredCredentialProviderIDs.contains(provider.id) == true ? .green : .secondary)
                            Button("刷新模型") { Task { await settings.discover(providerID: provider.id) } }
                                .disabled(settings.providerOperations[provider.id]?.isRunning == true || !provider.configured)
                            Button("管理凭据…") { credentialProvider = provider }
                        }
                        providerStatus(provider.id)
                    }
                }
                Section("自定义 Provider") {
                    ForEach(settings.customProviders, id: \.id) { provider in
                        HStack {
                            VStack(alignment: .leading) {
                                Text(provider.label ?? provider.name)
                                Text(provider.baseUrl).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1)
                            }
                            Spacer()
                            if let summary = settings.live?.providers.first(where: { $0.id == provider.id }) {
                                Button("刷新模型") { Task { await settings.discover(providerID: provider.id) } }
                                    .disabled(settings.providerOperations[provider.id]?.isRunning == true || !summary.configured)
                                Button("管理凭据…") { credentialProvider = summary }
                            }
                            Button("编辑…") { providerEditing = provider }
                            Button("删除…", role: .destructive) { providerPendingDeletion = provider }
                        }
                        providerStatus(provider.id)
                    }
                    Button("添加自定义 Provider…", systemImage: "plus") { showsCustomProvider = true }
                }
            }
            HStack {
                Spacer(); Button("保存 Provider 设置") { Task { await settings.save() } }
                    .disabled(settings.operation.isRunning)
            }.padding(10)
        }
    }

    private var recognition: some View {
        Form {
            Section("请求") {
                settingField("请求超时（毫秒）", .modelRequestTimeoutMS)
                settingField("超时重试次数", .modelRequestMaxRetries)
                settingField("页并发数", .modelPageConcurrency)
                settingField("全局识别并发数", .maxConcurrentRecognitions)
            }
            Section("模型") {
                LabeledContent("可用模型", value: "\(settings.live?.models.count ?? 0)")
            }
            Button("保存") { Task { await settings.save() } }.disabled(settings.operation.isRunning)
        }.formStyle(.grouped)
    }

    private var ocr: some View {
        Form {
            Section("Vision") {
                LabeledContent("可用性", value: settings.live?.visionAvailable == true ? "可用" : "不可用")
                settingPicker("启用策略", .visionOCREnabled, [("自动", "auto"), ("启用", "true"), ("禁用", "false")])
                settingField("语言", .visionOCRLanguage)
                settingPicker("识别级别", .visionOCRRecognitionLevel, [("精准", "accurate"), ("快速", "fast")])
            }
            Section("Paddle OCR") {
                LabeledContent("可用性", value: settings.live?.paddleAvailable == true ? "可用" : "未配置")
                settingPicker("启用策略", .paddleOCREnabled, [("自动", "auto"), ("启用", "true"), ("禁用", "false")])
                settingPicker("预设", .paddleOCRPreset, [("自定义", "custom"), ("性能", "performance"), ("平衡", "balanced"), ("快速", "fast")])
                settingPicker("配置档", .paddleOCRProfile, [("快速", "fast"), ("平衡", "balanced"), ("精准", "accurate")])
                settingField("Python 可执行文件", .paddleOCRPython)
                settingField("语言", .paddleOCRLanguage)
                Text("自动安装需要 Python 3.10+，安装过程不会在测试中联网。")
                    .font(.caption).foregroundStyle(.secondary)
                if let progress = paddleInstaller.progress {
                    ProgressView(value: progress.percent, total: 100) { Text(progress.message) }
                }
                HStack {
                    Button(settings.live?.paddleAvailable == true ? "重新安装 PaddleOCR" : "安装 PaddleOCR") {
                        paddleInstaller.install()
                    }.disabled(paddleInstaller.operation.isRunning)
                    if paddleInstaller.operation.isRunning {
                        Button("取消", role: .cancel) { paddleInstaller.cancel() }
                    }
                }
            }
            Button("保存") { Task { await settings.save() } }.disabled(settings.operation.isRunning)
        }.formStyle(.grouped)
    }

    private var advanced: some View {
        Form {
            Section("存储") { settingField("全局配置路径", .slateSyncConfigPath) }
            if let snapshot = settings.live?.runtime {
                Section("原生启动状态") {
                    LabeledContent("配置项", value: "\(snapshot.resolvedSettingCount)")
                    LabeledContent("配置版本", value: "\(snapshot.globalConfigVersion)")
                    LabeledContent("旧凭据迁移", value: migrationStatus(snapshot.migrationStatus))
                    if snapshot.migrationStatus == .failed {
                        Button("重试旧凭据迁移") { Task { await settings.retryLegacyCredentialMigration() } }
                    }
                }
            }
            Button("保存") { Task { await settings.save() } }.disabled(settings.operation.isRunning)
        }.formStyle(.grouped)
    }

    private func settingField(_ title: String, _ key: GlobalSettingKey) -> some View {
        TextField(title, text: Binding(get: { settings.value(key) }, set: { settings.setValue($0, for: key) }))
    }

    private func settingPicker(
        _ title: String,
        _ key: GlobalSettingKey,
        _ options: [(label: String, value: String)]
    ) -> some View {
        Picker(title, selection: Binding(
            get: { settings.value(key) },
            set: { settings.setValue($0, for: key) }
        )) {
            ForEach(options, id: \.value) { Text($0.label).tag($0.value) }
        }
    }

    @ViewBuilder private func providerStatus(_ providerID: String) -> some View {
        if let result = settings.discoveryResults[providerID] {
            HStack {
                Text("可用 \(result.visionModelCount)")
                if let pending = result.pendingModels, !pending.isEmpty {
                    Button("验证 \(pending.count) 个候选模型") {
                        Task { await settings.probe(
                            providerID: providerID,
                            modelIDs: pending.map { $0.apiId ?? $0.id }
                        ) }
                    }
                }
                if settings.probingProviderIDs.contains(providerID) {
                    Button("取消", role: .cancel) {
                        Task { await settings.cancelProbe(providerID: providerID) }
                    }
                }
                if let warning = result.warning { Text(warning).foregroundStyle(.secondary).lineLimit(2) }
            }
            .font(.caption)
        } else if case .failed(let error) = settings.providerOperations[providerID] {
            Text(error.message).font(.caption).foregroundStyle(.red)
        }
    }

    private func migrationStatus(_ status: LegacyCredentialMigrationStatus) -> String {
        switch status { case .notRun: "未运行"; case .sourceMissing: "未发现旧凭据"; case .noCredentials: "无可迁移凭据"; case .migrated: "已完成"; case .failed: "失败" }
    }
}

private struct CredentialSheet: View {
    let settings: GlobalSettingsModel
    let provider: ProviderSummary
    @Environment(\.dismiss) private var dismiss
    @State private var credential = ""
    @State private var error: SlateSyncError?
    @State private var isSubmitting = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("\(provider.label) 凭据").font(.title2.bold())
            Text("凭据仅保存在 macOS 钥匙串，保存后不会回显。").foregroundStyle(.secondary)
            SecureField("新凭据", text: $credential)
            if let error { Text(error.message).foregroundStyle(.red) }
            HStack {
                Button("清除凭据", role: .destructive) { submit(nil) }
                Spacer()
                Button("取消", role: .cancel) { dismiss() }
                Button("保存") { submit(credential) }.disabled(credential.isEmpty)
            }
        }
        .padding(24).frame(width: 460)
        .disabled(isSubmitting)
        .interactiveDismissDisabled(isSubmitting)
        .onDisappear { credential = "" }
    }

    private func submit(_ value: String?) {
        guard !isSubmitting else { return }
        // Keep the sheet alive until Keychain acknowledges the one submission.
        isSubmitting = true
        credential = ""
        Task {
            defer { isSubmitting = false }
            do { try await settings.storeCredential(value, providerID: provider.id); credential = ""; dismiss() }
            catch { self.error = ProductPrivacy.error(error); credential = "" }
        }
    }
}

private struct CustomProviderSheet: View {
    let settings: GlobalSettingsModel
    let provider: CustomProviderConfiguration?
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var baseURL: String
    @State private var modelIDs: String
    @State private var transport: ProviderTransport
    @State private var jsonMode: ProviderJSONMode
    @State private var imageDetail: ImageDetail

    init(settings: GlobalSettingsModel, provider: CustomProviderConfiguration? = nil) {
        self.settings = settings
        self.provider = provider
        _name = State(initialValue: provider?.name ?? "")
        _baseURL = State(initialValue: provider?.baseUrl ?? "")
        _modelIDs = State(initialValue: provider?.manualModelIds.joined(separator: ", ") ?? "")
        _transport = State(initialValue: provider?.transport ?? .chatCompletions)
        _jsonMode = State(initialValue: provider?.jsonMode ?? .jsonSchema)
        _imageDetail = State(initialValue: provider?.imageDetail ?? .high)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(provider == nil ? "添加自定义 Provider" : "编辑自定义 Provider").font(.title2.bold())
            Form {
                TextField("名称", text: $name)
                TextField("HTTP(S) Base URL", text: $baseURL)
                TextField("手动模型 ID（逗号分隔）", text: $modelIDs)
                Picker("传输", selection: $transport) {
                    Text("Chat Completions").tag(ProviderTransport.chatCompletions)
                    Text("Responses").tag(ProviderTransport.responses)
                }
                Picker("JSON 模式", selection: $jsonMode) {
                    Text("JSON Schema").tag(ProviderJSONMode.jsonSchema)
                    Text("JSON Object").tag(ProviderJSONMode.jsonObject)
                    Text("Prompt").tag(ProviderJSONMode.prompt)
                }
                Picker("图像细节", selection: $imageDetail) {
                    Text("自动").tag(ImageDetail.auto)
                    Text("低").tag(ImageDetail.low)
                    Text("高").tag(ImageDetail.high)
                    Text("原始").tag(ImageDetail.original)
                }
            }
            if case .failed(let error) = settings.operation {
                Label(error.message, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red)
            }
            HStack {
                Spacer(); Button("取消", role: .cancel) { dismiss() }
                Button(provider == nil ? "添加" : "保存") {
                    Task {
                        if await settings.saveCustomProvider(
                            existing: provider,
                            name: name,
                            baseURL: baseURL,
                            modelIDs: modelIDs,
                            transport: transport,
                            jsonMode: jsonMode,
                            imageDetail: imageDetail
                        ) { dismiss() }
                    }
                }
            }
        }.padding(24).frame(width: 500)
    }
}

import SlateSyncDomain
import SlateSyncWorkflow
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
    @State private var category = SettingsCategory.general
    @State private var focusedOCRSubregion: SettingsSubregion?
    @State private var highlightedOCRSubregion: SettingsSubregion?
    private let navigation: SettingsNavigationModel

    public init(
        settings: GlobalSettingsModel,
        paddleInstaller: PaddleInstallerModel,
        navigation: SettingsNavigationModel
    ) {
        self.settings = settings
        self.paddleInstaller = paddleInstaller
        self.navigation = navigation
    }

    public var body: some View {
        // A native segmented category selector keeps the five existing forms
        // inside one flexible content host. macOS 15's special Settings TabView
        // host otherwise forces its ideal size into fixed window constraints.
        VStack(spacing: 0) {
            Picker("设置分类", selection: $category) {
                ForEach(SettingsCategory.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented).labelsHidden()
            .accessibilityIdentifier("settings.category")
            .padding(density == "compact" ? 12 : 20)
            Divider()
            Group {
                switch category {
                case .general: general
                case .providers: providers
                case .recognition: recognition
                case .ocr: ocr
                case .advanced: advanced
                }
            }
            .padding(density == "compact" ? 12 : 20)
        }
        .slateWindowMinimumSize(width: 700, height: 540)
        .navigationTitle("设置")
        .tint(SlateSyncTheme.accent)
        .preferredColorScheme(appearance == "dark" ? .dark : appearance == "light" ? .light : nil)
        .controlSize(density == "compact" ? .small : .regular)
        // One scene-level preference drives native controls and content metrics.
        .environment(\.slateSyncDensity, SlateSyncDensity(rawValue: density) ?? .comfortable)
        .task {
            await settings.load()
            processPendingNavigation()
        }
        .onChange(of: navigation.pendingRequest) {
            processPendingNavigation()
        }
        .onChange(of: credentialProvider?.id) {
            processPendingNavigation()
        }
        .onChange(of: showsCustomProvider) {
            processPendingNavigation()
        }
        .onChange(of: providerEditing?.id) {
            processPendingNavigation()
        }
        .onChange(of: paddleInstaller.operation) {
            // Installation changes the persisted Python path outside this
            // form; merge that result without replacing unrelated user edits.
            if case .succeeded = paddleInstaller.operation { Task { await settings.refresh() } }
        }
        .sheet(
            isPresented: Binding(
                get: { credentialProvider != nil },
                set: { if !$0 { credentialProvider = nil } }
            )
        ) {
            if let provider = credentialProvider {
                if let definition = ProviderCatalog.definition(id: provider.id) {
                    BuiltinProviderConfigurationSheet(
                        settings: settings,
                        provider: provider,
                        definition: definition
                    )
                } else {
                    CredentialSheet(settings: settings, provider: provider)
                }
            }
        }
        .sheet(isPresented: $showsCustomProvider) {
            CustomProviderSheet(settings: settings)
        }
        .sheet(
            isPresented: Binding(
                get: { providerEditing != nil },
                set: { if !$0 { providerEditing = nil } }
            )
        ) {
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
                SlateStatusBar(error.message, tone: .error)
            }
        }
    }

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Help navigation is consumed only after the Settings scene can resolve
    /// its typed destination. If another sheet is editing, the request stays
    /// pending and is retried by the sheet-state observers above.
    private func processPendingNavigation() {
        guard let request = navigation.pendingRequest,
              credentialProvider == nil,
              !showsCustomProvider,
              providerEditing == nil else { return }

        if let providerID = request.providerID {
            let provider = settings.live?.providers.first { $0.id == providerID }
                ?? ProviderCatalog.definition(id: providerID).map {
                    ProviderSummary(
                        id: $0.id,
                        label: $0.label,
                        configured: false,
                        type: .builtin,
                        editable: $0.kind == .openAICompatible
                    )
                }
            guard let provider else { return }
            credentialProvider = provider
        }

        category = request.category
        if let subregion = request.subregion {
            focusedOCRSubregion = subregion
            highlightedOCRSubregion = subregion
            guard !reduceMotion else {
                navigation.consume(request)
                return
            }
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(1_200))
                if highlightedOCRSubregion == subregion {
                    highlightedOCRSubregion = nil
                }
            }
        }
        navigation.consume(request)
    }

    private var general: some View {
        Form {
            Picker("外观", selection: $appearance) {
                Text("跟随系统").tag("system")
                Text("浅色").tag("light")
                Text("深色").tag("dark")
            }
            // macOS Form presents picker titles as sibling static text, so
            // explicitly name the interactive controls for VoiceOver/XCUI.
            .accessibilityLabel("外观")
            .accessibilityIdentifier(AccessibilityID.settingsAppearance)
            Picker("界面密度", selection: $density) {
                Text("舒适").tag("comfortable")
                Text("紧凑").tag("compact")
            }
            .accessibilityLabel("界面密度")
            .accessibilityIdentifier(AccessibilityID.settingsDensity)
        }.formStyle(.grouped)
    }

    /// Authorization and read failures remain visible instead of claiming that
    /// a stored credential is absent. The shared chip pairs every state with
    /// a symbol so color is never the only signal (DESIGN.md 2026-09-11).
    private func credentialStatusChip(_ id: String) -> some View {
        let state = settings.live?.credentialStatuses[id]
            ?? (settings.live?.configuredCredentialProviderIDs.contains(id) == true ? .configured : .missing)
        let chip: CredentialChip.State = switch state {
        case .configured: .configured
        case .missing: .missing
        case .authorizationRequired: .needsAuthorization
        case .unavailable: .readFailed
        }
        return CredentialChip(chip)
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
                            credentialStatusChip(provider.id)
                            Button("刷新模型") { Task { await settings.discover(providerID: provider.id) } }
                                .disabled(
                                    settings.providerOperations[provider.id]?.isRunning == true || !provider.configured)
                            Button("配置…") { credentialProvider = provider }
                        }
                        providerStatus(provider.id)
                    }
                }
                Section("自定义 Provider") {
                    ForEach(settings.customProviders, id: \.id) { provider in
                        HStack {
                            VStack(alignment: .leading) {
                                Text(provider.label ?? provider.name)
                                Text(provider.baseUrl).font(.caption.monospaced()).foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            Spacer()
                            if let summary = settings.live?.providers.first(where: { $0.id == provider.id }) {
                                Button("刷新模型") { Task { await settings.discover(providerID: provider.id) } }
                                    .disabled(
                                        settings.providerOperations[provider.id]?.isRunning == true
                                            || !summary.configured)
                                Button("配置…") { credentialProvider = summary }
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
                Spacer()
                Button("保存 Provider 设置") { Task { await settings.save() } }
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
        ScrollViewReader { proxy in
            Form {
                Section("Vision") {
                    LabeledContent("可用性", value: settings.live?.visionAvailable == true ? "可用" : "不可用")
                    settingPicker("启用策略", .visionOCREnabled, [("自动", "auto"), ("启用", "true"), ("禁用", "false")])
                    settingField("语言", .visionOCRLanguage)
                    settingPicker("识别级别", .visionOCRRecognitionLevel, [("精准", "accurate"), ("快速", "fast")])
                }
                .id(SettingsSubregion.vision.rawValue)
                Section("Paddle OCR") {
                    LabeledContent("可用性", value: settings.live?.paddleAvailable == true ? "可用" : "未配置")
                    settingPicker("启用策略", .paddleOCREnabled, [("自动", "auto"), ("启用", "true"), ("禁用", "false")])
                    settingPicker(
                        "预设", .paddleOCRPreset,
                        [("自定义", "custom"), ("性能", "performance"), ("平衡", "balanced"), ("快速", "fast")])
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
                .id(SettingsSubregion.paddleOCR.rawValue)
                Button("保存") { Task { await settings.save() } }.disabled(settings.operation.isRunning)
            }
            .formStyle(.grouped)
            .onAppear {
                // The target can be published before the OCR branch is
                // mounted; onAppear handles that first render without a
                // timing delay and onChange handles subsequent requests.
                scrollOCR(using: proxy)
            }
            .onChange(of: focusedOCRSubregion) {
                scrollOCR(using: proxy)
            }
            .overlay(alignment: .top) {
                if let highlightedOCRSubregion {
                    Text(highlightedOCRSubregion == .vision ? "已定位到 Vision" : "已定位到 Paddle OCR")
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(SlateSyncTheme.accent.opacity(0.16), in: .capsule)
                        .padding(.top, 6)
                        .accessibilityLabel("已定位到\(highlightedOCRSubregion == .vision ? " Vision" : " Paddle OCR")")
                }
            }
        }
    }

    private func scrollOCR(using proxy: ScrollViewProxy) {
        guard let subregion = focusedOCRSubregion else { return }
        let scroll = {
            proxy.scrollTo(subregion.rawValue, anchor: .top)
            focusedOCRSubregion = nil
        }
        if reduceMotion {
            scroll()
        } else {
            withAnimation(.easeInOut(duration: 0.2), scroll)
        }
    }

    private var advanced: some View {
        Form {
            Section("存储") {
                // Old renderer row: label + hint. The field edits the
                // configured value; the effective path below is resolved at
                // startup and only changes after a restart.
                settingField("工作流配置路径", .slateSyncConfigPath)
                Text("开发环境读取；修改后下次启动生效。")
                    .font(.caption).foregroundStyle(.secondary)
                if let workflowPath = settings.live?.runtime.workflowConfigPath {
                    LabeledContent("实际生效路径") {
                        Text(workflowPath)
                            .font(.caption.monospaced())
                            .lineLimit(1)
                            .truncationMode(.head)
                            .help(workflowPath)
                    }
                }
                if settings.live?.restartRequired == true {
                    Text("工作流配置路径已修改，重启 SlateSync 后生效。")
                        .font(.caption).foregroundStyle(.yellow)
                }
            }
            if let snapshot = settings.live?.runtime {
                Section("原生启动状态") {
                    LabeledContent("配置项", value: "\(snapshot.resolvedSettingCount)")
                    LabeledContent("配置版本", value: "\(snapshot.globalConfigVersion)")
                    LabeledContent("旧凭据迁移", value: migrationStatus(snapshot.migrationStatus))
                    if snapshot.migrationStatus == .failed || snapshot.migrationStatus == .awaitingAuthorization {
                        Button(snapshot.migrationStatus == .awaitingAuthorization ? "迁移旧凭据" : "重试旧凭据迁移") { Task { await settings.retryLegacyCredentialMigration() } }
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
        Picker(
            title,
            selection: Binding(
                get: { settings.value(key) },
                set: { settings.setValue($0, for: key) }
            )
        ) {
            ForEach(options, id: \.value) { Text($0.label).tag($0.value) }
        }
    }

    @ViewBuilder private func providerStatus(_ providerID: String) -> some View {
        if let result = settings.discoveryResults[providerID] {
            HStack {
                Text("可用 \(result.visionModelCount)")
                if let pending = result.pendingModels, !pending.isEmpty {
                    Button("验证 \(pending.count) 个候选模型") {
                        Task {
                            await settings.probe(
                                providerID: providerID,
                                modelIDs: pending.map { $0.apiId ?? $0.id }
                            )
                        }
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
            Text(error.message).font(.caption).foregroundStyle(SlateSyncTheme.danger)
        }
    }

    private func migrationStatus(_ status: LegacyCredentialMigrationStatus) -> String {
        switch status {
        case .notRun: "未运行"
        case .awaitingAuthorization: "等待手动迁移"
        case .sourceMissing: "未发现旧凭据"
        case .noCredentials: "无可迁移凭据"
        case .migrated: "已完成"
        case .failed: "失败"
        }
    }
}

/// Built-in Providers share one guided form. It deliberately keeps the API
/// Key write separate from ordinary settings and never asks the service for a
/// previously stored secret.
private struct BuiltinProviderConfigurationSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable private var settings: GlobalSettingsModel
    @Environment(\.slateSyncDensity) private var density
    let provider: ProviderSummary
    let definition: ProviderCatalog.Definition
    @State private var baseURL: String
    @State private var apiKey = ""
    @State private var advancedValues: [GlobalSettingKey: String]
    @State private var initialBaseURL: String
    @State private var initialAdvancedValues: [GlobalSettingKey: String]
    @State private var advancedExpanded = false
    @State private var isSaving = false
    @State private var statusMessage: String?
    @State private var statusIsError = false
    @State private var confirmsKeyDeletion = false

    init(
        settings: GlobalSettingsModel,
        provider: ProviderSummary,
        definition: ProviderCatalog.Definition
    ) {
        self.settings = settings
        self.provider = provider
        self.definition = definition
        let stored = settings.live?.values ?? GlobalSettingsValidator.defaults
        let defaultBase = definition.defaultBaseURL.isEmpty
            ? GlobalSettingsValidator.defaults[definition.baseURLSetting] ?? ""
            : definition.defaultBaseURL
        let currentBase = stored[definition.baseURLSetting] ?? defaultBase
        let currentAdvanced = Dictionary(uniqueKeysWithValues: definition.advancedOptions.map { option in
            (option.key, stored[option.key] ?? option.defaultValue)
        })
        _baseURL = State(initialValue: currentBase)
        _initialBaseURL = State(initialValue: currentBase)
        _advancedValues = State(initialValue: currentAdvanced)
        _initialAdvancedValues = State(initialValue: currentAdvanced)
    }

    private var isDirty: Bool {
        baseURL != initialBaseURL || advancedValues != initialAdvancedValues || !apiKey.isEmpty
    }

    private var baseURLWarning: String? {
        ProviderURLGuidance.baseURLWarning(in: baseURL, transport: definition.transport)
    }

    private var hasConfiguredKey: Bool {
        guard let state = settings.live?.credentialStatuses[provider.id] else {
            return settings.live?.configuredCredentialProviderIDs.contains(provider.id) == true
        }
        return state == .configured || state == .authorizationRequired
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: density.sectionSpacing + 4) {
                    header
                    serviceSection
                    connectionSection
                    modelSection
                    if !definition.advancedOptions.isEmpty {
                        advancedSection
                    }
                    if let statusMessage {
                        Label(
                            statusMessage,
                            systemImage: statusIsError ? "exclamationmark.triangle" : "checkmark.circle"
                        )
                        .foregroundStyle(statusIsError ? SlateSyncTheme.danger : SlateSyncTheme.success)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(density.panelPadding)
                .frame(maxWidth: 860, alignment: .leading)
            }
            Divider()
            HStack(spacing: 10) {
                Button("取消", role: .cancel) { dismiss() }
                Spacer()
                Button("验证连接", systemImage: "arrow.triangle.2.circlepath") {
                    validateConnection()
                }
                .disabled(isSaving || isDirty)
                .help(isDirty ? "请先保存未保存的配置" : "使用已保存配置刷新模型列表")
                Button("保存配置") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(isSaving)
            }
            .padding(.horizontal, density.panelPadding)
            .padding(.vertical, density.rowPadding + 6)
        }
        .frame(minWidth: 680, minHeight: 600)
        .disabled(isSaving)
        .interactiveDismissDisabled(isSaving)
        .confirmationDialog(
            "删除 \(provider.label) 的 API Key？",
            isPresented: $confirmsKeyDeletion,
            titleVisibility: .visible
        ) {
            Button("删除 API Key", role: .destructive) {
                deleteKey()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("删除后不会修改 Base URL 或模型配置；之后需要重新输入 API Key 才能连接。")
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("\(provider.label) 配置").font(.title2.weight(.semibold))
            Text("先保存配置，再使用“验证连接”确认模型服务和视觉能力。")
                .font(.callout).foregroundStyle(.secondary)
        }
    }

    private var serviceSection: some View {
        GroupBox("服务说明") {
            VStack(alignment: .leading, spacing: 10) {
                Text(definition.serviceDescription)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                HStack(spacing: 14) {
                    externalLink("官方网站", url: definition.websiteURL)
                    externalLink("获取 API Key", url: definition.apiKeyURL)
                    externalLink("官方配置文档", url: definition.documentationURL)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var connectionSection: some View {
        GroupBox("连接配置") {
            VStack(alignment: .leading, spacing: 12) {
                TextField("API 基础地址（Base URL）", text: $baseURL)
                    .textFieldStyle(.roundedBorder)
                HStack {
                    Button("恢复默认地址") {
                        baseURL = defaultBaseURL
                    }
                    Text("当前值会用于拼接服务端点")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let baseURLWarning {
                    Label(baseURLWarning, systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(SlateSyncTheme.warning)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text("这里填写服务的基础地址，不要填写具体接口路径；应用会按协议自动追加请求端点。")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if !definition.protocolDescription.isEmpty {
                    LabeledContent("API 协议") {
                        Text(definition.protocolDescription)
                            .font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .multilineTextAlignment(.trailing)
                    }
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text(hasConfiguredKey ? "替换 API Key" : "API Key")
                        .font(.headline)
                    SecureField("留空保留当前 API Key", text: $apiKey)
                        .textFieldStyle(.roundedBorder)
                    Text(definition.apiKeyHint)
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if hasConfiguredKey {
                        Label("已配置；留空保留当前 API Key。", systemImage: "checkmark.circle")
                            .font(.caption).foregroundStyle(SlateSyncTheme.success)
                        Button("删除已保存 API Key", role: .destructive) {
                            confirmsKeyDeletion = true
                        }
                    } else if let state = settings.live?.credentialStatuses[provider.id], state == .unavailable {
                        Label("钥匙串状态读取失败；请确认授权后重试。", systemImage: "lock.trianglebadge.exclamationmark")
                            .font(.caption).foregroundStyle(SlateSyncTheme.warning)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var modelSection: some View {
        GroupBox("模型与识别能力") {
            VStack(alignment: .leading, spacing: 10) {
                Text(definition.modelHint)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                Text("模型列表获取成功，不代表每个模型都支持当前识别任务；能力验证会单独标记可用模型。")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text("模型选择仍属于项目/任务设置；这里仅刷新和验证当前 Provider 的模型能力。")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button("刷新模型") { refreshModels() }
                        .disabled(isDirty || settings.providerOperations[provider.id]?.isRunning == true)
                    Button("验证待选模型") { probePendingModels() }
                        .disabled(isDirty || !hasPendingModels || settings.providerOperations[provider.id]?.isRunning == true)
                    if settings.probingProviderIDs.contains(provider.id) {
                        Button("取消验证", role: .cancel) {
                            Task { await settings.cancelProbe(providerID: provider.id) }
                        }
                    }
                }
                if let result = settings.discoveryResults[provider.id] {
                    discoveryResult(result)
                } else {
                    Text("尚未获取模型列表。保存配置后点击“验证连接”开始检查。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                providerOperation
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var advancedSection: some View {
        DisclosureGroup("高级选项", isExpanded: $advancedExpanded) {
            VStack(alignment: .leading, spacing: 14) {
                Text("只显示当前 Provider 支持的选项。除下列字段外，不允许编辑任意认证请求头。")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                ForEach(definition.advancedOptions) { option in
                    VStack(alignment: .leading, spacing: 5) {
                        Text(option.title)
                            .font(.headline)
                        TextField(option.isRequired ? "必填" : "可选", text: binding(for: option.key))
                            .textFieldStyle(.roundedBorder)
                        Text("\(option.description) 默认：\(option.defaultValue.isEmpty ? "无" : option.defaultValue)")
                            .font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .padding(.top, 8)
        }
    }

    private var defaultBaseURL: String {
        definition.defaultBaseURL.isEmpty
            ? GlobalSettingsValidator.defaults[definition.baseURLSetting] ?? ""
            : definition.defaultBaseURL
    }

    private var hasPendingModels: Bool {
        !(settings.discoveryResults[provider.id]?.pendingModels ?? []).isEmpty
    }

    @ViewBuilder
    private func externalLink(_ title: String, url: String?) -> some View {
        if let url, let destination = URL(string: url) {
            Link("\(title) ↗", destination: destination)
                .help("在浏览器中打开\(title)")
        }
    }

    private func binding(for key: GlobalSettingKey) -> Binding<String> {
        Binding(
            get: { advancedValues[key] ?? "" },
            set: { advancedValues[key] = $0 }
        )
    }

    @ViewBuilder
    private func discoveryResult(_ result: ModelDiscoveryResult) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label(
                    result.source == .api ? "连接成功" : "未确认连接，使用本地目录",
                    systemImage: result.source == .api ? "checkmark.circle" : "questionmark.circle"
                )
                .foregroundStyle(result.source == .api ? SlateSyncTheme.success : SlateSyncTheme.warning)
                Spacer()
                Text("视觉模型 \(result.visionModelCount) 个")
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            if let available = result.availableModelCount {
                Text("服务端返回 \(available) 个模型，当前筛选出 \(result.visionModelCount) 个视觉模型。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            ForEach(ProviderCatalog.sort(result.models), id: \.id) { model in
                modelRow(model)
            }
            if let pending = result.pendingModels, !pending.isEmpty {
                Text("待验证（\(pending.count)）")
                    .font(.subheadline.weight(.semibold)).padding(.top, 4)
                ForEach(pending, id: \.id) { model in modelRow(model) }
            }
            if let unsupported = result.unsupportedModels, !unsupported.isEmpty {
                Text("不支持当前识别（\(unsupported.count)）")
                    .font(.subheadline.weight(.semibold)).padding(.top, 4)
                ForEach(unsupported, id: \.id) { model in
                    Label("\(model.id)：\(model.reason)", systemImage: "nosign")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if let failed = result.failedModels, !failed.isEmpty {
                Text("验证失败（\(failed.count)）")
                    .font(.subheadline.weight(.semibold)).padding(.top, 4)
                ForEach(failed, id: \.id) { model in modelRow(model) }
            }
            if let warning = result.warning {
                Text(warning).font(.caption).foregroundStyle(SlateSyncTheme.warning)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(10)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: SlateSyncTheme.controlRadius))
    }

    private func modelRow(_ model: ModelData) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(model.label).lineLimit(1)
                Text(model.apiId ?? model.id)
                    .font(.caption.monospaced()).foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            Spacer(minLength: 8)
            Text(modelStatus(model))
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var providerOperation: some View {
        Group {
            switch settings.providerOperations[provider.id] {
            case .running(let label):
                Label(label, systemImage: "arrow.triangle.2.circlepath")
            case .succeeded(let message):
                Label(message, systemImage: "checkmark.circle")
                    .foregroundStyle(SlateSyncTheme.success)
            case .failed(let error):
                Label(providerFailureMessage(error), systemImage: "exclamationmark.circle")
                    .foregroundStyle(SlateSyncTheme.danger)
            case .canceled:
                Label("验证已取消", systemImage: "slash.circle")
            case .idle, .none:
                EmptyView()
            }
        }
        .font(.caption)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func providerFailureMessage(_ error: SlateSyncError) -> String {
        switch error.status {
        case 401, 403:
            return "鉴权或权限不足：请检查或替换 API Key。"
        case 402:
            return "账户余额或额度不足：请前往服务商账户检查。"
        case 404:
            return "地址或接口错误：请检查 API 基础地址（Base URL）。"
        case 429:
            return "请求过于频繁或达到额度限制：请稍后重试并检查服务商账户。"
        default:
            if error.code == RecognitionFailure.timeout.code || error.retryable {
                return "网络失败或请求超时：请检查网络后重试。"
            }
            return error.message
        }
    }

    private func modelStatus(_ model: ModelData) -> String {
        switch model.capabilityStatus {
        case .verified: "验证通过"
        case .pending: "待验证"
        case .unsupported: "不支持识别"
        case .failed: "验证失败"
        case .canceled: "已取消"
        case .declared, .inferred: model.discovered == true ? "已发现" : "可用"
        case .none: "已发现"
        }
    }

    private func refreshModels() {
        guard !isDirty else {
            statusMessage = "请先保存未保存的配置，再验证连接。"
            statusIsError = true
            return
        }
        Task { await settings.discover(providerID: provider.id, forceRefresh: true) }
    }

    private func validateConnection() {
        guard !isDirty else {
            statusMessage = "请先保存未保存的配置，再验证连接。"
            statusIsError = true
            return
        }
        Task { await settings.discover(providerID: provider.id, forceRefresh: true) }
    }

    private func probePendingModels() {
        guard let pending = settings.discoveryResults[provider.id]?.pendingModels, !pending.isEmpty else { return }
        Task {
            await settings.probe(
                providerID: provider.id,
                modelIDs: pending.map { $0.apiId ?? $0.id }
            )
        }
    }

    private func save() {
        if let baseURLWarning {
            statusMessage = baseURLWarning
            statusIsError = true
            return
        }
        guard !baseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            statusMessage = "API 基础地址不能为空；请填写地址或恢复默认地址。"
            statusIsError = true
            return
        }
        var values: [GlobalSettingKey: String?] = [definition.baseURLSetting: baseURL]
        for option in definition.advancedOptions {
            let value = advancedValues[option.key]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            values[option.key] = value.isEmpty ? nil : value
        }
        let submittedKey = apiKey.isEmpty ? nil : apiKey
        isSaving = true
        statusMessage = nil
        Task { @MainActor in
            let result = await settings.saveBuiltinProviderConfiguration(
                providerID: provider.id,
                values: values,
                apiKey: submittedKey
            )
            isSaving = false
            statusMessage = result.message
            statusIsError = !result.isComplete
            if result.configurationSaved {
                baseURL = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
                for option in definition.advancedOptions {
                    advancedValues[option.key] = advancedValues[option.key]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                }
                initialBaseURL = baseURL
                initialAdvancedValues = advancedValues
            }
            if result.credentialSaved {
                apiKey = ""
            }
        }
    }

    private func deleteKey() {
        isSaving = true
        statusMessage = nil
        Task { @MainActor in
            do {
                try await settings.removeProviderCredential(providerID: provider.id)
                statusMessage = "API Key 已删除。"
                statusIsError = false
            } catch {
                statusMessage = ProductPrivacy.error(error).message
                statusIsError = true
            }
            isSaving = false
        }
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
            if let error { Text(error.message).foregroundStyle(SlateSyncTheme.danger) }
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
            do {
                try await settings.storeCredential(value, providerID: provider.id)
                credential = ""
                dismiss()
            } catch {
                self.error = ProductPrivacy.error(error)
                credential = ""
            }
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
                    .foregroundStyle(SlateSyncTheme.danger)
            }
            HStack {
                Spacer()
                Button("取消", role: .cancel) { dismiss() }
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
                        ) {
                            dismiss()
                        }
                    }
                }
            }
        }.padding(24).frame(width: 500)
    }
}

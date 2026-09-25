import SlateSyncDomain
import SlateSyncWorkflow
import SwiftUI

// Product copy uses the shared launch language; user content stays verbatim.

public struct SettingsRootView: View {
    @AppStorage(AppLanguage.preferenceKey) private var applicationLanguage = AppLanguage.simplifiedChinese.rawValue
    @AppStorage("appearance") private var appearance = "system"
    @AppStorage("density") private var density = "comfortable"
    @Bindable private var settings: GlobalSettingsModel
    @Bindable private var paddleInstaller: PaddleInstallerModel
    @State private var credentialProvider: ProviderSummary?
    @State private var showsCustomProvider = false
    @State private var showsPresetPicker = false
    @State private var providerSearch = ""
    @State private var showsUnconfigured = false
    @State private var showsBackups = false
    @State private var confirmsCredentialReset = false
    @AppStorage("providerFileCredentialNoticeDismissed") private var credentialNoticeDismissed = false
    @State private var providerPendingDeletion: CustomProviderConfiguration?
    @State private var providerEditing: CustomProviderConfiguration?
    @State private var category = SettingsCategory.general
    @State private var focusedOCRSubregion: SettingsSubregion?
    @State private var highlightedOCRSubregion: SettingsSubregion?
    private let preferences: UserDefaults
    private let navigation: SettingsNavigationModel

    public init(
        settings: GlobalSettingsModel,
        paddleInstaller: PaddleInstallerModel,
        navigation: SettingsNavigationModel,
        preferences: UserDefaults = .standard
    ) {
        self.preferences = preferences
        self.settings = settings
        self.paddleInstaller = paddleInstaller
        self.navigation = navigation
    }

    public var body: some View {
        // A native segmented category selector keeps the five existing forms
        // inside one flexible content host. macOS 15's special Settings TabView
        // host otherwise forces its ideal size into fixed window constraints.
        VStack(spacing: 0) {
            // The segmented control carries its own native bezel; an added
            // glass card doubles the frame and reads as a black border on the
            // dark canvas, so the classifier sits directly on the background.
            Picker(L10n.tr("设置分类"), selection: $category) {
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
        .navigationTitle(L10n.tr("设置"))
        // Settings shares the workbench canvas instead of the system window
        // gray, keeping both windows on one neutral scale in each appearance.
        .background(SlateSyncTheme.canvas)
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
            if case .succeeded = paddleInstaller.operation {
                settings.invalidateOCREnvironmentCheck()
                Task { await settings.refresh() }
            }
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
                    if let custom = settings.customProviders.first(where: { $0.id == provider.id }) {
                        CustomProviderSheet(settings: settings, provider: custom)
                    }
                }
            }
        }
        .sheet(isPresented: $showsCustomProvider) {
            CustomProviderSheet(settings: settings)
        }
        .sheet(isPresented: $showsPresetPicker) {
            ProviderAddSheet(settings: settings)
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
            L10n.tr("删除自定义 Provider？"),
            isPresented: Binding(
                get: { providerPendingDeletion != nil },
                set: { if !$0 { providerPendingDeletion = nil } }
            ),
            titleVisibility: .visible
        ) {
            if let provider = providerPendingDeletion {
                Button(L10n.tr("删除“{0}”", [String(describing: provider.name)]), role: .destructive) {
                    providerPendingDeletion = nil
                    Task { await settings.removeCustomProvider(id: provider.id) }
                }
            }
            Button(L10n.tr("取消"), role: .cancel) { providerPendingDeletion = nil }
        } message: {
            Text(L10n.tr("删除后需要保存 Provider 设置才会持久化。"))
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
            // Native menus and AppKit panels read language at launch. Persist
            // the next choice without replacing editors or interrupting work.
            Section {
                Picker("语言 / Language", selection: $applicationLanguage) {
                    Text(verbatim: "简体中文").tag(AppLanguage.simplifiedChinese.rawValue)
                    Text(verbatim: "English").tag(AppLanguage.english.rawValue)
                }
                .accessibilityLabel("语言 / Language")
                .accessibilityIdentifier("settings.applicationLanguage")
                .onChange(of: applicationLanguage) {
                    AppLanguage.save(AppLanguage(rawValue: applicationLanguage) ?? .simplifiedChinese, in: preferences)
                }
                if applicationLanguage != L10n.language.rawValue {
                    Label(L10n.tr("语言已保存，重启 SlateSync 后应用到所有窗口、菜单和帮助。"), systemImage: "arrow.clockwise")
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("settings.languageRestart")
                }
            } footer: {
                Text(L10n.tr("应用语言包含界面、菜单和帮助。更改后请退出并重新打开 SlateSync。"))
            }
            Picker(L10n.tr("外观"), selection: $appearance) {
                Text(L10n.tr("跟随系统")).tag("system")
                Text(L10n.tr("浅色")).tag("light")
                Text(L10n.tr("深色")).tag("dark")
            }
            // macOS Form presents picker titles as sibling static text, so
            // explicitly name the interactive controls for VoiceOver/XCUI.
            .accessibilityLabel(L10n.tr("外观"))
            .accessibilityIdentifier(AccessibilityID.settingsAppearance)
            Picker(L10n.tr("界面密度"), selection: $density) {
                Text(L10n.tr("舒适")).tag("comfortable")
                Text(L10n.tr("紧凑")).tag("compact")
            }
            .accessibilityLabel(L10n.tr("界面密度"))
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
        case .unavailable, .unreadable: .readFailed
        case .temporarilyUnavailable: .temporarilyUnavailable
        }
        return CredentialChip(chip)
    }

    private var providers: some View {
        VStack(spacing: 12) {
            HStack {
                SlateSearchField(title: L10n.tr("搜索 Provider"), text: $providerSearch, identifier: "providers.search")
                Button(L10n.tr("添加 Provider"), systemImage: "plus") { showsPresetPicker = true }
                    .slatePrimaryActionStyle()
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if !credentialNoticeDismissed {
                        HStack(alignment: .top) {
                            Label(L10n.tr("凭据存储方式已更新，请重新填写 API Key。"), systemImage: "lock.doc")
                                .font(.callout)
                            Spacer()
                            Button(L10n.tr("知道了")) { credentialNoticeDismissed = true }
                        }
                    }
                    GroupBox {
                        VStack(alignment: .leading, spacing: 12) {
                            defaultProviderSection
                            Divider()
                            DisclosureGroup(L10n.tr("备用组合"), isExpanded: $showsBackups) {
                                VStack(alignment: .leading, spacing: 8) {
                                    ForEach(backupChain, id: \.self) { backupRow($0) }
                                    backupAddMenu.disabled(backupChain.count >= 8)
                                }.padding(.top, 8)
                            }
                        }.padding(8)
                    }
                    providerListSection
                }.padding(2)
            }
            Divider()
            HStack {
                Menu {
                    Button(L10n.tr("重置本地凭据…"), role: .destructive) { confirmsCredentialReset = true }
                } label: { Image(systemName: "ellipsis.circle") }
                .menuStyle(.borderlessButton).fixedSize()
                .help(L10n.tr("凭据管理")).accessibilityLabel(L10n.tr("凭据管理"))
                Text(L10n.tr("默认、备用及删除修改需保存生效"))
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button(L10n.tr("保存 Provider 设置")) { Task { await settings.save() } }
                    .slatePrimaryActionStyle()
                    .disabled(settings.operation.isRunning)
            }
        }
        .confirmationDialog(L10n.tr("重置所有本地 API Key？"), isPresented: $confirmsCredentialReset, titleVisibility: .visible) {
            Button(L10n.tr("重置本地凭据"), role: .destructive) { Task { await settings.resetLocalCredentials() } }
            Button(L10n.tr("取消"), role: .cancel) {}
        } message: {
            Text(L10n.tr("将删除本地保存的全部 API Key 与加密主密钥，并清除默认和备用组合。Provider 配置保留；旧钥匙串不受影响。"))
        }
    }

    private var defaultProviderSection: some View {
        Section(L10n.tr("默认组合")) {
                    Picker(L10n.tr("默认 Provider"), selection: Binding(
                        get: { settings.value(.defaultProviderID) },
                        set: {
                            settings.setValue($0, for: .defaultProviderID)
                            settings.setValue("", for: .defaultModelID)
                        }
                    )) {
                        Text(L10n.tr("未设置")).tag("")
                        ForEach(providerEntries.filter(\.configured), id: \.id) { provider in
                            Text(L10n.providerLabel(provider)).tag(provider.id)
                        }
                    }
                    Picker(L10n.tr("默认模型"), selection: Binding(
                        get: { settings.value(.defaultModelID) },
                        set: { settings.setValue($0, for: .defaultModelID) }
                    )) {
                        Text(L10n.tr("未设置")).tag("")
                        ForEach(verifiedModels(for: settings.value(.defaultProviderID)), id: \.id) {
                            Text($0.label).tag($0.id)
                        }
                    }
        }
    }

    private func backupRow(_ pair: ProviderModelSelection) -> some View {
        let index = backupChain.firstIndex(of: pair) ?? 0
        let label = providerEntries.first(where: { $0.id == pair.providerID }).map { L10n.providerLabel($0) } ?? pair.providerID
        return HStack {
            Text("\(label) · \(pair.modelID)").lineLimit(1)
            Spacer()
            Button(L10n.tr("上移"), systemImage: "arrow.up") { moveBackup(index, by: -1) }
                .disabled(index == 0)
            Button(L10n.tr("下移"), systemImage: "arrow.down") { moveBackup(index, by: 1) }
                .disabled(index == backupChain.count - 1)
            Button(L10n.tr("移除"), systemImage: "minus.circle", role: .destructive) {
                var chain = backupChain; chain.remove(at: index); setBackupChain(chain)
            }
        }
    }

    private var backupAddMenu: some View {
        Menu(L10n.tr("添加备用组合…"), systemImage: "plus") {
            ForEach(providerEntries.filter(\.configured), id: \.id) { provider in
                Menu(L10n.providerLabel(provider)) {
                    ForEach(verifiedModels(for: provider.id), id: \.id) { model in
                        Button(model.label) {
                            let pair = ProviderModelSelection(providerID: provider.id, modelID: model.id)
                            guard !backupChain.contains(pair), backupChain.count < 8 else { return }
                            setBackupChain(backupChain + [pair])
                        }
                    }
                }
            }
        }
    }

    /// Group by configured identity, not successful key reads. A damaged vault
    /// must keep existing Providers visible so their recovery actions are found.
    private func isAdded(_ provider: ProviderSummary) -> Bool {
        ProviderListPresentation.isAdded(provider, credentialStatus: settings.live?.credentialStatuses[provider.id])
    }

    private var matchingProviders: [ProviderSummary] {
        providerEntries.filter { provider in
            let custom = settings.customProviders.first { $0.id == provider.id }
            let url = custom?.baseUrl ?? ProviderCatalog.definition(id: provider.id).map {
                settings.value($0.baseURLSetting).isEmpty ? $0.defaultBaseURL : settings.value($0.baseURLSetting)
            } ?? ""
            return ProviderListPresentation.matches(query: providerSearch, name: L10n.providerLabel(provider), url: url, notes: custom?.notes)
        }
    }

    private var providerListSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L10n.tr("Provider 列表") + " · \(matchingProviders.count)").font(.headline)
            ForEach(matchingProviders.filter { isAdded($0) }, id: \.id) { provider in
                providerRow(provider)
            }
            if !matchingProviders.contains(where: { isAdded($0) }) && providerSearch.isEmpty {
                Text(L10n.tr("尚未配置 Provider，请添加或展开下方内建服务。"))
                    .foregroundStyle(.secondary).font(.callout)
            }
            if !matchingProviders.filter({ !isAdded($0) }).isEmpty {
                DisclosureGroup(L10n.tr("未配置的内建服务"), isExpanded: Binding(
                    get: { showsUnconfigured || !providerSearch.isEmpty },
                    set: { showsUnconfigured = $0 }
                )) {
                    VStack(spacing: 12) {
                        ForEach(matchingProviders.filter { !isAdded($0) }, id: \.id) { providerRow($0) }
                    }.padding(.top, 8)
                }
            }
            // An empty catalog is not a failed search; keep the two empty states exclusive.
            if matchingProviders.isEmpty && !providerSearch.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text(L10n.tr("没有匹配的 Provider，请尝试其他关键词。"))
                    .foregroundStyle(.secondary).padding(.vertical, 16)
            }
        }
    }

    private var providerEntries: [ProviderSummary] {
        let builtin = (settings.live?.providers ?? []).filter { $0.type != .custom }
        let builtinIDs = Set(builtin.map(\.id))
        let custom = settings.customProviders.filter { !builtinIDs.contains($0.id) }.map { custom in
            settings.live?.providers.first(where: { $0.id == custom.id })
                ?? ProviderSummary(id: custom.id, label: custom.name, configured: true, type: .custom, editable: true)
        }
        return builtin + custom
    }

    private func verifiedModels(for providerID: String) -> [ModelData] {
        (settings.live?.models ?? []).filter {
            $0.providers.contains(providerID) && $0.capabilityStatus == .verified && $0.verifiedAvailable != false
        }
    }

    private var backupChain: [ProviderModelSelection] {
        (try? ProviderModelSelection.decodeAndValidateChain(settings.value(.recognitionFailoverChain))) ?? []
    }

    private func setBackupChain(_ chain: [ProviderModelSelection]) {
        if let value = try? ProviderModelSelection.encodeChain(chain) {
            settings.setValue(value, for: .recognitionFailoverChain)
        }
    }

    private func moveBackup(_ index: Int, by offset: Int) {
        var chain = backupChain
        let target = index + offset
        guard chain.indices.contains(index), chain.indices.contains(target) else { return }
        chain.swapAt(index, target)
        setBackupChain(chain)
    }

    private func providerRow(_ provider: ProviderSummary) -> some View {
        let materialized = settings.customProviders.first { $0.id == provider.id }
        let custom = provider.type == .custom ? materialized : nil
        let source: String = switch ProviderSourceBadge.source(for: custom) {
        case .builtin: L10n.tr("内建")
        case .preset: L10n.tr("预设")
        case .custom: L10n.tr("自定义")
        }
        let baseURL = materialized?.baseUrl
            ?? ProviderCatalog.definition(id: provider.id).map { settings.value($0.baseURLSetting).isEmpty ? $0.defaultBaseURL : settings.value($0.baseURLSetting) }
            ?? ""
        let capability = capabilityState(for: provider, custom: custom)
        return ProviderCard(
            title: L10n.providerLabel(provider), source: source, baseURL: baseURL,
            notes: custom?.notes, isDefault: settings.value(.defaultProviderID) == provider.id
        ) {
            HStack(spacing: 8) {
                credentialStatusChip(provider.id)
                CapabilityChip(capability)
                Spacer()
                Button(L10n.tr("配置…")) { credentialProvider = provider }
                Button(L10n.tr("刷新模型"), systemImage: "arrow.clockwise") {
                    Task { await settings.discover(providerID: provider.id) }
                }.disabled(settings.providerOperations[provider.id]?.isRunning == true || !provider.configured)
                Menu {
                Menu(L10n.tr("设为默认组合")) {
                    ForEach(verifiedModels(for: provider.id), id: \.id) { model in
                        Button(model.label) {
                            settings.setValue(provider.id, for: .defaultProviderID)
                            settings.setValue(model.id, for: .defaultModelID)
                        }
                    }
                }
                Menu(L10n.tr("添加到备用列表")) {
                    ForEach(verifiedModels(for: provider.id), id: \.id) { model in
                        Button(model.label) {
                            let pair = ProviderModelSelection(providerID: provider.id, modelID: model.id)
                            guard !backupChain.contains(pair), backupChain.count < 8 else { return }
                            setBackupChain(backupChain + [pair])
                        }
                    }
                }
                if let custom {
                    Button(L10n.tr("编辑…")) { providerEditing = custom }
                    Button(L10n.tr("删除…"), role: .destructive) { providerPendingDeletion = custom }
                }
                } label: { Image(systemName: "ellipsis") }
                .menuStyle(.borderlessButton).fixedSize()
                .accessibilityLabel(L10n.tr("更多操作")).help(L10n.tr("更多操作"))
                .disabled(settings.operation.isRunning)
            }
            providerStatus(provider.id)
        }
    }

    private func capabilityState(
        for provider: ProviderSummary,
        custom: CustomProviderConfiguration?
    ) -> CapabilityChip.State {
        if let custom {
            let checks = custom.manualModelIds.compactMap { id -> CustomProviderCapabilityVerification? in
                guard let entry = custom.capabilityCache?[id], entry.revision == custom.revision else { return nil }
                return entry
            }
            let verified = checks.filter { $0.status == .verified }
            if verified.contains(where: { $0.jsonMode != nil && $0.jsonMode != custom.jsonMode }) { return .attention }
            return CapabilityChip.state(verified: verified.count,
                failed: checks.filter { $0.status == .failed }.count,
                pending: max(0, custom.manualModelIds.count - checks.count))
        }
        let models = (settings.live?.models ?? []).filter { $0.providers.contains(provider.id) }
        if case .failed = settings.providerOperations[provider.id] { return .attention }
        return CapabilityChip.state(
            verified: models.filter { $0.capabilityStatus == .verified }.count,
            failed: models.filter { $0.capabilityStatus == .failed }.count,
            pending: models.filter { $0.capabilityStatus != .verified && $0.capabilityStatus != .failed }.count
        )
    }

    private var recognition: some View {
        Form {
            Section(L10n.tr("请求")) {
                settingField(L10n.tr("请求超时（毫秒）"), .modelRequestTimeoutMS)
                settingField(L10n.tr("超时重试次数"), .modelRequestMaxRetries)
                settingField(L10n.tr("页并发数"), .modelPageConcurrency)
                settingField(L10n.tr("全局识别并发数"), .maxConcurrentRecognitions)
            }
            Section(L10n.tr("模型")) {
                LabeledContent(L10n.tr("可用模型"), value: "\(settings.live?.models.count ?? 0)")
            }
            Button(L10n.tr("保存")) { Task { await settings.save() } }
                .slatePrimaryActionStyle()
                .disabled(settings.operation.isRunning)
        }.formStyle(.grouped)
    }

    private var ocr: some View {
        ScrollViewReader { proxy in
            Form {
                Section("Vision") {
                    settingPicker(L10n.tr("启用策略"), .visionOCREnabled, [(L10n.tr("自动"), "auto"), (L10n.tr("启用"), "true"), (L10n.tr("禁用"), "false")])
                    settingField(L10n.tr("语言"), .visionOCRLanguage)
                    settingPicker(L10n.tr("识别级别"), .visionOCRRecognitionLevel, [(L10n.tr("精准"), "accurate"), (L10n.tr("快速"), "fast")])
                }
                .id(SettingsSubregion.vision.rawValue)
                Section("Paddle OCR") {
                    settingPicker(L10n.tr("启用策略"), .paddleOCREnabled, [(L10n.tr("自动"), "auto"), (L10n.tr("启用"), "true"), (L10n.tr("禁用"), "false")])
                    settingPicker(
                        L10n.tr("预设"), .paddleOCRPreset,
                        [(L10n.tr("自定义"), "custom"), (L10n.tr("性能"), "performance"), (L10n.tr("平衡"), "balanced"), (L10n.tr("快速"), "fast")])
                    settingPicker(L10n.tr("配置档"), .paddleOCRProfile, [(L10n.tr("快速"), "fast"), (L10n.tr("平衡"), "balanced"), (L10n.tr("精准"), "accurate")])
                    settingField(L10n.tr("Python 可执行文件"), .paddleOCRPython)
                    settingField(L10n.tr("语言"), .paddleOCRLanguage)
                    Text(L10n.tr("自动安装需要 Python 3.10+，安装过程不会在测试中联网。"))
                        .font(.caption).foregroundStyle(.secondary)
                    if let progress = paddleInstaller.progress {
                        ProgressView(value: progress.percent, total: 100) { Text(L10n.message(progress.message)) }
                    }
                    HStack {
                        Button(settings.live?.paddleAvailable == true ? L10n.tr("重新安装 PaddleOCR") : L10n.tr("安装 PaddleOCR")) {
                            paddleInstaller.install()
                        }.disabled(paddleInstaller.operation.isRunning || settings.ocrCheckOperation.isRunning)
                        if paddleInstaller.operation.isRunning {
                            Button(L10n.tr("取消"), role: .cancel) { paddleInstaller.cancel() }
                        }
                    }
                }
                .id(SettingsSubregion.paddleOCR.rawValue)
                ocrEnvironmentSection
                Button(L10n.tr("保存")) { Task { await settings.save() } }
                    .slatePrimaryActionStyle()
                    .disabled(settings.operation.isRunning)
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
                    Text(highlightedOCRSubregion == .vision ? L10n.tr("已定位到 Vision") : L10n.tr("已定位到 Paddle OCR"))
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(SlateSyncTheme.accent.opacity(0.16), in: .capsule)
                        .padding(.top, 6)
                        .accessibilityLabel(L10n.tr("已定位到{0}", [String(describing: highlightedOCRSubregion == .vision ? " Vision" : " Paddle OCR")]))
                }
            }
        }
    }

    /// Native form rows share the existing settings typography and semantic
    /// colors; symbols and text convey status independently of color.
    private var ocrEnvironmentSection: some View {
        Section(L10n.tr("OCR 环境检测")) {
            Text(L10n.tr("按当前设置检测 Vision、Python 和 Paddle OCR 依赖；不会保存设置、安装依赖或下载模型。模型与设备能否识别需运行实际任务验证。"))
                .font(.caption).foregroundStyle(.secondary)
            Button(L10n.tr("检测 OCR 环境")) { Task { await settings.checkOCREnvironment() } }
                .disabled(settings.ocrCheckOperation.isRunning || paddleInstaller.operation.isRunning || settings.live == nil)
                .accessibilityIdentifier("settings.ocr.check")
            if settings.ocrCheckOperation.isRunning {
                ProgressView(L10n.tr("正在检测 OCR 环境…"))
                Button(L10n.tr("取消"), role: .cancel) { settings.cancelOCREnvironmentCheck() }
            } else if case .failed(let error) = settings.ocrCheckOperation {
                Text(L10n.message(error.message)).foregroundStyle(SlateSyncTheme.danger)
            } else if settings.ocrChecks.isEmpty {
                Text(L10n.tr("尚未检测")).foregroundStyle(.secondary)
            }
            if settings.ocrChecksAreStale {
                Label(L10n.tr("设置已更改，请重新检测。"), systemImage: "exclamationmark.triangle")
                    .foregroundStyle(SlateSyncTheme.warning)
            }
            ForEach(settings.ocrChecks) { check in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(L10n.message(check.title))
                        Spacer()
                        Label(check.status == .passed ? L10n.tr("通过") : check.status == .failed ? L10n.tr("失败") : L10n.tr("需注意"),
                              systemImage: check.status == .passed ? "checkmark.circle" : check.status == .failed ? "xmark.circle" : "exclamationmark.triangle")
                            .foregroundStyle(check.status == .passed ? SlateSyncTheme.success : check.status == .failed ? SlateSyncTheme.danger : SlateSyncTheme.warning)
                    }
                    Text(L10n.message(check.detail)).font(.caption).foregroundStyle(.secondary)
                        .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                }
                .accessibilityElement(children: .combine)
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
            Section(L10n.tr("存储")) {
                // Old renderer row: label + hint. The field edits the
                // configured value; the effective path below is resolved at
                // startup and only changes after a restart.
                settingField(L10n.tr("工作流配置路径"), .slateSyncConfigPath)
                Text(L10n.tr("开发环境读取；修改后下次启动生效。"))
                    .font(.caption).foregroundStyle(.secondary)
                if let workflowPath = settings.live?.runtime.workflowConfigPath {
                    LabeledContent(L10n.tr("实际生效路径")) {
                        Text(workflowPath)
                            .font(.caption.monospaced())
                            .lineLimit(1)
                            .truncationMode(.head)
                            .help(workflowPath)
                    }
                }
                if settings.live?.restartRequired == true {
                    Text(L10n.tr("工作流配置路径已修改，重启 SlateSync 后生效。"))
                        .font(.caption).foregroundStyle(SlateSyncTheme.warning)
                }
            }
            if let snapshot = settings.live?.runtime {
                Section(L10n.tr("原生启动状态")) {
                    LabeledContent(L10n.tr("配置项"), value: "\(snapshot.resolvedSettingCount)")
                    LabeledContent(L10n.tr("配置版本"), value: "\(snapshot.globalConfigVersion)")

                }
            }
            Button(L10n.tr("保存")) { Task { await settings.save() } }
                .slatePrimaryActionStyle()
                .disabled(settings.operation.isRunning)
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
        // Operation feedback remains attached to this card even when an older
        // discovery result exists; errors must never disappear behind that cache.
        if case .running(let label) = settings.providerOperations[providerID] {
            HStack {
                ProgressView().controlSize(.small)
                Text(L10n.message(label)).font(.caption)
                Spacer()
                if settings.probingProviderIDs.contains(providerID) {
                    Button(L10n.tr("取消"), role: .cancel) { Task { await settings.cancelProbe(providerID: providerID) } }
                }
            }
        }
        if case .failed(let error) = settings.providerOperations[providerID] {
            ProviderDiagnostic(message: L10n.message(error.message), isError: true)
        }
        if let result = settings.discoveryResults[providerID] {
            HStack {
                Text(L10n.tr("可用 {0}", [String(describing: result.visionModelCount)]))
                Spacer()
                if let pending = result.pendingModels, !pending.isEmpty {
                    Button(L10n.tr("验证 {0} 个候选模型", [String(describing: pending.count)])) {
                        Task { await settings.probe(providerID: providerID, modelIDs: pending.map { $0.apiId ?? $0.id }) }
                    }
                }
                Menu(L10n.tr("验证模型…")) {
                    ForEach(result.models + (result.pendingModels ?? []) + (result.failedModels ?? []), id: \.id) { model in
                        Button(model.label) { Task { await settings.probe(providerID: providerID, modelIDs: [model.apiId ?? model.id]) } }
                    }
                }.fixedSize()
            }
            .font(.caption)
            .disabled(settings.providerOperations[providerID]?.isRunning == true)
            if let warning = result.warning { ProviderDiagnostic(message: L10n.message(warning), isError: false) }
        }
    }


}

/// Built-in Providers share one guided form. It deliberately keeps the API
/// Key write separate from ordinary settings and never asks the service for a
/// previously stored secret.
struct BuiltinProviderConfigurationSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable private var settings: GlobalSettingsModel
    @Environment(\.slateSyncDensity) private var density
    let provider: ProviderSummary
    let definition: ProviderCatalog.Definition
    @State private var baseURL: String
    @State private var apiKey = ""
    @State private var revealsKey = false
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
                            L10n.message(statusMessage),
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
                Button(L10n.tr("取消"), role: .cancel) { dismiss() }
                Spacer()
                Button(L10n.tr("验证连接"), systemImage: "arrow.triangle.2.circlepath") {
                    validateConnection()
                }
                .disabled(isSaving || isDirty)
                .help(isDirty ? L10n.tr("请先保存未保存的配置") : L10n.tr("使用已保存配置刷新模型列表"))
                Button(L10n.tr("保存配置")) { save() }
                    .keyboardShortcut(.defaultAction)
                    .slatePrimaryActionStyle()
                    .disabled(isSaving)
            }
            .padding(.horizontal, density.panelPadding)
            .padding(.vertical, density.rowPadding + 6)
        }
        .frame(minWidth: 680, minHeight: 600)
        .disabled(isSaving)
        .interactiveDismissDisabled(isSaving)
        .onDisappear { apiKey = "" }
        .confirmationDialog(
            L10n.tr("删除 {0} 的 API Key？", [String(describing: L10n.providerLabel(provider))]),
            isPresented: $confirmsKeyDeletion,
            titleVisibility: .visible
        ) {
            Button(L10n.tr("删除 API Key"), role: .destructive) {
                deleteKey()
            }
            Button(L10n.tr("取消"), role: .cancel) {}
        } message: {
            // Local removal cannot revoke the credential at its issuing provider.
            Text(L10n.tr("只删除本机保存的 API Key，不会在服务商平台注销。Base URL 和模型配置保持不变；再次连接需重新输入 API Key。"))
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(L10n.tr("{0} 配置", [String(describing: L10n.providerLabel(provider))])).font(.title2.weight(.semibold))
            Text(L10n.tr("先保存配置，再使用“验证连接”确认模型服务和视觉能力。"))
                .font(.callout).foregroundStyle(.secondary)
        }
    }

    private var serviceSection: some View {
        GroupBox(L10n.tr("服务说明")) {
            VStack(alignment: .leading, spacing: 10) {
                Text(L10n.message(definition.serviceDescription))
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                HStack(spacing: 14) {
                    externalLink(L10n.tr("官方网站"), url: definition.websiteURL)
                    externalLink(L10n.tr("获取 API Key"), url: definition.apiKeyURL)
                    externalLink(L10n.tr("官方配置文档"), url: definition.documentationURL)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var connectionSection: some View {
        GroupBox(L10n.tr("连接配置")) {
            VStack(alignment: .leading, spacing: 12) {
                TextField(L10n.tr("API 基础地址（Base URL）"), text: $baseURL)
                    .textFieldStyle(.roundedBorder)
                HStack {
                    Button(L10n.tr("恢复默认地址")) {
                        baseURL = defaultBaseURL
                    }
                    Text(L10n.tr("当前值会用于拼接服务端点"))
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let baseURLWarning {
                    Label(L10n.message(baseURLWarning), systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(SlateSyncTheme.warning)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text(L10n.tr("这里填写服务的基础地址，不要填写具体接口路径；应用会按协议自动追加请求端点。"))
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if !definition.protocolDescription.isEmpty {
                    LabeledContent(L10n.tr("API 协议")) {
                        Text(L10n.message(definition.protocolDescription))
                            .font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .multilineTextAlignment(.trailing)
                    }
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text(hasConfiguredKey ? L10n.tr("替换 API Key") : "API Key")
                        .font(.headline)
                    HStack {
                        if revealsKey { TextField(L10n.tr("留空保留当前 API Key"), text: $apiKey) }
                        else { SecureField(L10n.tr("留空保留当前 API Key"), text: $apiKey) }
                        Button { revealsKey.toggle() } label: { Image(systemName: revealsKey ? "eye.slash" : "eye") }
                            .help(revealsKey ? L10n.tr("隐藏 API Key") : L10n.tr("显示 API Key"))
                            .accessibilityLabel(revealsKey ? L10n.tr("隐藏 API Key") : L10n.tr("显示 API Key"))
                    }.textFieldStyle(.roundedBorder)
                    Text(L10n.tr("凭据使用 AES-256-GCM 加密保存在本机，保存后不会回显。"))
                        .font(.caption).foregroundStyle(.secondary)
                    Text(L10n.message(definition.apiKeyHint))
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if hasConfiguredKey {
                        Label(L10n.tr("已配置；留空保留当前 API Key。"), systemImage: "checkmark.circle")
                            .font(.caption).foregroundStyle(SlateSyncTheme.success)
                        Button(L10n.tr("删除已保存 API Key"), role: .destructive) {
                            confirmsKeyDeletion = true
                        }
                    } else if let state = settings.live?.credentialStatuses[provider.id],
                              let notice = ProviderListPresentation.credentialNotice(state) {
                        Label(notice, systemImage: "lock.trianglebadge.exclamationmark")
                            .font(.caption).foregroundStyle(SlateSyncTheme.warning)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var modelSection: some View {
        GroupBox(L10n.tr("模型与识别能力")) {
            VStack(alignment: .leading, spacing: 10) {
                Text(L10n.message(definition.modelHint))
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                Text(L10n.tr("模型列表获取成功，不代表每个模型都支持当前识别任务；能力验证会单独标记可用模型。"))
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(L10n.tr("模型选择仍属于项目/任务设置；这里仅刷新和验证当前 Provider 的模型能力。"))
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button(L10n.tr("刷新模型")) { refreshModels() }
                        .disabled(isDirty || settings.providerOperations[provider.id]?.isRunning == true)
                    Button(L10n.tr("验证待选模型")) { probePendingModels() }
                        .disabled(isDirty || !hasPendingModels || settings.providerOperations[provider.id]?.isRunning == true)
                    if settings.probingProviderIDs.contains(provider.id) {
                        Button(L10n.tr("取消验证"), role: .cancel) {
                            Task { await settings.cancelProbe(providerID: provider.id) }
                        }
                    }
                }
                if let result = settings.discoveryResults[provider.id] {
                    discoveryResult(result)
                } else {
                    Text(L10n.tr("尚未获取模型列表。保存配置后点击“验证连接”开始检查。"))
                        .font(.caption).foregroundStyle(.secondary)
                }
                providerOperation
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var advancedSection: some View {
        DisclosureGroup(L10n.tr("高级选项"), isExpanded: $advancedExpanded) {
            VStack(alignment: .leading, spacing: 14) {
                Text(L10n.tr("只显示当前 Provider 支持的选项。除下列字段外，不允许编辑任意认证请求头。"))
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                ForEach(definition.advancedOptions) { option in
                    VStack(alignment: .leading, spacing: 5) {
                        Text(L10n.message(option.title))
                            .font(.headline)
                        TextField(option.isRequired ? L10n.tr("必填") : L10n.tr("可选"), text: binding(for: option.key))
                            .textFieldStyle(.roundedBorder)
                        Text(L10n.tr("{0} 默认：{1}", [String(describing: L10n.message(option.description)), String(describing: option.defaultValue.isEmpty ? L10n.tr("无") : option.defaultValue)]))
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
                .help(L10n.tr("在浏览器中打开{0}", [String(describing: title)]))
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
                    result.source == .api ? L10n.tr("连接成功") : L10n.tr("未确认连接，使用本地目录"),
                    systemImage: result.source == .api ? "checkmark.circle" : "questionmark.circle"
                )
                .foregroundStyle(result.source == .api ? SlateSyncTheme.success : SlateSyncTheme.warning)
                Spacer()
                Text(L10n.tr("视觉模型 {0} 个", [String(describing: result.visionModelCount)]))
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            if let available = result.availableModelCount {
                Text(L10n.tr("服务端返回 {0} 个模型，当前筛选出 {1} 个视觉模型。", [String(describing: available), String(describing: result.visionModelCount)]))
                    .font(.caption).foregroundStyle(.secondary)
            }
            ForEach(ProviderCatalog.sort(result.models), id: \.id) { model in
                modelRow(model)
            }
            if let pending = result.pendingModels, !pending.isEmpty {
                Text(L10n.tr("待验证（{0}）", [String(describing: pending.count)]))
                    .font(.subheadline.weight(.semibold)).padding(.top, 4)
                ForEach(pending, id: \.id) { model in modelRow(model) }
            }
            if let unsupported = result.unsupportedModels, !unsupported.isEmpty {
                Text(L10n.tr("不支持当前识别（{0}）", [String(describing: unsupported.count)]))
                    .font(.subheadline.weight(.semibold)).padding(.top, 4)
                ForEach(unsupported, id: \.id) { model in
                    Label("\(model.id): \(L10n.message(model.reason))", systemImage: "nosign")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if let failed = result.failedModels, !failed.isEmpty {
                Text(L10n.tr("验证失败（{0}）", [String(describing: failed.count)]))
                    .font(.subheadline.weight(.semibold)).padding(.top, 4)
                ForEach(failed, id: \.id) { model in modelRow(model) }
            }
            if let warning = result.warning {
                Text(L10n.message(warning)).font(.caption).foregroundStyle(SlateSyncTheme.warning)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(10)
        // Discovery results are a bounded custom panel, not a list row; one
        // shared surface keeps the model status readable in both appearances.
        .slateGlassSurface(.panel)
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
                Label(L10n.message(label), systemImage: "arrow.triangle.2.circlepath")
            case .succeeded(let message):
                Label(L10n.message(message), systemImage: "checkmark.circle")
                    .foregroundStyle(SlateSyncTheme.success)
            case .failed(let error):
                Label(providerFailureMessage(error), systemImage: "exclamationmark.circle")
                    .foregroundStyle(SlateSyncTheme.danger)
            case .canceled:
                Label(L10n.tr("验证已取消"), systemImage: "slash.circle")
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
            return L10n.tr("鉴权或权限不足：请检查或替换 API Key。")
        case 402:
            return L10n.tr("账户余额或额度不足：请前往服务商账户检查。")
        case 404:
            return L10n.tr("地址或接口错误：请检查 API 基础地址（Base URL）。")
        case 429:
            return L10n.tr("请求过于频繁或达到额度限制：请稍后重试并检查服务商账户。")
        default:
            if error.code == RecognitionFailure.timeout.code || error.retryable {
                return L10n.tr("网络失败或请求超时：请检查网络后重试。")
            }
            return L10n.message(error.message)
        }
    }

    private func modelStatus(_ model: ModelData) -> String {
        switch model.capabilityStatus {
        case .verified: L10n.tr("验证通过")
        case .pending: L10n.tr("待验证")
        case .unsupported: L10n.tr("不支持识别")
        case .failed: L10n.tr("验证失败")
        case .canceled: L10n.tr("已取消")
        case .declared, .inferred: model.discovered == true ? L10n.tr("已发现") : L10n.tr("可用")
        case .none: L10n.tr("已发现")
        }
    }

    private func refreshModels() {
        guard !isDirty else {
            statusMessage = L10n.tr("请先保存未保存的配置，再验证连接。")
            statusIsError = true
            return
        }
        Task { await settings.discover(providerID: provider.id, forceRefresh: true) }
    }

    private func validateConnection() {
        guard !isDirty else {
            statusMessage = L10n.tr("请先保存未保存的配置，再验证连接。")
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
            statusMessage = L10n.tr("API 基础地址不能为空；请填写地址或恢复默认地址。")
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
            statusIsError = result.error != nil
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
            // Return to settings only after configuration and any requested
            // credential update succeed; partial failures stay visible for retry.
            if result.isComplete {
                dismiss()
            }
        }
    }

    private func deleteKey() {
        isSaving = true
        statusMessage = nil
        Task { @MainActor in
            do {
                try await settings.removeProviderCredential(providerID: provider.id)
                statusMessage = L10n.tr("API Key 已删除。")
                statusIsError = false
            } catch {
                statusMessage = ProductPrivacy.error(error).message
                statusIsError = true
            }
            isSaving = false
        }
    }
}

/// Editor-local secrets are never read back from storage or copied into drafts.
struct CustomProviderSheet: View {
    let settings: GlobalSettingsModel
    let preset: ProviderPreset?
    @Environment(\.dismiss) private var dismiss
    @State private var savedProvider: CustomProviderConfiguration?
    @State private var name: String
    @State private var baseURL: String
    @State private var modelIDs: String
    @State private var transport: ProviderTransport
    @State private var jsonMode: ProviderJSONMode
    @State private var imageDetail: ImageDetail
    @State private var notes: String
    @State private var apiKey = ""
    @State private var revealsKey = false
    @State private var advanced = false
    @State private var submitting = false
    @State private var confirmsDeletion = false

    init(settings: GlobalSettingsModel, provider: CustomProviderConfiguration? = nil, preset: ProviderPreset? = nil) {
        self.settings = settings
        self.preset = preset
        _savedProvider = State(initialValue: provider)
        _name = State(initialValue: provider?.name ?? preset?.name ?? "")
        _baseURL = State(initialValue: provider?.baseUrl ?? preset?.baseURL ?? "")
        _modelIDs = State(initialValue: provider?.manualModelIds.joined(separator: ", ") ?? preset?.suggestedModelID ?? "")
        _transport = State(initialValue: provider?.transport ?? preset?.transport ?? .chatCompletions)
        _jsonMode = State(initialValue: provider?.jsonMode ?? preset?.jsonMode ?? .jsonSchema)
        _imageDetail = State(initialValue: provider?.imageDetail ?? .high)
        _notes = State(initialValue: provider?.notes ?? preset?.notes ?? "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(savedProvider == nil ? L10n.tr("添加 Provider") : L10n.tr("编辑自定义 Provider")).font(.title2.bold())
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if let preset {
                        Text(L10n.message(preset.notes)).font(.callout).foregroundStyle(.secondary)
                        HStack {
                            Link(L10n.tr("官网"), destination: preset.websiteURL)
                            Link(L10n.tr("获取 API Key"), destination: preset.keyURL)
                            Link(L10n.tr("接口文档"), destination: preset.documentationURL)
                        }
                    }
                    field(L10n.tr("名称"), text: $name)
                    field("HTTP(S) Base URL", text: $baseURL)
                    VStack(alignment: .leading, spacing: 6) {
                        Text("API Key").font(.headline)
                        HStack {
                            if revealsKey { TextField(L10n.tr("留空保留当前 API Key"), text: $apiKey) }
                            else { SecureField(L10n.tr("留空保留当前 API Key"), text: $apiKey) }
                            Button { revealsKey.toggle() } label: { Image(systemName: revealsKey ? "eye.slash" : "eye") }
                                .help(revealsKey ? L10n.tr("隐藏 API Key") : L10n.tr("显示 API Key"))
                                .accessibilityLabel(revealsKey ? L10n.tr("隐藏 API Key") : L10n.tr("显示 API Key"))
                        }
                        Text(L10n.tr("凭据使用 AES-256-GCM 加密保存在本机，保存后不会回显。"))
                            .font(.caption).foregroundStyle(.secondary)
                        if let id = savedProvider?.id, let state = settings.live?.credentialStatuses[id],
                           let notice = ProviderListPresentation.credentialNotice(state) {
                            // Custom and built-in editors share the same recovery guidance.
                            Label(notice, systemImage: "exclamationmark.triangle")
                                .font(.caption).foregroundStyle(SlateSyncTheme.warning)
                        }
                        if savedProvider != nil {
                            Button(L10n.tr("删除已保存 API Key"), role: .destructive) { confirmsDeletion = true }
                        }
                    }
                    field(L10n.tr("手动模型 ID（逗号分隔）"), text: $modelIDs)
                    field(L10n.tr("备注"), text: $notes)
                    DisclosureGroup(L10n.tr("高级配置"), isExpanded: $advanced) {
                        VStack(alignment: .leading, spacing: 10) {
                            Picker(L10n.tr("传输"), selection: $transport) {
                                Text("Chat Completions").tag(ProviderTransport.chatCompletions)
                                Text("Responses").tag(ProviderTransport.responses)
                            }
                            Picker(L10n.tr("JSON 模式"), selection: $jsonMode) {
                                Text("JSON Schema").tag(ProviderJSONMode.jsonSchema)
                                Text("JSON Object").tag(ProviderJSONMode.jsonObject)
                                Text("Prompt").tag(ProviderJSONMode.prompt)
                            }
                            Picker(L10n.tr("图像细节"), selection: $imageDetail) {
                                Text(L10n.tr("自动")).tag(ImageDetail.auto)
                                Text(L10n.tr("低")).tag(ImageDetail.low)
                                Text(L10n.tr("高")).tag(ImageDetail.high)
                                Text(L10n.tr("原始")).tag(ImageDetail.original)
                            }
                        }.padding(.top, 10)
                    }
                    if case .failed(let error) = settings.operation {
                        Label(L10n.message(error.message), systemImage: "exclamationmark.triangle")
                            .foregroundStyle(SlateSyncTheme.danger).textSelection(.enabled)
                    }
                }.textFieldStyle(.roundedBorder).padding(2)
            }
            Divider()
            HStack {
                if submitting { ProgressView().controlSize(.small) }
                Spacer()
                Button(L10n.tr("取消"), role: .cancel) { dismiss() }
                Button(L10n.tr("保存配置")) { save() }.slatePrimaryActionStyle()
            }
        }.padding(20).frame(minWidth: 500, idealWidth: 620, minHeight: 440, idealHeight: 540)
        .disabled(submitting).interactiveDismissDisabled(submitting)
        .onDisappear { apiKey = "" }
        .confirmationDialog(L10n.tr("删除 API Key"), isPresented: $confirmsDeletion, titleVisibility: .visible) {
            Button(L10n.tr("删除 API Key"), role: .destructive) {
                guard let savedProvider else { return }
                submitting = true
                Task {
                    defer { submitting = false }
                    do { try await settings.removeProviderCredential(providerID: savedProvider.id) }
                    catch { /* The settings model owns the sanitized inline error. */ }
                }
            }
        }
    }

    private func field(_ title: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.headline)
            TextField(title, text: text).labelsHidden().accessibilityLabel(title)
        }
    }

    private func save() {
        guard !submitting else { return }
        submitting = true
        Task {
            defer { submitting = false }
            let result = await settings.saveCustomProviderConfiguration(
                existing: savedProvider, name: name, baseURL: baseURL, modelIDs: modelIDs,
                transport: transport, jsonMode: jsonMode, imageDetail: imageDetail,
                notes: notes, sourcePresetID: preset?.id ?? savedProvider?.sourcePresetID,
                apiKey: apiKey.isEmpty ? nil : apiKey
            )
            savedProvider = result.provider
            // A refresh failure must not keep a successfully persisted key in the editor.
            if result.credentialSaved { apiKey = "" }
            if result.isComplete { dismiss() }
        }
    }
}

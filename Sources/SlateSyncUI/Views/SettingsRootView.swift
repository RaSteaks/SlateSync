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
    @State private var providerStartsWithModels = false
    @State private var showsCustomProvider = false
    @State private var showsPresetPicker = false
    @State private var providerSearch = ""
    @State private var showsUnconfigured = false
    @State private var showsBackups = false
    @State private var showsDefaultSelection = false
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
                        definition: definition, startsAtModels: providerStartsWithModels
                    )
                } else {
                    if let custom = settings.customProviders.first(where: { $0.id == provider.id }) {
                        CustomProviderSheet(settings: settings, provider: custom, startsAtModels: providerStartsWithModels)
                    }
                }
            }
        }
        .sheet(isPresented: $showsCustomProvider) {
            CustomProviderSheet(settings: settings)
        }
        .sheet(isPresented: $showsDefaultSelection) { ProviderDefaultSelectionSheet(settings: settings) }
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
        .sheet(isPresented: Binding(
            get: { providerPendingDeletion != nil },
            set: { if !$0 { providerPendingDeletion = nil } }
        )) {
            if let provider = providerPendingDeletion { ProviderDeletionSheet(settings: settings, provider: provider) }
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
                SlateSearchField(title: L10n.tr("搜索模型服务"), text: $providerSearch, identifier: "providers.search")
                Button(L10n.tr("添加模型服务"), systemImage: "plus") { showsPresetPicker = true }
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
                            VStack(alignment: .leading, spacing: 8) {
                                // A native Button makes the complete disclosure header an activation target.
                                Button { showsBackups.toggle() } label: {
                                    Label(L10n.tr("备用模型"), systemImage: showsBackups ? "chevron.down" : "chevron.right")
                                }
                                .buttonStyle(.plain)
                                .accessibilityValue(showsBackups ? L10n.tr("已展开") : L10n.tr("已折叠"))
                                if showsBackups {
                                    VStack(alignment: .leading, spacing: 8) {
                                        ForEach(backupChain, id: \.self) { backupRow($0) }
                                        backupAddMenu.disabled(backupChain.count >= 8 || settings.operation.isRunning)
                                    }
                                }
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
                if case .running(let label) = settings.operation {
                    // Loading, credential removal and saves retain their actual operation name.
                    ProgressView().controlSize(.small)
                    Text(L10n.message(label)).font(.caption)
                } else {
                    Text(L10n.tr("默认和备用操作立即保存" )).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
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
        let selections = ProviderSelections(settings.live?.values ?? .init())
        return HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(L10n.tr("默认识别模型")).font(.headline)
                if let pair = selections.primary {
                    let name = providerEntries.first { $0.id == pair.providerID }.map { L10n.providerLabel($0) } ?? pair.providerID
                    Text("\(name) · \(pair.modelID)").textSelection(.enabled)
                } else {
                    Text(L10n.tr("还没有默认模型，请先配置并验证模型服务。"))
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
            Spacer()
            Button(L10n.tr("更改…")) { showsDefaultSelection = true }
                .disabled(settings.operation.isRunning).accessibilityIdentifier("providers.default.change")
        }
    }

    private func backupRow(_ pair: ProviderModelSelection) -> some View {
        let index = backupChain.firstIndex(of: pair) ?? 0
        let label = providerEntries.first(where: { $0.id == pair.providerID }).map { L10n.providerLabel($0) } ?? pair.providerID
        return HStack {
            Text("\(label) · \(pair.modelID)").lineLimit(1)
            Spacer()
            Button(L10n.tr("上移"), systemImage: "arrow.up") { moveBackup(index, by: -1) }
                .disabled(index == 0 || settings.operation.isRunning)
            Button(L10n.tr("下移"), systemImage: "arrow.down") { moveBackup(index, by: 1) }
                .disabled(index == backupChain.count - 1 || settings.operation.isRunning)
            Button(L10n.tr("移除"), systemImage: "minus.circle", role: .destructive) {
                Task { await settings.commitProviderChange(.removeBackup(pair)) }
            }.disabled(settings.operation.isRunning)
        }
    }

    private var backupAddMenu: some View {
        Menu(L10n.tr("添加备用模型…"), systemImage: "plus") {
            ForEach(providerEntries.filter(\.configured), id: \.id) { provider in
                Menu(L10n.providerLabel(provider)) {
                    ForEach(verifiedModels(for: provider.id), id: \.id) { model in
                        Button(model.label) {
                            let pair = ProviderModelSelection(providerID: provider.id, modelID: model.id)
                            guard !backupChain.contains(pair), backupChain.count < 8 else { return }
                            Task { await settings.commitProviderChange(.addBackup(pair)) }
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
            Text(L10n.tr("模型服务列表") + " · \(matchingProviders.count)").font(.headline)
            ForEach(matchingProviders.filter { isAdded($0) }, id: \.id) { provider in
                providerRow(provider)
            }
            if !matchingProviders.contains(where: { isAdded($0) }) && providerSearch.isEmpty {
                Text(L10n.tr("尚未配置模型服务，请添加或展开下方内建服务。"))
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
                Text(L10n.tr("没有匹配的模型服务，请尝试其他关键词。"))
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
        guard let snapshot = settings.live else { return [] }
        return snapshot.models.filter {
            $0.providers.contains(providerID) && ProviderPresentation.isVerified(.init(providerID: providerID, modelID: $0.id), in: snapshot)
        }
    }

    private var backupChain: [ProviderModelSelection] {
        ProviderSelections(settings.live?.values ?? .init()).backups
    }

    /// Reorder by stable pair identity; the model rebases on the latest committed chain.
    private func moveBackup(_ index: Int, by offset: Int) {
        guard backupChain.indices.contains(index) else { return }
        let pair = backupChain[index]
        Task { await settings.commitProviderChange(.moveBackup(pair, offset)) }
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
            notes: custom?.notes, isDefault: settings.live?.values[.defaultProviderID] == provider.id
        ) {
            HStack(spacing: 8) {
                credentialStatusChip(provider.id)
                CapabilityChip(capability)
                Spacer()
                Button(L10n.tr("配置…")) { providerStartsWithModels = false; credentialProvider = provider }
                Button(L10n.tr("刷新模型"), systemImage: "arrow.clockwise") {
                    Task { await settings.discover(providerID: provider.id) }
                }.disabled(settings.providerOperations[provider.id]?.isRunning == true || !provider.configured)
                Menu {
                Menu(L10n.tr("设为默认")) {
                    ForEach(verifiedModels(for: provider.id), id: \.id) { model in
                        Button(model.label) {
                            Task { await settings.setDefaultPair(providerID: provider.id, modelID: model.id) }
                        }
                    }
                }
                Menu(L10n.tr("添加到备用列表")) {
                    ForEach(verifiedModels(for: provider.id), id: \.id) { model in
                        Button(model.label) {
                            let pair = ProviderModelSelection(providerID: provider.id, modelID: model.id)
                            guard !backupChain.contains(pair), backupChain.count < 8 else { return }
                            Task { await settings.commitProviderChange(.addBackup(pair)) }
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
                // SwiftUI Menu 在 macOS 15 与 26 上暴露的元素类型不同
                // （PopUpButton / menuButton），测试用固定标识符做类型无关查询。
                .accessibilityIdentifier("providers.moreActions")
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
        ProviderOperationFeedback(settings: settings, providerID: providerID,
            retry: {
                let failed = settings.probeResults[providerID]?.results.filter { $0.capabilityStatus == .failed }.map(\.model) ?? []
                Task {
                    if failed.isEmpty { await settings.discover(providerID: providerID) }
                    else { await settings.probe(providerID: providerID, modelIDs: failed) }
                }
            },
            editCredential: { providerStartsWithModels = false; credentialProvider = providerEntries.first { $0.id == providerID } },
            editAddress: { providerStartsWithModels = false; credentialProvider = providerEntries.first { $0.id == providerID } })
        // Validation is always reachable, including persisted manual models and failed discovery.
        Button(L10n.tr("选择并验证模型")) {
            providerStartsWithModels = true
            credentialProvider = providerEntries.first { $0.id == providerID }
        }.disabled(settings.operation.isRunning)
    }

}

/// Built-in Providers share one guided form. It deliberately keeps the API
/// Key write separate from ordinary settings and never asks the service for a
/// previously stored secret.
struct BuiltinProviderConfigurationSheet: View {
    let settings: GlobalSettingsModel
    let provider: ProviderSummary
    let definition: ProviderCatalog.Definition
    var onBack: (() -> Void)? = nil
    var startsAtModels = false
    var body: some View { ProviderConfigurationSheet(settings: settings, definition: definition, onBack: onBack, startsAtModels: startsAtModels) }
}

/// Existing callers retain their identities while both editors use one setup flow.
struct CustomProviderSheet: View {
    let settings: GlobalSettingsModel
    var provider: CustomProviderConfiguration? = nil
    var preset: ProviderPreset? = nil
    var onBack: (() -> Void)? = nil
    var startsAtModels = false
    var body: some View { ProviderConfigurationSheet(settings: settings, provider: provider, preset: preset, onBack: onBack, startsAtModels: startsAtModels) }
}

import SlateSyncDomain
import SlateSyncWorkflow
import SwiftUI

/// Editing metadata has value semantics; secret input remains separate, view-local state.
private struct ProviderEditorDraft: Equatable {
    var name: String
    var baseURL: String
    var modelIDs: String
    var notes: String
    var transport: ProviderTransport
    var jsonMode: ProviderJSONMode
    var imageDetail: ImageDetail
    var advanced: [GlobalSettingKey: String]

    var parsedModelIDs: [String] {
        var seen = Set<String>()
        return modelIDs.split(whereSeparator: { $0 == "," || $0 == "\n" })
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    func requestDiffers(from other: Self) -> Bool {
        (try? CustomProviderValidator.normalizeBaseURL(baseURL)) != (try? CustomProviderValidator.normalizeBaseURL(other.baseURL))
            || parsedModelIDs != other.parsedModelIDs || transport != other.transport
            || jsonMode != other.jsonMode || imageDetail != other.imageDetail || advanced != other.advanced
    }
}

/// One editor owns staged saving, discovery, verification and activation for every service.
/// It never treats a successful GET or credential write as recognition proof.
struct ProviderConfigurationSheet: View {
    let settings: GlobalSettingsModel
    let definition: ProviderCatalog.Definition?
    let preset: ProviderPreset?
    var onBack: (() -> Void)?
    @Environment(\.dismiss) private var dismiss
    @State private var providerID: String?
    @State private var draft: ProviderEditorDraft
    @State private var savedDraft: ProviderEditorDraft
    @State private var apiKey = ""
    @State private var revealsKey = false
    @State private var advanced = false
    @State private var editsAddress: Bool
    @State private var stage = 0
    @State private var hasSaved: Bool
    @State private var needsStatusRefresh = false
    @State private var message: String?
    @State private var messageIsError = false
    @State private var errors: [Field: String] = [:]
    @State private var selected = Set<String>()
    @State private var requestTask: Task<Void, Never>?
    @State private var confirmExit = false
    @State private var exitToPresets = false
    @State private var confirmKeyDeletion = false
    @State private var remoteResult: ModelDiscoveryResult?
    @State private var originalRoles: ProviderSelections?
    @State private var expectedRoles: ProviderSelections?
    @State private var lastProbeIDs: [String] = []
    // Additional built-in OpenRouter IDs are persisted by successful capability probes,
    // rather than becoming unverified connection settings or expanding remote discovery.
    @State private var openRouterModelID = ""
    @FocusState private var focused: Field?
    private enum Field: Hashable { case name, address, key, models, openRouterModel; case option(GlobalSettingKey) }

    init(settings: GlobalSettingsModel, definition: ProviderCatalog.Definition? = nil,
         provider: CustomProviderConfiguration? = nil, preset: ProviderPreset? = nil, onBack: (() -> Void)? = nil, startsAtModels: Bool = false) {
        self.settings = settings
        self.definition = definition
        self.preset = preset
        self.onBack = onBack
        let values = settings.live?.values ?? GlobalSettingsValidator.defaults
        let initial = ProviderEditorDraft(
            name: provider?.name ?? preset?.name ?? definition?.label ?? "",
            baseURL: definition.map { values[$0.baseURLSetting] ?? $0.defaultBaseURL } ?? provider?.baseUrl ?? preset?.baseURL ?? "",
            modelIDs: provider?.manualModelIds.joined(separator: ", ") ?? preset?.suggestedModelID ?? "",
            notes: provider?.notes ?? preset?.notes ?? "",
            transport: definition?.transport ?? provider?.transport ?? preset?.transport ?? .chatCompletions,
            jsonMode: definition?.jsonMode ?? provider?.jsonMode ?? preset?.jsonMode ?? .jsonSchema,
            imageDetail: provider?.imageDetail ?? .high,
            advanced: Dictionary(uniqueKeysWithValues: (definition?.advancedOptions ?? []).map { ($0.key, values[$0.key] ?? $0.defaultValue) }))
        _draft = State(initialValue: initial)
        _savedDraft = State(initialValue: initial)
        _providerID = State(initialValue: definition?.id ?? provider?.id)
        _hasSaved = State(initialValue: provider != nil || definition.map { settings.live?.configuredCredentialProviderIDs.contains($0.id) == true } == true)
        _editsAddress = State(initialValue: definition == nil && preset == nil)
        // Saved anonymous endpoints can open models directly; credential-required
        // built-ins start at configuration until their key is actually available.
        let canOpenModels = ProviderPresentation.canUseModels(requiresCredential: definition?.credentialRequired == true,
            hasSavedCredential: definition.map { settings.live?.configuredCredentialProviderIDs.contains($0.id) == true } == true)
        _stage = State(initialValue: startsAtModels && canOpenModels ? 1 : 0)
    }

    private var dirty: Bool { draft != savedDraft || !apiKey.isEmpty }
    private var enteredOpenRouterModelID: String { openRouterModelID.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var hasManualModelDraft: Bool { definition?.kind == .openRouter && !enteredOpenRouterModelID.isEmpty }
    private var busy: Bool { requestTask != nil || settings.operation.isRunning || providerID.map { settings.providerOperations[$0]?.isRunning == true } == true }
    private var requestChanged: Bool { draft.requestDiffers(from: savedDraft) || !apiKey.isEmpty }
    private var hasKey: Bool { providerID.map { settings.live?.configuredCredentialProviderIDs.contains($0) == true } == true }
    private var canDiscover: Bool {
        ProviderPresentation.canUseModels(requiresCredential: definition?.credentialRequired == true, hasSavedCredential: hasKey)
    }
    private var models: [ModelData] {
        guard let providerID else { return [] }
        var result = ProviderPresentation.models(providerID: providerID, snapshot: settings.live,
            discovery: settings.discoveryResults[providerID] ?? remoteResult, probe: settings.probeResults[providerID])
        // Newly typed manual IDs must be selectable before the next saved verification.
        for id in draft.parsedModelIDs where definition == nil && !result.contains(where: { ($0.apiId ?? $0.id) == id }) {
            result.append(.init(id: id, label: id, description: "", providers: [providerID], capabilityStatus: .pending))
        }
        return result
    }
    private var selectedVerified: ModelData? {
        guard !dirty, !hasManualModelDraft, selected.count == 1, let id = selected.first, let providerID, let snapshot = settings.live,
              ProviderPresentation.isVerified(.init(providerID: providerID, modelID: id), in: snapshot) else { return nil }
        return models.first { $0.id == id }
    }
    private var accountURL: URL? {
        preset?.keyURL ?? definition?.apiKeyURL.flatMap(URL.init(string:))
    }
    private var impactedRoles: ProviderSelections? {
        guard requestChanged, let providerID, let values = settings.live?.values else { return nil }
        let roles = ProviderSelections(values)
        return roles.contains(providerID) ? roles : nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if stage == 0 { configuration }
                    else { modelConfiguration }
                    if let message {
                        Label(message, systemImage: messageIsError ? "exclamationmark.circle" : "checkmark.circle")
                            .foregroundStyle(messageIsError ? SlateSyncTheme.danger : SlateSyncTheme.success)
                            .font(.callout).textSelection(.enabled)
                    }
                }.padding(4)
            }
            // Native automation must distinguish this clipped content viewport
            // from the fixed footer before interacting with a model row.
            .accessibilityIdentifier("providers.editor.content")
            Divider()
            actions
        }
        .padding(20).frame(minWidth: 560, idealWidth: 640, maxWidth: 780, minHeight: 430, idealHeight: 580)
        .interactiveDismissDisabled(dirty || hasManualModelDraft || busy)
        .confirmationDialog(L10n.tr("放弃未保存的修改？"), isPresented: $confirmExit, titleVisibility: .visible) {
            Button(L10n.tr("放弃修改"), role: .destructive) { finishExit() }
            Button(L10n.tr("继续编辑"), role: .cancel) {}
        } message: { Text(L10n.tr("已保存的配置会保留，仅放弃本次未保存的修改。")) }
        .confirmationDialog(L10n.tr("删除 API Key"), isPresented: $confirmKeyDeletion, titleVisibility: .visible) {
            Button(L10n.tr("删除 API Key"), role: .destructive) { deleteKey() }
            Button(L10n.tr("取消"), role: .cancel) {}
        } message: { Text(L10n.tr("只删除本机保存的 API Key，不会在服务商平台注销。需要重新填写并验证模型。")) }
        .onChange(of: focused) { previous, _ in
            if let previous { validateField(previous) }
        }
        .onChange(of: draft.baseURL) { invalidateNetworkResult() }
        .onChange(of: draft.transport) { invalidateNetworkResult() }
        .onChange(of: draft.jsonMode) { invalidateNetworkResult() }
        .onChange(of: draft.imageDetail) { invalidateNetworkResult() }
        .onChange(of: draft.advanced) { invalidateNetworkResult() }
        .onChange(of: apiKey) { remoteResult = nil }
        .onDisappear {
            requestTask?.cancel()
            apiKey = ""
            if let providerID, settings.providerOperations[providerID]?.isRunning == true {
                Task { await settings.cancelProbe(providerID: providerID) }
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(definition.map { L10n.message($0.label) } ?? (draft.name.isEmpty ? L10n.tr("添加模型服务") : draft.name))
                    .font(.title2.bold())
                Spacer()
                Text(dirty ? L10n.tr("有未保存修改") : (hasSaved ? L10n.tr("配置已保存") : L10n.tr("尚未保存")))
                    .font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Button(L10n.tr("连接配置")) { stage = 0 }.disabled(busy)
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary)
                Button(L10n.tr("选择并验证模型")) { stage = 1 }.disabled(!hasSaved || dirty || busy || !canDiscover)
            }
            if hasSaved { Text(L10n.tr("分步保存：关闭不会撤销已保存的配置。" )).font(.caption).foregroundStyle(.secondary) }
        }
    }

    private var configuration: some View {
        VStack(alignment: .leading, spacing: 14) {
            if definition == nil { input(L10n.tr("名称"), text: $draft.name, field: .name) }
            HStack {
                if let accountURL { Link(L10n.tr("获取 API Key"), destination: accountURL) }
                if let url = preset?.documentationURL ?? definition?.documentationURL.flatMap(URL.init(string:)) {
                    Link(L10n.tr("官方配置文档"), destination: url)
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                Text(hasKey ? L10n.tr("替换 API Key") : "API Key").font(.headline)
                HStack {
                    Group {
                        if revealsKey { TextField(keyPlaceholder, text: $apiKey) }
                        else { SecureField(keyPlaceholder, text: $apiKey) }
                    }.focused($focused, equals: .key).accessibilityIdentifier("providers.editor.key")
                    Button { revealsKey.toggle() } label: { Image(systemName: revealsKey ? "eye.slash" : "eye") }
                        .accessibilityLabel(revealsKey ? L10n.tr("隐藏 API Key") : L10n.tr("显示 API Key"))
                        .help(revealsKey ? L10n.tr("隐藏 API Key") : L10n.tr("显示 API Key"))
                }
                fieldError(.key)
                Text(L10n.tr("凭据使用 AES-256-GCM 加密保存在本机，保存后不会回显。"))
                    .font(.caption).foregroundStyle(.secondary)
                if hasKey {
                    Label(L10n.tr("密钥已保存，模型识别能力需单独验证。"), systemImage: "lock.fill")
                        .font(.caption).foregroundStyle(.secondary)
                    Button(L10n.tr("删除已保存 API Key"), role: .destructive) { confirmKeyDeletion = true }
                } else if let providerID, let status = settings.live?.credentialStatuses[providerID],
                          let notice = ProviderListPresentation.credentialNotice(status) {
                    Text(notice).font(.caption).foregroundStyle(SlateSyncTheme.warning)
                }
            }
            DisclosureGroup(L10n.tr("修改地址"), isExpanded: $editsAddress) {
                input(L10n.tr("API 基础地址（Base URL）"), text: $draft.baseURL, field: .address)
                if let warning = ProviderURLGuidance.baseURLWarning(in: draft.baseURL, transport: draft.transport) {
                    Text(L10n.message(warning)).font(.caption).foregroundStyle(SlateSyncTheme.warning)
                }
                if let defaultURL = definition?.defaultBaseURL ?? preset?.baseURL {
                    Button(L10n.tr("恢复默认地址")) { draft.baseURL = defaultURL }
                }
            }
            if !editsAddress { Text(draft.baseURL).font(.caption.monospaced()).textSelection(.enabled).foregroundStyle(.secondary) }
            DisclosureGroup(L10n.tr("高级配置"), isExpanded: $advanced) { advancedFields.padding(.top, 8) }
            if impactedRoles != nil || (originalRoles != nil && requestChanged) {
                Label(L10n.tr("此修改会撤销旧验证，并停用该服务的默认和备用模型。保存后请重新验证，可恢复原用途。"), systemImage: "exclamationmark.triangle")
                    .font(.callout).foregroundStyle(SlateSyncTheme.warning)
                if let roles = impactedRoles, let providerID {
                    if let pair = roles.primary, pair.providerID == providerID { Text(L10n.tr("默认模型：{0}", [pair.modelID])).font(.caption) }
                    ForEach(roles.backups.filter { $0.providerID == providerID }, id: \.self) { pair in
                        Text(L10n.tr("备用模型：{0}", [pair.modelID])).font(.caption)
                    }
                }
            }
        }.textFieldStyle(.roundedBorder).disabled(busy)
    }

    private var keyPlaceholder: String { hasKey ? L10n.tr("留空保留当前 API Key") : L10n.tr("粘贴服务商提供的 API Key") }

    @ViewBuilder private var advancedFields: some View {
        if let definition {
            Text(L10n.message(definition.protocolDescription)).font(.caption).foregroundStyle(.secondary)
            ForEach(definition.advancedOptions) { option in
                VStack(alignment: .leading, spacing: 4) {
                    input(L10n.message(option.title), text: Binding(get: { draft.advanced[option.key] ?? "" }, set: { draft.advanced[option.key] = $0 }), field: .option(option.key))
                    Text(L10n.message(option.description)).font(.caption).foregroundStyle(.secondary)
                }
            }
        } else {
            Picker(L10n.tr("API 协议"), selection: $draft.transport) {
                Text("Chat Completions").tag(ProviderTransport.chatCompletions)
                Text("Responses").tag(ProviderTransport.responses)
            }
            Picker(L10n.tr("JSON 模式"), selection: $draft.jsonMode) {
                Text("JSON Schema").tag(ProviderJSONMode.jsonSchema)
                Text("JSON Object").tag(ProviderJSONMode.jsonObject)
                Text("Prompt").tag(ProviderJSONMode.prompt)
            }
            Picker(L10n.tr("图像细节"), selection: $draft.imageDetail) {
                Text(L10n.tr("自动")).tag(ImageDetail.auto)
                Text(L10n.tr("低")).tag(ImageDetail.low)
                Text(L10n.tr("高")).tag(ImageDetail.high)
                Text(L10n.tr("原始")).tag(ImageDetail.original)
            }
            input(L10n.tr("手动模型 ID（逗号分隔）"), text: $draft.modelIDs, field: .models)
            TextField(L10n.tr("备注"), text: $draft.notes)
        }
    }

    private var modelConfiguration: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L10n.tr("获取列表不代表识别验证通过。验证只发送内置测试图片，服务商可能计费。"))
                .font(.caption).foregroundStyle(.secondary)
            if let providerID {
                ProviderOperationFeedback(settings: settings, providerID: providerID, retry: retry,
                    editCredential: { stage = 0; focused = .key }, editAddress: { stage = 0; editsAddress = true; focused = .address }, accountURL: accountURL)
            }
            HStack {
                Button(L10n.tr("刷新模型")) { fetch() }.disabled(busy || dirty || !canDiscover)
                if selected.count > 1 {
                    Button(L10n.tr("验证所选 {0} 个模型", [String(selected.count)])) { verify(Array(selected)) }.disabled(busy)
                }
            }
            if definition == nil {
                Text(L10n.tr("验证新增模型前会先保存模型列表，并撤销该服务的旧验证及默认、备用用途。"))
                    .font(.caption).foregroundStyle(.secondary)
                input(L10n.tr("手动模型 ID（逗号分隔）"), text: $draft.modelIDs, field: .models).disabled(busy)
                if dirty { Text(L10n.tr("模型列表有修改，验证前将先保存。" )).font(.caption).foregroundStyle(.secondary) }
            } else if definition?.kind == .openRouter {
                Text(L10n.tr("默认提供 Qwen、GPT Luna 和 GPT Terra。其他模型请输入 OpenRouter 的完整模型 ID，验证通过后可设为默认或备用。"))
                    .font(.caption).foregroundStyle(.secondary)
                input(L10n.tr("其他 OpenRouter 模型 ID"), text: $openRouterModelID, field: .openRouterModel)
                    .disabled(busy)
                Button(L10n.tr("验证并添加模型")) { verifyOpenRouterModel() }
                    .disabled(busy || dirty || enteredOpenRouterModelID.isEmpty || !canDiscover)
                    .accessibilityIdentifier("providers.editor.addOpenRouterModel")
            }
            ProviderModelList(models: models, selected: $selected, busy: busy, verify: verify)
        }
    }

    /// Role actions remain reachable without scrolling the model list. Long translated
    /// button titles can wrap into two footer rows without increasing the sheet minimum.
    private var actions: some View {
        VStack(alignment: .leading, spacing: 8) {
            if stage == 1, let model = selectedVerified {
                HStack {
                    Button(L10n.tr("添加为备用")) { activate(model, asDefault: false) }.disabled(busy)
                    if let id = providerID, let originalRoles, let expectedRoles, originalRoles.contains(id),
                       settings.live.map({ ProviderSelections($0.values) }) != originalRoles {
                        Button(L10n.tr("恢复原用途")) { restore(id, original: originalRoles, expected: expectedRoles) }.disabled(busy)
                    }
                    Spacer()
                }
            }
            ViewThatFits(in: .horizontal) {
                HStack { navigationActions; Spacer(); commitActions }
                VStack(alignment: .trailing, spacing: 8) {
                    HStack { navigationActions; Spacer() }
                    HStack { Spacer(); commitActions }
                }
            }
        }
    }

    @ViewBuilder private var navigationActions: some View {
        if onBack != nil { Button(L10n.tr("返回预设选择")) { requestExit(back: true) }.disabled(busy) }
        Button(hasSaved ? L10n.tr("关闭") : L10n.tr("取消"), role: .cancel) { requestExit(back: false) }
            .keyboardShortcut(.cancelAction).disabled(busy)
    }

    @ViewBuilder private var commitActions: some View {
        if requestTask != nil { ProgressView().controlSize(.small) }
        if stage == 0 {
            Button(L10n.tr("仅保存配置")) { saveAndContinue(fetchModels: false) }.disabled(busy || (!dirty && hasSaved && !needsStatusRefresh))
            Button(L10n.tr("保存并获取模型")) { saveAndContinue(fetchModels: true) }
                .slatePrimaryActionStyle().keyboardShortcut(.defaultAction).disabled(busy).accessibilityIdentifier("providers.editor.continue")
        } else if let model = selectedVerified {
            Button(L10n.tr("设为默认并完成")) { activate(model, asDefault: true) }
                .slatePrimaryActionStyle().keyboardShortcut(.defaultAction).disabled(busy).accessibilityIdentifier("providers.editor.activate")
        } else {
            Button(L10n.tr("验证所选模型")) { verify(Array(selected)) }
                .slatePrimaryActionStyle().keyboardShortcut(.defaultAction).disabled(busy || selected.isEmpty).accessibilityIdentifier("providers.editor.verify")
        }
    }

    private func input(_ title: String, text: Binding<String>, field: Field) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.headline)
            TextField(title, text: text).textFieldStyle(.roundedBorder).focused($focused, equals: field)
                .accessibilityIdentifier("providers.editor." + String(describing: field))
                .onSubmit { validateField(field) }
            fieldError(field)
        }
    }
    @ViewBuilder private func fieldError(_ field: Field) -> some View {
        if let error = errors[field] { Text(error).font(.caption).foregroundStyle(SlateSyncTheme.danger) }
    }
    private func validateField(_ field: Field) {
        switch field {
        case .address:
            // Endpoint-looking suffixes stay advisory, including for existing custom proxy routes.
            do { _ = try CustomProviderValidator.normalizeBaseURL(draft.baseURL); errors[field] = nil }
            catch { errors[field] = L10n.message(ProductPrivacy.error(error).message) }
        case .key:
            errors[field] = !apiKey.isEmpty && apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? L10n.tr("API Key 不能只包含空白字符") : nil
        case .name:
            let name = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
            errors[field] = name.isEmpty || name.unicodeScalars.count > 60 ? L10n.tr("名称需为 1–60 个字符") : nil
            if settings.customProviders.contains(where: { $0.id != providerID && $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
                errors[field] = L10n.tr("模型服务名称已存在")
            }
        case .models:
            errors[field] = draft.parsedModelIDs.contains(where: { !ProviderCatalog.isValidModelID($0) }) ? L10n.tr("模型 ID 格式无效，请检查空格或特殊字符。") : nil
        case .openRouterModel:
            errors[field] = !ProviderCatalog.isValidModelID(enteredOpenRouterModelID)
                ? L10n.tr("模型 ID 格式无效，请检查空格或特殊字符。") : nil
        case .option(let key):
            let value = draft.advanced[key] ?? ""
            if definition?.advancedOptions.first(where: { $0.key == key })?.isRequired == true && value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                errors[field] = L10n.tr("此项不能为空")
            } else {
                do { _ = try GlobalSettingsValidator.normalizedPatchValue(value, for: key); errors[field] = nil }
                catch { errors[field] = L10n.message(ProductPrivacy.error(error).message) }
            }
        }
    }
    private func validate() -> Bool {
        let fields: [Field] = definition == nil ? [.name, .address, .key, .models] : [.address, .key] + (definition?.advancedOptions.map { .option($0.key) } ?? [])
        for field in fields { validateField(field) }
        if let invalid = fields.first(where: { errors[$0] != nil }) {
            stage = 0
            if invalid == .address { editsAddress = true }
            if invalid == .models { advanced = true }
            if case .option = invalid { advanced = true }
            focused = invalid
            return false
        }
        return true
    }

    private func saveAndContinue(fetchModels: Bool) {
        guard !busy, validate(), !fetchModels || requireCredentialForRequest() else { return }
        requestTask = Task {
            defer { requestTask = nil }
            guard await saveDraft() else { return }
            if fetchModels, let providerID {
                stage = 1
                lastProbeIDs = []
                remoteResult = await settings.discover(providerID: providerID)
            }
        }
    }

    /// This is deliberately not a transaction across config and encrypted credentials.
    /// Track each completed boundary so a retry never repeats a successful key write.
    private func saveDraft() async -> Bool {
        if needsStatusRefresh && !dirty {
            let succeeded = await settings.refresh()
            needsStatusRefresh = !succeeded
            if succeeded { message = L10n.tr("配置状态已刷新"); messageIsError = false }
            return succeeded
        }
        if !dirty && hasSaved { return true }
        let submitted = draft
        if originalRoles == nil, let roles = impactedRoles, let providerID {
            originalRoles = roles
            expectedRoles = roles.removing(providerID)
        }
        var configurationSaved = false
        var credentialSaved = false
        var complete = false
        if let definition {
            var values = Dictionary(uniqueKeysWithValues: draft.advanced.map { ($0.key, Optional($0.value)) })
            values[definition.baseURLSetting] = draft.baseURL
            let result = await settings.saveBuiltinProviderConfiguration(providerID: definition.id, values: values, apiKey: apiKey.isEmpty ? nil : apiKey)
            configurationSaved = result.configurationSaved
            credentialSaved = result.credentialSaved
            complete = result.isComplete
            message = result.message
        } else {
            let existing = settings.live?.customProviders.first { $0.id == providerID }
            let result = await settings.saveCustomProviderConfiguration(existing: existing,
                name: draft.name, baseURL: draft.baseURL, modelIDs: draft.modelIDs, transport: draft.transport,
                jsonMode: draft.jsonMode, imageDetail: draft.imageDetail, notes: draft.notes,
                sourcePresetID: preset?.id ?? existing?.sourcePresetID, apiKey: apiKey.isEmpty ? nil : apiKey)
            if let id = result.provider?.id { providerID = id }
            configurationSaved = result.configurationSaved
            credentialSaved = result.credentialSaved
            complete = result.isComplete
            if case .failed(let error) = settings.operation { message = L10n.message(error.message) }
            else { message = complete ? L10n.tr("配置已保存") : L10n.tr("操作已取消") }
        }
        if configurationSaved { savedDraft = submitted; hasSaved = true }
        if credentialSaved { apiKey = "" }
        messageIsError = !complete
        needsStatusRefresh = configurationSaved && !complete && (credentialSaved || apiKey.isEmpty)
        return complete
    }

    /// Save-only remains possible offline; network actions identify the missing field before dispatch.
    private func requireCredentialForRequest() -> Bool {
        guard ProviderPresentation.canUseModels(requiresCredential: definition?.credentialRequired == true,
            hasSavedCredential: hasKey, draftKey: apiKey) else {
            errors[.key] = L10n.tr("请先填写 API Key")
            stage = 0; focused = .key
            return false
        }
        return true
    }

    private func fetch() {
        guard !busy, !dirty, hasSaved, requireCredentialForRequest(), let providerID else { return }
        requestTask = Task {
            defer { requestTask = nil }
            lastProbeIDs = []
            remoteResult = await settings.discover(providerID: providerID)
        }
    }
    private func verify(_ ids: [String]) {
        guard !busy, requireCredentialForRequest(), let providerID else { return }
        let physical = ids.map { id in models.first { $0.id == id }?.apiId ?? id }
        selected = Set(ids)
        if definition == nil {
            var persistedIDs = draft.parsedModelIDs
            for id in physical where !persistedIDs.contains(id) { persistedIDs.append(id) }
            draft.modelIDs = persistedIDs.joined(separator: ", ")
        }
        guard validate() else { return }
        requestTask = Task {
            defer { requestTask = nil }
            guard await saveDraft() else { return }
            lastProbeIDs = ids
            let result = await settings.probe(providerID: providerID, modelIDs: physical)
            // Clear only a successfully committed manual ID. Failures and cancellation
            // retain the entry so the existing probe feedback and retry remain actionable.
            if definition?.kind == .openRouter, physical == [enteredOpenRouterModelID],
               result?.canceled == false,
               result?.results.first?.capabilityStatus == .verified {
                openRouterModelID = ""
                errors[.openRouterModel] = nil
            }
            message = nil
        }
    }
    private func verifyOpenRouterModel() {
        guard !busy, !dirty, hasSaved else { return }
        validateField(.openRouterModel)
        guard errors[.openRouterModel] == nil else { focused = .openRouterModel; return }
        // Reuse the same credential gate, synthetic-image probe and persisted proof as every model row.
        verify([enteredOpenRouterModelID])
    }
    private func retry() {
        if lastProbeIDs.isEmpty { fetch() } else { verify(lastProbeIDs) }
    }
    private func activate(_ model: ModelData, asDefault: Bool) {
        guard !busy, let providerID else { return }
        requestTask = Task {
            defer { requestTask = nil }
            let pair = ProviderModelSelection(providerID: providerID, modelID: model.id)
            let success = await settings.commitProviderChange(asDefault ? .setDefault(pair) : .addBackup(pair))
            if success {
                if asDefault { dismiss() }
                else { message = L10n.tr("已添加为备用模型"); messageIsError = false }
            } else if case .failed(let error) = settings.operation { message = L10n.message(error.message); messageIsError = true }
        }
    }
    private func restore(_ id: String, original: ProviderSelections, expected: ProviderSelections) {
        requestTask = Task {
            defer { requestTask = nil }
            if await settings.commitProviderChange(.restore(providerID: id, original: original, expected: expected)) {
                message = L10n.tr("已恢复通过验证模型的原用途")
                messageIsError = false
                originalRoles = nil; expectedRoles = nil
            } else if case .failed(let error) = settings.operation { message = L10n.message(error.message); messageIsError = true }
        }
    }
    private func deleteKey() {
        guard !busy, let providerID else { return }
        let roles = settings.live.map { ProviderSelections($0.values) }
        // Retain the intended roles before removal too: revocation may commit even if key deletion fails.
        if originalRoles == nil, let roles, roles.contains(providerID) {
            originalRoles = roles; expectedRoles = roles.removing(providerID)
        }
        requestTask = Task {
            defer { requestTask = nil }
            do {
                try await settings.removeProviderCredential(providerID: providerID)
                apiKey = ""; selected = []; remoteResult = nil
                message = L10n.tr("API Key 已删除。"); messageIsError = false
            } catch { message = L10n.message(ProductPrivacy.error(error).message); messageIsError = true }
        }
    }
    private func invalidateNetworkResult() {
        remoteResult = nil
        selected = []
    }
    private func requestExit(back: Bool) {
        exitToPresets = back
        if dirty || hasManualModelDraft { confirmExit = true } else { finishExit() }
    }
    private func finishExit() {
        apiKey = ""
        if exitToPresets { onBack?() } else { dismiss() }
    }
}

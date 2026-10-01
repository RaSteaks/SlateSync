import SlateSyncDomain
import SwiftUI

/// Shared feedback preserves partial success and cancellation instead of treating completion as proof.
struct ProviderOperationFeedback: View {
    let settings: GlobalSettingsModel
    let providerID: String
    var retry: (() -> Void)? = nil
    var editCredential: (() -> Void)? = nil
    var editAddress: (() -> Void)? = nil
    var accountURL: URL? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if case .running(let message) = settings.providerOperations[providerID] {
                HStack {
                    ProgressView().controlSize(.small)
                    Text(L10n.message(message))
                    Spacer()
                    Button(L10n.tr("取消")) { Task { await settings.cancelProbe(providerID: providerID) } }
                }
            } else if case .failed(let error) = settings.providerOperations[providerID] {
                ProviderDiagnostic(message: ProviderPresentation.errorMessage(error), isError: true)
                recovery(error)
            } else if let result = settings.probeResults[providerID] {
                let passed = result.results.filter { $0.capabilityStatus == .verified }.count
                let allPassed = !result.canceled && result.total > 0 && passed == result.total
                Label(ProviderPresentation.probeSummary(result), systemImage: allPassed ? "checkmark.circle" : "exclamationmark.circle")
                    .foregroundStyle(allPassed ? SlateSyncTheme.success : (passed == 0 && !result.canceled ? SlateSyncTheme.danger : SlateSyncTheme.warning))
                if result.canceled { Text(L10n.tr("本次验证已取消，未保存新的验证结果。")) }
                if let failed = result.results.first(where: { $0.capabilityStatus == .failed }) {
                    recovery(.init(code: "MODEL_PROBE", message: failed.message, status: failed.status))
                }
            } else if case .canceled = settings.providerOperations[providerID] {
                Label(L10n.tr("操作已取消"), systemImage: "slash.circle")
            } else if let result = settings.discoveryResults[providerID] {
                Text(ProviderPresentation.discoverySummary(result))
                    .foregroundStyle(result.source == .api && result.modelsEndpointAvailable != false ? SlateSyncTheme.secondary : SlateSyncTheme.warning)
                if let warning = result.warning { ProviderDiagnostic(message: L10n.message(warning), isError: false) }
            }
        }
        .font(.caption)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityIdentifier("providers.operation")
    }
    /// Probe batches preserve HTTP failure categories just like discovery requests.
    private func recovery(_ error: SlateSyncError) -> some View {
        HStack {
            if ([401, 403].contains(error.status ?? 0) || error.code == RecognitionFailure.providerNotConfigured.code), let editCredential {
                Button(L10n.tr("修改密钥"), action: editCredential)
            } else if [400, 404, 405, 501].contains(error.status ?? 0), let editAddress {
                Button(L10n.tr("检查地址"), action: editAddress)
            }
            if [402, 429].contains(error.status ?? 0), let accountURL {
                Link(L10n.tr("查看服务商账户"), destination: accountURL)
            }
            if let retry { Button(L10n.tr("重试"), action: retry) }
        }
    }

}

/// One bounded, searchable model list serves both built-in and custom setup.
struct ProviderModelList: View {
    let models: [ModelData]
    @Binding var selected: Set<String>
    let busy: Bool
    let verify: ([String]) -> Void
    @State private var query = ""
    @State private var filter = -1

    private var matching: [ModelData] {
        models.filter { model in
            (filter == -1 || ProviderPresentation.rank(model.capabilityStatus) == filter)
                && (query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    || model.label.localizedStandardContains(query.trimmingCharacters(in: .whitespacesAndNewlines))
                    || (model.apiId ?? model.id).localizedStandardContains(query.trimmingCharacters(in: .whitespacesAndNewlines)))
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SlateSearchField(title: L10n.tr("搜索模型名称或 ID"), text: $query, identifier: "providers.models.search")
            Picker(L10n.tr("模型状态"), selection: $filter) {
                Text(L10n.tr("全部")).tag(-1)
                Text(L10n.tr("已验证")).tag(0)
                Text(L10n.tr("待验证")).tag(1)
                Text(L10n.tr("失败或取消")).tag(2)
                Text(L10n.tr("不支持识别")).tag(3)
            }
            if models.isEmpty {
                Text(L10n.tr("尚无模型。获取模型列表，或手动填写模型 ID。"))
                    .foregroundStyle(.secondary)
            } else if matching.isEmpty {
                Text(L10n.tr("没有匹配的模型，请清除搜索或更改筛选。"))
                    .foregroundStyle(.secondary)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(rows) { row in
                            VStack(alignment: .leading, spacing: 8) {
                                if row.startsGroup {
                                    Text(groupTitle(ProviderPresentation.rank(row.model.capabilityStatus)))
                                        .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                                        .accessibilityAddTraits(.isHeader)
                                }
                                ProviderModelRow(model: row.model, selected: $selected, busy: busy, verify: verify)
                            }
                        }
                    }.padding(4)
                }.frame(minHeight: 150, idealHeight: 230, maxHeight: 290)
                    // The list can extend beyond its parent content viewport;
                    // its AX identity lets tests account for both clipping bounds.
                    .accessibilityIdentifier("providers.models.list")
            }
        }
    }

    private func groupTitle(_ rank: Int) -> String {
        switch rank { case 0: L10n.tr("已验证"); case 1: L10n.tr("待验证"); case 2: L10n.tr("失败或取消"); default: L10n.tr("不支持识别") }
    }

    /// Data-driven row identities survive status-group changes. A constant outer
    /// range of lazy groups can retain stale native control labels and enabled state.
    private struct Row: Identifiable {
        let model: ModelData
        let startsGroup: Bool
        var id: String { model.id }
    }
    private var rows: [Row] {
        var seen = Set<Int>()
        return matching.map { model in
            Row(model: model, startsGroup: seen.insert(ProviderPresentation.rank(model.capabilityStatus)).inserted)
        }
    }
}

/// A row owns its invalidation boundary, so proof and operation changes update the native Toggle together.
private struct ProviderModelRow: View {
    let model: ModelData
    @Binding var selected: Set<String>
    let busy: Bool
    let verify: ([String]) -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Toggle(isOn: Binding(get: { selected.contains(model.id) }, set: { value in
                if value { selected.insert(model.id) } else { selected.remove(model.id) }
            })) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(model.label).lineLimit(2)
                    Text(model.apiId ?? model.id).font(.caption.monospaced()).textSelection(.enabled)
                    Text(ProviderPresentation.status(model.capabilityStatus)).font(.caption).foregroundStyle(.secondary)
                    if let message = model.capabilityMessage, !message.isEmpty, model.capabilityStatus != .verified {
                        ProviderDiagnostic(message: L10n.message(message), isError: model.capabilityStatus == .failed)
                    }
                }
            }.toggleStyle(.checkbox)
            .accessibilityIdentifier("providers.model." + model.id)
            Spacer(minLength: 0)
            if model.capabilityStatus != .unsupported {
                Button(model.capabilityStatus == .failed ? L10n.tr("重试验证") : L10n.tr("验证此模型")) { verify([model.id]) }
            }
        }.disabled(busy || model.capabilityStatus == .unsupported)
    }
}

/// Default selection remains explicit: changing a picker never persists a half pair.
struct ProviderDefaultSelectionSheet: View {
    let settings: GlobalSettingsModel
    @Environment(\.dismiss) private var dismiss
    @State private var providerID = ""
    @State private var modelID = ""
    private var providers: [ProviderSummary] {
        (settings.live?.providers ?? []).filter { provider in
            (settings.live?.models ?? []).contains { $0.providers.contains(provider.id) && eligible(provider.id, $0.id) }
        }
    }
    private func eligible(_ provider: String, _ model: String) -> Bool {
        guard let snapshot = settings.live else { return false }
        return ProviderPresentation.isVerified(.init(providerID: provider, modelID: model), in: snapshot)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(L10n.tr("默认识别模型")).font(.title2.bold())
            if providers.isEmpty { Text(L10n.tr("还没有通过验证的模型，请先配置并验证模型服务。")) }
            Picker(L10n.tr("模型服务"), selection: $providerID) {
                Text(L10n.tr("请选择")).tag("")
                ForEach(providers, id: \.id) { Text(L10n.providerLabel($0)).tag($0.id) }
            }.onChange(of: providerID) { modelID = "" }
            Picker(L10n.tr("模型"), selection: $modelID) {
                Text(L10n.tr("请选择")).tag("")
                ForEach((settings.live?.models ?? []).filter { eligible(providerID, $0.id) }, id: \.id) { Text($0.label).tag($0.id) }
            }
            if case .failed(let error) = settings.operation { ProviderDiagnostic(message: L10n.message(error.message), isError: true) }
            HStack {
                Button(L10n.tr("关闭"), role: .cancel) { dismiss() }
                if ProviderSelections(settings.live?.values ?? .init()).primary != nil {
                    Button(L10n.tr("清除默认模型")) {
                        Task { if await settings.commitProviderChange(.setDefault(nil)) { dismiss() } }
                    }
                }
                Spacer()
                Button(L10n.tr("设为默认")) {
                    Task { if await settings.setDefaultPair(providerID: providerID, modelID: modelID) { dismiss() } }
                }.slatePrimaryActionStyle().disabled(!eligible(providerID, modelID))
            }
        }.padding(20).frame(width: 480).disabled(settings.operation.isRunning)
            .interactiveDismissDisabled(settings.operation.isRunning)
    }
}

/// Keep a destructive confirmation mounted through persistence and recoverable errors.
struct ProviderDeletionSheet: View {
    let settings: GlobalSettingsModel
    let provider: CustomProviderConfiguration
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(L10n.tr("删除模型服务“{0}”？", [provider.name])).font(.title2.bold())
            Text(L10n.tr("仅删除服务配置及其默认、备用引用，立即生效。"))
            if case .failed(let error) = settings.operation {
                ProviderDiagnostic(message: L10n.message(error.message), isError: true)
            }
            HStack {
                Button(L10n.tr("取消"), role: .cancel) { dismiss() }
                Spacer()
                if settings.operation.isRunning { ProgressView().controlSize(.small) }
                Button(L10n.tr("删除"), role: .destructive) {
                    Task { if await settings.removeCustomProvider(id: provider.id) { dismiss() } }
                }
            }.disabled(settings.operation.isRunning)
        }.padding(20).frame(width: 440)
            .interactiveDismissDisabled(settings.operation.isRunning)
    }
}

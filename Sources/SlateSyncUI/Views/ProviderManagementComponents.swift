import SlateSyncDomain
import SlateSyncWorkflow
import SwiftUI

/// Local search has no network side effects and does not alter the catalog order.
enum ProviderListPresentation {
    static func isAdded(_ provider: ProviderSummary, credentialStatus: CredentialStatus?) -> Bool {
        provider.type == .custom || provider.configured || credentialStatus == .unavailable || credentialStatus == .authorizationRequired
            || credentialStatus == .temporarilyUnavailable || credentialStatus == .unreadable
    }

    /// Transient contention never suggests destructive recovery.
    static func credentialNotice(_ status: CredentialStatus) -> String? {
        switch status {
        case .temporarilyUnavailable: L10n.tr("本地凭据暂时被占用，请稍后重试。")
        case .unavailable: L10n.tr("无法访问本地凭据，请检查文件权限后重试。")
        case .unreadable: L10n.tr("本地凭据无法解密；如无法恢复，可重置本地凭据后重新填写 API Key。")
        default: nil
        }
    }

    static func matches(query: String, name: String, url: String, notes: String?) -> Bool {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return query.isEmpty || [name, url, notes ?? ""].contains { $0.localizedStandardContains(query) }
    }
}

/// Opaque cards associate diagnostics with their Provider without adding glass
/// per scrolling row. The established theme owns all visual roles.
struct ProviderCard<Content: View>: View {
    let title: String
    let source: String
    let baseURL: String
    let notes: String?
    let isDefault: Bool
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: "network").foregroundStyle(.secondary).accessibilityHidden(true)
                Text(title).font(.headline).lineLimit(2).help(title)
                Text(source).font(.caption).foregroundStyle(.secondary)
                Spacer()
                if isDefault { Label(L10n.tr("默认"), systemImage: "checkmark.circle.fill").font(.caption).foregroundStyle(SlateSyncTheme.accent) }
            }
            if !baseURL.isEmpty {
                Text(baseURL).font(.caption.monospaced()).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle).help(baseURL).textSelection(.enabled)
            }
            if let notes, !notes.isEmpty { Text(notes).font(.caption).foregroundStyle(.secondary).lineLimit(2).help(notes) }
            content()
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(SlateSyncTheme.evidenceSurface, in: RoundedRectangle(cornerRadius: SlateSyncTheme.panelRadius))
        .overlay(RoundedRectangle(cornerRadius: SlateSyncTheme.panelRadius).strokeBorder(isDefault ? SlateSyncTheme.accent : SlateSyncTheme.separator, lineWidth: 1))
        .accessibilityElement(children: .contain)
    }
}

/// A single sheet owns source selection and configuration. Keeping the editor
/// mounted on Back preserves its draft without publishing secrets to a model.
struct ProviderAddSheet: View {
    let settings: GlobalSettingsModel
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var route: String?
    @State private var showsEditor = false
    @State private var filter = "all"

    private var presets: [ProviderPreset] {
        ProviderPresets.all.filter {
            (filter == "all" || filter == $0.category.rawValue)
                && ProviderListPresentation.matches(query: query, name: $0.name, url: $0.baseURL, notes: $0.notes)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if showsEditor {
                Button(L10n.tr("返回预设选择"), systemImage: "chevron.left") { showsEditor = false }
                    .disabled(settings.operation.isRunning)
            }
            ZStack {
                selection.opacity(showsEditor ? 0 : 1).allowsHitTesting(!showsEditor).accessibilityHidden(showsEditor)
                if let route {
                    editor(route).opacity(showsEditor ? 1 : 0).allowsHitTesting(showsEditor).accessibilityHidden(!showsEditor)
                }
            }
        }.padding(20).frame(width: 680, height: 600)
        .interactiveDismissDisabled(settings.operation.isRunning)
    }

    private var selection: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(L10n.tr("添加 Provider")).font(.title2.bold())
            Text(L10n.tr("选择服务后填写配置和 API Key；模型能力需另行验证。"))
                .font(.callout).foregroundStyle(.secondary)
            SlateSearchField(title: L10n.tr("搜索预设"), text: $query, identifier: "providers.presets.search")
            Picker(L10n.tr("来源"), selection: $filter) {
                Text(L10n.tr("全部")).tag("all")
                Text(L10n.tr("内建")).tag("builtin")
                Text(L10n.tr("直连厂商")).tag("direct")
                Text(L10n.tr("聚合中转")).tag("aggregator")
            }.pickerStyle(.segmented)
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 190), alignment: .leading)], spacing: 10) {
                    if query.isEmpty && filter == "all" { tile(L10n.tr("自定义配置"), id: "custom") }
                    if filter == "all" || filter == "builtin" {
                        ForEach(ProviderCatalog.definitions.filter {
                            ProviderListPresentation.matches(query: query, name: $0.label, url: $0.defaultBaseURL, notes: nil)
                        }, id: \.id) { tile(L10n.message($0.label), id: $0.id) }
                    }
                    ForEach(presets) { tile($0.name, id: "preset:" + $0.id) }
                }.padding(2)
                if presets.isEmpty && !query.isEmpty && !ProviderCatalog.definitions.contains(where: {
                    (filter == "all" || filter == "builtin") && ProviderListPresentation.matches(query: query, name: $0.label, url: $0.defaultBaseURL, notes: nil)
                }) { Text(L10n.tr("没有匹配的 Provider，请尝试其他关键词。")).foregroundStyle(.secondary).padding() }
            }
            HStack { Spacer(); Button(L10n.tr("取消"), role: .cancel) { dismiss() } }
        }
    }

    private func tile(_ title: String, id: String) -> some View {
        Button {
            route = id
            showsEditor = true
        } label: {
            HStack {
                Image(systemName: id == "custom" ? "slider.horizontal.3" : "network")
                Text(title).lineLimit(2).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").font(.caption)
            }.padding(12).frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
        }.buttonStyle(.bordered).help(title)
    }

    @ViewBuilder private func editor(_ id: String) -> some View {
        if let definition = ProviderCatalog.definition(id: id),
           let provider = settings.live?.providers.first(where: { $0.id == id }) {
            BuiltinProviderConfigurationSheet(settings: settings, provider: provider, definition: definition)
        } else {
            CustomProviderSheet(settings: settings, preset: ProviderPresets.all.first { "preset:" + $0.id == id })
                .id(id)
        }
    }
}

/// Long service diagnostics are expandable and selectable without widening rows.
struct ProviderDiagnostic: View {
    let message: String
    let isError: Bool
    @State private var expanded = false
    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            Text(message).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
        } label: {
            Label(message, systemImage: isError ? "exclamationmark.triangle" : "info.circle")
                .lineLimit(2)
        }
        .font(.caption)
        .foregroundStyle(isError ? SlateSyncTheme.danger : SlateSyncTheme.secondary)
    }
}

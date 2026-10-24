import SlateSyncDomain
import SwiftUI

// Product copy uses the shared launch language; user content stays verbatim.

// Shared components for the 2026-10-23 "Bare Face" direction. Everything is a
// system symbol, system control or system color: no custom shapes, no tinted
// capsules, no raised cards. The only film-set vocabulary that survives is the
// four take states (过条 / 保条 / 废条 / 待定), each a distinct silhouette so the
// state reads from shape and label, never from hue alone.

// MARK: - TakeMark(过条 / 保条 / 废条 / 待定)

/// Take status glyph. Four silhouettes: check (过条), bookmark (保条), cross
/// (废条) and a dashed ring (待定). Emphasis follows what needs a decision, not
/// what is routine: 过条 is a label-color check, 保条 and 废条 secondary
/// (same weight, distinct silhouettes), and only 待定 — the state awaiting a
/// decision — carries a hue (the system orange). The glyph is decorative:
/// callers pair it with `label` text.
public struct TakeMark: View {
    public enum Phase: Equatable, Sendable, CaseIterable {
        case passed, hold, rejected, pending
    }

    /// Exposed for feature rows that mirror the mark in accessibility text.
    public let phase: Phase

    public init(_ status: TakeStatus?) {
        switch status {
        case nil: phase = .pending
        case .passed: phase = .passed
        case .hold: phase = .hold
        case .rejected: phase = .rejected
        }
    }

    public init(phase: Phase) {
        self.phase = phase
    }

    /// Localized state name shown next to the glyph and read by VoiceOver.
    public static func label(for phase: Phase) -> String {
        switch phase {
        case .passed: L10n.tr("过条")
        case .hold: L10n.tr("保条")
        case .rejected: L10n.tr("废条")
        case .pending: L10n.tr("待定")
        }
    }

    var symbol: String {
        switch phase {
        case .passed: "checkmark"
        case .hold: "bookmark.fill"
        case .rejected: "xmark"
        case .pending: "circle.dashed"
        }
    }

    var style: Color {
        switch phase {
        case .passed: SlateSyncTheme.primary
        case .hold: SlateSyncTheme.secondary
        case .rejected: SlateSyncTheme.secondary
        case .pending: SlateSyncTheme.warning
        }
    }

    public var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(style)
            .frame(width: 16, height: 16)
            .accessibilityHidden(true)
    }
}

// MARK: - Provider status(服务商状态)

/// Source badges describe how a row was created, not a new wire provider kind.
public enum ProviderSourceBadge: Equatable, Sendable {
    case builtin, preset, custom

    public static func source(for configuration: CustomProviderConfiguration?) -> Self {
        guard let configuration else { return .builtin }
        return configuration.sourcePresetID == nil ? .custom : .preset
    }
}

/// Capability reflects the current probe projection. Only the glyph is tinted;
/// the label stays in the neutral secondary foreground and always names the
/// state, so verification never depends on color alone.
public struct CapabilityChip: View {
    public enum State: Equatable, Sendable {
        case verified, failed, unverified, attention
    }

    public let state: State
    public init(_ state: State) { self.state = state }

    public static func state(verified: Int, failed: Int, pending: Int) -> State {
        if failed > 0, verified > 0 { return .attention }
        if failed > 0 { return .failed }
        if verified > 0, pending > 0 { return .attention }
        return verified > 0 ? .verified : .unverified
    }

    private var title: String {
        switch state {
        case .verified: L10n.tr("已验证")
        case .failed: L10n.tr("验证失败")
        case .unverified: L10n.tr("未验证")
        case .attention: L10n.tr("需要注意")
        }
    }

    private var symbol: String {
        switch state {
        case .verified: "checkmark"
        case .failed: "xmark.octagon"
        case .unverified: "questionmark.circle"
        case .attention: "exclamationmark.triangle"
        }
    }

    private var color: Color {
        switch state {
        case .verified: SlateSyncTheme.success
        case .failed: SlateSyncTheme.danger
        case .unverified: SlateSyncTheme.secondary
        case .attention: SlateSyncTheme.warning
        }
    }

    public var body: some View {
        Label {
            Text(title).foregroundStyle(.secondary)
        } icon: {
            Image(systemName: symbol).foregroundStyle(color)
        }
        .font(.caption)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(L10n.tr("能力状态 {0}", [String(describing: title)]))
    }
}

/// Credential states for Provider rows distinguish temporary contention. 取消授权 must surface as
/// 需要授权 or 读取失败 — never silently as 缺失 (DESIGN.md 2026-09-11 rule).
/// Color is never the only signal; each state pairs a symbol and a label.
public struct CredentialChip: View {
    public enum State: Equatable, Sendable {
        case configured, missing, needsAuthorization, readFailed, temporarilyUnavailable
    }

    let state: State

    public init(_ state: State) {
        self.state = state
    }

    var title: String {
        switch state {
        case .configured: L10n.tr("已配置")
        case .missing: L10n.tr("缺失")
        case .needsAuthorization: L10n.tr("需要授权")
        case .readFailed: L10n.tr("读取失败")
        case .temporarilyUnavailable: L10n.tr("暂时不可用")
        }
    }

    var symbol: String {
        switch state {
        case .configured: "checkmark"
        case .missing: "minus.circle"
        case .needsAuthorization: "lock.open"
        case .readFailed: "exclamationmark.triangle"
        case .temporarilyUnavailable: "clock"
        }
    }

    var color: Color {
        switch state {
        case .configured: SlateSyncTheme.success
        case .missing: SlateSyncTheme.secondary
        case .needsAuthorization: SlateSyncTheme.warning
        case .readFailed: SlateSyncTheme.danger
        case .temporarilyUnavailable: SlateSyncTheme.warning
        }
    }

    public var body: some View {
        Label {
            Text(title).foregroundStyle(.secondary)
        } icon: {
            Image(systemName: symbol).foregroundStyle(color)
        }
        .font(.caption)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(L10n.tr("凭据状态 {0}", [String(describing: title)]))
    }
}

// MARK: - WarnRow(告警行)

/// Reconciliation alert row: neutral text and a trailing action slot (typically
/// 校对). No tinted background and no edge bar. Callers lead `content` with a
/// severity glyph tinted via `WarnRow.color(for:)`, so the state is a symbol
/// plus a sentence and survives color-blind reading.
public struct WarnRow<Content: View, Actions: View>: View {
    public enum Severity: Sendable {
        case warning, danger
    }

    private let severity: Severity
    private let content: () -> Content
    private let actions: () -> Actions

    public init(
        severity: Severity,
        @ViewBuilder content: @escaping () -> Content,
        @ViewBuilder actions: @escaping () -> Actions
    ) {
        self.severity = severity
        self.content = content
        self.actions = actions
    }

    public static func color(for severity: Severity) -> Color {
        severity == .warning ? SlateSyncTheme.warning : SlateSyncTheme.danger
    }

    public var body: some View {
        HStack(spacing: 10) {
            content()
            Spacer(minLength: 8)
            actions()
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }
}

extension WarnRow where Actions == EmptyView {
    public init(
        severity: Severity,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.init(severity: severity, content: content, actions: { EmptyView() })
    }
}

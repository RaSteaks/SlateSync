import SwiftUI

// Product copy uses the shared launch language; user content stays verbatim.

/// Shared feedback keeps recovery in the owning feature, without global toast
/// timers or changing a model's operation lifetime when a view is remounted.
struct SlateStatusBar<Actions: View>: View {
    @Environment(\.slateSyncDensity) private var density
    enum Tone { case info, success, warning, error }
    let message: String
    var tone: Tone = .info
    var busy = false
    /// Optional accessory placed right after the message (a progress bar), so
    /// a value sits beside the words that describe it.
    var inline: AnyView?
    @ViewBuilder var actions: () -> Actions

    // Only the leading glyph carries the tone; the message stays neutral so
    // a strip never reads as a colored banner.
    private var color: Color { tone.slateGlassTone.color }
    private var symbol: String {
        switch tone {
        case .info: "info.circle"
        case .success: "checkmark.circle"
        case .warning: "exclamationmark.triangle"
        case .error: "exclamationmark.circle"
        }
    }
    var body: some View {
        HStack(spacing: 10) {
            if busy {
                ProgressView().controlSize(.small)
            } else {
                Image(systemName: symbol).foregroundStyle(color).accessibilityHidden(true)
            }
            Text(L10n.message(message)).font(.callout).textSelection(.enabled).fixedSize(
                horizontal: false, vertical: true)
            if let inline { inline }
            Spacer(minLength: 8)
            actions()
        }
        // Feedback follows panel density without reducing semantic type sizes.
        .padding(.horizontal, density.panelPadding).padding(.vertical, density.rowPadding + 3)
        .frame(maxWidth: .infinity, alignment: .leading)
        // Full-width feedback is docked chrome: a flat strip with a top
        // hairline. Glass stays on floating elements.
        .slateDockedSurface(.status(tone.slateGlassTone), separator: .top)
    }
}

extension SlateStatusBar where Actions == EmptyView {
    init(_ message: String, tone: Tone = .info, busy: Bool = false) {
        self.message = message
        self.tone = tone
        self.busy = busy
        self.actions = { EmptyView() }
    }
}

/// Empty and no-result surfaces use the same readable hierarchy and keep their
/// next action keyboard reachable, including at the minimum window size.
struct SlateEmptyState<Actions: View>: View {
    let title: String
    let symbol: String
    let message: String
    @ViewBuilder var actions: () -> Actions
    var body: some View {
        ContentUnavailableView {
            Label(title, systemImage: symbol)
        } description: {
            Text(L10n.message(message))
        } actions: {
            actions()
        }
        // Empty-state art stays neutral like every other static icon.
        .tint(Color.secondary)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct SlatePanelHeading: View {
    let title: String
    var subtitle: String? = nil
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.headline).lineLimit(1).help(title)
            if let subtitle { Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(2).help(subtitle) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Inline failure text for forms and sheets. The symbol keeps the error
/// readable without color (Differentiate Without Color); window-level
/// feedback still belongs to SlateStatusBar.
struct SlateInlineError: View {
    let message: String
    init(_ message: String) { self.message = message }
    var body: some View {
        Label {
            Text(L10n.message(message)).textSelection(.enabled)
        } icon: {
            Image(systemName: "exclamationmark.circle")
        }
        .foregroundStyle(SlateSyncTheme.dangerText)
    }
}

/// Page identity for views that have no window toolbar title of their own: a
/// semibold title over one secondary line. No icon tile or container.
struct SlatePageHeading: View {
    let title: String
    let subtitle: String
    let symbol: String
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.title2.weight(.semibold)).lineLimit(1).help(title)
            Text(subtitle).font(.callout).foregroundStyle(.secondary)
                .lineLimit(2).help(subtitle)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Counts describe actual loaded data, never synthetic activity or progress.
struct SlateCountLabel: View {
    let title: String
    let count: Int
    var body: some View {
        HStack(spacing: 6) {
            Text(title).foregroundStyle(.secondary)
            Text(count, format: .number).fontWeight(.semibold).monospacedDigit()
        }
        .font(.callout)
        .accessibilityElement(children: .combine)
    }
}

/// Clearing a local search preserves native text entry and returns focus to
/// the field. No debounce is added to in-memory task/help filtering. The field
/// is a quiet system-fill well; the accent appears only as the focus outline.
struct SlateSearchField: View {
    let title: String
    @Binding var text: String
    var identifier: String
    @FocusState private var focused: Bool
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary).accessibilityHidden(true)
            TextField(title, text: $text)
                .textFieldStyle(.plain).focused($focused)
                .accessibilityLabel(title).accessibilityIdentifier(identifier)
            Button {
                text = ""
                focused = true
            } label: {
                Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(L10n.tr("清除{0}", [String(describing: title)])).help(L10n.tr("清除{0}", [String(describing: title)]))
            .accessibilityIdentifier("\(identifier).clear")
            .opacity(text.isEmpty ? 0 : 1).disabled(text.isEmpty)
            .accessibilityHidden(text.isEmpty)
        }
        .padding(.horizontal, 8).padding(.vertical, 5)
        .background(Color(nsColor: .quaternarySystemFill),
                    in: RoundedRectangle(cornerRadius: SlateSyncTheme.smallRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: SlateSyncTheme.smallRadius, style: .continuous)
                .strokeBorder(SlateSyncTheme.accent, lineWidth: focused ? 1.5 : 0)
        }
    }
}

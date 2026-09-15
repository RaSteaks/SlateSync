import SwiftUI

/// Shared feedback keeps recovery in the owning feature, without global toast
/// timers or changing a model's operation lifetime when a view is remounted.
struct SlateStatusBar<Actions: View>: View {
    @Environment(\.slateSyncDensity) private var density
    enum Tone { case info, success, warning, error }
    let message: String
    var tone: Tone = .info
    var busy = false
    @ViewBuilder var actions: () -> Actions

    private var color: Color {
        switch tone {
        case .info: SlateSyncTheme.secondary
        case .success: SlateSyncTheme.success
        case .warning: SlateSyncTheme.warning
        case .error: SlateSyncTheme.danger
        }
    }
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
            Text(message).font(.callout).textSelection(.enabled).fixedSize(
                horizontal: false, vertical: true)
            Spacer(minLength: 8)
            actions()
        }
        // Feedback follows panel density without reducing semantic type sizes.
        .padding(.horizontal, density.panelPadding).padding(.vertical, density.rowPadding + 3)
        .frame(maxWidth: .infinity, alignment: .leading)
        // The full-width status surface uses the shared material fallback on
        // older systems and the native Liquid Glass renderer on macOS 26+.
        .slateGlassSurface(.status(tone.slateGlassTone), shape: .rectangle)
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
            Text(message)
        } actions: {
            actions()
        }
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

/// Page identity is deliberately stronger than a panel heading. Both library
/// and workspace use this composition, while native controls retain focus.
struct SlatePageHeading: View {
    let title: String
    let subtitle: String
    let symbol: String
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.title2.weight(.medium))
                .foregroundStyle(SlateSyncTheme.accent)
                .frame(width: 44, height: 44)
                .background(SlateSyncTheme.accent.opacity(0.08),
                            in: RoundedRectangle(cornerRadius: SlateSyncTheme.panelRadius))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 5) {
                Text(title).font(.title2.weight(.semibold)).lineLimit(1).help(title)
                Text(subtitle).font(.callout).foregroundStyle(.secondary)
                    .lineLimit(2).help(subtitle)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
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
/// the field. No debounce is added to in-memory task/help filtering.
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
            .accessibilityLabel("清除\(title)").help("清除\(title)")
            .accessibilityIdentifier("\(identifier).clear")
            .opacity(text.isEmpty ? 0 : 1).disabled(text.isEmpty)
            .accessibilityHidden(text.isEmpty)
        }
        .padding(7)
        // Search is a real interactive control, so it opts into the shared
        // glass surface instead of painting a bespoke blur per feature view.
        // The existing focus/separator outline is the sole custom border.
        .slateGlassSurface(.control, interactive: true, border: .none)
        .overlay {
            RoundedRectangle(cornerRadius: SlateSyncTheme.controlRadius).strokeBorder(
                focused ? SlateSyncTheme.accent : SlateSyncTheme.separator, lineWidth: focused ? 2 : 0.5)
        }
    }
}

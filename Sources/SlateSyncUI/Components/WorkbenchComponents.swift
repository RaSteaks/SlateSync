import SlateSyncDomain
import SwiftUI

// Product copy uses the shared launch language; user content stays verbatim.

// Shared components for the 2026-09-14 Slate Workbench direction. Every color
// comes from SlateSyncTheme or system semantics (DESIGN.md: feature views never
// embed RGB literals), and each signature element appears only in its owning
// business state: the stripe marks project identity, the pencil circle and
// grease strike mark confirmed result rows, the leader dial marks live
// recognition, and the lightbox hosts real slate evidence.

// MARK: - SlateBadge(项目身份斜纹)

/// Film-slate stripe edge for project identity surfaces. The clapperboard
/// pattern is deliberately pure black/white like the physical slate; it is
/// content-sanctioned by DESIGN.md's signature, not a theme color. Never
/// attach it to tasks, buttons or non-project containers.
public struct SlateBadge: View {
    public static let edgeWidth: CGFloat = 3

    public init() {}

    public var body: some View {
        Canvas { context, size in
            // 45° alternating bands; the run starts on ink so short heights
            // still read as stripes rather than a plain bar.
            let band: CGFloat = 5
            var x = -size.height
            var index = 0
            while x < size.width {
                var path = Path()
                path.move(to: CGPoint(x: x, y: size.height))
                path.addLine(to: CGPoint(x: x + band, y: size.height))
                path.addLine(to: CGPoint(x: x + band + size.height, y: 0))
                path.addLine(to: CGPoint(x: x + size.height, y: 0))
                path.closeSubpath()
                context.fill(
                    path, with: .color(index.isMultiple(of: 2) ? .black : .white))
                x += band * 2
                index += 1
            }
        }
        .frame(width: Self.edgeWidth)
        .accessibilityHidden(true)
    }
}

// MARK: - TakeMark(确认痕迹)

/// Take confirmation traces: a hollow dot while pending, a slightly tilted
/// pencil ellipse for 好条/保条, and a grease strike for 废条. A fresh confirm
/// draws its stroke once over 240 ms; restored results appear already drawn.
/// Reduced Motion skips the draw-on animation entirely.
public struct TakeMark: View {
    public enum Phase: Equatable, Sendable {
        case pending, circled, struck
    }

    /// Exposed for feature rows that mirror the mark in accessibility text.
    public let phase: Phase

    @State private var strokeProgress: CGFloat = 1
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(_ status: TakeStatus?) {
        switch status {
        case nil: phase = .pending
        case .rejected: phase = .struck
        case .passed, .hold: phase = .circled
        }
    }

    public init(phase: Phase) {
        self.phase = phase
    }

    public var body: some View {
        ZStack {
            switch phase {
            case .pending:
                Circle()
                    .strokeBorder(SlateSyncTheme.secondary, lineWidth: 1.2)
                    .frame(width: 9, height: 9)
            case .circled:
                PencilEllipse()
                    .trim(from: 0, to: strokeProgress)
                    .stroke(
                        Color(nsColor: .systemGray),
                        style: StrokeStyle(lineWidth: 1.6, lineCap: .round))
                    .frame(width: 24, height: 15)
                    .rotationEffect(.degrees(-4))
            case .struck:
                GreaseStrike()
                    .trim(from: 0, to: strokeProgress)
                    .stroke(
                        SlateSyncTheme.danger,
                        style: StrokeStyle(lineWidth: 2, lineCap: .round))
                    .frame(width: 22, height: 12)
            }
        }
        .frame(width: 30, height: 20)
        .accessibilityHidden(true)
        .onChange(of: phase) { _, newValue in
            guard newValue != .pending else {
                strokeProgress = 0
                return
            }
            if reduceMotion {
                strokeProgress = 1
            } else {
                strokeProgress = 0
                withAnimation(.easeInOut(duration: 0.24)) { strokeProgress = 1 }
            }
        }
    }
}

/// Hand-drawn ellipse: the main loop plus a short overshoot tail near the
/// lower-right, like a real pencil pass that does not quite close.
private struct PencilEllipse: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.addEllipse(in: rect.insetBy(dx: 1.5, dy: 1))
        path.move(to: CGPoint(x: rect.maxX - rect.width * 0.30, y: rect.maxY - 1))
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX - rect.width * 0.04, y: rect.maxY - rect.height * 0.42),
            control: CGPoint(x: rect.maxX - 1, y: rect.maxY - rect.height * 0.08))
        return path
    }
}

/// Grease-pencil rejection strike: a slightly bowed line through the entry.
private struct GreaseStrike: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.maxY - 1))
        path.addCurve(
            to: CGPoint(x: rect.maxX, y: rect.minY + 1),
            control1: CGPoint(x: rect.midX - 2, y: rect.minY + rect.height * 0.62),
            control2: CGPoint(x: rect.midX + 2, y: rect.maxY - rect.height * 0.62))
        return path
    }
}

// MARK: - LeaderProgress(识别进度)

/// Academy-leader recognition dial. The sweep advances only with real page
/// completions and stops when recognition ends — no idle rotation and no
/// synthetic countdown. When the total page count is unknown the center shows
/// the named phase instead of a fake fraction. Reduced Motion swaps the dial
/// for the native progress bar.
public struct LeaderProgress: View {
    private let completed: Int?
    private let total: Int?
    private let phaseText: String

    private static let dialSize: CGFloat = 68

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(completedPages: Int, totalPages: Int) {
        completed = max(0, completedPages)
        total = max(1, totalPages)
        phaseText = ""
    }

    public init(phaseText: String) {
        completed = nil
        total = nil
        self.phaseText = phaseText
    }

    var centerLabel: String {
        if let completed, let total { return L10n.tr("第 {0}/{1} 页", [String(describing: completed), String(describing: total)]) }
        return phaseText
    }

    var accessibilityValue: String {
        if let completed, let total { return L10n.tr("第 {0} 页,共 {1} 页", [String(describing: completed), String(describing: total)]) }
        return phaseText
    }

    private var fraction: CGFloat {
        guard let completed, let total else { return 0 }
        return min(1, CGFloat(completed) / CGFloat(total))
    }

    public var body: some View {
        Group {
            if reduceMotion {
                reducedMotionFallback
            } else {
                dial
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(L10n.tr("识别进度"))
        .accessibilityValue(Text(accessibilityValue))
    }

    private var reducedMotionFallback: some View {
        VStack(spacing: 6) {
            if total != nil {
                ProgressView(value: fraction)
            } else {
                ProgressView()
            }
            Text(centerLabel).font(.callout).monospacedDigit()
        }
    }

    private var dial: some View {
        ZStack {
            Circle()
                .stroke(SlateSyncTheme.separator, lineWidth: 4)
            if total != nil {
                Circle()
                    .trim(from: 0, to: fraction)
                    .stroke(
                        SlateSyncTheme.accent,
                        style: StrokeStyle(lineWidth: 4, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.easeOut(duration: 0.3), value: fraction)
            }
            // Leader crosshair tick at 12 o'clock.
            Rectangle()
                .fill(SlateSyncTheme.accent)
                .frame(width: 1.5, height: 5)
                .offset(y: -Self.dialSize / 2 + 3.5)
            if total != nil {
                Text(centerLabel)
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .minimumScaleFactor(0.8)
                    .lineLimit(1)
                    .padding(.horizontal, 8)
            } else {
                VStack(spacing: 4) {
                    ProgressView().controlSize(.small)
                    Text(L10n.message(phaseText))
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .lineLimit(1)
                }
                .padding(.horizontal, 8)
            }
        }
        .frame(width: Self.dialSize, height: Self.dialSize)
    }
}

// MARK: - LightTable(灯箱)

/// The lightbox hosts real slate evidence only. Paging, zoom and import
/// controls belong in the adjacent control bar; the paper never carries forms
/// or buttons. The surface sits one step darker than canvas in both
/// appearances so the evidence page stays the brightest region (灯箱反转).
public struct LightTable<Content: View>: View {
    @Environment(\.slateSyncDensity) private var density
    private let content: () -> Content

    public init(@ViewBuilder content: @escaping () -> Content) {
        self.content = content
    }

    public var body: some View {
        let shape = RoundedRectangle(
            cornerRadius: SlateSyncTheme.panelRadius, style: .continuous)
        return content()
            // Raised evidence preview keeps the soft shadow DESIGN.md reserves
            // for overlays and evidence.
            .shadow(color: .black.opacity(0.20), radius: 9, x: 0, y: 3)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(density.panelPadding)
            .background {
                ZStack {
                    shape.fill(SlateSyncTheme.canvas)
                    Color.black.opacity(0.14)
                    RadialGradient(
                        colors: [.clear, .black.opacity(0.16)],
                        center: .center, startRadius: 60, endRadius: 420)
                }
                .clipShape(shape)
                .overlay {
                    shape.strokeBorder(SlateSyncTheme.separator, lineWidth: 0.5)
                }
            }
    }
}

// MARK: - CredentialChip(凭据状态)

/// Four credential states for Provider rows. 取消授权 must surface as
/// 需要授权 or 读取失败 — never silently as 缺失 (DESIGN.md 2026-09-11 rule).
/// Color is never the only signal; each state pairs a symbol.
public struct CredentialChip: View {
    public enum State: Equatable, Sendable {
        case configured, missing, needsAuthorization, readFailed
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
        }
    }

    var symbol: String {
        switch state {
        case .configured: "checkmark.seal"
        case .missing: "minus.circle"
        case .needsAuthorization: "lock.open"
        case .readFailed: "exclamationmark.triangle"
        }
    }

    var color: Color {
        switch state {
        case .configured: SlateSyncTheme.success
        case .missing: SlateSyncTheme.secondary
        case .needsAuthorization: SlateSyncTheme.warning
        case .readFailed: SlateSyncTheme.danger
        }
    }

    private var glassTone: SlateGlassTone {
        switch state {
        case .configured: .success
        case .missing: .info
        case .needsAuthorization: .warning
        case .readFailed: .error
        }
    }

    public var body: some View {
        HStack(spacing: 4) {
            Image(systemName: symbol).imageScale(.small)
            Text(title)
        }
        .font(.caption.weight(.medium))
        .foregroundStyle(color)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        // Preserve pill geometry; reserve the extra outline for accessibility.
        .slateGlassSurface(.status(glassTone), shape: .capsule, border: .accessibilityOnly)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(L10n.tr("凭据状态 {0}", [String(describing: title)]))
    }
}

// MARK: - WarnRow(告警行)

/// Reconciliation alert row: dim severity background with a 3 pt leading edge
/// and a trailing action slot (typically 校对). Severity color is paired with
/// the row's inline text so the state survives color-blind reading.
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

    private var severityColor: Color {
        severity == .warning ? SlateSyncTheme.warning : SlateSyncTheme.danger
    }

    public var body: some View {
        HStack(spacing: 10) {
            content()
            Spacer(minLength: 8)
            actions()
        }
        .padding(.leading, 3)
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .background(severityColor.opacity(0.12))
        .overlay(alignment: .leading) {
            Rectangle().fill(severityColor).frame(width: 3)
        }
        .clipShape(
            RoundedRectangle(cornerRadius: SlateSyncTheme.smallRadius, style: .continuous))
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

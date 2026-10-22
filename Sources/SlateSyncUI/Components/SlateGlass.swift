import AppKit
import SwiftUI

/// Semantic glass roles keep Liquid Glass decisions out of feature views.
/// macOS 26 uses the system glass renderer; older systems retain the Slate
/// material and contrast treatment without changing the deployment target.
/// Glass is reserved for floating elements (progress cards, search/filter
/// strips, status chips, the primary action); docked chrome such as header
/// bars, side panels and status strips uses `slateDockedSurface` instead.
enum SlateGlassRole {
    case panel
    case control
    case prominent
    case status(SlateGlassTone)

    var cornerRadius: CGFloat {
        switch self {
        case .panel: SlateSyncTheme.panelRadius
        case .control: SlateSyncTheme.controlRadius
        case .prominent: SlateSyncTheme.controlRadius
        case .status: SlateSyncTheme.smallRadius
        }
    }

    var fallbackMaterial: Material {
        switch self {
        case .control: .thinMaterial
        default: .regularMaterial
        }
    }

    var fallbackFill: Color {
        switch self {
        case .panel: SlateSyncTheme.evidenceSurface.opacity(0.82)
        case .control: SlateSyncTheme.canvas.opacity(0.78)
        case .prominent: SlateSyncTheme.accent.opacity(0.16)
        case .status(let tone): tone.color.opacity(0.14)
        }
    }

    /// Opaque alternatives are used when the user asks macOS to reduce
    /// transparency, preserving the semantic hierarchy without translucency.
    var reducedTransparencyFill: Color {
        switch self {
        case .control: SlateSyncTheme.canvas
        default: SlateSyncTheme.evidenceSurface
        }
    }

    var borderColor: Color {
        switch self {
        case .status(let tone): tone.color
        default: SlateSyncTheme.separator
        }
    }

    /// Strength of the top sheen on the pre-macOS 26 fallback. Small status
    /// chips stay nearly flat; larger floating surfaces and the primary action
    /// get a clearer light catch.
    var fallbackSheenOpacity: Double {
        switch self {
        case .panel: 0.14
        case .control: 0.10
        case .prominent: 0.18
        case .status: 0.08
        }
    }

    @available(macOS 26.0, *)
    func glass(interactive: Bool) -> Glass {
        var value: Glass
        switch self {
        case .panel:
            value = .regular
        case .control:
            value = .clear
        case .prominent:
            value = .regular.tint(SlateSyncTheme.accent)
        case .status(let tone):
            value = .regular.tint(tone.color)
        }
        return interactive ? value.interactive() : value
    }
}

enum SlateGlassTone {
    case info
    case success
    case warning
    case error

    var color: Color {
        switch self {
        // Informational feedback shares the neutral foreground of its callers.
        case .info: SlateSyncTheme.secondary
        case .success: SlateSyncTheme.success
        case .warning: SlateSyncTheme.warning
        case .error: SlateSyncTheme.danger
        }
    }
}

enum SlateGlassShape {
    case rounded
    case rectangle
    case capsule

    func anyShape(for role: SlateGlassRole) -> AnyShape {
        switch self {
        case .rounded:
            AnyShape(RoundedRectangle(cornerRadius: role.cornerRadius, style: .continuous))
        case .capsule:
            AnyShape(Capsule())
        case .rectangle:
            AnyShape(Rectangle())
        }
    }
}

/// Components with their own focus or structural rule own that border entirely.
/// Small badges only need an extra outline in accessibility modes.
enum SlateGlassBorder {
    case automatic
    case accessibilityOnly
    case none
}

private struct SlateGlassSurfaceModifier: ViewModifier {
    let role: SlateGlassRole
    let shape: SlateGlassShape
    let interactive: Bool
    let border: SlateGlassBorder

    // SwiftUI exposes this macOS accessibility cue rather than the iOS-only
    // accessibilityContrast environment value. It is also the right signal
    // for preserving status meaning without relying on color alone.
    @Environment(\.accessibilityDifferentiateWithoutColor) private var differentiateWithoutColor
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorScheme) private var colorScheme

    // AppKit posts changes on its workspace notification center. Store the
    // current value so toggling Increase Contrast invalidates mounted surfaces.
    @State private var increaseContrast = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast

    func body(content: Content) -> some View {
        let resolvedShape = shape.anyShape(for: role)
        Group {
            if reduceTransparency {
                opaqueSurface(content: content, shape: resolvedShape)
            } else if #available(macOS 26.0, *) {
                glassSurface(content: content, shape: resolvedShape)
            } else {
                materialSurface(content: content, shape: resolvedShape)
            }
        }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(
            for: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification
        )) { _ in
            increaseContrast = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
        }
        .onAppear {
            increaseContrast = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
        }
    }

    private func opaqueSurface(content: Content, shape: AnyShape) -> some View {
        content
            .background(role.reducedTransparencyFill, in: shape)
            .overlay { contrastBorder(shape) }
    }

    // macOS 15–25 cannot sample or refract the content behind a surface, so the
    // fallback imitates Liquid Glass with public API only: blurred material,
    // the Slate tint, a top sheen and a lit rim. Stacking order, front to back:
    // content, highlights, tint, material. The highlights sit behind the
    // content so they never lower text contrast.
    private func materialSurface(content: Content, shape: AnyShape) -> some View {
        content
            .background { glassHighlights(shape) }
            .background(role.fallbackFill, in: shape)
            .background(role.fallbackMaterial, in: shape)
            .overlay { contrastBorder(shape) }
    }

    /// Soft sheen from the top edge plus a 1 pt rim that is bright on the
    /// upper-left and fades toward the lower-right, the way a glass edge catches
    /// light. Light appearance adds a faint dark return edge so the rim still
    /// reads over near-white canvas. Skipped under Increase Contrast, where the
    /// plain border rules. Gradients fade through `white.opacity(0)` instead of
    /// `.clear` to avoid a gray fringe while interpolating.
    @ViewBuilder
    private func glassHighlights(_ shape: AnyShape) -> some View {
        if !increaseContrast {
            let dark = colorScheme == .dark
            let transparent = Color.white.opacity(0)
            ZStack {
                shape.fill(LinearGradient(
                    colors: [.white.opacity(role.fallbackSheenOpacity * (dark ? 0.7 : 1)), transparent],
                    startPoint: .top, endPoint: .center))
                // A centered 2 pt stroke clipped to the shape leaves a 1 pt inner rim.
                shape.stroke(
                    LinearGradient(
                        colors: dark
                            ? [.white.opacity(0.30), transparent, .white.opacity(0.10)]
                            : [.white.opacity(0.75), transparent, .black.opacity(0.07)],
                        startPoint: .topLeading, endPoint: .bottomTrailing),
                    lineWidth: 2)
            }
            .clipShape(shape)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }

    @available(macOS 26.0, *)
    private func glassSurface(content: Content, shape: AnyShape) -> some View {
        content
            .glassEffect(
                role.glass(interactive: interactive && !reduceMotion),
                in: shape
            )
            .overlay { contrastBorder(shape) }
    }

    @ViewBuilder
    private func contrastBorder(_ shape: AnyShape) -> some View {
        if border != .none {
            if differentiateWithoutColor || reduceTransparency || increaseContrast {
                shape.stroke(role.borderColor.opacity(0.72), lineWidth: 1)
            } else if border == .automatic {
                shape.stroke(role.borderColor.opacity(0.34), lineWidth: 0.5)
            }
        }
    }
}

/// A single group gives neighboring custom glass surfaces a shared sampling
/// context on macOS 26; older systems simply render the contained views.
struct SlateGlassContainer<Content: View>: View {
    private let spacing: CGFloat?
    private let content: () -> Content

    init(spacing: CGFloat? = nil, @ViewBuilder content: @escaping () -> Content) {
        self.spacing = spacing
        self.content = content
    }

    @ViewBuilder
    var body: some View {
        if #available(macOS 26.0, *) {
            GlassEffectContainer(spacing: spacing, content: content)
        } else {
            content()
        }
    }
}

extension View {
    /// Applies a role-based glass surface with a macOS 15-compatible fallback.
    /// Feature views should use this instead of choosing materials independently.
    func slateGlassSurface(
        _ role: SlateGlassRole,
        shape: SlateGlassShape = .rounded,
        interactive: Bool = false,
        border: SlateGlassBorder = .automatic
    ) -> some View {
        modifier(SlateGlassSurfaceModifier(role: role, shape: shape, interactive: interactive, border: border))
    }

    /// Primary actions use native Liquid Glass on macOS 26 and the existing
    /// prominent button treatment on older systems or reduced-motion/
    /// reduced-transparency accessibility modes.
    func slatePrimaryActionStyle() -> some View {
        modifier(SlatePrimaryActionModifier())
    }
}

private struct SlatePrimaryActionModifier: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *), !reduceMotion, !reduceTransparency {
            content.buttonStyle(.glassProminent)
        } else {
            content.buttonStyle(.borderedProminent)
        }
    }
}

// MARK: - Docked chrome

/// Opaque roles for docked, edge-to-edge chrome. These sit in the content
/// layer, so they stay flat and cheap: no material sampling, no shadow.
/// Reduced Transparency and Increase Contrast need no special handling because
/// the fills are already opaque theme tokens and the hairline uses the system
/// separator color.
enum SlateDockedRole {
    /// Page heading bar above a work area.
    case header
    /// Side panel hosting live controls (evidence tone, like a sheet).
    case panel
    /// Overview strip above a native list (canvas tone).
    case summary
    /// Full-width feedback strip: canvas with a light tint of the tone.
    case status(SlateGlassTone)
}

private struct SlateDockedSurfaceModifier: ViewModifier {
    let role: SlateDockedRole
    let separator: Edge?

    func body(content: Content) -> some View {
        content
            .background { fill }
            .overlay(alignment: alignment) {
                if let separator {
                    let horizontal = separator == .top || separator == .bottom
                    Rectangle()
                        .fill(SlateSyncTheme.separator)
                        .frame(width: horizontal ? nil : 0.5, height: horizontal ? 0.5 : nil)
                        .allowsHitTesting(false)
                }
            }
    }

    @ViewBuilder private var fill: some View {
        switch role {
        case .header, .panel:
            SlateSyncTheme.evidenceSurface
        case .summary:
            SlateSyncTheme.canvas
        case .status(let tone):
            ZStack {
                SlateSyncTheme.canvas
                tone.color.opacity(0.12)
            }
        }
    }

    private var alignment: Alignment {
        switch separator {
        case .top: .top
        case .bottom: .bottom
        case .leading: .leading
        case .trailing: .trailing
        case nil: .center
        }
    }
}

extension View {
    /// Flat opaque surface for docked chrome; `separator` draws a hairline on
    /// the given edge (omit it when a Divider already draws that edge).
    func slateDockedSurface(_ role: SlateDockedRole, separator: Edge? = nil) -> some View {
        modifier(SlateDockedSurfaceModifier(role: role, separator: separator))
    }
}

extension SlateStatusBar.Tone {
    var slateGlassTone: SlateGlassTone {
        switch self {
        case .info: .info
        case .success: .success
        case .warning: .warning
        case .error: .error
        }
    }
}

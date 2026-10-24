import AppKit
import SwiftUI

/// Semantic glass roles keep Liquid Glass decisions out of feature views.
/// Glass is reserved for elements that genuinely float above content (the
/// opening-progress card, the log filter strip, the search field). Docked
/// chrome never uses it; see `slateDockedSurface`. macOS 26 uses the system
/// glass renderer untinted; older systems fall back to a plain system
/// material with a hairline — no sheen, rim or tint is painted on top.
enum SlateGlassRole {
    case panel
    case control

    var cornerRadius: CGFloat {
        switch self {
        case .panel: SlateSyncTheme.panelRadius
        case .control: SlateSyncTheme.controlRadius
        }
    }

    var fallbackMaterial: Material {
        switch self {
        case .control: .thinMaterial
        case .panel: .regularMaterial
        }
    }

    /// Opaque alternatives are used when the user asks macOS to reduce
    /// transparency, preserving the semantic hierarchy without translucency.
    var reducedTransparencyFill: Color {
        switch self {
        case .control: SlateSyncTheme.canvas
        case .panel: SlateSyncTheme.evidenceSurface
        }
    }

    @available(macOS 26.0, *)
    func glass(interactive: Bool) -> Glass {
        let value: Glass = switch self {
        case .panel: .regular
        case .control: .clear
        }
        return interactive ? value.interactive() : value
    }
}

/// Status tone for feedback strips. The tone colors the leading glyph only;
/// the message text stays in the neutral foreground.
enum SlateGlassTone {
    case info
    case success
    case warning
    case error

    var color: Color {
        switch self {
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
enum SlateGlassBorder {
    case automatic
    case none
}

private struct SlateGlassSurfaceModifier: ViewModifier {
    let role: SlateGlassRole
    let shape: SlateGlassShape
    let interactive: Bool
    let border: SlateGlassBorder

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    func body(content: Content) -> some View {
        let resolvedShape = shape.anyShape(for: role)
        Group {
            if reduceTransparency {
                content
                    .background(role.reducedTransparencyFill, in: resolvedShape)
                    .overlay { hairline(resolvedShape) }
            } else if #available(macOS 26.0, *) {
                content
                    .glassEffect(role.glass(interactive: interactive && !reduceMotion), in: resolvedShape)
                    .overlay { hairline(resolvedShape) }
            } else {
                content
                    .background(role.fallbackMaterial, in: resolvedShape)
                    .overlay { hairline(resolvedShape) }
            }
        }
    }

    @ViewBuilder
    private func hairline(_ shape: AnyShape) -> some View {
        if border == .automatic {
            shape.stroke(SlateSyncTheme.separator, lineWidth: 0.5)
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

    /// Primary actions use native Liquid Glass on macOS 26 and the standard
    /// prominent button on older systems or in reduced-motion/
    /// reduced-transparency accessibility modes. Both follow the system accent.
    func slatePrimaryActionStyle() -> some View {
        modifier(SlatePrimaryActionModifier())
    }
}

extension View {
    /// The primary action inside a window toolbar: always the standard
    /// prominent (accent-filled) bordered button. The glass variant above blends
    /// into the toolbar's own material, which in dark appearance left an enabled
    /// primary action looking like a disabled one.
    func slateToolbarPrimaryStyle() -> some View {
        buttonStyle(.borderedProminent)
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

/// Docked, edge-to-edge chrome is one flat opaque surface plus an optional
/// hairline — no material sampling, no tint, no shadow. Bars and strips use the
/// content color; a side panel (the inspector) sits back on the window canvas,
/// so in dark mode it never comes forward of the content.
/// Reduced Transparency and Increase Contrast need no special handling because
/// the fill is opaque and the hairline is the system separator color.
enum SlateDockedRole {
    /// Bar above a work area.
    case header
    /// Side panel hosting live controls.
    case panel
    /// Overview strip above a native list.
    case summary
    /// Full-width feedback strip. The tone colors the leading glyph in the
    /// owning view; the strip itself stays untinted.
    case status(SlateGlassTone)
}

private struct SlateDockedSurfaceModifier: ViewModifier {
    let role: SlateDockedRole
    let separator: Edge?

    private var fill: Color {
        if case .panel = role { SlateSyncTheme.canvas } else { SlateSyncTheme.evidenceSurface }
    }

    func body(content: Content) -> some View {
        content
            .background(fill)
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

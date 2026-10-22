import AppKit
import SwiftUI

/// Semantic roles shared by native scenes. System-owned chrome and selection
/// remain adaptive. Cool slate-gray surfaces and a single tungsten-amber
/// signal keep the workbench cohesive in both appearances; status hues remain
/// distinct from the amber accent.
public enum SlateSyncTheme {
    // DESIGN.md palette: amber actions, cool slate canvas, white evidence.
    // Keep evidence images unmodified; these colors apply only to their
    // containers.
    public static let accent = adaptive(light: 0xB45309, dark: 0xF59E0B)
    public static let evidenceSurface = adaptive(light: 0xFFFFFF, dark: 0x2A2F37)
    public static let canvas = adaptive(light: 0xF6F7F9, dark: 0x1E2229)
    public static let primary = Color.primary
    public static let secondary = Color.secondary
    public static let separator = Color(nsColor: .separatorColor)
    // Light success/warning text also sits on its own 12–14% tint (chips,
    // WarnRow, diagnostic badges); these values keep it above 4.5:1 there
    // (success 5.05, warning 5.13). Dark values already clear 6:1.
    public static let success = adaptive(light: 0x17694C, dark: 0x7FC9A9)
    public static let warning = adaptive(light: 0x6B5B00, dark: 0xE3C36B)
    public static let danger = adaptive(light: 0xB03A2E, dark: 0xE58873)
    // DESIGN.md `rounded` ladder. Custom containers use `.continuous` corners;
    // feature views must not introduce local 7/9/10 pt radii (single-theme rule).
    public static let smallRadius: CGFloat = 6
    public static let controlRadius: CGFloat = 8
    public static let panelRadius: CGFloat = 12
    public static let largeRadius: CGFloat = 16

    private static func adaptive(light: UInt32, dark: UInt32) -> Color {
        Color(
            nsColor: NSColor(
                name: nil,
                dynamicProvider: { appearance in
                    let rgb = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
                    return NSColor(
                        srgbRed: Double((rgb >> 16) & 255) / 255,
                        green: Double((rgb >> 8) & 255) / 255,
                        blue: Double(rgb & 255) / 255, alpha: 1)
                }))
    }
}

/// Layout metrics. The app ships a single layout (`comfortable`) and exposes no
/// density choice: nothing injects `.compact` into the environment any more, so
/// the key's default applies everywhere. The compact metrics remain only as the
/// table the native CSV table's density-change path and its regression test
/// exercise. A stale "density" value in user defaults is simply ignored.
public enum SlateSyncDensity: String, Sendable {
    case comfortable, compact
    public var panelPadding: CGFloat { self == .compact ? 12 : 20 }
    public var sectionSpacing: CGFloat { self == .compact ? 12 : 16 }
    public var rowPadding: CGFloat { self == .compact ? 3 : 7 }
    public var tableRowHeight: CGFloat { self == .compact ? 24 : 30 }
}

private struct SlateSyncDensityKey: EnvironmentKey {
    static let defaultValue = SlateSyncDensity.comfortable
}

extension EnvironmentValues {
    var slateSyncDensity: SlateSyncDensity {
        get { self[SlateSyncDensityKey.self] }
        set { self[SlateSyncDensityKey.self] = newValue }
    }
}

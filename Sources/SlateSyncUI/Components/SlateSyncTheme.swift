import AppKit
import SwiftUI

/// Semantic roles shared by native scenes. Everything resolves to a system
/// color: surfaces follow the system window/content ladder, the accent
/// follows the user's System Settings accent, and status hues are the system
/// green/orange/red. The app owns no brand palette of its own, so any macOS
/// appearance, accent or accessibility setting carries through unchanged.
public enum SlateSyncTheme {
    // The user's system accent. Reserved for the current selection, focus and
    // the one primary action; status never borrows it.
    public static let accent = Color.accentColor
    // Surface ladder: `canvas` is window chrome and the backdrop behind a
    // document page; `evidenceSurface` is the content layer (lists, tables,
    // docked panels). Evidence images are never tinted.
    public static let canvas = Color(nsColor: .windowBackgroundColor)
    public static let evidenceSurface = Color(nsColor: .controlBackgroundColor)
    public static let primary = Color.primary
    public static let secondary = Color.secondary
    public static let separator = Color(nsColor: .separatorColor)

    // Status glyphs and fills use the system hues. Status is always paired
    // with a symbol and a label, so the hue never carries the meaning alone.
    public static let success = Color(nsColor: .systemGreen)
    public static let warning = Color(nsColor: .systemOrange)
    public static let danger = Color(nsColor: .systemRed)

    // The light-mode system hues are only 2.2–3.6:1 as small text on the
    // content surface. Text that has to carry a status color (inline errors,
    // form hints) uses these adaptive tints instead; glyphs keep the system
    // hues. WCAG contrast on #FFFFFF / #1E1E1E: success 6.3 / 9.1, warning
    // 6.8 / 9.4, danger 5.7 / 6.8.
    public static let successText = adaptive(light: 0x1B6E3B, dark: 0x63D68A)
    public static let warningText = adaptive(light: 0x8A4B00, dark: 0xFFB340)
    public static let dangerText = adaptive(light: 0xC4281C, dark: 0xFF8077)

    // Continuous-corner ladder for the few custom containers that remain.
    // Feature views must not introduce local radii.
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
    public var tableRowHeight: CGFloat { self == .compact ? 24 : 26 }
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

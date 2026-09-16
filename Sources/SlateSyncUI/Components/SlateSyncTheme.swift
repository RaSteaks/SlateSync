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
    public static let success = adaptive(light: 0x1E7A5A, dark: 0x7FC9A9)
    public static let warning = adaptive(light: 0x7C6A00, dark: 0xE3C36B)
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

/// Persisted preference values stay compatible with previous releases.
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

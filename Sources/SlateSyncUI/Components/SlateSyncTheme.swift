import AppKit
import SwiftUI

/// Semantic roles shared by native scenes. System-owned chrome and selection
/// remain adaptive; only evidence surfaces and the restrained signal use ink.
public enum SlateSyncTheme {
    public static let accent = adaptive(light: 0x3F50BA, dark: 0x8C9CFF)
    public static let evidenceSurface = adaptive(light: 0xFFFFFF, dark: 0x1C2735)
    public static let canvas = adaptive(light: 0xF1F4F7, dark: 0x151D29)
    public static let primary = Color.primary
    public static let secondary = Color.secondary
    public static let separator = Color(nsColor: .separatorColor)
    public static let success = adaptive(light: 0x18794E, dark: 0x79D5A5)
    public static let warning = adaptive(light: 0x865B0A, dark: 0xEBC572)
    public static let danger = adaptive(light: 0xB33A32, dark: 0xFF9A91)
    public static let panelRadius: CGFloat = 12

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

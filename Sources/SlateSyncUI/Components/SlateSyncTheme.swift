import AppKit
import SwiftUI

public enum SlateSyncTheme {
    public static let accent = Color(nsColor: NSColor(
        name: nil,
        dynamicProvider: { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                ? NSColor(srgbRed: 140 / 255, green: 156 / 255, blue: 1, alpha: 1)
                : NSColor(srgbRed: 63 / 255, green: 80 / 255, blue: 186 / 255, alpha: 1)
        }
    ))

    public static let evidenceSurface = Color(nsColor: NSColor(
        name: nil,
        dynamicProvider: { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                ? NSColor(srgbRed: 28 / 255, green: 39 / 255, blue: 53 / 255, alpha: 1)
                : .white
        }
    ))
}

import SwiftUI

extension View {
    /// The split container owns collapse/expand motion. Keep this above the
    /// column boundaries, which intentionally remove inherited child motion.
    func sidebarVisibilityAnimation(_ visibility: NavigationSplitViewVisibility, reduceMotion: Bool) -> some View {
        animation(reduceMotion ? nil : SlateMotion.handoff, value: visibility)
    }

    /// Native split-view motion belongs to the column boundary. Children must
    /// follow the proposed geometry immediately instead of starting another
    /// implicit animation on native lists, forms or editors, and must not draw
    /// outside their column while it collapses. Local explicit animations still
    /// work.
    func sidebarResizeBoundary() -> some View {
        clipped()
            .transaction { $0.animation = nil }
    }
}

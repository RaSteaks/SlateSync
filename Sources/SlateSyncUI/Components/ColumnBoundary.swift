import SwiftUI

extension View {
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

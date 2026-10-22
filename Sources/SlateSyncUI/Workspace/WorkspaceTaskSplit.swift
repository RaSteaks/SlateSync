import SwiftUI

/// One layout owns both edges of the task split. Animating a frame on only
/// the rail lets HStack and native controls interpolate different rectangles,
/// leaving rows/search controls behind while the workspace moves underneath.
struct WorkspaceTaskSplit<Rail: View, Detail: View>: View {
    let showsTasks: Bool
    // Supplied from the workspace environment; keeping it explicit also lets
    // offscreen regression tests verify both policies without changing macOS.
    let reduceMotion: Bool
    @ViewBuilder var rail: Rail
    @ViewBuilder var detail: Detail

    var body: some View {
        WorkspaceTaskLayout(revealedWidth: showsTasks ? WorkspaceTaskLayout.railWidth : 0) {
            rail
                .frame(width: WorkspaceTaskLayout.railWidth)
                .overlay(alignment: .trailing) {
                    Rectangle().fill(SlateSyncTheme.separator).frame(width: 0.5)
                }
                .sidebarResizeBoundary()
                .allowsHitTesting(showsTasks)
                .accessibilityHidden(!showsTasks)
            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .sidebarResizeBoundary()
        }
        // Clip the translated rail at the workspace edge, including its
        // header and native search/list controls, throughout both directions.
        .clipped()
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: showsTasks)
    }
}

struct WorkspaceTaskLayout: Layout {
    static let railWidth: CGFloat = 210
    var revealedWidth: CGFloat

    var animatableData: CGFloat {
        get { revealedWidth }
        set { revealedWidth = newValue }
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        CGSize(width: proposal.width.flatMap { $0.isFinite ? max(0, $0) : nil } ?? 900,
               height: proposal.height.flatMap { $0.isFinite ? max(0, $0) : nil } ?? 600)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard subviews.count == 2 else { return }
        let frames = Self.frames(in: bounds, revealedWidth: revealedWidth)
        subviews[0].place(at: frames.rail.origin, anchor: .topLeading, proposal: ProposedViewSize(frames.rail.size))
        subviews[1].place(at: frames.detail.origin, anchor: .topLeading, proposal: ProposedViewSize(frames.detail.size))
    }

    /// Translate the unchanged list out of the viewport rather than squeezing
    /// it. The detail starts at the very same edge on every animation frame.
    static func frames(in bounds: CGRect, revealedWidth: CGFloat) -> (rail: CGRect, detail: CGRect) {
        let width = max(0, bounds.width)
        let reveal = min(width, max(0, min(railWidth, revealedWidth)))
        return (
            CGRect(x: bounds.minX + reveal - railWidth, y: bounds.minY, width: railWidth, height: bounds.height),
            CGRect(x: bounds.minX + reveal, y: bounds.minY, width: width - reveal, height: bounds.height)
        )
    }
}

extension View {
    /// The split container owns motion. Its children must follow proposed
    /// geometry immediately instead of starting another implicit animation on
    /// native lists, forms or editors. Local explicit animations still work.
    func sidebarResizeBoundary() -> some View {
        clipped()
            .transaction { $0.animation = nil }
    }
}

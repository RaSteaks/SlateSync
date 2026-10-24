import SwiftUI

/// Resizing either sidebar changes placement only: the result editor stays in
/// its original slot and no animated width is written back into view state.
struct WorkspaceResultLayout: Layout {
    private var originalProgress: CGFloat

    init(showsOriginal: Bool) { originalProgress = showsOriginal ? 1 : 0 }

    // One layout value moves the original and releases exactly the same space
    // beside it, keeping the native table and image mounted throughout.
    var animatableData: CGFloat {
        get { originalProgress }
        set { originalProgress = newValue }
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        // Layout probes may be unspecified or infinite; never return an
        // infinite size to SwiftUI. Normal placement fills the finite viewport.
        CGSize(
            width: proposal.width.flatMap { $0.isFinite ? max(0, $0) : nil } ?? 900,
            height: proposal.height.flatMap { $0.isFinite ? max(0, $0) : nil } ?? 600
        )
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard let result = subviews.first else { return }
        let frames = Self.frames(in: bounds, originalProgress: subviews.count > 1 ? originalProgress : 0)
        result.place(at: frames.result.origin, anchor: .topLeading, proposal: ProposedViewSize(frames.result.size))
        if subviews.count > 1 {
            subviews[1].place(at: frames.original.origin, anchor: .topLeading,
                              proposal: ProposedViewSize(frames.original.size))
        }
    }

    /// Keep the original 900 pt inline breakpoint and exact 40% / 420 pt
    /// sizing. Quantizing this width made both sidebar animations jump in
    /// 10 pt increments, even when SwiftUI supplied intermediate geometry.
    static func frames(in bounds: CGRect, showsOriginal: Bool) -> (result: CGRect, original: CGRect) {
        frames(in: bounds, originalProgress: showsOriginal ? 1 : 0)
    }

    static func frames(in bounds: CGRect, originalProgress: CGFloat) -> (result: CGRect, original: CGRect) {
        let width = max(0, bounds.width)
        let inline = width >= 900
        let originalWidth = min(420, inline ? width * 0.4 : width)
        let progress = min(1, max(0, originalProgress))
        let inset = inline ? originalWidth * progress : 0
        return (
            CGRect(x: bounds.minX + inset, y: bounds.minY, width: width - inset, height: bounds.height),
            CGRect(x: bounds.minX - originalWidth * (1 - progress), y: bounds.minY,
                   width: originalWidth, height: bounds.height)
        )
    }
}

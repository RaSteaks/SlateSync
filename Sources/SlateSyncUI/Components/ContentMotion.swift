import AppKit
import QuartzCore
import SwiftUI

/// Navigation and in-region handoffs share a two-second Bézier pace. The
/// four-second appearance reveal remains separate; native editors never
/// independently inherit the container's animations.
enum SlateMotion {
    static let revealDuration: TimeInterval = 2.0
    static let handoffDuration: TimeInterval = 2.0
    // Slow start, faster middle, then a gentle finish. One curve owns both
    // SwiftUI layout motion and the Core Animation masks/image handoffs.
    static let controlPoints: (Double, Double, Double, Double) = (0.4, 0, 0.2, 1)

    static var handoff: Animation {
        let p = controlPoints
        return .timingCurve(p.0, p.1, p.2, p.3, duration: handoffDuration)
    }

    static var timingFunction: CAMediaTimingFunction {
        let p = controlPoints
        return CAMediaTimingFunction(controlPoints: Float(p.0), Float(p.1), Float(p.2), Float(p.3))
    }
}

/// Keyboard navigation uses the same control-relative origin as pointer input.
/// The top strip is centered at its real design width, not stretched across a
/// large content column; sidebar routes enter from the content's leading edge.
enum ContentRevealOrigin: Equatable {
    case leading
    case topSegment(index: Int, count: Int, width: CGFloat)

    func point(in bounds: CGRect) -> CGPoint {
        switch self {
        case .leading:
            return CGPoint(x: bounds.minX, y: bounds.midY)
        case let .topSegment(index, count, width):
            let count = max(1, count)
            let index = min(max(0, index), count - 1)
            let span = min(max(0, width), bounds.width)
            return CGPoint(x: bounds.midX + (CGFloat(index) + 0.5 - CGFloat(count) / 2) * span / CGFloat(count),
                           y: bounds.minY)
        }
    }
}

/// Stable IDs retain the actual outgoing editor until the reveal finishes.
/// Only presentation is retained: callers still own routes and save barriers.
@MainActor @Observable
final class ContentRevealState<Value: Equatable> {
    struct Page: Identifiable {
        let id = UUID()
        let value: Value
    }

    private(set) var pages: [Page]
    private(set) var current: Page
    private(set) var generation = UUID()
    private(set) var origin: ContentRevealOrigin
    private(set) var pendingDestination: (value: Value, origin: ContentRevealOrigin)?
    var progress: CGFloat = 1
    var isTransitioning: Bool { pages.count == 2 }
    var targetProgress: CGFloat { current.id == pages.last?.id ? 1 : 0 }

    init(_ value: Value, origin: ContentRevealOrigin = .leading) {
        let page = Page(value: value)
        pages = [page]
        current = page
        self.origin = origin
    }

    func select(_ value: Value, animated: Bool, origin: ContentRevealOrigin = .leading) {
        guard animated else {
            current = pages.first { $0.value == value } ?? Page(value: value)
            self.origin = origin
            pendingDestination = nil
            finish()
            return
        }
        if isTransitioning {
            guard let destination = pages.first(where: { $0.value == value }) else {
                // A third page cannot replace either half of the live composite
                // without a jump. Finish this leg, then reveal only the latest
                // queued destination; never mount a third editor or snapshot.
                pendingDestination = (value, origin)
                return
            }
            pendingDestination = nil
            guard destination.id != current.id else { return }
            // Reverse the existing circle without changing page order, origin,
            // mask roles or progress. SwiftUI retargets from its rendered radius.
            current = destination
            generation = UUID()
            return
        }
        guard current.value != value else { return }
        begin(value, origin: origin)
    }

    /// Only animation completion may start another leg. Resize, Reduce Motion
    /// and detachment instead use finish() to settle the latest request at once.
    func complete(generation token: UUID) {
        guard token == generation, isTransitioning else { return }
        if let pending = pendingDestination {
            begin(pending.value, origin: pending.origin)
        } else {
            finish()
        }
    }

    func finish(generation token: UUID? = nil) {
        guard token == nil || token == generation else { return }
        if let pending = pendingDestination {
            current = Page(value: pending.value)
            origin = pending.origin
        }
        pendingDestination = nil
        pages = [current]
        progress = 1
        generation = UUID()
    }

    private func begin(_ value: Value, origin: ContentRevealOrigin) {
        let destination = Page(value: value)
        pages = [current, destination]
        current = destination
        self.origin = origin
        pendingDestination = nil
        progress = 0
        generation = UUID()
    }
}

/// Both real pages use the same geometry and animated progress. Even-odd fill
/// keeps the old page outside the circle, including transparent table areas;
/// the new page is visible only inside it. No pixels are captured or recolored.
struct ContentRevealClip: Shape {
    var progress: CGFloat
    let origin: ContentRevealOrigin
    let outgoing: Bool
    var isTransitioning = true

    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    func path(in rect: CGRect) -> Path {
        guard isTransitioning else { return Path(rect) }
        let center = origin.point(in: rect)
        let radius = AppearanceReveal.radius(in: rect, from: center) * min(max(progress, 0), 1)
        var path = outgoing ? Path(rect) : Path()
        path.addEllipse(in: CGRect(x: center.x - radius, y: center.y - radius,
                                   width: radius * 2, height: radius * 2))
        return path
    }
}

extension EnvironmentValues {
    // An outgoing page remains visually enabled; only its input and window
    // chrome ownership are suspended. Nested reveals inherit this boundary.
    @Entry var contentRevealIsActive = true
    @Entry var contentRevealIsManaged = false
}

struct ContentRevealNavigation: Equatable {
    var title = ""
    var subtitle = ""
}

struct ContentRevealNavigationKey: PreferenceKey {
    static let defaultValue = ContentRevealNavigation()
    static func reduce(value: inout ContentRevealNavigation, nextValue: () -> ContentRevealNavigation) {
        let next = nextValue()
        if !next.title.isEmpty { value = next }
    }
}

private struct ContentRevealNavigationModifier: ViewModifier {
    let navigation: ContentRevealNavigation
    @Environment(\.contentRevealIsActive) private var isActive
    @Environment(\.contentRevealIsManaged) private var isManaged

    @ViewBuilder func body(content: Content) -> some View {
        if isManaged {
            // A retained outgoing page must not compete for the window title.
            // AppRootView applies the active page's preference outside masks.
            content.preference(key: ContentRevealNavigationKey.self,
                               value: isActive ? navigation : .init())
        } else {
            content.navigationTitle(navigation.title).navigationSubtitle(navigation.subtitle)
        }
    }
}

extension View {
    func contentRevealNavigationTitle(_ title: String, subtitle: String = "") -> some View {
        modifier(ContentRevealNavigationModifier(navigation: .init(title: title, subtitle: subtitle)))
    }
}

/// Keep the pages in the original SwiftUI tree so their environment, drafts,
/// native controls and toolbar preferences survive. Clipping changes visibility
/// of live content, never its opacity, enabled state or backing color space.
struct ContentRevealRegion<Value: Equatable, Content: View>: View {
    let value: Value
    let origin: ContentRevealOrigin
    private let content: (Value) -> Content
    private let reduceMotionOverride: Bool?
    @State private var presentation: ContentRevealState<Value>
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.contentRevealIsActive) private var ancestorIsActive

    // Production callers inherit the system policy. Offscreen tests inject both
    // policies because SwiftUI's accessibilityReduceMotion is read-only and a
    // hosted runner may enable it independently of the developer's machine.
    init(value: Value, origin: ContentRevealOrigin, reduceMotion: Bool? = nil,
         @ViewBuilder content: @escaping (Value) -> Content) {
        self.value = value
        self.origin = origin
        self.content = content
        reduceMotionOverride = reduceMotion
        _presentation = State(initialValue: ContentRevealState(value, origin: origin))
    }

    private var reduceMotion: Bool { reduceMotionOverride ?? systemReduceMotion }

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                ForEach(presentation.pages) { page in
                    // Chrome follows the committed request even while its page
                    // waits for the current visual leg. Old actions disappear now.
                    let active = page.value == value
                    let inside = page.id == presentation.pages.last?.id
                    content(page.value)
                        .environment(\.contentRevealIsManaged, true)
                        .environment(\.contentRevealIsActive, active && ancestorIsActive)
                        .frame(width: geometry.size.width, height: geometry.size.height)
                        // Animate only the masks, not editor values or layout.
                        .transaction { $0.animation = nil }
                        .clipShape(ContentRevealClip(progress: presentation.progress, origin: presentation.origin,
                            outgoing: !inside, isTransitioning: presentation.isTransitioning),
                            style: FillStyle(eoFill: true))
                        // The detail column's sidebarResizeBoundary strips every
                        // inherited animation, including an explicit withAnimation
                        // from this region. Re-attach the curve below that boundary,
                        // on the masks only. New legs reset without animation;
                        // reversing a leg animates the existing radius back to 0.
                        .animation(SlateMotion.handoff, value: presentation.progress)
                        .allowsHitTesting(active && !presentation.isTransitioning && ancestorIsActive)
                        .accessibilityHidden(!active || !ancestorIsActive)
                        .transition(.identity)
                        .zIndex(inside ? 1 : 0)
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            // One persistent native canvas behind both complementary regions.
            .background(SlateSyncTheme.canvas)
            .overlay {
                ContentRevealInputShield(blocked: presentation.isTransitioning)
                    .accessibilityHidden(true)
            }
            .clipped()
            .onChange(of: geometry.size) { _, _ in finish() }
        }
        .onChange(of: value) { _, destination in
            withoutAnimation {
                presentation.select(destination, animated: !reduceMotion && ancestorIsActive, origin: origin)
            }
        }
        .task(id: presentation.generation) {
            guard presentation.isTransitioning else { return }
            let token = presentation.generation
            // New legs mount at radius zero; reversals keep the rendered radius
            // and animate toward the other endpoint. Cancellation never removes
            // a newer transition's page.
            await Task.yield()
            guard !Task.isCancelled, token == presentation.generation else { return }
            // Plain assignment: the mask's own .animation(value:) supplies the
            // curve, so ancestor transaction resets cannot cancel the reveal.
            presentation.progress = presentation.targetProgress
            do { try await Task.sleep(for: .seconds(SlateMotion.revealDuration)) }
            catch { return }
            withoutAnimation { presentation.complete(generation: token) }
        }
        .onChange(of: reduceMotion) { _, reduced in if reduced { finish() } }
        .onChange(of: ancestorIsActive) { _, active in if !active { finish() } }
        .onChange(of: colorScheme) { _, _ in finish() }
        .onDisappear { finish() }
    }

    private func finish() { withoutAnimation { presentation.finish() } }

    private func withoutAnimation(_ action: () -> Void) {
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction, action)
    }
}

/// A clear native event boundary prevents editing a partially revealed page.
/// Unlike disabled(true), it does not recolor native controls. Window/sidebar
/// controls remain outside it and can immediately retarget navigation.
struct ContentRevealInputShield: NSViewRepresentable {
    let blocked: Bool

    func makeNSView(context: Context) -> Shield { Shield() }
    func updateNSView(_ view: Shield, context: Context) { view.setBlocked(blocked) }
    static func dismantleNSView(_ view: Shield, coordinator: ()) { view.setBlocked(false) }

    final class Shield: NSView {
        private(set) var blocked = false
        override var acceptsFirstResponder: Bool { blocked }
        override func hitTest(_ point: NSPoint) -> NSView? {
            blocked ? super.hitTest(point) : nil
        }
        override func mouseDown(with event: NSEvent) {}
        override func keyDown(with event: NSEvent) {}
        override func scrollWheel(with event: NSEvent) {}

        func setBlocked(_ value: Bool) {
            guard blocked != value else { return }
            blocked = value
            guard let window else { return }
            if value, let responder = window.firstResponder as? NSView,
               responder !== self,
               convert(bounds, to: nil).intersects(responder.convert(responder.bounds, to: nil)) {
                // Save/IME barriers run in the caller before route commitment.
                // Resign only an editor inside this region, never the sidebar.
                window.makeFirstResponder(self)
            } else if !value, window.firstResponder === self {
                window.makeFirstResponder(nil)
            }
        }
    }
}

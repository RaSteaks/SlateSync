import AppKit
import QuartzCore
@testable import SlateSyncUI
import SwiftUI
import XCTest

/// No ordered windows, XCUI, app launch or screen capture. These checks cover
/// live-page lifetime, editor identity, input ownership and complementary masks.
@MainActor
final class ContentMotionTests: XCTestCase {
    func testOriginsFollowCenteredControlsWithinLocalBounds() {
        let bounds = CGRect(x: 20, y: 30, width: 1_200, height: 600)
        XCTAssertEqual(ContentRevealOrigin.leading.point(in: bounds), CGPoint(x: 20, y: 330))
        for (index, x): (Int, CGFloat) in [(0, 500), (1, 620), (2, 740)] {
            XCTAssertEqual(ContentRevealOrigin.topSegment(index: index, count: 3, width: 360).point(in: bounds),
                           CGPoint(x: x, y: 30))
        }
        let narrow = CGRect(x: 0, y: 0, width: 180, height: 400)
        XCTAssertEqual(ContentRevealOrigin.topSegment(index: 99, count: 3, width: 360).point(in: narrow).x, 150)
        XCTAssertEqual(ContentRevealOrigin.topSegment(index: -1, count: 0, width: 360).point(in: narrow).x, 90)
    }

    func testRetargetingReusesPagesAndRejectsStaleCompletion() {
        let state = ContentRevealState(0)
        let original = state.current.id
        let firstOrigin = ContentRevealOrigin.topSegment(index: 1, count: 3, width: 360)
        state.select(1, animated: true, origin: firstOrigin)
        let firstToken = state.generation
        let second = state.current.id
        state.progress = 0.4
        state.select(0, animated: true)
        XCTAssertEqual(state.current.id, original, "Return to the retained actual editor")
        XCTAssertEqual(state.pages.map(\.id), [original, second], "Reversal must not swap mask roles")
        XCTAssertEqual(state.progress, 0.4, "Retarget from the existing radius, never reset it")
        XCTAssertEqual(state.targetProgress, 0)
        XCTAssertEqual(state.origin, firstOrigin, "Changing tabs must not move the in-flight circle")
        state.complete(generation: firstToken)
        XCTAssertEqual(state.pages.count, 2, "An older timer cannot remove a newer outgoing page")
        state.complete(generation: state.generation)
        XCTAssertEqual(state.pages.map(\.id), [original])
        XCTAssertEqual(state.progress, 1)
        state.select(3, animated: false)
        XCTAssertEqual(state.pages.map(\.value), [3], "Reduced motion swaps synchronously")
    }

    func testThirdDestinationWaitsWithoutReplacingEitherVisiblePage() {
        let state = ContentRevealState(0)
        state.select(1, animated: true)
        let token = state.generation
        let ids = state.pages.map(\.id)
        state.progress = 0.4
        state.select(2, animated: true)
        let latestOrigin = ContentRevealOrigin.topSegment(index: 2, count: 3, width: 360)
        state.select(3, animated: true, origin: latestOrigin)
        XCTAssertEqual(state.pages.map(\.id), ids)
        XCTAssertEqual(state.progress, 0.4)
        XCTAssertEqual(state.generation, token, "Queueing cannot restart the running animation or timer")
        XCTAssertEqual(state.origin, .leading)
        XCTAssertEqual(state.pendingDestination?.value, 3, "Only retain the latest request")
        state.complete(generation: token)
        XCTAssertEqual(state.pages.map(\.value), [1, 3])
        XCTAssertEqual(state.pages.first?.id, ids.last)
        XCTAssertEqual(state.origin, latestOrigin)
        XCTAssertEqual(state.progress, 0)
        state.complete(generation: token)
        XCTAssertEqual(state.pages.count, 2, "Old completion cannot finish the queued leg")
        state.complete(generation: state.generation)
        XCTAssertEqual(state.pages.map(\.value), [3])
    }

    func testQueuedDestinationCanBeCancelledOrSettledImmediately() {
        let state = ContentRevealState(0)
        state.select(1, animated: true)
        let token = state.generation
        state.select(2, animated: true)
        state.select(1, animated: true)
        XCTAssertNil(state.pendingDestination)
        XCTAssertEqual(state.generation, token)
        state.select(2, animated: true)
        state.finish()
        XCTAssertEqual(state.pages.map(\.value), [2], "Resize/detachment settles the latest requested page")
        state.select(3, animated: true)
        state.select(4, animated: true)
        state.select(5, animated: false)
        XCTAssertEqual(state.pages.map(\.value), [5], "Reduced motion must discard an older queue")
        XCTAssertNil(state.pendingDestination)
    }

    /// The previous implementation passes identity checks but turns this far
    /// edge white when a partly revealed white page becomes the outgoing page.
    func testRapidReturnAndThirdDestinationKeepTheUnrevealedPixels() async throws {
        for destination in [0, 2] {
            let state = RegionState()
            let host = NSHostingView(rootView: PaintFixture(state: state))
            host.sizingOptions = []
            let window = makeWindow(size: CGSize(width: 600, height: 400))
            window.contentView = host
            defer { window.contentView = nil; window.close() }
            try await settle(host)
            state.page = 1
            try await settle(host)
            let before = try trailingBrightness(of: host)
            XCTAssertLessThan(before, 0.05)
            state.page = destination
            try await settle(host)
            let after = try trailingBrightness(of: host)
            XCTAssertEqual(after, before, accuracy: 0.05, "Rapid navigation must not expose B across the whole viewport")
            XCTAssertFalse(window.isVisible)
        }
    }

    func testMasksAreComplementaryThroughoutReveal() {
        let rect = CGRect(x: 0, y: 0, width: 800, height: 500)
        for origin: ContentRevealOrigin in [.leading, .topSegment(index: 2, count: 3, width: 360)] {
            for progress: CGFloat in [0, 0.1, 0.5, 0.9, 1] {
                let old = ContentRevealClip(progress: progress, origin: origin, outgoing: true).path(in: rect)
                let new = ContentRevealClip(progress: progress, origin: origin, outgoing: false).path(in: rect)
                for x in stride(from: 7, to: 800, by: 37) {
                    for y in stride(from: 9, to: 500, by: 41) {
                        let point = CGPoint(x: x, y: y)
                        XCTAssertNotEqual(old.contains(point, eoFill: true), new.contains(point, eoFill: true),
                                          "Each interior point belongs to exactly one real page")
                    }
                }
            }
        }
    }

    func testComplementaryMasksClipNativeViewsWithoutSnapshotReplay() async throws {
        let host = NSHostingView(rootView: ZStack {
            NativePaint(color: NSColor(srgbRed: 0, green: 0, blue: 0, alpha: 1))
                .clipShape(ContentRevealClip(progress: 0.5, origin: .leading, outgoing: true), style: FillStyle(eoFill: true))
            NativePaint(color: NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
                .clipShape(ContentRevealClip(progress: 0.5, origin: .leading, outgoing: false), style: FillStyle(eoFill: true))
        })
        host.sizingOptions = []
        let window = makeWindow(size: CGSize(width: 600, height: 400))
        window.contentView = host
        defer { window.contentView = nil; window.close() }
        try await settle(host)
        // Read only the offscreen fixture's composited pixels. Production does
        // not capture or replay any bitmap; this asserts native views are clipped.
        let image = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: image)
        let inside = try XCTUnwrap(image.colorAt(x: 20, y: image.pixelsHigh / 2)?.usingColorSpace(.sRGB))
        let outside = try XCTUnwrap(image.colorAt(x: image.pixelsWide - 20, y: image.pixelsHigh / 2)?.usingColorSpace(.sRGB))
        // Black/white endpoints avoid out-of-gamut primary-color conversions
        // in custom monitor profiles; this check is about clipping, not color.
        for value in [inside.redComponent, inside.greenComponent, inside.blueComponent] {
            XCTAssertGreaterThan(value, 0.95, "Circle interior must contain the incoming native view")
        }
        for value in [outside.redComponent, outside.greenComponent, outside.blueComponent] {
            XCTAssertLessThan(value, 0.05, "Circle exterior must retain the outgoing native view")
        }
        XCTAssertFalse(window.isVisible)
    }

    func testRevealAnimatesBelowTheSidebarResizeBoundary() async throws {
        // The production detail column strips inherited animations. Before the
        // masks owned their curve, the new page replaced the old one at once.
        let state = RegionState()
        let host = NSHostingView(rootView: PaintFixture(state: state))
        host.sizingOptions = []
        let window = makeWindow(size: CGSize(width: 600, height: 400))
        window.contentView = host
        defer { window.contentView = nil; window.close() }
        try await settle(host)
        state.page = 1
        try await settle(host)
        XCTAssertLessThan(try trailingBrightness(of: host), 0.05,
                          "Early in the reveal the far edge still shows the outgoing page")
        try await Task.sleep(for: .seconds(SlateMotion.revealDuration + 0.15))
        try await settle(host)
        XCTAssertGreaterThan(try trailingBrightness(of: host), 0.95, "The finished reveal covers the region")
        XCTAssertFalse(window.isVisible)
    }

    func testActualEditorSurvivesOutgoingAndReturnWithoutBeingDisabled() async throws {
        let state = RegionState()
        let host = NSHostingView(rootView: LiveFixture(state: state))
        host.sizingOptions = []
        let window = makeWindow(size: CGSize(width: 900, height: 500))
        window.contentView = host
        defer { window.contentView = nil; window.close() }
        try await settle(host)
        let original = try XCTUnwrap(descendants(of: NSTextField.self, in: host).first { $0.identifier?.rawValue == "editor-0" })
        original.stringValue = "Retained draft"
        state.page = 1
        try await settle(host)
        XCTAssertNotNil(original.superview, "Retain the real outgoing editor")
        XCTAssertEqual(state.navigation.title, "Page 1", "Only the destination owns the window title")
        XCTAssertTrue(original.isEnabled, "Input blocking must not dim outgoing controls")
        XCTAssertEqual(descendants(of: NSTextField.self, in: host).filter { $0.identifier?.rawValue.hasPrefix("editor-") == true }.count, 2)
        XCTAssertTrue(descendants(of: ContentRevealInputShield.Shield.self, in: host).contains { $0.blocked })
        state.page = 0
        try await settle(host)
        let returned = descendants(of: NSTextField.self, in: host).first { $0.identifier?.rawValue == "editor-0" }
        XCTAssertTrue(returned === original)
        XCTAssertEqual(returned?.stringValue, "Retained draft")
        try await Task.sleep(for: .seconds(SlateMotion.revealDuration + 0.15))
        try await settle(host)
        XCTAssertEqual(descendants(of: NSTextField.self, in: host).filter { $0.identifier?.rawValue.hasPrefix("editor-") == true }.count, 1)
        XCTAssertFalse(descendants(of: ContentRevealInputShield.Shield.self, in: host).contains { $0.blocked })
        XCTAssertFalse(window.isVisible)
    }

    /// Follow the real generation-driven tasks through the queued leg, while
    /// deterministic state tests above cover cancellation without timer waits.
    func testQueuedNavigationEventuallyMountsOnlyTheLatestDestination() async throws {
        let state = RegionState()
        let host = NSHostingView(rootView: LiveFixture(state: state))
        host.sizingOptions = []
        let window = makeWindow(size: CGSize(width: 900, height: 500))
        window.contentView = host
        defer { window.contentView = nil; window.close() }
        func editors() -> Set<String> {
            Set(descendants(of: NSTextField.self, in: host).compactMap { $0.identifier?.rawValue }
                .filter { $0.hasPrefix("editor-") })
        }
        try await settle(host)
        state.page = 1
        try await settle(host)
        state.page = 2
        try await settle(host)
        state.page = 3
        try await settle(host)
        XCTAssertEqual(editors(), ["editor-0", "editor-1"])
        try await Task.sleep(for: .seconds(SlateMotion.revealDuration + 0.15))
        try await settle(host)
        XCTAssertEqual(editors(), ["editor-1", "editor-3"])
        XCTAssertEqual(state.navigation.title, "Page 3")
        try await Task.sleep(for: .seconds(SlateMotion.revealDuration + 0.15))
        try await settle(host)
        XCTAssertEqual(editors(), ["editor-3"])
        XCTAssertFalse(descendants(of: ContentRevealInputShield.Shield.self, in: host).contains { $0.blocked })
        XCTAssertFalse(window.isVisible)
    }

    /// Cover the real view for both initial and mid-reveal Reduce Motion, in
    /// addition to the animated fixtures. Never toggle host system preferences.
    func testReducedMotionSettlesLatestPageAndReleasesInputShield() async throws {
        print("CONTENT_MOTION systemReduceMotion=\(NSWorkspace.shared.accessibilityDisplayShouldReduceMotion); testing both injected policies")
        for initiallyReduced in [false, true] {
            let state = RegionState()
            state.reduceMotion = initiallyReduced
            let host = NSHostingView(rootView: LiveFixture(state: state))
            host.sizingOptions = []
            let window = makeWindow(size: CGSize(width: 900, height: 500))
            window.contentView = host
            defer { window.contentView = nil; window.close() }
            try await settle(host)
            state.page = 1
            try await settle(host)
            XCTAssertEqual(descendants(of: NSTextField.self, in: host).count, initiallyReduced ? 1 : 2)
            state.page = 2
            try await settle(host)
            state.reduceMotion = true
            try await settle(host)
            XCTAssertEqual(descendants(of: NSTextField.self, in: host).compactMap { $0.identifier?.rawValue }, ["editor-2"])
            XCTAssertFalse(descendants(of: ContentRevealInputShield.Shield.self, in: host).contains { $0.blocked })
            XCTAssertEqual(state.navigation.title, "Page 2")
            XCTAssertFalse(window.isVisible)
        }
    }

    func testResizeReleasesOutgoingPage() async throws {
        let state = RegionState()
        let host = NSHostingView(rootView: LiveFixture(state: state))
        host.sizingOptions = []
        let window = makeWindow(size: CGSize(width: 900, height: 500))
        window.contentView = host
        defer { window.contentView = nil; window.close() }
        try await settle(host)
        state.page = 1
        try await settle(host)
        XCTAssertTrue(descendants(of: ContentRevealInputShield.Shield.self, in: host).contains { $0.blocked })
        window.setContentSize(CGSize(width: 950, height: 520))
        try await settle(host)
        XCTAssertFalse(descendants(of: ContentRevealInputShield.Shield.self, in: host).contains { $0.blocked })
        XCTAssertEqual(descendants(of: NSTextField.self, in: host).filter { $0.identifier?.rawValue.hasPrefix("editor-") == true }.count, 1)
        XCTAssertFalse(window.isVisible)
    }

    func testInputShieldBlocksWithoutChangingNativeControlEnabledState() {
        let shield = ContentRevealInputShield.Shield(frame: CGRect(x: 0, y: 0, width: 300, height: 200))
        XCTAssertNil(shield.hitTest(CGPoint(x: 20, y: 20)))
        shield.setBlocked(true)
        XCTAssertTrue(shield.hitTest(CGPoint(x: 20, y: 20)) === shield)
        XCTAssertTrue(shield.acceptsFirstResponder)
        shield.setBlocked(false)
        XCTAssertNil(shield.hitTest(CGPoint(x: 20, y: 20)))
    }

    func testComparisonHandoffHasOneContinuousSharedEdge() {
        for width: CGFloat in [400, 900, 1_200] {
            let bounds = CGRect(x: 17, y: 9, width: width, height: 600)
            for progress: CGFloat in [0, 0.1, 0.25, 0.5, 0.9, 1] {
                let frames = WorkspaceResultLayout.frames(in: bounds, originalProgress: progress)
                XCTAssertEqual(frames.result.maxX, bounds.maxX, accuracy: 0.001)
                if width >= 900 {
                    XCTAssertEqual(frames.result.minX, frames.original.maxX, accuracy: 0.001)
                } else {
                    XCTAssertEqual(frames.result, bounds, "Narrow originals overlay a stationary editor")
                }
            }
        }
    }

    func testPageHandoffOnlyRunsForNewImagesAndCanBeReduced() throws {
        let view = MediaPreviewImage.ImageView()
        let first = image(.blue)
        let second = image(.red)
        view.setImage(first, animated: true)
        XCTAssertNil(view.imageLayer.animation(forKey: kCATransition), "Initial content does not add a second reveal")
        view.setImage(second, animated: true)
        assertSharedTiming(try XCTUnwrap(view.imageLayer.animation(forKey: kCATransition)))
        assertSharedTiming(try XCTUnwrap(view.imageLayer.animation(forKey: "page.arrival")))
        view.finishHandoff()
        view.setImage(second, animated: true)
        XCTAssertNil(view.imageLayer.animation(forKey: kCATransition), "Layout-only updates cannot restart motion")
        view.setImage(first, animated: false)
        XCTAssertTrue(view.imageLayer.animationKeys()?.isEmpty ?? true)
        view.setImage(nil, animated: true)
        XCTAssertNil(view.imageLayer.contents)
    }

    private func image(_ color: NSColor) -> NSImage {
        NSImage(size: CGSize(width: 100, height: 100), flipped: false) { rect in
            color.setFill(); rect.fill(); return true
        }
    }

    private func assertSharedTiming(_ animation: CAAnimation, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(animation.duration, 2.0, file: file, line: line)
        guard let timing = animation.timingFunction else {
            XCTFail("Motion must use the shared Bézier timing function", file: file, line: line)
            return
        }
        var point = [Float](repeating: 0, count: 2)
        timing.getControlPoint(at: 1, values: &point)
        XCTAssertEqual(point[0], 0.4, accuracy: 0.001, file: file, line: line)
        XCTAssertEqual(point[1], 0, accuracy: 0.001, file: file, line: line)
        timing.getControlPoint(at: 2, values: &point)
        XCTAssertEqual(point[0], 0.2, accuracy: 0.001, file: file, line: line)
        XCTAssertEqual(point[1], 1, accuracy: 0.001, file: file, line: line)
    }

    private func trailingBrightness(of host: NSView) throws -> CGFloat {
        let image = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: image)
        let color = try XCTUnwrap(image.colorAt(x: image.pixelsWide - 10, y: image.pixelsHigh / 2)?.usingColorSpace(.sRGB))
        return color.redComponent
    }

    private func settle(_ host: NSView) async throws {
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(35))
        host.layoutSubtreeIfNeeded()
    }

    private func descendants<T: NSView>(of type: T.Type, in root: NSView) -> [T] {
        (root as? T).map { [$0] } ?? root.subviews.flatMap { descendants(of: type, in: $0) }
    }

    private func makeWindow(size: CGSize) -> NSWindow {
        let window = NSWindow(contentRect: CGRect(origin: CGPoint(x: -10_000, y: -10_000), size: size),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        return window
    }

    @MainActor @Observable final class RegionState {
        var page = 0
        // Explicit fixture input lets both accessibility policies run without
        // changing the developer's or hosted runner's system preferences.
        var reduceMotion = false
        var navigation = ContentRevealNavigation()
    }

    private struct LiveFixture: View {
        let state: RegionState
        var body: some View {
            NavigationSplitView {
                Text("Sidebar")
            } detail: {
                ContentRevealRegion(value: state.page, origin: .leading, reduceMotion: state.reduceMotion) { page in
                    Editor(page: page).contentRevealNavigationTitle("Page \(page)")
                }.sidebarResizeBoundary()
            }
            .onPreferenceChange(ContentRevealNavigationKey.self) { state.navigation = $0 }
        }
    }

    private struct PaintFixture: View {
        let state: RegionState
        var body: some View {
            ContentRevealRegion(value: state.page, origin: .leading, reduceMotion: state.reduceMotion) { page in
                NativePaint(color: page == 0 ? NSColor(srgbRed: 0, green: 0, blue: 0, alpha: 1)
                                             : NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
            }.sidebarResizeBoundary()
        }
    }

    private struct Editor: NSViewRepresentable {
        let page: Int
        func makeNSView(context: Context) -> NSTextField {
            let field = NSTextField(string: "Draft \(page)")
            field.identifier = NSUserInterfaceItemIdentifier("editor-\(page)")
            return field
        }
        func updateNSView(_ nsView: NSTextField, context: Context) {}
    }

    private struct NativePaint: NSViewRepresentable {
        let color: NSColor
        func makeNSView(context: Context) -> PaintView { PaintView(color: color) }
        func updateNSView(_ nsView: PaintView, context: Context) {}
    }

    private final class PaintView: NSView {
        let color: NSColor
        init(color: NSColor) { self.color = color; super.init(frame: .zero) }
        required init?(coder: NSCoder) { nil }
        override var isOpaque: Bool { true }
        override func draw(_ dirtyRect: NSRect) { color.setFill(); dirtyRect.fill() }
    }
}

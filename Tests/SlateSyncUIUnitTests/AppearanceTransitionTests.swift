import AppKit
import QuartzCore
@testable import SlateSyncUI
import SwiftUI
import XCTest

/// These tests use unordered, offscreen windows only. They exercise the native
/// snapshot/mask boundary without launching the app or taking display focus.
@MainActor
final class AppearanceTransitionTests: XCTestCase {
    func testSystemPreferenceResolvesToActualAppearance() {
        for systemIsDark in [false, true] {
            XCTAssertEqual(AppearanceReveal.isDark("system", systemIsDark: systemIsDark), systemIsDark)
            XCTAssertEqual(AppearanceReveal.isDark("unknown", systemIsDark: systemIsDark), systemIsDark)
            XCTAssertFalse(AppearanceReveal.isDark("light", systemIsDark: systemIsDark))
            XCTAssertTrue(AppearanceReveal.isDark("dark", systemIsDark: systemIsDark))
        }
    }

    func testCircularHoleRevealsCenterAndEventuallyEveryCorner() {
        for size in [CGSize(width: 960, height: 600), CGSize(width: 1_440, height: 900),
                     CGSize(width: 700, height: 540), CGSize(width: 2_560, height: 1_440)] {
            let bounds = CGRect(origin: CGPoint(x: 17, y: 31), size: size)
            for origin in [CGPoint(x: bounds.minX + 180, y: bounds.minY + 30),
                           CGPoint(x: bounds.midX, y: bounds.midY),
                           CGPoint(x: bounds.maxX - 20, y: bounds.maxY - 20)] {
                let radius = AppearanceReveal.radius(in: bounds, from: origin)
                let partial = AppearanceReveal.maskPath(in: bounds, origin: origin, radius: 40)
                XCTAssertFalse(partial.contains(origin, using: .evenOdd))
                XCTAssertFalse(partial.contains(CGPoint(x: origin.x + 10, y: origin.y + 10), using: .evenOdd))
                let final = AppearanceReveal.maskPath(in: bounds, origin: origin, radius: radius)
                for x in [bounds.minX + 0.1, bounds.maxX - 0.1] {
                    for y in [bounds.minY + 0.1, bounds.maxY - 0.1] {
                        let corner = CGPoint(x: x, y: y)
                        XCTAssertGreaterThan(radius, hypot(corner.x - origin.x, corner.y - origin.y))
                        XCTAssertFalse(final.contains(corner, using: .evenOdd), "No old-theme corner may remain")
                    }
                }
                let outsideCircle = CGPoint(x: origin.x + 60, y: origin.y)
                if bounds.contains(outsideCircle) {
                    XCTAssertTrue(partial.contains(outsideCircle, using: .evenOdd), "Outside the circle retains the old theme")
                }
            }
        }
    }

    func testRevealUsesBezierTimingAndExpandingPath() throws {
        let bounds = CGRect(x: 0, y: 0, width: 960, height: 600)
        let origin = CGPoint(x: 180, y: 30)
        let start = AppearanceReveal.maskPath(in: bounds, origin: origin, radius: 0.001)
        let end = AppearanceReveal.maskPath(in: bounds, origin: origin,
                                            radius: AppearanceReveal.radius(in: bounds, from: origin))
        let animation = AppearanceReveal.animation(from: start, to: end)
        XCTAssertEqual(animation.keyPath, "path")
        XCTAssertEqual(animation.duration, 4.0, "The reveal takes four seconds")
        XCTAssertTrue((3.0...5.0).contains(animation.duration), "The sweep stays within the 3–5 s budget")
        let timing = try XCTUnwrap(animation.timingFunction)
        var point = [Float](repeating: 0, count: 2)
        timing.getControlPoint(at: 1, values: &point)
        // Ease-in-out: a gentle start (c1y = 0) and a settled finish (c2y = 1).
        XCTAssertEqual(point[0], 0.4, accuracy: 0.001)
        XCTAssertEqual(point[1], 0)
        timing.getControlPoint(at: 2, values: &point)
        XCTAssertEqual(point[0], 0.2, accuracy: 0.001)
        XCTAssertEqual(point[1], 1)
        // Progress through the first half of the time stays well under half the
        // radius before the middle of the curve (the change is spread over the
        // duration, not front-loaded).
        var early = [Float](repeating: 0, count: 2)
        timing.getControlPoint(at: 1, values: &early)
        XCTAssertLessThan(early[1], early[0], "The curve starts slower than linear")
    }

    func testRevealStartsAtTopTrailingCornerAndSweepsToTheOppositeCorner() {
        for size in [CGSize(width: 960, height: 600), CGSize(width: 1_440, height: 900)] {
            let bounds = CGRect(origin: CGPoint(x: 5, y: 9), size: size)
            let origin = AppearanceReveal.origin(in: bounds)
            XCTAssertEqual(origin, CGPoint(x: bounds.maxX, y: bounds.maxY), "Top-right of the window frame")
            // The farthest corner is bottom-left; the radius must clear it.
            let radius = AppearanceReveal.radius(in: bounds, from: origin)
            XCTAssertGreaterThan(radius, hypot(size.width, size.height))
            let start = AppearanceReveal.maskPath(in: bounds, origin: origin, radius: 0.001)
            XCTAssertTrue(start.contains(CGPoint(x: bounds.minX + 1, y: bounds.minY + 1), using: .evenOdd),
                          "Before the reveal the old appearance covers the far corner")
            let midway = AppearanceReveal.maskPath(in: bounds, origin: origin, radius: radius / 2)
            XCTAssertFalse(midway.contains(CGPoint(x: bounds.maxX - 40, y: bounds.maxY - 40), using: .evenOdd))
            XCTAssertTrue(midway.contains(CGPoint(x: bounds.minX + 40, y: bounds.minY + 40), using: .evenOdd),
                          "The bottom-left is still old halfway through the sweep")
        }
    }

    func testSystemResolvesToAnExplicitSchemeNeverNil() {
        for systemIsDark in [false, true] {
            XCTAssertEqual(AppearanceController.colorScheme(for: "light", systemIsDark: systemIsDark), .light)
            XCTAssertEqual(AppearanceController.colorScheme(for: "dark", systemIsDark: systemIsDark), .dark)
            // 跟随系统 is applied as the current system value, never as nil.
            XCTAssertEqual(AppearanceController.colorScheme(for: "system", systemIsDark: systemIsDark),
                           systemIsDark ? .dark : .light)
        }
    }

    func testMatchingAppearanceReducedMotionAndMissingAnchorStillSave() {
        let fixture = Fixture()
        defer { fixture.close() }
        var saved: [String] = []
        // The window already looks light even if the saved preference was system.
        fixture.transition.change(to: "light", reduceMotion: false) { saved.append("light") }
        XCTAssertNil(fixture.transition.snapshot)
        fixture.transition.change(to: "dark", reduceMotion: true) { saved.append("dark") }
        XCTAssertNil(fixture.transition.snapshot)
        fixture.transition.source = nil
        fixture.transition.change(to: "system", reduceMotion: false) { saved.append("system") }
        XCTAssertNil(fixture.transition.snapshot)
        XCTAssertNil(fixture.transition.requestedPreference)
        XCTAssertEqual(saved, ["light", "dark", "system"])
    }

    func testSnapshotOriginInputAndEditorIdentity() throws {
        let fixture = Fixture()
        defer { fixture.close() }
        fixture.window.makeFirstResponder(fixture.editor)
        let responder = fixture.window.firstResponder
        fixture.transition.change(to: "dark", reduceMotion: false) {
            fixture.window.appearance = NSAppearance(named: .darkAqua)
        }
        let snapshot = try XCTUnwrap(fixture.transition.snapshot)
        // The reveal opens at the window's top-right corner, not at the control.
        let expected = AppearanceReveal.origin(in: snapshot.bounds)
        XCTAssertEqual(snapshot.origin, expected)
        XCTAssertEqual(snapshot.frame, fixture.root.bounds)
        // The old image spans the titlebar as well as the content, from a
        // click-through child window laid exactly over the app window, so the
        // top-right corner joins the sweep. No subview enters the frame view.
        let cover = try XCTUnwrap(snapshot.window)
        XCTAssertTrue(cover.parent === fixture.window)
        XCTAssertEqual(cover.frame, fixture.window.frame)
        XCTAssertTrue(cover.ignoresMouseEvents)
        XCTAssertFalse(cover.canBecomeKey)
        XCTAssertFalse(cover.isVisible, "An unordered parent keeps its overlay unordered")
        XCTAssertTrue(snapshot.targetWindow === fixture.window)
        XCTAssertFalse(fixture.root.subviews.contains(snapshot))
        XCTAssertGreaterThan(snapshot.frame.height, fixture.content.frame.height)
        XCTAssertNotNil(snapshot.image)
        XCTAssertNil(snapshot.hitTest(expected))
        XCTAssertFalse(snapshot.isAccessibilityElement())
        XCTAssertTrue(fixture.editor.superview === fixture.content)
        XCTAssertTrue(fixture.window.firstResponder === responder)
        XCTAssertEqual(fixture.editor.stringValue, "Unsaved 场记 draft")
        XCTAssertFalse(fixture.window.isVisible)
        fixture.transition.finish()
        XCTAssertNil(snapshot.superview)
        XCTAssertNil(cover.parent)
        XCTAssertTrue(fixture.window.childWindows?.isEmpty ?? true)
        XCTAssertNil(fixture.transition.snapshot)
    }

    /// Only ordinary titled windows get an overlay (never another overlay or a
    /// borderless helper), and the square-cornered capture is clipped to a
    /// rounded outline except in full screen.
    func testOverlayEligibilityAndCornerClip() {
        let fixture = Fixture()
        defer { fixture.close() }
        XCTAssertTrue(AppearanceReveal.acceptsOverlay(fixture.window))
        let cover = AppearanceOverlayWindow(over: fixture.window)
        XCTAssertFalse(AppearanceReveal.acceptsOverlay(cover))
        XCTAssertFalse(AppearanceReveal.acceptsOverlay(NSWindow(
            contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: false)))
        XCTAssertGreaterThan(AppearanceReveal.cornerRadius(of: fixture.window), 0)
        XCTAssertEqual(cover.contentView?.layer?.cornerRadius, AppearanceReveal.cornerRadius(of: fixture.window))
        XCTAssertEqual(cover.contentView?.layer?.masksToBounds, true)
    }

    func testRapidRequestsKeepOnlyLatestAndSkipMatchingDestination() throws {
        let fixture = Fixture()
        defer { fixture.close() }
        var saved: [String] = []
        fixture.transition.change(to: "dark", reduceMotion: false) {
            saved.append("dark")
            fixture.window.appearance = NSAppearance(named: .darkAqua)
        }
        let original = try XCTUnwrap(fixture.transition.snapshot)
        fixture.transition.change(to: "light", reduceMotion: false) { saved.append("discarded") }
        fixture.transition.change(to: "dark", reduceMotion: false) { saved.append("latest") }
        XCTAssertTrue(fixture.transition.snapshot === original)
        XCTAssertEqual(fixture.transition.requestedPreference, "dark")
        XCTAssertEqual(saved, ["dark"])
        fixture.transition.finish(animatePending: true)
        XCTAssertEqual(saved, ["dark", "latest"])
        XCTAssertNil(fixture.transition.snapshot, "The queued target already matches the live dark window")
        XCTAssertNil(fixture.transition.requestedPreference)
    }

    func testOtherWindowSupersedesPendingChoiceBeforeSaving() throws {
        for preference in ["system", "light", "dark"] {
            for reduceMotion in [false, true] {
                for animatePending in [false, true] {
                    let first = Fixture()
                    let second = Fixture()
                    defer { first.close(); second.close() }
                    var saved: [String] = []
                    // Both windows observe the same preference. The second
                    // request must supersede the first even if its color matches.
                    first.transition.change(to: "dark", reduceMotion: false) {
                        saved.append("dark")
                        first.window.appearance = NSAppearance(named: .darkAqua)
                        second.window.appearance = NSAppearance(named: .darkAqua)
                    }
                    let oldSnapshot = try XCTUnwrap(first.transition.snapshot)
                    first.transition.change(to: "light", reduceMotion: false) { saved.append("stale") }
                    second.transition.change(to: preference, reduceMotion: reduceMotion) {
                        XCTAssertNil(first.transition.snapshot, "Cancel the old reveal before saving the new choice")
                        XCTAssertNil(first.transition.requestedPreference, "The next sidebar click must use the shared preference")
                        saved.append(preference)
                    }
                    XCTAssertNil(oldSnapshot.superview)
                    // Neither normal completion nor resize/close cleanup may
                    // resurrect a request superseded by the other window.
                    first.transition.finish(animatePending: animatePending)
                    NotificationCenter.default.post(name: NSWindow.didResizeNotification, object: first.window)
                    XCTAssertEqual(saved, ["dark", preference])
                    XCTAssertFalse(first.window.isVisible)
                    XCTAssertFalse(second.window.isVisible)
                }
            }
        }
    }

    func testLatestWindowQueueSurvivesOldWindowTimeoutAndTeardown() async throws {
        let first = Fixture()
        let second = Fixture()
        defer { first.close(); second.close() }
        var saved: [String] = []
        // Leave effective appearances unchanged so the one-second fallback
        // stays pending after the older anchor is dismantled, without UI focus.
        first.transition.change(to: "dark", reduceMotion: false) { saved.append("first") }
        first.transition.change(to: "light", reduceMotion: false) { saved.append("stale") }
        second.transition.change(to: "dark", reduceMotion: false) { saved.append("second") }
        second.transition.change(to: "system", reduceMotion: false) { saved.append("system") }
        XCTAssertNotNil(second.transition.snapshot)
        AppearanceTransitionAnchor.dismantleNSView(first.anchor, coordinator: ())
        XCTAssertEqual(second.transition.requestedPreference, "system")
        try await Task.sleep(for: .milliseconds(1_200))
        XCTAssertEqual(saved, ["first", "second", "system"])
        XCTAssertNil(first.transition.snapshot)
        XCTAssertNil(second.transition.snapshot)
        XCTAssertNil(second.transition.requestedPreference)
        XCTAssertFalse(first.window.isVisible)
        XCTAssertFalse(second.window.isVisible)
    }

    func testResizeAndReduceMotionDiscardSnapshotAndApplyPendingChoice() {
        for reduceMotion in [false, true] {
            let fixture = Fixture()
            fixture.transition.change(to: "dark", reduceMotion: false) {
                fixture.window.appearance = NSAppearance(named: .darkAqua)
            }
            var applied = false
            fixture.transition.change(to: "light", reduceMotion: reduceMotion) { applied = true }
            if !reduceMotion {
                NotificationCenter.default.post(name: NSWindow.didResizeNotification, object: fixture.window)
            }
            XCTAssertTrue(applied)
            XCTAssertNil(fixture.transition.snapshot)
            XCTAssertNil(fixture.transition.requestedPreference)
            XCTAssertFalse(fixture.window.isVisible)
            fixture.close()
        }
    }

    func testNativeAppearanceCallbackInstallsMaskAndCleansUp() async throws {
        let fixture = Fixture()
        defer { fixture.close() }
        fixture.transition.change(to: "dark", reduceMotion: false) {
            fixture.window.appearance = NSAppearance(named: .darkAqua)
        }
        let snapshot = try XCTUnwrap(fixture.transition.snapshot)
        // Give the native appearance/layout callback a turn without ordering
        // the window front. This is not a foreground animation/FPS assertion.
        try await Task.sleep(for: .milliseconds(30))
        let mask = try XCTUnwrap(snapshot.layer?.mask as? CAShapeLayer)
        XCTAssertEqual(mask.fillRule, .evenOdd)
        // Core Animation may complete immediately for an unordered window;
        // timing is verified separately, without pretending to sample display FPS.
        // One point inside the corner: the hole is centred there, so it is open.
        let inside = CGPoint(x: snapshot.origin.x - 1, y: snapshot.origin.y - 1)
        XCTAssertFalse(try XCTUnwrap(mask.path).contains(inside, using: .evenOdd))
        try await waitForReveal(fixture.transition)
        XCTAssertNil(fixture.transition.snapshot)
        XCTAssertNil(snapshot.superview)
        XCTAssertFalse(fixture.window.isVisible)
    }

    func testSwiftUIPreferenceUpdateRevealsWithoutReplacingHostedEditor() async throws {
        let state = HostedState()
        let transition = AppearanceTransition()
        let host = NSHostingView(rootView: HostedSurface(state: state, transition: transition))
        host.sizingOptions = []
        let window = NSWindow(contentRect: CGRect(x: -10_000, y: -10_000, width: 960, height: 600),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer {
            transition.finish()
            window.contentView = nil
            window.close()
        }
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(60))
        let source = try XCTUnwrap(transition.source)
        XCTAssertEqual(window.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]), .aqua)
        for preference in ["dark", "light"] {
            transition.change(to: preference, reduceMotion: false) { state.preference = preference }
            let snapshot = try XCTUnwrap(transition.snapshot)
            let image = try XCTUnwrap(snapshot.image)
            let bitmap = try XCTUnwrap(NSBitmapImageRep(data: XCTUnwrap(image.tiffRepresentation)))
            for point in [CGPoint(x: 30, y: 100), CGPoint(x: bitmap.pixelsWide / 2, y: bitmap.pixelsHigh / 2)] {
                XCTAssertGreaterThan(try XCTUnwrap(bitmap.colorAt(x: Int(point.x), y: Int(point.y))).alphaComponent,
                                     0.99, "Native sidebar material must not leak the new theme outside the circle")
            }
            // Optional artifact export keeps offline capture evidence out of
            // the repository and never reads another app's on-screen pixels.
            if let directory = ProcessInfo.processInfo.environment["SLATESYNC_APPEARANCE_EVIDENCE_DIR"] {
                let url = URL(fileURLWithPath: directory, isDirectory: true)
                try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
                try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                    .write(to: url.appendingPathComponent("before-\(preference).png"))
            }
            try await Task.sleep(for: .milliseconds(100))
            host.layoutSubtreeIfNeeded()
            XCTAssertNotNil(snapshot.layer?.mask, "The actual preferredColorScheme update must start the reveal")
            try await waitForReveal(transition)
            XCTAssertNil(transition.snapshot)
            XCTAssertTrue(transition.source === source, "Changing appearance preserves the hosted control")
            XCTAssertEqual(state.draft, "Unsaved 场记 draft")
            XCTAssertFalse(window.isVisible)
        }
    }

    /// The production wiring: an explicit `preferredColorScheme` for every choice
    /// (system resolves to the live system value). Every light/dark/system change
    /// must leave the window and its content in the same appearance — the nil
    /// scheme left them split after 浅色 → 跟随系统 — and the reveal overlay must be
    /// gone afterwards.
    func testEveryChoiceLeavesWindowAndContentTogether() async throws {
        let state = HostedState()
        let transition = AppearanceTransition()
        let host = NSHostingView(rootView: SyncedSurface(state: state, transition: transition))
        host.sizingOptions = []
        let window = NSWindow(contentRect: CGRect(x: -10_000, y: -10_000, width: 960, height: 600),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { transition.finish(); window.contentView = nil; window.close() }
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(80))

        func isDark(_ appearance: NSAppearance) -> Bool { appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua }
        func contentIsDark() throws -> Bool {
            host.layoutSubtreeIfNeeded()
            let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: rep)
            let color = try XCTUnwrap(rep.colorAt(x: rep.pixelsWide * 3 / 4, y: rep.pixelsHigh * 4 / 5)?.usingColorSpace(.deviceRGB))
            return color.brightnessComponent < 0.5
        }
        let systemIsDark = isDark(NSApplication.shared.effectiveAppearance)
        // Includes light → system, the choice that used to split the window.
        for preference in ["dark", "light", "system", "dark", "system"] {
            transition.change(to: preference, reduceMotion: false) { state.preference = preference }
            try await waitForReveal(transition)
            try await Task.sleep(for: .milliseconds(150))
            XCTAssertNil(transition.snapshot, "\(preference): the reveal overlay must be gone")
            let expectedDark = AppearanceReveal.isDark(preference, systemIsDark: systemIsDark)
            XCTAssertEqual(isDark(window.effectiveAppearance), expectedDark, "\(preference): window")
            XCTAssertEqual(try contentIsDark(), expectedDark, "\(preference): content must agree with the window")
        }
    }

    /// The reveal runs for four seconds; poll instead of sleeping a fixed
    /// time so a choice that skips the animation (same effective appearance)
    /// does not pay for it.
    private func waitForReveal(_ transition: AppearanceTransition) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(7))
        try await Task.sleep(for: .milliseconds(50))
        while transition.snapshot != nil, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }
    }

    @MainActor @Observable
    fileprivate final class HostedState {
        var preference = "light"
        var draft = "Unsaved 场记 draft"
    }

    private struct HostedSurface: View {
        @Bindable var state: HostedState
        let transition: AppearanceTransition

        var body: some View {
            NavigationSplitView {
                List { Text("Project Library"); Text("Workspace") }
                    .listStyle(.sidebar)
                    .safeAreaInset(edge: .bottom) {
                        Image(systemName: "sun.max")
                            .frame(width: 20, height: 20)
                            .background(AppearanceTransitionAnchor(transition: transition, preference: state.preference))
                            .padding(20)
                    }
                    .navigationSplitViewColumnWidth(230)
            } detail: {
                TextField("Draft", text: $state.draft)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color(nsColor: .windowBackgroundColor))
            }
            .preferredColorScheme(state.preference == "dark" ? .dark : .light)
        }
    }

    private struct SyncedSurface: View {
        @Bindable var state: HostedState
        let transition: AppearanceTransition

        var body: some View {
            NavigationSplitView {
                List { Text("Project Library"); Text("Workspace") }
                    .listStyle(.sidebar)
                    .safeAreaInset(edge: .bottom) {
                        Image(systemName: "sun.max")
                            .frame(width: 20, height: 20)
                            .background(AppearanceTransitionAnchor(transition: transition, preference: state.preference))
                            .padding(20)
                    }
                    .navigationSplitViewColumnWidth(230)
            } detail: {
                SlateSyncTheme.canvas.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .preferredColorScheme(AppearanceController.colorScheme(
                for: state.preference, systemIsDark: SystemAppearanceMonitor.shared.isDark))
        }
    }

    @MainActor
    private final class Fixture {
        let window: NSWindow
        let content = NSView(frame: CGRect(x: 0, y: 0, width: 960, height: 600))
        let anchor = AppearanceTransitionAnchor.Probe(frame: CGRect(x: 170, y: 20, width: 20, height: 20))
        let editor = NSTextField(string: "Unsaved 场记 draft")
        let transition = AppearanceTransition()
        /// The window frame view: the overlay covers titlebar and content.
        var root: NSView { content.superview ?? content }

        init() {
            _ = NSApplication.shared
            window = NSWindow(contentRect: CGRect(x: -10_000, y: -10_000, width: 960, height: 600),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.appearance = NSAppearance(named: .aqua)
            window.contentView = content
            editor.frame = CGRect(x: 250, y: 200, width: 300, height: 30)
            content.addSubview(editor)
            content.addSubview(anchor)
            anchor.transition = transition
            transition.source = anchor
            root.layoutSubtreeIfNeeded()
        }

        func close() {
            transition.finish()
            window.contentView = nil
            window.close()
        }
    }
}

import AppKit
import QuartzCore
import SwiftUI

/// Geometry and timing for the appearance reveal. A frozen image of the old
/// appearance covers the whole window — titlebar and toolbar included — from a
/// click-through child window, and loses an expanding circular hole: inside the circle is the live new
/// appearance, outside it the old one. The circle is centred on the window's
/// top-right corner and sweeps to the bottom-left one in four seconds (the
/// middle of the 3–5 s budget). Its radius follows a cubic Bézier curve: a
/// gentle start, the fastest growth early in the sweep, and a long settle as
/// the edge reaches the far corner.
enum AppearanceReveal {
    static let duration: CFTimeInterval = 4.0
    /// Cubic Bézier control points (c1x, c1y, c2x, c2y): cubic-bezier(0.4, 0, 0.2, 1).
    static let controlPoints: (Float, Float, Float, Float) = (0.4, 0, 0.2, 1)

    /// Top-right corner of a (non-flipped) overlay that spans the window frame:
    /// the circle's centre, so it grows diagonally across the whole window.
    static func origin(in bounds: CGRect) -> CGPoint {
        CGPoint(x: bounds.maxX, y: bounds.maxY)
    }

    /// The view whose drawing is the whole window. The frame view (the content
    /// view's superview) also draws the titlebar and toolbar, which sit above
    /// the content view: an overlay inside the content view stayed beneath
    /// them, so the top-right corner — the circle's centre — flipped instantly
    /// instead of joining the sweep. The frame view is only drawn into a
    /// bitmap; AppKit rejects foreign subviews there ("unknown subview").
    @MainActor
    static func captureRoot(of window: NSWindow) -> NSView? {
        window.contentView?.superview ?? window.contentView
    }

    /// Ordinary titled windows only. A window with a sheet (or the sheet
    /// itself) changes instantly: an overlay window ordered above the parent
    /// could hide the live sheet behind a stale image.
    @MainActor
    static func acceptsOverlay(_ window: NSWindow) -> Bool {
        !(window is AppearanceOverlayWindow) && window.styleMask.contains(.titled)
            && window.sheetParent == nil && window.attachedSheet == nil
    }

    /// The captured frame has square corners, so the overlay clips itself.
    /// AppKit publishes no window corner radius; each value matches or
    /// slightly exceeds the system's, so an imperfect guess leaves a sliver
    /// of the new appearance at a corner rather than an old-colored square
    /// past the window's outline.
    @MainActor
    static func cornerRadius(of window: NSWindow) -> CGFloat {
        if window.styleMask.contains(.fullScreen) { return 0 }
        if #available(macOS 26, *) { return window.toolbar == nil ? 18 : 28 }
        return 11
    }

    static func isDark(_ preference: String, systemIsDark: Bool) -> Bool {
        switch preference {
        case "light": false
        case "dark": true
        default: systemIsDark
        }
    }

    static func radius(in bounds: CGRect, from origin: CGPoint) -> CGFloat {
        let dx = max(abs(origin.x - bounds.minX), abs(origin.x - bounds.maxX))
        let dy = max(abs(origin.y - bounds.minY), abs(origin.y - bounds.maxY))
        // An extra point clears antialiased pixels at the farthest corner.
        return hypot(dx, dy) + 1
    }

    static func maskPath(in bounds: CGRect, origin: CGPoint, radius: CGFloat) -> CGPath {
        let path = CGMutablePath()
        path.addRect(bounds)
        path.addEllipse(in: CGRect(x: origin.x - radius, y: origin.y - radius,
                                  width: radius * 2, height: radius * 2))
        return path
    }

    static func animation(from start: CGPath, to end: CGPath) -> CABasicAnimation {
        let animation = CABasicAnimation(keyPath: "path")
        animation.fromValue = start
        animation.toValue = end
        animation.duration = duration
        let p = controlPoints
        animation.timingFunction = CAMediaTimingFunction(controlPoints: p.0, p.1, p.2, p.3)
        return animation
    }
}

/// Resolves the saved preference to an explicit SwiftUI color scheme.
///
/// `preferredColorScheme(nil)` does not reliably hand control back to the system:
/// after 浅色 → 跟随系统 the window followed macOS while SwiftUI's content stayed
/// light, leaving a half-light, half-dark window. So the roots never pass nil —
/// "system" resolves to the live system appearance and is applied as an explicit
/// scheme, exactly like 浅色 / 深色. `SystemAppearanceMonitor` keeps that value
/// current while the user's macOS appearance changes.
@MainActor
enum AppearanceController {
    static func colorScheme(for preference: String, systemIsDark: Bool) -> ColorScheme {
        AppearanceReveal.isDark(preference, systemIsDark: systemIsDark) ? .dark : .light
    }
}

/// The true macOS appearance, observable. The application-level appearance is
/// never overridden, so `NSApp.effectiveAppearance` always reports the system.
@MainActor @Observable
final class SystemAppearanceMonitor: NSObject {
    static let shared = SystemAppearanceMonitor()

    private(set) var isDark: Bool
    @ObservationIgnored private var observation: NSKeyValueObservation?

    private override init() {
        isDark = Self.read()
        super.init()
        observation = NSApplication.shared.observe(\.effectiveAppearance, options: [.new]) { [weak self] _, _ in
            Task { @MainActor in self?.refresh() }
        }
        DistributedNotificationCenter.default().addObserver(
            self, selector: #selector(systemThemeChanged),
            name: Notification.Name("AppleInterfaceThemeChangedNotification"), object: nil)
    }

    @objc private func systemThemeChanged() {
        // The notification precedes the application's own appearance update.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in self?.refresh() }
    }

    private func refresh() {
        let now = Self.read()
        if now != isDark { isDark = now }
    }

    private static func read() -> Bool {
        NSApplication.shared.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    }
}

/// A control-local bridge retains only a temporary bitmap, never another copy
/// of the SwiftUI hierarchy. Preferences and preferredColorScheme remain owned
/// by the existing views, including system-following and other open windows.
@MainActor
final class AppearanceTransition: NSObject {
    // Every app window writes the same appearance preference. Keep only a
    // weak request owner so a new window can supersede queued work without
    // retaining another window, its editors, or its temporary snapshot.
    private static weak var latestRequester: AppearanceTransition?

    weak var source: NSView?
    private(set) var requestedPreference: String?
    private(set) var snapshot: AppearanceSnapshotView?
    /// Overlays on the app's other visible windows, so the whole app changes
    /// together instead of only the window that holds the control.
    private var companions: [AppearanceSnapshotView] = []
    private var pending: Request?
    private var generation = UUID()
    private var destinationIsDark = false
    private var hasStarted = false

    private struct Request {
        let preference: String
        let reduceMotion: Bool
        let apply: () -> Void
    }

    func change(to preference: String, reduceMotion: Bool, apply: @escaping () -> Void) {
        if let previous = Self.latestRequester, previous !== self {
            // Revoke pending writes before cleanup, which normally applies
            // them. Do this even when the new choice has the same effective
            // color or skips animation; preference identity still changed.
            previous.pending = nil
            previous.finish()
        }
        Self.latestRequester = self
        requestedPreference = preference
        let request = Request(preference: preference, reduceMotion: reduceMotion, apply: apply)
        // Finish the current reveal before applying the most recent choice.
        // Capturing a half-revealed image or removing it early would flash.
        if snapshot != nil {
            pending = request
            if reduceMotion { finish(animatePending: false) }
            return
        }
        perform(request)
    }

    private func perform(_ request: Request) {
        let target = AppearanceReveal.isDark(request.preference, systemIsDark: Self.isDark(NSApplication.shared.effectiveAppearance))
        guard !request.reduceMotion,
              let source, let window = source.window,
              Self.isDark(window.effectiveAppearance) != target,
              AppearanceReveal.acceptsOverlay(window),
              let overlay = Self.overlay(over: window) else {
            requestedPreference = nil
            request.apply()
            return
        }

        snapshot = overlay
        companions = otherWindowOverlays(besides: window, target: target)
        destinationIsDark = target
        hasStarted = false
        generation = UUID()
        let token = generation

        // Resize/close/display changes invalidate the captured geometry. Drop
        // the visual layer while keeping the user's latest requested preference.
        for name in [NSWindow.willCloseNotification, NSWindow.didResizeNotification,
                     NSWindow.didChangeBackingPropertiesNotification] {
            NotificationCenter.default.addObserver(self, selector: #selector(invalidateSnapshot), name: name, object: window)
        }
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(accessibilityChanged),
            name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
        request.apply()
        appearanceDidUpdate()

        // If the host disappears or never publishes its new appearance, a
        // stale snapshot must not cover an otherwise interactive window.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            guard let self, self.generation == token, !self.hasStarted else { return }
            self.finish(animatePending: false)
        }
    }

    func appearanceDidUpdate() {
        guard let snapshot, let window = snapshot.targetWindow else { return }
        let matchesDestination = Self.isDark(window.effectiveAppearance) == destinationIsDark
        if hasStarted {
            // Another window or the system may change the shared appearance
            // during this reveal. Never leave an old bitmap over that new state.
            if !matchesDestination { finish(animatePending: false) }
            return
        }
        guard matchesDestination else { return }
        let token = generation
        // AppKit's effective-appearance callback can precede SwiftUI layout.
        // Begin on the next turn only after the destination is actually applied.
        DispatchQueue.main.async { [weak self, weak snapshot] in
            guard let self, let snapshot, self.generation == token, !self.hasStarted,
                  let window = snapshot.targetWindow,
                  Self.isDark(window.effectiveAppearance) == self.destinationIsDark else { return }
            self.hasStarted = true
            // Settle the live window underneath before the hole first opens.
            window.contentView?.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            // Every window reveals on the same clock from its own top-right corner.
            for companion in self.companions { companion.reveal {} }
            snapshot.reveal { [weak self] in
                guard let self, self.generation == token else { return }
                self.finish(animatePending: true)
            }
        }
    }

    @objc private func invalidateSnapshot() { finish(animatePending: false) }

    @objc private func accessibilityChanged() {
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            finish(animatePending: false)
        }
    }

    func finish(animatePending: Bool = false) {
        generation = UUID()
        let oldSnapshot = snapshot
        snapshot = nil
        oldSnapshot?.dismiss()
        for companion in companions { companion.dismiss() }
        companions = []
        NotificationCenter.default.removeObserver(self)
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        let next = pending
        pending = nil
        requestedPreference = nil
        if let next {
            if animatePending {
                requestedPreference = next.preference
                perform(next)
            } else {
                next.apply()
            }
        }
    }

    /// Snapshot every other visible app window that still shows the old
    /// appearance. Resizing or closing any of them drops all overlays.
    private func otherWindowOverlays(besides primary: NSWindow, target: Bool) -> [AppearanceSnapshotView] {
        NSApplication.shared.windows.compactMap { other in
            guard other !== primary, other.isVisible, !other.isMiniaturized,
                  AppearanceReveal.acceptsOverlay(other),
                  Self.isDark(other.effectiveAppearance) != target,
                  let overlay = Self.overlay(over: other) else { return nil }
            for name in [NSWindow.willCloseNotification, NSWindow.didResizeNotification] {
                NotificationCenter.default.addObserver(
                    self, selector: #selector(invalidateSnapshot), name: name, object: other)
            }
            return overlay
        }
    }

    private static func isDark(_ appearance: NSAppearance) -> Bool {
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    }

    /// Captures the whole window (titlebar, toolbar and content) in its
    /// current appearance and lays that image exactly over it from a child
    /// window, which moves with the window and never takes input or focus.
    private static func overlay(over window: NSWindow) -> AppearanceSnapshotView? {
        guard let root = AppearanceReveal.captureRoot(of: window), let image = capture(root) else { return nil }
        let cover = AppearanceOverlayWindow(over: window)
        guard let container = cover.contentView else { return nil }
        let overlay = AppearanceSnapshotView(frame: container.bounds)
        overlay.image = image
        overlay.origin = AppearanceReveal.origin(in: overlay.bounds)
        overlay.targetWindow = window
        container.addSubview(overlay)
        window.addChildWindow(cover, ordered: .above)
        return overlay
    }

    private static func capture(_ view: NSView) -> NSImage? {
        guard view.bounds.width > 0, view.bounds.height > 0,
              let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
        view.layoutSubtreeIfNeeded()
        // App-local drawing uses public AppKit APIs; no screen recording,
        // screenshot permissions, disk files, or duplicated editors are needed.
        view.cacheDisplay(in: view.bounds, to: bitmap)
        guard let cgImage = bitmap.cgImage,
              let context = CGContext(data: nil, width: cgImage.width, height: cgImage.height,
                                      bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        // Native sidebar/toolbar materials can cache with transparent pixels. Flatten
        // against the OLD window color so the new theme cannot leak through
        // those pixels outside the expanding hole. Only two bitmaps exist
        // during capture; the overlay retains the finished opaque image alone.
        let pixels = CGRect(x: 0, y: 0, width: cgImage.width, height: cgImage.height)
        view.effectiveAppearance.performAsCurrentDrawingAppearance {
            context.setFillColor(NSColor.windowBackgroundColor.cgColor)
            context.fill(pixels)
        }
        context.draw(cgImage, in: pixels)
        guard let opaqueImage = context.makeImage() else { return nil }
        return NSImage(cgImage: opaqueImage, size: view.bounds.size)
    }
}

/// A borderless, transparent, click-through window laid exactly over one app
/// window for the duration of a reveal. As a child window it follows moves,
/// Spaces and full screen with its parent and stays ordered directly above it.
@MainActor
final class AppearanceOverlayWindow: NSWindow {
    init(over parent: NSWindow) {
        super.init(contentRect: parent.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        isReleasedWhenClosed = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true
        animationBehavior = .none
        isExcludedFromWindowsMenu = true
        collectionBehavior = [.transient, .ignoresCycle, .fullScreenAuxiliary]
        level = parent.level
        setAccessibilityElement(false)
        setFrame(parent.frame, display: false)
        // The parent's own shadow and outline stay visible; only the rounded
        // interior is covered by the old image.
        let container = NSView(frame: CGRect(origin: .zero, size: parent.frame.size))
        container.wantsLayer = true
        container.layer?.cornerRadius = AppearanceReveal.cornerRadius(of: parent)
        container.layer?.cornerCurve = .continuous
        container.layer?.masksToBounds = true
        contentView = container
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// The bitmap is decorative and passes all input to the original controls.
@MainActor
final class AppearanceSnapshotView: NSImageView {
    var origin = CGPoint.zero
    /// The app window this image covers. Its appearance, not the overlay
    /// window's, decides when the reveal starts.
    weak var targetWindow: NSWindow?

    override init(frame: NSRect) {
        super.init(frame: frame)
        imageScaling = .scaleAxesIndependently
        wantsLayer = true
        setAccessibilityElement(false)
        setAccessibilityHidden(true)
    }

    required init?(coder: NSCoder) { nil }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// Stops the sweep and removes the image together with its overlay window.
    func dismiss() {
        layer?.mask?.removeAllAnimations()
        let cover = window
        removeFromSuperview()
        if let cover {
            cover.parent?.removeChildWindow(cover)
            cover.orderOut(nil)
        }
    }

    func reveal(completion: @escaping @MainActor () -> Void) {
        guard let layer else { completion(); return }
        let mask = CAShapeLayer()
        mask.frame = bounds
        mask.fillRule = .evenOdd
        let start = AppearanceReveal.maskPath(in: bounds, origin: origin, radius: 0.001)
        let end = AppearanceReveal.maskPath(in: bounds, origin: origin,
                                            radius: AppearanceReveal.radius(in: bounds, from: origin))
        // Only the mask path animates; text, native tables and document state
        // stay mounted and never perform a second color/layout interpolation.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        CATransaction.setCompletionBlock {
            Task { @MainActor in completion() }
        }
        mask.path = end
        layer.mask = mask
        mask.add(AppearanceReveal.animation(from: start, to: end), forKey: "appearance.reveal")
        CATransaction.commit()
    }
}

/// A noninteractive background measures the real icon/control location even
/// for keyboard activation and after sidebar resizing; it never uses the mouse.
struct AppearanceTransitionAnchor: NSViewRepresentable {
    let transition: AppearanceTransition
    // Include the preference in representable updates even when switching
    // system/explicit modes leaves the source's layout and icon unchanged.
    let preference: String

    func makeNSView(context: Context) -> Probe {
        let probe = Probe()
        probe.transition = transition
        transition.source = probe
        return probe
    }

    func updateNSView(_ view: Probe, context: Context) {
        transition.source = view
        transition.appearanceDidUpdate()
    }

    static func dismantleNSView(_ view: Probe, coordinator: ()) {
        view.transition?.finish()
        view.transition?.source = nil
    }

    final class Probe: NSView {
        weak var transition: AppearanceTransition?
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidChangeEffectiveAppearance() {
            super.viewDidChangeEffectiveAppearance()
            transition?.appearanceDidUpdate()
        }
    }
}

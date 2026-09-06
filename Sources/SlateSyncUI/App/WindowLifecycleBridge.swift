import AppKit
import SwiftUI

/// The narrow window-close half of the lifecycle adapter. SwiftUI onDisappear
/// runs after a window has already closed and cannot veto a failed save. This
/// zero-size probe only locates its own window; it creates no window or UI.
public struct WindowLifecycleBridge: NSViewRepresentable {
    private let close: @MainActor () async throws -> Void
    private let failure: @MainActor (Error) -> Void
    private let visibility: @MainActor (Bool) -> Void

    public init(
        close: @escaping @MainActor () async throws -> Void,
        failure: @escaping @MainActor (Error) -> Void,
        visibility: @escaping @MainActor (Bool) -> Void = { _ in }
    ) {
        self.close = close
        self.failure = failure
        self.visibility = visibility
    }

    public func makeCoordinator() -> WindowCloseCoordinator {
        WindowCloseCoordinator(close: close, failure: failure, visibility: visibility)
    }

    public func makeNSView(context: Context) -> WindowProbe {
        let view = WindowProbe()
        view.didAttach = { [weak coordinator = context.coordinator] in coordinator?.attach(to: $0) }
        return view
    }

    public func updateNSView(_ view: WindowProbe, context: Context) {}

    public static func dismantleNSView(_ view: WindowProbe, coordinator: WindowCloseCoordinator) {
        view.didAttach = nil
        coordinator.detach()
    }

    public final class WindowProbe: NSView {
        var didAttach: ((NSWindow) -> Void)?
        public override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window { didAttach?(window) }
        }
    }
}

/// Proxy only the close decision and forward every other delegate capability
/// to SwiftUI. A failed drain keeps both the window and its draft alive. The
/// captured request is single-flight; AppKit receives one successful close.
@MainActor
public final class WindowCloseCoordinator: NSObject, NSWindowDelegate {
    private weak var window: NSWindow?
    private weak var previous: (any NSWindowDelegate)?
    private let close: @MainActor () async throws -> Void
    private let failure: @MainActor (Error) -> Void
    private let visibility: @MainActor (Bool) -> Void
    private var closeTask: Task<Void, Never>?
    private var approved = false

    public init(close: @escaping @MainActor () async throws -> Void, failure: @escaping @MainActor (Error) -> Void, visibility: @escaping @MainActor (Bool) -> Void = { _ in }) {
        self.close = close
        self.failure = failure
        self.visibility = visibility
    }

    public func attach(to window: NSWindow) {
        guard self.window !== window else { return }
        detach()
        // A coordinator can outlive a closed SwiftUI scene and be reused for
        // another window; approval belongs to the old window only.
        approved = false
        self.window = window
        previous = window.delegate
        window.delegate = self
        visibility(window.occlusionState.contains(.visible))
    }

    public func detach() {
        visibility(false)
        if let window, window.delegate === self { window.delegate = previous }
        window = nil
        previous = nil
    }

    public nonisolated override func responds(to selector: Selector!) -> Bool {
        if super.responds(to: selector) { return true }
        // NSObject declares this introspection hook nonisolated, while AppKit
        // invokes an NSWindow delegate on the main thread. Make that bridge
        // contract explicit before reading the MainActor-owned delegate.
        return MainActor.assumeIsolated {
            previous?.responds(to: selector) == true
        }
    }

    public func windowDidChangeOcclusionState(_ notification: Notification) {
        // Visibility belongs to this exact window, including minimization and
        // app hiding; an inactive but visible secondary window stays distinct.
        if let window { visibility(window.occlusionState.contains(.visible)) }
        previous?.windowDidChangeOcclusionState?(notification)
    }

    public nonisolated override func forwardingTarget(for selector: Selector!) -> Any? {
        let target: MainThreadForwardingTarget? = MainActor.assumeIsolated {
            guard previous?.responds(to: selector) == true else { return nil }
            // Retain only across this synchronous Objective-C forwarding
            // boundary; takeRetainedValue transfers ownership to AppKit's
            // returned AnyObject without an unchecked Sendable escape.
            return previous.map {
                MainThreadForwardingTarget(
                    address: UInt(bitPattern: Unmanaged.passRetained($0).toOpaque())
                )
            }
        }
        if let target {
            guard let pointer = UnsafeMutableRawPointer(bitPattern: target.address) else {
                return super.forwardingTarget(for: selector)
            }
            return Unmanaged<AnyObject>.fromOpaque(pointer).takeRetainedValue()
        }
        return super.forwardingTarget(for: selector)
    }

    public func windowShouldClose(_ sender: NSWindow) -> Bool {
        if approved { return true }
        guard closeTask == nil else { return false }
        if let editor = sender.firstResponder as? NSTextView, editor.hasMarkedText() {
            // Do not force an IME candidate into persistent state during close.
            failure(WindowCloseFailure.composition)
            return false
        }
        // The business drain below is the authoritative close decision. A
        // SwiftUI scene delegate may return false while it is retaining the
        // scene for restoration, which would otherwise veto every valid close.
        // Resign the editor opportunistically; Workspace.flushEditor remains
        // the lossless fallback when AppKit cannot change first responder.
        _ = sender.makeFirstResponder(nil)
        closeTask = Task { [weak self, weak sender] in
            guard let self else { return }
            do {
                try await close()
                approved = true
                sender?.performClose(nil)
            } catch { failure(error) }
            closeTask = nil
        }
        return false
    }
}

/// The retained Objective-C address is Sendable as an integer while the object
/// is immediately transferred back to AppKit on the same synchronous call.
private struct MainThreadForwardingTarget: Sendable {
    let address: UInt
}

private enum WindowCloseFailure: LocalizedError {
    case composition
    var errorDescription: String? { "请先完成正在输入的文字，再关闭窗口" }
}

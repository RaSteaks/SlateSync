import AppKit
import SwiftUI

extension View {
    /// Expresses the minimum in outer-window points, including native chrome.
    /// Measuring the owning window avoids baking one macOS toolbar height into
    /// layout, and keeps settings and document windows independent.
    public func slateWindowMinimumSize(width: CGFloat, height: CGFloat) -> some View {
        modifier(WindowMinimumSize(width: width, height: height))
    }
}

private struct WindowMinimumSize: ViewModifier {
    let width: CGFloat
    let height: CGFloat
    @State private var chromeHeight: CGFloat = 0

    func body(content: Content) -> some View {
        content
            // Flexible maxima let the native scene offer standard resizing.
            .frame(
                minWidth: width, maxWidth: .infinity,
                minHeight: max(0, height - chromeHeight), maxHeight: .infinity
            )
            .background {
                WindowChromeProbe { measuredHeight in
                    if chromeHeight != measuredHeight { chromeHeight = measuredHeight }
                }
                .frame(width: 0, height: 0)
            }
    }
}

private struct WindowChromeProbe: NSViewRepresentable {
    let report: (CGFloat) -> Void
    func makeNSView(context: Context) -> Probe {
        let view = Probe()
        view.report = report
        return view
    }
    func updateNSView(_ view: Probe, context: Context) {
        view.report = report
        view.refresh()
    }

    final class Probe: NSView {
        var report: ((CGFloat) -> Void)?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            let center = NotificationCenter.default
            center.removeObserver(self)
            if let window {
                // macOS 15/26 的 Settings 宿主会在多个时机重设 styleMask 并剥掉
                // resizable（含标题栏点击之后这类没有 key/main 变化的时刻）。
                // didUpdate 随窗口每个事件触发，把补插延迟压到一个事件周期内，
                // 拖拽前的任何交互都能先恢复可缩放状态。
                center.addObserver(self, selector: #selector(windowRestyled),
                                   name: NSWindow.didUpdateNotification, object: window)
                center.addObserver(self, selector: #selector(windowRestyled),
                                   name: NSWindow.didBecomeKeyNotification, object: window)
                center.addObserver(self, selector: #selector(windowRestyled),
                                   name: NSWindow.didBecomeMainNotification, object: window)
                center.addObserver(self, selector: #selector(windowRestyled),
                                   name: NSWindow.didChangeOcclusionStateNotification, object: window)
            }
            refresh()
        }
        override func viewDidChangeEffectiveAppearance() {
            super.viewDidChangeEffectiveAppearance()
            // The macOS 15 Settings host reapplies its style mask when appearance
            // changes. Restore the native resize affordance after that update too.
            refresh()
        }
        @objc private func windowRestyled() {
            refresh()
        }
        func refresh() {
            // Defer until SwiftUI has installed the native toolbar. This probe
            // neither retains the window nor changes restoration or its frame.
            DispatchQueue.main.async { [weak self] in
                guard let self, let window = self.window else { return }
                // macOS 15 Settings reports flexible min/max bounds but omits
                // NSWindow.StyleMask.resizable (32771 vs 32779). Enable only
                // that native affordance; leave all size constraints to SwiftUI.
                if !window.styleMask.contains(.resizable) { window.styleMask.insert(.resizable) }
                self.report?(max(0, window.frame.height - window.contentLayoutRect.height))
            }
        }
    }
}

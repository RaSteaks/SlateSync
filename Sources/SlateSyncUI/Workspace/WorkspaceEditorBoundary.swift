import AppKit
import SlateSyncDomain
import SwiftUI

/// Window-local probe covers SwiftUI text fields as well as the CSV bridge.
/// It owns no window; changing layout first refuses marked text, then lets the
/// native field editor publish committed text before the existing store flush.
@MainActor
final class WorkspaceEditorBoundary {
    weak var window: NSWindow?

    func prepare() throws {
        guard let window else { return }
        if let editor = window.firstResponder as? NSTextView, editor.hasMarkedText() {
            throw SlateSyncError(code: "EDIT_COMPOSITION", message: "请先完成当前文字输入，再切换布局")
        }
        guard window.makeFirstResponder(nil) else {
            throw SlateSyncError(code: "EDIT_FOCUS", message: "请先完成当前编辑，再切换布局")
        }
    }
}

struct WorkspaceEditorProbe: NSViewRepresentable {
    let boundary: WorkspaceEditorBoundary
    func makeNSView(context: Context) -> Probe {
        let view = Probe()
        view.boundary = boundary
        return view
    }
    func updateNSView(_ view: Probe, context: Context) { view.boundary = boundary }

    final class Probe: NSView {
        weak var boundary: WorkspaceEditorBoundary?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            boundary?.window = window
        }
    }
}

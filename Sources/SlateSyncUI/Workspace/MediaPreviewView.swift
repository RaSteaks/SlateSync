import AppKit
import QuartzCore
import SlateSyncDomain
import SwiftUI

// Product copy uses the shared launch language; user content stays verbatim.

/// Only displays the JPEG already validated/prepared by Media; original
/// PDF/ImageIO parsing and page ownership remain outside the view layer.
struct MediaPreviewView: View {
    let document: PreparedDocument
    @Binding var pageIndex: Int
    @State private var showsLightbox = false
    // Retain only the visible page image. Progress/layout updates reuse it;
    // page or document changes replace it without retaining the full PDF.
    @State private var previewImage: NSImage?

    var body: some View {
        VStack(spacing: 8) {
            Button { showsLightbox = true } label: {
                // The native image layer fits its viewport without a
                // GeometryReader rebuilding this image/shadow tree per frame.
                pageStage
            }.buttonStyle(.plain).accessibilityLabel(L10n.tr("放大场记单预览")).accessibilityIdentifier("workspace.preview.enlarge").help(L10n.tr("放大场记单预览"))
            navigation.padding(.bottom, 10)
        }
        // The page floats on the window canvas with its own shadow.
        .background(SlateSyncTheme.canvas)
        .onChange(of: previewJPEG, initial: true) {
            previewImage = previewJPEG.flatMap { NSImage(data: $0) }
        }
        .sheet(isPresented: $showsLightbox) {
            VStack {
                HStack { navigation; Spacer(); Button(L10n.tr("关闭预览")) { showsLightbox = false }.keyboardShortcut(.cancelAction) }
                pageStage
            }
            .padding(20).frame(minWidth: 720, minHeight: 480)
            // Paging shortcuts exist only inside the enlarged preview, so arrow keys
            // in task/result text editors retain native caret/IME behavior.
            .onKeyPress(.leftArrow) { previous(); return .handled }
            .onKeyPress(.rightArrow) { next(); return .handled }
        }
    }

    /// The document page alone, centered with the standard page margin. The
    /// layer draws its own rectangular shadow; there is no frame around it.
    private var pageStage: some View {
        preview
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(20)
    }

    private var preview: some View {
        MediaPreviewImage(
            image: previewImage,
            accessibilityLabel: L10n.tr("场记单第 {0} 页，共 {1} 页", [String(describing: pageIndex + 1), String(describing: document.pages.count)])
        )
    }

    private var previewJPEG: Data? {
        guard document.pages.indices.contains(pageIndex) else { return nil }
        return document.pages[pageIndex].views.first?.image.jpeg
    }

    private var navigation: some View {
        HStack {
            Button(L10n.tr("上一页"), systemImage: "chevron.left", action: previous).labelStyle(.iconOnly).buttonStyle(.borderless).foregroundStyle(.secondary).help(L10n.tr("上一页")).accessibilityIdentifier("workspace.preview.previous").disabled(pageIndex == 0)
            Text("\(pageIndex + 1) / \(document.pages.count)").monospacedDigit()
            Button(L10n.tr("下一页"), systemImage: "chevron.right", action: next).labelStyle(.iconOnly).buttonStyle(.borderless).foregroundStyle(.secondary).help(L10n.tr("下一页")).accessibilityIdentifier("workspace.preview.next").disabled(pageIndex + 1 >= document.pages.count)
        }
    }

    private func previous() { pageIndex = max(0, pageIndex - 1) }
    private func next() { pageIndex = min(document.pages.count - 1, pageIndex + 1) }
}

/// Core Animation retains the current page's bitmap while either sidebar
/// resizes. Only the aspect-fit frame and a rectangular shadow path change;
/// no image decoding or composited-alpha shadow is repeated for geometry.
struct MediaPreviewImage: NSViewRepresentable {
    let image: NSImage?
    let accessibilityLabel: String
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeNSView(context: Context) -> ImageView { ImageView() }

    func updateNSView(_ view: ImageView, context: Context) {
        view.setImage(image, animated: !reduceMotion)
        if reduceMotion { view.finishHandoff() }
        view.setAccessibilityLabel(accessibilityLabel)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: ImageView, context: Context) -> CGSize? {
        // The page's pixel dimensions must never become its layout minimum.
        proposal.replacingUnspecifiedDimensions(by: CGSize(width: 640, height: 400))
    }

    final class ImageView: NSView {
        let imageLayer = CALayer()
        private var image: NSImage?
        private var pixelSize = CGSize.zero

        override var isFlipped: Bool { true }

        init() {
            super.init(frame: .zero)
            wantsLayer = true
            imageLayer.isHidden = true
            imageLayer.contentsGravity = .resizeAspect
            imageLayer.shadowColor = NSColor.black.cgColor
            imageLayer.shadowOpacity = 0.20
            imageLayer.shadowRadius = 9
            imageLayer.shadowOffset = CGSize(width: 0, height: 3)
            layer?.addSublayer(imageLayer)
            setAccessibilityElement(true)
            setAccessibilityRole(.image)
        }

        required init?(coder: NSCoder) { nil }

        func setImage(_ image: NSImage?, animated: Bool = false) {
            guard self.image !== image else { return }
            let replacesVisibleImage = self.image != nil
            finishHandoff()
            self.image = image
            let bitmap = image?.cgImage(forProposedRect: nil, context: nil, hints: nil)
            pixelSize = bitmap.map { CGSize(width: $0.width, height: $0.height) } ?? .zero
            // Geometry follows the owning layout immediately. Only an actual
            // page/image replacement receives the shared, centered handoff;
            // repeated layout updates continue to reuse the same bitmap.
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            // Initial mounting belongs to the surrounding feature reveal;
            // only a page already on screen hands off to its replacement.
            if animated, replacesVisibleImage, bitmap != nil {
                let fade = CATransition()
                fade.type = .fade
                fade.duration = SlateMotion.handoffDuration
                fade.timingFunction = SlateMotion.timingFunction
                // CATransition uses Core Animation's reserved transition key.
                // Register before changing contents so both bitmaps participate.
                imageLayer.add(fade, forKey: kCATransition)
                let arrival = CABasicAnimation(keyPath: "transform.translation.y")
                arrival.fromValue = 6
                arrival.toValue = 0
                arrival.duration = SlateMotion.handoffDuration
                arrival.timingFunction = fade.timingFunction
                imageLayer.add(arrival, forKey: "page.arrival")
            }
            imageLayer.contents = bitmap
            imageLayer.isHidden = bitmap == nil
            CATransaction.commit()
            needsLayout = true
        }

        /// Changing accessibility settings or clearing media also clears any
        /// in-flight visual work; the new page never waits for an old one.
        func finishHandoff() {
            imageLayer.removeAnimation(forKey: kCATransition)
            imageLayer.removeAnimation(forKey: "page.arrival")
        }

        override func layout() {
            super.layout()
            let scale = pixelSize.width > 0 && pixelSize.height > 0
                ? min(max(0, bounds.width) / pixelSize.width, max(0, bounds.height) / pixelSize.height) : 0
            let size = CGSize(width: pixelSize.width * scale, height: pixelSize.height * scale)
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            imageLayer.frame = CGRect(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2,
                                      width: size.width, height: size.height)
            imageLayer.shadowPath = size.width > 0 && size.height > 0
                ? CGPath(rect: CGRect(origin: .zero, size: size), transform: nil) : nil
            CATransaction.commit()
        }

        // The enclosing SwiftUI Button owns clicks and opens the enlarged preview.
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}

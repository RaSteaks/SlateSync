import SlateSyncDomain
import SwiftUI

/// Only displays the JPEG already validated/prepared by Media; original
/// PDF/ImageIO parsing and page ownership remain outside the view layer.
struct MediaPreviewView: View {
    let document: PreparedDocument
    @Binding var pageIndex: Int
    @Environment(\.slateSyncDensity) private var density
    @State private var showsLightbox = false
    // Retain only the visible page image. Progress/layout updates reuse it;
    // page or document changes replace it without retaining the full PDF.
    @State private var previewImage: NSImage?

    var body: some View {
        VStack(spacing: 8) {
            Button { showsLightbox = true } label: {
                // Geometry bounds the image independently of its pixel size;
                // the LightTable keeps the evidence page the brightest region
                // (灯箱反转) while paging controls stay in the adjacent bar.
                GeometryReader { geometry in
                    LightTable {
                        preview.frame(
                            width: max(0, geometry.size.width - density.panelPadding * 2),
                            height: max(0, geometry.size.height - density.panelPadding * 2))
                    }
                }
            }.buttonStyle(.plain).accessibilityLabel("放大场记单预览").accessibilityIdentifier("workspace.preview.enlarge").help("放大场记单预览")
            Divider()
            navigation.padding(.horizontal, 12).padding(.bottom, 12)
        }
        .background(SlateSyncTheme.canvas)
        .onChange(of: previewJPEG, initial: true) {
            previewImage = previewJPEG.flatMap { NSImage(data: $0) }
        }
        .sheet(isPresented: $showsLightbox) {
            VStack {
                HStack { navigation; Spacer(); Button("关闭预览") { showsLightbox = false }.keyboardShortcut(.cancelAction) }
                LightTable { preview }
            }
            .padding(20).frame(minWidth: 720, minHeight: 480)
            // Paging shortcuts exist only inside the lightbox, so arrow keys
            // in task/result text editors retain native caret/IME behavior.
            .onKeyPress(.leftArrow) { previous(); return .handled }
            .onKeyPress(.rightArrow) { next(); return .handled }
        }
    }

    @ViewBuilder private var preview: some View {
        if let image = previewImage {
            Image(nsImage: image).resizable().scaledToFit()
                .accessibilityLabel("场记单第 \(pageIndex + 1) 页，共 \(document.pages.count) 页")
        }
    }

    private var previewJPEG: Data? {
        guard document.pages.indices.contains(pageIndex) else { return nil }
        return document.pages[pageIndex].views.first?.image.jpeg
    }

    private var navigation: some View {
        HStack {
            Button("上一页", systemImage: "chevron.left", action: previous).labelStyle(.iconOnly).help("上一页").accessibilityIdentifier("workspace.preview.previous").disabled(pageIndex == 0)
            Text("\(pageIndex + 1) / \(document.pages.count)").monospacedDigit()
            Button("下一页", systemImage: "chevron.right", action: next).labelStyle(.iconOnly).help("下一页").accessibilityIdentifier("workspace.preview.next").disabled(pageIndex + 1 >= document.pages.count)
        }
    }

    private func previous() { pageIndex = max(0, pageIndex - 1) }
    private func next() { pageIndex = min(document.pages.count - 1, pageIndex + 1) }
}

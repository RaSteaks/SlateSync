import SlateSyncDomain
import SwiftUI

/// Only displays the JPEG already validated/prepared by Media; original
/// PDF/ImageIO parsing and page ownership remain outside the view layer.
struct MediaPreviewView: View {
    let document: PreparedDocument
    @Binding var pageIndex: Int
    @State private var showsLightbox = false

    var body: some View {
        VStack(spacing: 8) {
            Button { showsLightbox = true } label: {
                preview.frame(maxHeight: 180)
            }.buttonStyle(.plain).accessibilityLabel("放大场记单预览")
            navigation
        }
        .sheet(isPresented: $showsLightbox) {
            VStack {
                HStack { navigation; Spacer(); Button("关闭预览") { showsLightbox = false }.keyboardShortcut(.cancelAction) }
                preview.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .padding(20).frame(minWidth: 720, minHeight: 480)
            // Paging shortcuts exist only inside the lightbox, so arrow keys
            // in task/result text editors retain native caret/IME behavior.
            .onKeyPress(.leftArrow) { previous(); return .handled }
            .onKeyPress(.rightArrow) { next(); return .handled }
        }
    }

    @ViewBuilder private var preview: some View {
        if document.pages.indices.contains(pageIndex),
           let jpeg = document.pages[pageIndex].views.first?.image.jpeg,
           let image = NSImage(data: jpeg) {
            Image(nsImage: image).resizable().scaledToFit()
                .accessibilityLabel("场记单第 \(pageIndex + 1) 页，共 \(document.pages.count) 页")
        }
    }

    private var navigation: some View {
        HStack {
            Button("上一页", systemImage: "chevron.left", action: previous).disabled(pageIndex == 0)
            Text("\(pageIndex + 1) / \(document.pages.count)").monospacedDigit()
            Button("下一页", systemImage: "chevron.right", action: next).disabled(pageIndex + 1 >= document.pages.count)
        }
    }

    private func previous() { pageIndex = max(0, pageIndex - 1) }
    private func next() { pageIndex = min(document.pages.count - 1, pageIndex + 1) }
}

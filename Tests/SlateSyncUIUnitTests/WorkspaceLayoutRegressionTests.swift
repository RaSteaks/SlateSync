import AppKit
import SlateSyncDomain
@testable import SlateSyncUI
import SwiftUI
import XCTest

/// Layout-only regressions never order a window front or sample display FPS.
/// They cover the intermediate widths supplied by both sidebar animations.
@MainActor
final class WorkspaceLayoutRegressionTests: XCTestCase {
    func testTaskSplitHasOneSharedEdgeAtEveryIntermediateWidth() {
        // Include overshoot, fractional positions, nonzero origins and narrow
        // proposals; no frame may expose a gap or leave the list over detail.
        for width: CGFloat in [0, 100, 700, 1_000] {
            let bounds = CGRect(x: 27, y: 13, width: width, height: 600)
            for reveal: CGFloat in [-10, 0, 0.25, 79.5, 150, 209.75, 210, 220] {
                let frames = WorkspaceTaskLayout.frames(in: bounds, revealedWidth: reveal)
                XCTAssertEqual(frames.rail.width, 210)
                XCTAssertEqual(frames.rail.maxX, frames.detail.minX, accuracy: 0.001)
                XCTAssertEqual(frames.detail.maxX, bounds.maxX, accuracy: 0.001)
                XCTAssertGreaterThanOrEqual(frames.detail.width, 0)
                XCTAssertGreaterThanOrEqual(frames.detail.minX, bounds.minX)
                XCTAssertLessThanOrEqual(frames.rail.maxX, bounds.maxX)
                if reveal <= 0 {
                    XCTAssertEqual(frames.detail, bounds)
                    XCTAssertLessThanOrEqual(frames.rail.maxX, bounds.minX)
                }
            }
        }
    }

    func testTaskSplitKeepsNativePanesAndSuppressesInheritedAnimations() async throws {
        let probes = LayoutProbes()
        let host = NSHostingView(rootView: taskSurface(reveal: 210, probes: probes))
        host.sizingOptions = []
        let window = NSWindow(contentRect: CGRect(x: -10_000, y: -10_000, width: 1_000, height: 600),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.contentView = nil; window.close() }
        try await settle(host)
        let rail = try XCTUnwrap(probes.views["rail"])
        let detail = try XCTUnwrap(probes.views["detail"])
        // Drive the actual Layout through close/open/reversal positions. The
        // injected parent animation models NavigationSplitView's transaction.
        for reveal: CGFloat in [150, 79.5, 0, 79.5, 150, 79.5, 210] {
            host.rootView = taskSurface(reveal: reveal, probes: probes)
            try await settle(host)
            let railFrame = rail.convert(rail.bounds, to: host)
            let detailFrame = detail.convert(detail.bounds, to: host)
            XCTAssertEqual(railFrame.width, 210, accuracy: 1 / window.backingScaleFactor)
            XCTAssertEqual(railFrame.maxX, detailFrame.minX, accuracy: 1 / window.backingScaleFactor)
            XCTAssertEqual(detailFrame.minX, reveal, accuracy: 1 / window.backingScaleFactor)
            XCTAssertEqual(detailFrame.maxX, 1_000, accuracy: 1 / window.backingScaleFactor)
            XCTAssertTrue(probes.views["rail"] === rail)
            XCTAssertTrue(probes.views["detail"] === detail)
        }
        XCTAssertEqual(probes.creationCount, 2)
        XCTAssertFalse(probes.receivedAnimation, "Pane controls must not run a second split animation")
        XCTAssertFalse(window.isVisible)
    }

    func testTaskSplitToggleAndReduceMotionReachCleanEndpoints() async throws {
        for reduceMotion in [false, true] {
            let probes = LayoutProbes()
            let host = NSHostingView(rootView: taskSplit(visible: true, reduceMotion: reduceMotion, probes: probes))
            host.sizingOptions = []
            let window = NSWindow(contentRect: CGRect(x: -10_000, y: -10_000, width: 1_000, height: 600),
                                  styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = host
            defer { window.contentView = nil; window.close() }
            try await settle(host)
            let rail = try XCTUnwrap(probes.views["rail"])
            let detail = try XCTUnwrap(probes.views["detail"])
            for visible in [false, true, false, true] {
                host.rootView = taskSplit(visible: visible, reduceMotion: reduceMotion, probes: probes)
                try await settle(host)
                // Even while moving, the native panes must share one edge.
                XCTAssertEqual(rail.convert(rail.bounds, to: host).maxX,
                               detail.convert(detail.bounds, to: host).minX, accuracy: 1)
                if !reduceMotion {
                    try await Task.sleep(for: .milliseconds(300))
                    try await settle(host)
                }
                let railFrame = rail.convert(rail.bounds, to: host)
                let detailFrame = detail.convert(detail.bounds, to: host)
                XCTAssertEqual(railFrame.width, 210, accuracy: 1)
                XCTAssertEqual(railFrame.maxX, visible ? 210 : 0, accuracy: 1)
                XCTAssertEqual(detailFrame.minX, visible ? 210 : 0, accuracy: 1)
                XCTAssertEqual(detailFrame.maxX, 1_000, accuracy: 1)
            }
            XCTAssertEqual(probes.creationCount, 2)
            XCTAssertFalse(probes.receivedAnimation)
            XCTAssertFalse(window.isVisible)
        }
    }

    func testComparisonUsesContinuousWidthsAndStaysInsideViewport() {
        let origin = CGPoint(x: 27, y: 13)
        let start = WorkspaceResultLayout.frames(in: CGRect(origin: origin, size: CGSize(width: 900, height: 600)), showsOriginal: true)
        let next = WorkspaceResultLayout.frames(in: CGRect(origin: origin, size: CGSize(width: 900.25, height: 600)), showsOriginal: true)
        // Fractional changes must survive placement; the previous 10 pt bins
        // kept the image still and then jumped it during sidebar motion.
        XCTAssertEqual(start.original.width, 360)
        XCTAssertEqual(next.original.width, 360.1, accuracy: 0.001)
        XCTAssertEqual(next.result.minX, next.original.maxX, accuracy: 0.001)
        XCTAssertEqual(next.result.maxX, 927.25, accuracy: 0.001)
        XCTAssertEqual(next.original.origin, origin)

        for width: CGFloat in [0, 210, 899.5, 900, 1_050, 1_440] {
            let bounds = CGRect(x: 0, y: 0, width: width, height: 600)
            let visible = WorkspaceResultLayout.frames(in: bounds, showsOriginal: true)
            let hidden = WorkspaceResultLayout.frames(in: bounds, showsOriginal: false)
            XCTAssertEqual(hidden.result, bounds, "Hiding the original always restores the entire editor")
            XCTAssertGreaterThanOrEqual(visible.result.width, 0)
            XCTAssertLessThanOrEqual(visible.original.maxX, bounds.maxX)
            XCTAssertLessThanOrEqual(visible.original.width, 420)
            if width < 900 { XCTAssertEqual(visible.result, bounds, "Narrow comparison overlays the editor") }
        }
    }

    func testResizeAndComparisonTogglePreserveMountedPanes() async throws {
        let probes = LayoutProbes()
        let host = NSHostingView(rootView: resultSurface(showsOriginal: true, probes: probes))
        host.sizingOptions = []
        let window = NSWindow(contentRect: CGRect(x: -10_000, y: -10_000, width: 1_000, height: 600),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer {
            window.contentView = nil
            window.close()
        }
        try await settle(host)
        let result = try XCTUnwrap(probes.views["result"])
        let original = try XCTUnwrap(probes.views["original"])
        // Shrink and grow through the native-sidebar and task-rail ranges.
        for width: CGFloat in [1_000, 951, 901, 899, 700, 899, 901, 1_000] {
            window.setContentSize(CGSize(width: width, height: 600))
            try await settle(host)
            let frame = original.convert(original.bounds, to: host)
            // Native view placement snaps to backing pixels. The value-level
            // test above separately requires exact fractional geometry.
            XCTAssertEqual(frame.width, width >= 900 ? width * 0.4 : 420, accuracy: 1 / window.backingScaleFactor)
            XCTAssertTrue(probes.views["result"] === result)
            XCTAssertTrue(probes.views["original"] === original)
        }
        for visible in [false, true] {
            host.rootView = resultSurface(showsOriginal: visible, probes: probes)
            try await settle(host)
            let frame = result.convert(result.bounds, to: host)
            XCTAssertEqual(frame.width, visible ? 600 : 1_000, accuracy: 0.01)
        }
        XCTAssertEqual(probes.creationCount, 2, "Resizing and toggling must not remount the editor or preview")
        XCTAssertFalse(window.isVisible)
    }

    func testPreviewResizeReusesBitmapAndRectangularShadow() throws {
        let image = try fixtureImage(width: 200, height: 100)
        let view = MediaPreviewImage.ImageView()
        view.setImage(image)
        let contents = try XCTUnwrap(view.imageLayer.contents as AnyObject?)
        for width: CGFloat in [1_000, 900.25, 700, 420, 210, 0, 210, 420, 900.25, 1_000] {
            view.frame = CGRect(x: 0, y: 0, width: width, height: 500)
            view.setImage(image)
            view.needsLayout = true
            view.layoutSubtreeIfNeeded()
            XCTAssertTrue(view.imageLayer.contents as AnyObject? === contents, "Geometry must reuse the decoded page")
            XCTAssertEqual(view.imageLayer.frame.width, width, accuracy: 0.001)
            XCTAssertEqual(view.imageLayer.frame.height, width / 2, accuracy: 0.001)
            if width > 0 {
                XCTAssertEqual(view.imageLayer.shadowPath?.boundingBox, view.imageLayer.bounds)
            } else {
                XCTAssertNil(view.imageLayer.shadowPath)
            }
            XCTAssertTrue(view.imageLayer.animationKeys()?.isEmpty ?? true, "Layer animations must not lag the sidebar")
        }
        XCTAssertNil(view.hitTest(.zero), "The enclosing SwiftUI Button retains lightbox click ownership")
    }

    func testMediaPreviewKeepsNativeImageAcrossSidebarWidths() async throws {
        let image = try fixtureImage(width: 200, height: 100)
        let bitmap = try XCTUnwrap(image.representations.first as? NSBitmapImageRep)
        let jpeg = try XCTUnwrap(bitmap.representation(using: .jpeg, properties: [:]))
        let prepared = try PreparedImage(jpeg: jpeg, width: 200, height: 100)
        let document = PreparedDocument(filename: "sidebar-fixture.jpg", pages: [
            PreparedMediaPage(pageNumber: 1, views: [PreparedMediaView(viewIndex: 0, viewType: .full, image: prepared)])
        ])
        let host = NSHostingView(rootView: MediaPreviewView(document: document, pageIndex: .constant(0)))
        host.sizingOptions = []
        let window = NSWindow(contentRect: CGRect(x: -10_000, y: -10_000, width: 1_000, height: 600),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer {
            window.contentView = nil
            window.close()
        }
        try await settle(host)
        let native = try XCTUnwrap(nativeImage(in: host))
        let contents = try XCTUnwrap(native.imageLayer.contents as AnyObject?)
        for width: CGFloat in [790, 560, 790, 1_000] {
            window.setContentSize(CGSize(width: width, height: 600))
            try await settle(host)
            XCTAssertTrue(nativeImage(in: host) === native)
            XCTAssertTrue(native.imageLayer.contents as AnyObject? === contents)
            XCTAssertEqual(native.bounds.width, width - 40, accuracy: 1 / window.backingScaleFactor)
        }
        XCTAssertFalse(window.isVisible)
    }

    func testPreviewReplacesPageAndClearsPreviousContents() throws {
        let view = MediaPreviewImage.ImageView()
        view.frame = CGRect(x: 0, y: 0, width: 400, height: 400)
        view.setImage(try fixtureImage(width: 200, height: 100))
        view.layoutSubtreeIfNeeded()
        let first = try XCTUnwrap(view.imageLayer.contents as AnyObject?)
        view.setImage(try fixtureImage(width: 100, height: 200))
        view.layoutSubtreeIfNeeded()
        XCTAssertFalse(view.imageLayer.contents as AnyObject? === first)
        XCTAssertEqual(view.imageLayer.frame.size, CGSize(width: 200, height: 400))
        view.setImage(nil)
        view.layoutSubtreeIfNeeded()
        XCTAssertNil(view.imageLayer.contents)
        XCTAssertNil(view.imageLayer.shadowPath)
        XCTAssertTrue(view.imageLayer.isHidden)
    }

    private func fixtureImage(width: Int, height: Int) throws -> NSImage {
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
            bitsPerSample: 8, samplesPerPixel: 3, hasAlpha: false, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        let image = NSImage(size: CGSize(width: width, height: height))
        image.addRepresentation(bitmap)
        return image
    }

    private func resultSurface(showsOriginal: Bool, probes: LayoutProbes) -> some View {
        WorkspaceResultLayout(showsOriginal: showsOriginal) {
            LayoutProbe(key: "result", probes: probes)
            LayoutProbe(key: "original", probes: probes)
        }
    }

    private func taskSurface(reveal: CGFloat, probes: LayoutProbes) -> some View {
        WorkspaceTaskLayout(revealedWidth: reveal) {
            // Inject at each pane so this geometry test drives exact sampled
            // positions; the separate toggle test exercises the real clock.
            LayoutProbe(key: "rail", probes: probes).sidebarResizeBoundary()
                .transaction { $0.animation = .easeInOut(duration: 0.2) }
            LayoutProbe(key: "detail", probes: probes).sidebarResizeBoundary()
                .transaction { $0.animation = .easeInOut(duration: 0.2) }
        }
        .clipped()
    }

    private func taskSplit(visible: Bool, reduceMotion: Bool, probes: LayoutProbes) -> some View {
        WorkspaceTaskSplit(showsTasks: visible, reduceMotion: reduceMotion) {
            LayoutProbe(key: "rail", probes: probes)
        } detail: {
            LayoutProbe(key: "detail", probes: probes)
        }
    }

    private func nativeImage(in view: NSView) -> MediaPreviewImage.ImageView? {
        if let image = view as? MediaPreviewImage.ImageView { return image }
        return view.subviews.lazy.compactMap { self.nativeImage(in: $0) }.first
    }

    private func settle(_ host: NSView) async throws {
        host.needsLayout = true
        host.layoutSubtreeIfNeeded()
        // Allow SwiftUI's scheduled layout pass without presenting the window.
        try await Task.sleep(for: .milliseconds(20))
        host.layoutSubtreeIfNeeded()
    }
}

@MainActor
private final class LayoutProbes {
    var views: [String: NSView] = [:]
    var creationCount = 0
    var receivedAnimation = false
}

private struct LayoutProbe: NSViewRepresentable {
    let key: String
    let probes: LayoutProbes

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        probes.views[key] = view
        probes.creationCount += 1
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        // Capture the transaction at the native leaf, below the boundary.
        probes.receivedAnimation = probes.receivedAnimation || context.transaction.animation != nil
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSView, context: Context) -> CGSize? {
        proposal.replacingUnspecifiedDimensions()
    }
}

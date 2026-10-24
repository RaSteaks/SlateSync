import AppKit
import SlateSyncDomain
@testable import SlateSyncUI
import SwiftUI
import XCTest

/// Layout-only regressions never order a window front or sample display FPS.
/// They cover the intermediate widths supplied by both sidebar animations.
@MainActor
final class WorkspaceLayoutRegressionTests: XCTestCase {
    func testSystemSidebarRevealDoesNotReflowItsHeaderAndFooter() async throws {
        // Drive native reveal proposals without bringing any window forward.
        // A shrinking inset used to push the list down by over 200 points.
        let suite = "SlateSync.SidebarLayout.\(UUID().uuidString)"
        let preferences = try XCTUnwrap(UserDefaults(suiteName: suite))
        let originalLanguage = L10n.language
        defer {
            AppLanguage.save(originalLanguage, in: preferences)
            L10n.configure(preferences: preferences)
            preferences.removePersistentDomain(forName: suite)
        }
        for language in AppLanguage.allCases {
            AppLanguage.save(language, in: preferences)
            L10n.configure(preferences: preferences)
            try await verifySystemSidebarReveal(language: language)
        }
    }

    private func verifySystemSidebarReveal(language: AppLanguage) async throws {
        let host = NSHostingView(rootView: SidebarView(selection: .constant(.workspace), currentProjectName: "A long project name 场记项目"))
        host.sizingOptions = []
        let window = NSWindow(contentRect: CGRect(x: -10_000, y: -10_000, width: 230, height: 600),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.contentView = nil; window.close() }
        try await settle(host)
        let table = try XCTUnwrap(nativeTable(in: host))
        let originalFrame = table.convert(table.bounds, to: host)
        for width: CGFloat in [230, 190, 150, 80, 32, 0, 32, 80, 150, 190, 230, 280, 230] {
            window.setContentSize(CGSize(width: width, height: 600))
            try await settle(host)
            let frame = table.convert(table.bounds, to: host)
            XCTAssertEqual(host.bounds.width, width, accuracy: 1, "The viewport must accept native reveal widths")
            XCTAssertEqual(frame.minY, originalFrame.minY, accuracy: 1, "Header reflow at \(width) pt")
            XCTAssertEqual(frame.maxY, originalFrame.maxY, accuracy: 1, "Footer reflow at \(width) pt")
            XCTAssertTrue(nativeTable(in: host) === table, "Navigation selection must keep its native list")
            // Optional fixture snapshots stay in the caller's evidence folder;
            // they never capture the display or the user's project contents.
            if width > 0, let directory = ProcessInfo.processInfo.environment["SLATESYNC_SIDEBAR_EVIDENCE_DIR"],
               let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                host.cacheDisplay(in: host.bounds, to: rep)
                let url = URL(fileURLWithPath: directory, isDirectory: true)
                try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
                try rep.representation(using: .png, properties: [:])?.write(
                    to: url.appendingPathComponent("\(language.rawValue)-\(Int(width)).png"))
            }
        }
        XCTAssertFalse(window.isVisible)
    }

    func testNativeNavigationReopensWithoutPushingTheDetailOrReplacingItsEditor() async throws {
        let state = NavigationRevealState()
        let probes = LayoutProbes()
        let host = NSHostingView(rootView: SystemNavigationSurface(state: state, probes: probes))
        host.sizingOptions = []
        let window = NSWindow(contentRect: CGRect(x: -10_000, y: -10_000, width: 960, height: 600),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.contentView = nil; window.close() }
        try await settle(host)
        let detail = try XCTUnwrap(probes.views["navigationDetail"])
        let expanded = detail.convert(detail.bounds, to: host)
        let table = try XCTUnwrap(nativeTable(in: host))
        let listFrame = table.convert(table.bounds, to: host)
        XCTAssertGreaterThan(expanded.minX, 0)
        for visibility in [NavigationSplitViewVisibility.detailOnly, .all, .detailOnly, .all] {
            state.visibility = visibility
            try await Task.sleep(for: .seconds(SlateMotion.handoffDuration + 0.1))
            try await settle(host)
            let frame = detail.convert(detail.bounds, to: host)
            XCTAssertEqual(host.bounds.width, 960, accuracy: 1)
            XCTAssertEqual(frame.maxX, host.bounds.maxX, accuracy: 1)
            if visibility == .all {
                XCTAssertEqual(frame.minX, expanded.minX, accuracy: 1)
                XCTAssertEqual(table.convert(table.bounds, to: host).minY, listFrame.minY, accuracy: 1)
            } else {
                XCTAssertLessThan(frame.minX, expanded.minX, "Collapse must release the sidebar's width")
            }
            XCTAssertTrue(probes.views["navigationDetail"] === detail)
        }
        XCTAssertEqual(probes.creationCount, 1)
        XCTAssertFalse(window.isVisible)
    }

    // The task rail and its split layout were removed on 2026-10-23: tasks now
    // live in the system sidebar (SidebarView), which the two native reveal
    // tests above exercise.

    func testSystemSidebarAnimatesItsContainerButNotNativeChildren() async throws {
        for reduced in [false, true] {
            let state = NavigationRevealState()
            let probes = LayoutProbes()
            let host = NSHostingView(rootView: SystemNavigationSurface(state: state, probes: probes, reduceMotion: reduced))
            host.sizingOptions = []
            let window = NSWindow(contentRect: CGRect(x: -10_000, y: -10_000, width: 960, height: 600),
                                  styleMask: [.titled, .resizable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = host
            defer { window.contentView = nil; window.close() }
            try await settle(host)
            for visibility in [NavigationSplitViewVisibility.detailOnly, .all] {
                state.visibility = visibility
                try await settle(host)
                XCTAssertEqual(probes.containerAnimations.last, !reduced,
                               "The container needs an explicit visibility animation, except under Reduce Motion")
                XCTAssertFalse(probes.receivedAnimation, "Native child controls must not lag behind the split")
                try await Task.sleep(for: .seconds(reduced ? 0.05 : SlateMotion.handoffDuration + 0.1))
            }
            XCTAssertEqual(probes.containerAnimations.count, 2)
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

    private func nativeImage(in view: NSView) -> MediaPreviewImage.ImageView? {
        if let image = view as? MediaPreviewImage.ImageView { return image }
        return view.subviews.lazy.compactMap { self.nativeImage(in: $0) }.first
    }

    private func nativeTable(in view: NSView) -> NSTableView? {
        if let table = view as? NSTableView { return table }
        return view.subviews.lazy.compactMap { self.nativeTable(in: $0) }.first
    }

    private func settle(_ host: NSView) async throws {
        host.needsLayout = true
        host.layoutSubtreeIfNeeded()
        // Allow SwiftUI's scheduled layout pass without presenting the window.
        try await Task.sleep(for: .milliseconds(20))
        host.layoutSubtreeIfNeeded()
    }
}

@MainActor @Observable
private final class NavigationRevealState {
    var visibility = NavigationSplitViewVisibility.all
}

private struct SystemNavigationSurface: View {
    @Bindable var state: NavigationRevealState
    let probes: LayoutProbes
    var reduceMotion = false

    var body: some View {
        // Exercise the same native column policy as AppRootView using a
        // stable native detail probe, without loading any user project.
        NavigationSplitView(columnVisibility: $state.visibility) {
            SidebarView(selection: .constant(.workspace), currentProjectName: "Layout fixture")
                .navigationSplitViewColumnWidth(min: SidebarView.minimumColumnWidth, ideal: 230, max: 280)
        } detail: {
            LayoutProbe(key: "navigationDetail", probes: probes)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .sidebarResizeBoundary()
        }
        .background(SidebarMotionTransactionProbe(visibility: state.visibility, probes: probes))
        .sidebarVisibilityAnimation(state.visibility, reduceMotion: reduceMotion)
    }
}

@MainActor
private final class LayoutProbes {
    var views: [String: NSView] = [:]
    var creationCount = 0
    var receivedAnimation = false
    var containerAnimations: [Bool] = []
}

/// Observe the transaction at the split container, before child isolation.
/// A changed input forces updates even when native layout decides its own frames.
private struct SidebarMotionTransactionProbe: NSViewRepresentable {
    let visibility: NavigationSplitViewVisibility
    let probes: LayoutProbes

    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> NSView { NSView() }
    func updateNSView(_ view: NSView, context: Context) {
        if let previous = context.coordinator.previous, previous != visibility {
            probes.containerAnimations.append(context.transaction.animation != nil)
        }
        context.coordinator.previous = visibility
    }
    final class Coordinator { var previous: NavigationSplitViewVisibility? }
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

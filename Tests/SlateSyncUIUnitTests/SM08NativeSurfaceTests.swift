import AppKit
import CryptoKit
import Foundation
import Darwin
import QuartzCore
import SlateSyncDomain
@testable import SlateSyncUI
import SwiftUI
import XCTest

/// Actual AppKit-backed surfaces, mounted in a test-owned window. These tests
/// never launch the product or access the operator's Library or Keychain.
@MainActor
final class SM08NativeSurfaceTests: XCTestCase {
    func testNativeCSVReusesViewsForTenThousandRowsAndReleasesOwners() async throws {
        var renderMS: [Double] = [], editMS: [Double] = [], viewCounts: [Int] = []
        var scrollFPS: [Double] = [], memoryDeltas: [Int64] = []
        let table = fixtureTable()
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let bytes = try encoder.encode(table)
        let fixtureSHA = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        // Exclude the deliberately retained 10k-row fixture and its encoded
        // bytes from native-owner retention; only AppKit allocations belong in
        // the post-unmount resident-memory budget.
        let baselineMemory = try residentBytes()
        for sample in 0..<6 {
            var harness: CSVHarness? = CSVHarness(table: table)
            let began = ContinuousClock.now
            try await harness!.mount()
            let loadedMS = began.duration(to: .now).milliseconds
            let native = try XCTUnwrap(harness?.tableView)
            let cadence = await ScrollCadenceProbe().measure(window: harness!.window!, table: native)
            XCTAssertEqual(native.numberOfRows, 10_000)
            native.scrollRowToVisible(9_999)
            native.layoutSubtreeIfNeeded()
            native.displayIfNeeded()
            let visible = native.rows(in: native.visibleRect)
            XCTAssertLessThan(visible.length, 80)
            XCTAssertGreaterThanOrEqual(NSMaxRange(visible), 10_000)
            let field = try XCTUnwrap(native.view(atColumn: 1, row: 9_999, makeIfNecessary: false) as? NSTextField)
            let coordinator = try XCTUnwrap(field.delegate as? EditableCSVTableRepresentable.Coordinator)
            let editBegan = ContinuousClock.now
            coordinator.controlTextDidBeginEditing(Notification(name: NSControl.textDidBeginEditingNotification, object: field))
            field.stringValue = "末行 中文 🎬"
            try coordinator.flushEdit()
            XCTAssertEqual(harness?.commits.last?.rowID, 9_999)
            XCTAssertEqual(harness?.commits.last?.value, "末行 中文 🎬")
            let editedMS = editBegan.duration(to: .now).milliseconds
            let count = native.descendants.filter { $0 is NSTextField }.count
            XCTAssertLessThanOrEqual(count, 300, "CSV must virtualize its 10k rows")
            if sample > 0 {
                renderMS.append(loadedMS); editMS.append(editedMS); viewCounts.append(count)
                scrollFPS.append(cadence); memoryDeltas.append(max(0, try residentBytes() - baselineMemory))
            }
            // Weak references are checked after releasing the hosting tree;
            // retaining the native table local here would invalidate that test.
            harness?.unmount()
            harness = nil
        }
        XCTAssertLessThanOrEqual(renderMS.max() ?? .infinity, 1200)
        XCTAssertLessThanOrEqual(editMS.max() ?? .infinity, 100)
        XCTAssertGreaterThanOrEqual(scrollFPS.min() ?? 0, 45)
        XCTAssertLessThanOrEqual(memoryDeltas.max() ?? .max, 134_217_728)
        // Dedicated scope has no test-local strong native reference.
        var released: WeakCSVReferences?
        do {
            var harness: CSVHarness? = CSVHarness(table: table)
            try await harness!.mount()
            released = WeakCSVReferences(host: harness!.host!, table: harness!.tableView!)
            harness?.unmount(); harness = nil
        }
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while (released?.host != nil || released?.table != nil), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertNil(released?.host)
        XCTAssertNil(released?.table)
        // Measure resident retention after native owners are gone, allowing
        // deferred AppKit/autorelease cleanup only within the frozen 2s budget.
        var retained = max(0, try residentBytes() - baselineMemory)
        while retained > 33_554_432, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
            retained = max(0, try residentBytes() - baselineMemory)
        }
        XCTAssertLessThanOrEqual(retained, 33_554_432)
        try saveMetrics(["schemaVersion": 1, "fixtureRows": 10_000, "fixtureSHA256": fixtureSHA,
                         "warmups": 1, "samples": 5, "snapshotMs": renderMS, "farRowEditMs": editMS,
                         "visibleCellCounts": viewCounts, "scrollFramesPerSecond": scrollFPS,
                         "residentDeltaBytes": memoryDeltas, "retainedResidentBytes": retained], named: "native-csv-scale.json")
    }

    func testNativeCSVMarkedTextDoesNotCommitAndFlushRetainsComposition() async throws {
        let harness = CSVHarness(table: fixtureTable())
        defer { harness.unmount() }
        try await harness.mount()
        let table = try XCTUnwrap(harness.tableView)
        let field = try XCTUnwrap(table.view(atColumn: 1, row: 0, makeIfNecessary: true) as? NSTextField)
        field.selectText(nil)
        let editor = try XCTUnwrap(field.currentEditor() as? NSTextView)
        let coordinator = try XCTUnwrap(field.delegate as? EditableCSVTableRepresentable.Coordinator)
        coordinator.controlTextDidBeginEditing(Notification(name: NSControl.textDidBeginEditingNotification, object: field))
        // Chinese pinyin remains a local composition until the candidate is committed.
        editor.setMarkedText("zhongwen", selectedRange: NSRange(location: 8, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        coordinator.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: field))
        try await Task.sleep(for: .milliseconds(320))
        XCTAssertTrue(editor.hasMarkedText())
        XCTAssertTrue(harness.commits.isEmpty)
        XCTAssertThrowsError(try coordinator.flushEdit()) { error in
            XCTAssertEqual((error as? SlateSyncError)?.code, "EDIT_COMPOSITION")
        }
        XCTAssertTrue(coordinator.control(field, textView: editor, doCommandBy: #selector(NSResponder.cancelOperation(_:))))
        XCTAssertTrue(editor.hasMarkedText())
        editor.unmarkText()
        editor.string = "中文"
        coordinator.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: field))
        try await Task.sleep(for: .milliseconds(320))
        XCTAssertEqual(harness.commits.last?.value, "中文")
        // Flush and blur may occur before a parent render acknowledges the
        // timer's commit; they must not enqueue the same draft again.
        try coordinator.flushEdit()
        coordinator.controlTextDidEndEditing(Notification(name: NSControl.textDidEndEditingNotification, object: field))
        XCTAssertEqual(harness.commits.count, 1)
    }

    func testWindowCloseVetoRetainsWindowUntilRetrySucceeds() async throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 960, height: 600), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        var attempts = 0, failures = 0
        let coordinator = WindowCloseCoordinator(close: {
            attempts += 1
            if attempts == 1 { throw SlateSyncError(code: "TEST_SAVE", message: "save failed") }
        }, failure: { _ in failures += 1 })
        coordinator.attach(to: window)
        window.orderFront(nil)
        window.performClose(nil)
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(attempts, 1)
        XCTAssertEqual(failures, 1)
        XCTAssertTrue(window.isVisible)
        window.performClose(nil)
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(attempts, 2)
        XCTAssertFalse(window.isVisible)
        coordinator.detach()
    }

    func testNativeCSVReplacesRowsWhenIdentityChangesAtSameRevision() async throws {
        let initial = ResolveCSVTable(headers: ["场", "镜"], rows: [["旧场", "旧镜"]], format: .init())
        let harness = CSVHarness(table: initial)
        defer { harness.unmount() }
        try await harness.mount()
        let native = try XCTUnwrap(harness.tableView)
        XCTAssertEqual(native.numberOfRows, 1)
        // Recognition results each begin at revision zero but have separate
        // table identities. Reuse the same native view to exercise replacement.
        harness.replace(ResolveCSVTable(headers: initial.headers,
            rows: [["新场", "新镜"], ["第二场", "第二镜"]], format: .init()))
        try await Task.sleep(for: .milliseconds(40))
        harness.host?.layoutSubtreeIfNeeded()
        XCTAssertTrue(harness.tableView === native)
        XCTAssertEqual(native.numberOfRows, 2)
        let cell = try XCTUnwrap(native.view(atColumn: 0, row: 0, makeIfNecessary: true) as? NSTextField)
        XCTAssertEqual(cell.stringValue, "新场")
    }

    private func fixtureTable() -> ResolveCSVTable {
        ResolveCSVTable(headers: ["文件名", "注释", "场", "镜", "次", "帧率"],
            rows: (0..<10_000).map { [String(format: "A%05d.mov", $0), "", "1", "2", "3", "24"] }, format: .init())
    }

    private func saveMetrics(_ value: [String: Any], named name: String) throws {
        guard let path = ProcessInfo.processInfo.environment["SLATESYNC_SM08_METRICS_DIR"] else { return }
        let directory = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .prettyPrinted]).write(to: directory.appending(path: name))
    }
}

@MainActor
private final class CSVHarness {
    private let input: ResolveCSVTable
    var commits: [CSVCellCommit] = []
    var host: NSHostingView<EditableCSVTableRepresentable>?
    var window: NSWindow?
    var tableView: NSTableView? { host?.descendants.compactMap { $0 as? NSTableView }.first }
    init(table: ResolveCSVTable) { input = table }
    func replace(_ table: ResolveCSVTable) {
        host?.rootView = EditableCSVTableRepresentable(tableID: UUID(), table: table, revision: 0) { [weak self] in self?.commits.append($0) }
    }
    func mount() async throws {
        _ = NSApplication.shared
        let content = EditableCSVTableRepresentable(tableID: UUID(), table: input, revision: 0) { [weak self] in self?.commits.append($0) }
        let host = NSHostingView(rootView: content)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 600), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        self.host = host; self.window = window
        window.makeKeyAndOrderFront(nil)
        host.layoutSubtreeIfNeeded()
        // Give SwiftUI one mount pass; this wait is included in snapshot timing.
        try await Task.sleep(for: .milliseconds(40))
        host.layoutSubtreeIfNeeded()
    }
    func unmount() {
        window?.makeFirstResponder(nil)
        window?.contentView = nil
        window?.orderOut(nil)
        window?.close()
        host = nil; window = nil
    }
}

@MainActor private final class WeakCSVReferences {
    weak var host: NSView?
    weak var table: NSTableView?
    init(host: NSView, table: NSTableView) { self.host = host; self.table = table }
}

private extension NSView {
    var descendants: [NSView] { subviews.flatMap { [$0] + $0.descendants } }
}

private extension Duration {
    var milliseconds: Double { Double(components.seconds) * 1000 + Double(components.attoseconds) / 1e15 }
}

/// Measures delivered display-link cadence while each frame scrolls and draws
/// the actual table. A timeout returns zero rather than manufacturing a pass.
@MainActor private final class ScrollCadenceProbe: NSObject {
    private var link: CADisplayLink?
    private weak var table: NSTableView?
    private var timestamps: [Double] = []
    private var completion: CheckedContinuation<Double, Never>?
    private var timeout: Task<Void, Never>?
    func measure(window: NSWindow, table: NSTableView) async -> Double {
        self.table = table
        return await withCheckedContinuation { continuation in
            completion = continuation
            let link = window.displayLink(target: self, selector: #selector(frame(_:)))
            link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 60, preferred: 60)
            self.link = link
            link.add(to: .main, forMode: .common)
            timeout = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(3)) } catch { return }
                self?.finish(0)
            }
        }
    }
    @objc private func frame(_ sender: CADisplayLink) {
        guard let table else { finish(0); return }
        timestamps.append(CACurrentMediaTime())
        table.scrollRowToVisible((timestamps.count * 149) % table.numberOfRows)
        table.layoutSubtreeIfNeeded()
        table.displayIfNeeded()
        if timestamps.count >= 61 {
            finish(Double(timestamps.count - 1) / (timestamps.last! - timestamps.first!))
        }
    }
    private func finish(_ value: Double) {
        link?.invalidate(); link = nil
        timeout?.cancel(); timeout = nil
        let callback = completion; completion = nil
        callback?.resume(returning: value)
    }
}

private func residentBytes() throws -> Int64 {
    var info = mach_task_basic_info()
    var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<integer_t>.size)
    let result = withUnsafeMutablePointer(to: &info) { pointer in
        pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
        }
    }
    // Missing measurement is a test failure, never a zero delta obtained by
    // subtracting two sentinel values.
    guard result == KERN_SUCCESS else { throw NSError(domain: "SM08ResidentMeasurement", code: Int(result)) }
    return Int64(info.resident_size)
}

/// Shared native list harness also used with project/task projections. It
/// retains one non-presented hosting tree and provides an explicit release
/// boundary, allowing scale measurements to remain a background-only test.
@MainActor final class SM08ListHarness<Content: View> {
    private(set) var host: NSHostingView<Content>?
    private var window: NSWindow?
    var table: NSTableView? { host?.descendants.compactMap { $0 as? NSTableView }.first }
    init(_ content: Content) {
        _ = NSApplication.shared
        let host = NSHostingView(rootView: content)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 600), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        self.host = host; self.window = window
        window.contentView = host
        host.frame = window.contentLayoutRect
        // `settle()` performs the single delayed layout needed by the hidden
        // measurement surface; this window is never ordered onto the desktop.
    }
    func settle() async throws {
        try await Task.sleep(for: .milliseconds(40))
        host?.layoutSubtreeIfNeeded()
    }
    func close() {
        window?.contentView = nil; window?.orderOut(nil); window?.close()
        host = nil; window = nil
    }
}

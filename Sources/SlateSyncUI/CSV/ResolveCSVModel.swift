import Foundation
import Observation
import SlateSyncDomain

public struct CSVCellCommit: Hashable, Sendable {
    public let tableID: UUID
    public let rowID: Int
    public let columnID: Int
    public let revision: Int
    public let value: String
}

/// Main-actor CSV projection. Parsing and encoding stay in Workflow; cell
/// callbacks carry stable integer identities and are ignored after revision or
/// table generation changes.
@MainActor @Observable
public final class ResolveCSVModel {
    public private(set) var tableID = UUID()
    public private(set) var table: ResolveCSVTable?
    public private(set) var revision = 0
    public private(set) var filename: String?
    public private(set) var operation: OperationState = .idle
    private var work: Task<Void, Never>?
    private var workGeneration = 0
    private var editGeneration = 0
    public var permitsNewOperation: (@MainActor () -> Bool)?
    private let service: any WorkspaceWorkflowServing
    public var onTableChange: (@MainActor (ResolveCSVTable, String?) -> Void)?
    public var flushEditor: (@MainActor () throws -> Void)?

    public init(service: any WorkspaceWorkflowServing) {
        self.service = service
    }

    public func importData(_ data: Data, filename: String) async {
        await performWork { [self] in
            try flushEditor?()
            let edits = editGeneration
            let decoded = try await service.decodeResolveCSV(data)
            try Task.checkCancellation()
            try requireUnchangedEdits(edits)
            tableID = UUID()
            table = decoded
            self.filename = filename
            revision += 1
            onTableChange?(decoded, filename)
            operation = .succeeded(message: "已载入 \(decoded.rows.count) 行")
        }
    }

    public func receive(_ commit: CSVCellCommit) {
        guard commit.tableID == tableID, commit.revision == revision,
              var current = table,
              current.rows.indices.contains(commit.rowID),
              current.headers.indices.contains(commit.columnID) else { return }
        while current.rows[commit.rowID].count < current.headers.count {
            current.rows[commit.rowID].append("")
        }
        // A blur/flush may repeat a debounce callback before SwiftUI refreshes
        // the native parent's snapshot. Equal values are not new edits.
        guard current.rows[commit.rowID][commit.columnID] != commit.value else { return }
        current.rows[commit.rowID][commit.columnID] = commit.value
        editGeneration += 1
        table = current
        // The coordinator commits its IME-safe draft after 250 ms. Persist
        // this canonical table through Workspace's single autosave writer.
        onTableChange?(current, filename)
    }

    public func encodedData() async throws -> Data {
        try flushEditor?()
        guard let table else {
            throw SlateSyncError(code: "CSV_EMPTY", message: "请先导入 Resolve CSV")
        }
        return try await service.encodeResolveCSV(table)
    }

    /// Metadata matching uses the table currently owned by this model. The
    /// editor is flushed first so a just-typed material key cannot be omitted
    /// from the scanner's expected set.
    public func materialKeys() async throws -> [String] {
        try flushEditor?()
        guard let table else {
            throw SlateSyncError(code: "CSV_EMPTY", message: "请先导入 Resolve CSV")
        }
        return try await service.resolveMaterialKeys(in: table)
    }

    public func merge(records: [ResolveSlateRecord], metadata: [PersistedSlateMetadata], settings: ProjectSettings.ResolveSettings) async {
        guard let exporter = service as? any ResolveExportWorkflowServing else { return }
        await performWork { [self] in
            try flushEditor?()
            let edits = editGeneration
            guard let table else { throw SlateSyncError(code: "CSV_EMPTY", message: "请先导入 Resolve CSV") }
            // Capture once after flushing. Calling encodedData here would
            // flush again against an AppKit snapshot awaiting a render pass.
            let source = try await service.encodeResolveCSV(table)
            let result = try await exporter.mergeResolve(source: source, records: records, metadata: metadata, settings: settings)
            try Task.checkCancellation()
            try requireUnchangedEdits(edits)
            self.table = result.merge.table
            revision += 1
            onTableChange?(result.merge.table, filename)
            operation = .succeeded(message: "已更新 \(result.merge.updatedRowCount) 行")
        }
    }

    /// Decode/merge owns a cancel-and-join chain. Selection and close cannot
    /// release the workspace while a late parser still holds its callback.
    private func performWork(_ action: @escaping @MainActor () async throws -> Void) async {
        guard permitsNewOperation?() != false else { return }
        let previous = work
        previous?.cancel()
        workGeneration += 1
        let generation = workGeneration
        operation = .running(label: "正在处理 CSV…")
        let task = Task { @MainActor [weak self] in
            await previous?.value
            guard let self, !Task.isCancelled else { return }
            do { try await action() }
            catch is CancellationError { if generation == workGeneration { operation = .canceled } }
            catch { if generation == workGeneration { report(error) } }
        }
        work = task
        await task.value
        if generation == workGeneration { work = nil }
    }

    private func requireUnchangedEdits(_ expected: Int) throws {
        // A native field editor can finish while an actor call is suspended.
        // Never replace its newer edits with a merge based on an older table.
        guard expected == editGeneration else {
            throw SlateSyncError(code: "CSV_CHANGED", message: "表格已有新编辑，已保留。请重试导入或合并。", retryable: true)
        }
    }

    public func standaloneData(records: [ResolveSlateRecord], settings: ProjectSettings.ResolveSettings) async throws -> Data {
        guard let exporter = service as? any ResolveExportWorkflowServing else {
            throw SlateSyncError(code: "CSV_EXPORT_UNAVAILABLE", message: "导出服务当前不可用")
        }
        return try await exporter.exportStandalone(records: records, settings: settings)
    }

    public func reset() {
        work?.cancel()
        workGeneration += 1
        tableID = UUID()
        table = nil
        filename = nil
        revision += 1
        operation = .idle
    }

    public func load(task: TaskData?) {
        reset()
        table = task?.resolveCsvTable
        filename = task?.resolveCsvFilename
    }

    public func report(_ error: Error) { operation = .failed(ProductPrivacy.error(error)) }

    public func exported() { operation = .succeeded(message: "CSV 已导出") }

    /// Local edit timers belong to the visible coordinator; the shared
    /// workspace barrier flushes it before this owner is released.
    public func drain() async {
        workGeneration += 1
        work?.cancel()
        await work?.value
        work = nil
        if operation.isRunning { operation = .canceled }
    }
}

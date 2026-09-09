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

/// Everything the workspace autosave needs to persist one CSV stage: the
/// visible table, its source name, the manual sparse edits keyed "row:column"
/// (the retained TaskData format), and the retained raw bytes as base64. The
/// raw bytes plus the edits are what a canonical export re-merges from.
public struct CSVStageSnapshot: Sendable {
    public let table: ResolveCSVTable
    public let filename: String?
    public let edits: [String: String]
    public let rawBase64: String?

    public init(table: ResolveCSVTable, filename: String?, edits: [String: String], rawBase64: String?) {
        self.table = table
        self.filename = filename
        self.edits = edits
        self.rawBase64 = rawBase64
    }
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
    // Retained raw import bytes (the old worker's metadataTable) plus the
    // manual edits keyed "row:column"; a canonical export re-merges from
    // these instead of re-encoding the merged display table.
    private var rawData: Data?
    private var rawBase64: String?
    private var sparseEdits: [String: String] = [:]
    private var work: Task<Void, Never>?
    private var workGeneration = 0
    private var editGeneration = 0
    public var permitsNewOperation: (@MainActor () -> Bool)?
    private let service: any WorkspaceWorkflowServing
    public var onTableChange: (@MainActor (CSVStageSnapshot) -> Void)?
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
            // A fresh import replaces the retained raw source and clears the
            // edits from any previous table geometry.
            rawData = data
            rawBase64 = data.base64EncodedString()
            sparseEdits = [:]
            revision += 1
            onTableChange?(CSVStageSnapshot(table: decoded, filename: filename, edits: sparseEdits, rawBase64: rawBase64))
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
        // Edits are tracked by stable cell coordinates; merges keep the row
        // geometry, so a manual edit survives a merge and is reapplied on the
        // freshly merged table exactly like the retained worker's csvEdits.
        sparseEdits["\(commit.rowID):\(commit.columnID)"] = commit.value
        table = current
        // The coordinator commits its IME-safe draft after 250 ms. Persist
        // this canonical table plus raw bytes/edits through Workspace's single
        // autosave writer.
        onTableChange?(CSVStageSnapshot(table: current, filename: filename, edits: sparseEdits, rawBase64: rawBase64))
    }

    public func encodedData() async throws -> Data {
        try flushEditor?()
        guard let table else {
            throw SlateSyncError(code: "CSV_EMPTY", message: "请先导入 Resolve CSV")
        }
        return try await service.encodeResolveCSV(table)
    }

    /// Canonical merged export, frozen from the retained Worker's
    /// `export-resolve`: the merge starts from the retained raw table so the
    /// latest recognition records win over the staged preview, manual sparse
    /// edits are applied last byte-for-byte, and the whole table is encoded
    /// with canonicalized field widths and Comments. An empty recognition
    /// list is never exportable (`CSV_NO_EXPORT`).
    public func exportData(records: [ResolveSlateRecord], metadata: [PersistedSlateMetadata], settings: ProjectSettings.ResolveSettings) async throws -> Data {
        try flushEditor?()
        guard let current = table else {
            throw SlateSyncError(code: "CSV_EMPTY", message: "请先导入 Resolve CSV")
        }
        guard let exporter = service as? any ResolveExportWorkflowServing else {
            throw SlateSyncError(code: "CSV_EXPORT_UNAVAILABLE", message: "导出服务当前不可用")
        }
        // Tasks persisted before raw bytes existed fall back to their staged
        // table; the merge is still recomputed from the latest records.
        let source: Data
        if let rawData { source = rawData } else { source = try await service.encodeResolveCSV(current) }
        return try await exporter.mergeResolve(source: source, records: records, metadata: metadata, settings: settings, edits: orderedSparseEdits).data
    }

    /// Suggested export filename, frozen from the old renderer naming
    /// (`baseName` + the `<…>_场记已回填.csv` / `<…>_场记识别.csv` suffixes).
    public static func suggestedFilename(_ filename: String?, fallback: String, suffix: String) -> String {
        let base = filename.map(baseName) ?? ""
        let stem = base.isEmpty ? fallback : base
        return "\(stem)_\(suffix).csv"
    }

    /// Frozen old renderer `baseName`: strip the last extension, then replace
    /// every run of characters outside ASCII word chars, hyphen, and the
    /// U+4E00–U+9FFF range with a single underscore (old JS `\w` was ASCII
    /// only and its `+` quantifier collapsed runs).
    private static func baseName(_ filename: String) -> String {
        let stripped = filename.replacingOccurrences(of: "\\.[^.]+$", with: "", options: .regularExpression)
        var result = String.UnicodeScalarView()
        var inRun = false
        for scalar in stripped.unicodeScalars {
            let value = scalar.value
            let asciiWord = (0x41...0x5A).contains(value) || (0x61...0x7A).contains(value) || (0x30...0x39).contains(value) || value == 0x5F
            if asciiWord || value == 0x2D || (0x4E00...0x9FFF).contains(value) {
                result.append(scalar); inRun = false
            } else if !inRun {
                result.append("_"); inRun = true
            }
        }
        return String(result)
    }

    /// Persisted edits ("row:column" → value) as ordered sparse edits, sorted
    /// by position so application is deterministic.
    private var orderedSparseEdits: [ResolveSparseEdit] {
        sparseEdits.compactMap { key, value in
            let parts = key.split(separator: ":")
            guard parts.count == 2, let row = Int(parts[0]), let column = Int(parts[1]) else { return nil }
            return ResolveSparseEdit(rowIndex: row, columnIndex: column, value: value)
        }.sorted { ($0.rowIndex, $0.columnIndex) < ($1.rowIndex, $1.columnIndex) }
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
            guard let current = table else { throw SlateSyncError(code: "CSV_EMPTY", message: "请先导入 Resolve CSV") }
            // The merge recomputes from the retained raw table (old worker
            // semantics); manual edits ride along and are applied last. Tasks
            // persisted before raw bytes existed fall back to their staged
            // table. Calling encodedData here would flush again against an
            // AppKit snapshot awaiting a render pass.
            let source: Data
            if let rawData { source = rawData } else { source = try await service.encodeResolveCSV(current) }
            let result = try await exporter.mergeResolve(source: source, records: records, metadata: metadata, settings: settings, edits: orderedSparseEdits)
            try Task.checkCancellation()
            try requireUnchangedEdits(edits)
            self.table = result.merge.table
            revision += 1
            onTableChange?(CSVStageSnapshot(table: result.merge.table, filename: filename, edits: sparseEdits, rawBase64: rawBase64))
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
        rawData = nil
        rawBase64 = nil
        sparseEdits = [:]
        revision += 1
        operation = .idle
    }

    public func load(task: TaskData?) {
        reset()
        table = task?.resolveCsvTable
        filename = task?.resolveCsvFilename
        // Restore the retained raw bytes and the manual edits so a reloaded
        // task still exports by re-merging from its raw source (old behavior).
        if let base64 = task?.resolveCsvBase64 {
            rawBase64 = base64
            rawData = Data(base64Encoded: base64)
        }
        if let edits = task?.resolveCsvEdits { sparseEdits = edits }
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

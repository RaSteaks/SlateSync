import Foundation
import SlateSyncDomain

/// Background composition boundary for SM-05. It owns stateless actors only;
/// project-scoped Scenario persistence stays behind the caller's ProjectRuntime.
public actor SM05WorkflowServices {
    private let csv: ResolveCSVEngine
    private let merger: ResolveCSVMerger
    private let scanner: SlateMetadataScanner
    private let scenarios: ScenarioProfileEngine
    private let logger = SlateSyncLogger(category: "workflow.sm05")

    public init(
        csv: ResolveCSVEngine = ResolveCSVEngine(),
        merger: ResolveCSVMerger = ResolveCSVMerger(),
        scanner: SlateMetadataScanner = SlateMetadataScanner(),
        scenarios: ScenarioProfileEngine = ScenarioProfileEngine()
    ) {
        self.csv = csv
        self.merger = merger
        self.scanner = scanner
        self.scenarios = scenarios
    }

    public func mergeAndEncode(
        source: Data,
        records: [ResolveSlateRecord],
        metadata: [PersistedSlateMetadata] = [],
        fieldFormats: ResolveFieldFormats = .init(),
        comments: ResolveComments = .init(),
        edits: [ResolveSparseEdit] = []
    ) async throws -> ResolveExportArtifact {
        try fieldFormats.validate()
        try comments.validate()
        let clock = ContinuousClock()
        let start = clock.now
        let table = try await csv.decode(source)
        let result = try await merger.merge(source: table, records: records, metadata: metadata, fieldFormats: fieldFormats, comments: comments, edits: edits)
        // Match export-resolve: manual edits may make an otherwise unchanged
        // merge exportable, but an empty recognition list is never exportable.
        // ResolveSparseEdit is the typed equivalent of a normalized JS edit.
        guard !records.isEmpty, result.updatedRowCount > 0 || !edits.isEmpty else {
            throw SlateSyncError(code: "CSV_NO_EXPORT", message: "没有匹配到可写入的完整记录，请检查卷号、视频码、场次、镜和次。")
        }
        try Task.checkCancellation()
        let data = try await csv.encode(result.table, fieldFormats: fieldFormats, comments: comments, canonicalizeComments: true)
        let milliseconds = Self.milliseconds(start.duration(to: clock.now))
        // Diagnostics intentionally contain counts/duration only—never cells,
        // OCR text, prompt hints, file names, or absolute media paths.
        logger.info("Resolve CSV export completed", metadata: [
            "rowCount": .number(Double(result.table.rows.count)),
            "changedCellCount": .number(Double(result.changedCellCount)),
            "durationMs": .number(Double(milliseconds)),
        ])
        return ResolveExportArtifact(merge: result, data: data, durationMilliseconds: milliseconds)
    }

    /// Builds the provider-free Resolve file and rejects a header-only export,
    /// matching the retained Worker's export-standalone boundary.
    public func exportStandalone(
        records: [ResolveSlateRecord],
        fieldFormats: ResolveFieldFormats = .init()
    ) async throws -> Data {
        try fieldFormats.validate()
        let table = try await merger.standaloneTable(records: records, fieldFormats: fieldFormats)
        guard !table.rows.isEmpty else {
            throw SlateSyncError(code: "CSV_NO_EXPORT", message: "没有场次、镜、次完整的识别记录可导出。")
        }
        try Task.checkCancellation()
        return try await csv.encode(table, fieldFormats: fieldFormats, comments: .init(), canonicalizeComments: false)
    }

    public func scanMetadata(directory: URL, options: SlateMetadataScanOptions) async throws -> ScanResult {
        let result = try await scanner.scan(directory: directory, options: options)
        logger.info("Slate metadata scan completed", metadata: [
            "expectedKeyCount": .number(Double(options.expectedKeys.count)),
            "metadataCount": .number(Double(result.metadata.count)),
            "warningCount": .number(Double(result.warnings.count)),
        ])
        return result
    }

    public func makeProfile(from input: ScenarioObservationInput, resolve: ProjectSettings.ResolveSettings = .init()) async throws -> ScenarioProfile {
        let profile = try await scenarios.profile(from: input, resolve: resolve)
        logger.info("Scenario profile prepared", metadata: [
            "pageCount": .number(Double(profile.layout.pages.count)),
            "blockCount": .number(Double(profile.layout.blockCount)),
        ])
        return profile
    }

    private nonisolated static func milliseconds(_ duration: Duration) -> Int {
        let components = duration.components
        return Int(Double(components.seconds) * 1_000 + Double(components.attoseconds) / 1e15)
    }
}

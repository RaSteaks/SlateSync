import Foundation
import MCP
import SlateSyncDomain
import SlateSyncMedia
import SlateSyncPersistence
import SlateSyncWorkflow

/// Stateless tools share the app's workflow actors. No tools mutate the
/// desktop library, global settings, provider credentials, or source media.
public actor MCPToolService {
    public typealias ProgressSink = @Sendable (RecognitionProgress) async -> Void
    private let files: MCPFileAccess
    private let runtime: SlateSyncRuntime
    private let allowsModelRequests: Bool
    private let resources: OCRRuntimePaths.Resources?
    private let workflow = SM05WorkflowServices()
    private let transportFactory: @Sendable () -> any ProviderHTTPTransporting
    private var operations: [UUID: Task<CallTool.Result, Error>] = [:]
    private var closed = false
    private let recognitionLimiter = RecognitionLimiter()

    public init(files: MCPFileAccess, runtime: SlateSyncRuntime, allowsModelRequests: Bool = false,
                resources: OCRRuntimePaths.Resources? = nil,
                transportFactory: (@Sendable () -> any ProviderHTTPTransporting)? = nil) {
        self.files = files
        self.runtime = runtime
        self.allowsModelRequests = allowsModelRequests
        self.resources = resources
        self.transportFactory = transportFactory ?? { URLSessionProviderTransport(credentials: runtime.credentialStore) }
    }

    public func call(_ params: CallTool.Parameters, progress: ProgressSink? = nil) async throws -> CallTool.Result {
        guard !closed else { throw MCPError.internalError("Server is closing.") }
        guard let tool = MCPToolCatalog.tools.first(where: { $0.name == params.name }) else {
            throw MCPError.invalidParams("Unknown tool.")
        }
        let input = Value.object(params.arguments ?? [:])
        try MCPArguments.validate(input, schema: tool.inputSchema)
        guard try JSONEncoder().encode(input).count <= 16 * 1024 * 1024 else {
            throw MCPError.invalidParams("Tool arguments exceed 16 MiB.")
        }
        guard operations.count < 8 else {
            return Self.error("MCP_BUSY", "Too many operations. Wait for a result or cancel an existing request.")
        }
        let id = UUID()
        let task = Task { try await self.perform(name: params.name, arguments: params.arguments ?? [:], progress: progress) }
        operations[id] = task
        defer { operations.removeValue(forKey: id) }
        let result = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
        try Task.checkCancellation()
        guard !task.isCancelled else { throw CancellationError() }
        return result
    }

    public func close() async {
        closed = true
        let active = Array(operations.values)
        active.forEach { $0.cancel() }
        for task in active { _ = try? await task.value }
    }

    private func perform(name: String, arguments: [String: Value], progress: ProgressSink?) async throws -> CallTool.Result {
        do {
            try Task.checkCancellation()
            switch name {
            case "slatesync_list_models":
                let registry = try await registry()
                return try Self.result(ModelsResult(providers: await registry.providerSummaries(),
                                                    models: await registry.publicModels()))
            case "slatesync_import_slate_csv":
                let data = try files.read(try text("path", arguments), maximumBytes: CSVInputBudget.maximumInputBytes)
                let rows = try await SlateCSVWorkflow().decode(data)
                let records = await SlateCSVWorkflow().records(rows).map {
                    ResolveSlateRecord(cardNumber: $0.cardNumber, videoCode: $0.videoCode,
                        scene: $0.scene, shot: $0.shot, take: $0.take, takeStatus: $0.takeStatus)
                }
                return try Self.result(RecordsResult(records: records))
            case "slatesync_scan_metadata":
                let source = try files.read(try text("csvPath", arguments), maximumBytes: CSVInputBudget.maximumInputBytes)
                let directory = try files.directory(try text("directoryPath", arguments))
                let edits = try optional([ResolveSparseEdit].self, "edits", arguments) ?? []
                let preview = try await workflow.previewMerge(source: source, records: [], edits: edits)
                let keys = Array(Set(preview.rowKeys.filter { !$0.isEmpty })).sorted()
                let config = try await runtime.workflowConfigProvider().current()
                let scan = try await workflow.scanMetadata(directory: directory,
                    options: .init(expectedKeys: keys, maxDepth: config.slate.maxDirectoryDepth))
                return try Self.result(scan)
            case "slatesync_preview_merge", "slatesync_export_csv":
                return try await merge(arguments, export: name == "slatesync_export_csv")
            case "slatesync_recognize":
                return try await recognize(arguments, progress: progress)
            default: throw MCPError.invalidParams("Unknown tool.")
            }
        } catch is CancellationError { throw CancellationError() }
        catch let error as MCPError { throw error }
        catch let error as SlateSyncError {
            if Task.isCancelled || error.code == RecognitionFailure.canceled.code { throw CancellationError() }
            return Self.error(error.code, StructuredLogRedactor.redactText(error.message))
        } catch {
            try Task.checkCancellation()
            return Self.error("MCP_OPERATION_FAILED", "The operation failed. Check input files and local configuration, then retry.")
        }
    }

    private func merge(_ arguments: [String: Value], export: Bool) async throws -> CallTool.Result {
        let source = try files.read(try text("csvPath", arguments), maximumBytes: CSVInputBudget.maximumInputBytes)
        let records = try MCPArguments.decode([MCPRecord].self, from: arguments["records"]!).map(\.record)
        let metadata = try optional([PersistedSlateMetadata].self, "metadata", arguments) ?? []
        let edits = try optional([ResolveSparseEdit].self, "edits", arguments) ?? []
        let defaults = try await runtime.workflowConfigProvider().current().resolve
        let settings = try optional(ProjectSettings.ResolveSettings.self, "resolve", arguments) ?? defaults
        let preview = try await workflow.previewMerge(source: source, records: records, metadata: metadata,
            fieldFormats: settings.fieldFormats, comments: settings.comments, edits: edits)
        let offset = arguments["offset"]?.intValue ?? 0, limit = arguments["limit"]?.intValue ?? 50
        let canExport = preview.permitsExport(recordCount: records.count, edits: edits)
        var output: String?
        if export {
            guard canExport else { return Self.error("CSV_NO_EXPORT", "No complete matched record. Review material identity and Scene/Shot/Take in preview.") }
            guard preview.reviewIssueCount == 0 || arguments["allowWarnings"]?.boolValue == true else {
                return Self.error("MCP_REVIEW_REQUIRED", "Preview contains \(preview.reviewIssueCount) review issues. Inspect them before retrying with allowWarnings=true.")
            }
            // Encode the exact preview already checked, not a second mutable
            // read of source files or settings. The native encoder preserves format.
            let bytes = try await ResolveCSVEngine().encode(preview.table)
            try Task.checkCancellation()
            output = try files.writeNew(bytes, path: text("outputPath", arguments)).path
        }
        return try Self.result(MCPMergeResult(preview, canExport: canExport, outputPath: output, offset: offset, limit: limit))
    }

    private func recognize(_ arguments: [String: Value], progress: ProgressSink?) async throws -> CallTool.Result {
        guard allowsModelRequests else {
            return Self.error("MCP_MODEL_REQUESTS_DISABLED", "Restart with --allow-model-requests to permit image/OCR transmission and provider API charges.")
        }
        let path = try text("path", arguments)
        let bytes = try files.read(path, maximumBytes: 20 * 1024 * 1024)
        let snapshot = await runtime.bootstrap()
        await recognitionLimiter.setLimit(RecognitionRuntimeOptions.globalConcurrency(snapshot.configuration.values[.maxConcurrentRecognitions]))
        let registry = try await registry()
        let factory = try await RecognitionMediaFactory.make(runtime: runtime,
            values: snapshot.configuration.values, resources: resources)
        let config = await runtime.workflowConfigProvider()
        let defaults = try await config.current()
        let settings = ProjectSettings(accuracyMode: try optional(ProjectSettings.AccuracyMode.self, "accuracyMode", arguments) ?? .high,
            customPrompt: arguments["customPrompt"]?.stringValue ?? "",
            resolve: try optional(ProjectSettings.ResolveSettings.self, "resolve", arguments) ?? defaults.resolve)
        let slateRows: [SlateCsvRecord]
        if let slatePath = arguments["slateCSVPath"]?.stringValue {
            slateRows = try await SlateCSVWorkflow().decode(files.read(slatePath, maximumBytes: CSVInputBudget.maximumInputBytes))
        } else { slateRows = [] }
        // The shared coordinator owns all recognition rules; absence of
        // persistence keeps desktop tasks and autosave entirely untouched.
        let coordinator = RecognitionCoordinator(registry: registry,
            client: ProviderRecognitionClient(transport: transportFactory()), mediaFactory: factory.make,
            clearMediaSession: factory.clearSession, closeMediaResources: factory.close,
            settings: snapshot.configuration.values, limiter: recognitionLimiter, workflowConfiguration: { try await config.current() })
        let events = await coordinator.progress(for: "mcp")
        let progressTask = Task {
            for await event in events {
                guard !Task.isCancelled else { break }
                await progress?(event)
            }
        }
        do {
            let result = try await coordinator.recognize(.init(projectID: "mcp", input: .bytes(bytes, filename: URL(fileURLWithPath: path).lastPathComponent),
                filename: URL(fileURLWithPath: path).lastPathComponent, providerID: arguments["providerID"]?.stringValue,
                modelID: arguments["modelID"]?.stringValue, settings: settings, slateCSVRecords: slateRows))
            await coordinator.close()
            progressTask.cancel()
            await progressTask.value
            try Task.checkCancellation()
            return try Self.result(RecognitionResult(result))
        } catch {
            progressTask.cancel()
            await coordinator.close()
            await progressTask.value
            throw error
        }
    }

    private func registry() async throws -> ProviderRegistry {
        let snapshot = await runtime.bootstrap()
        let config = try await runtime.globalConfigStore.load()
        return ProviderRegistry(settings: snapshot.configuration.values, customProviders: config.customProviders,
            credentials: runtime.credentialStore, builtinCapabilities: config.builtinCapabilities)
    }

    private func text(_ key: String, _ values: [String: Value]) throws -> String {
        guard let value = values[key]?.stringValue, !value.isEmpty else { throw MCPArguments.invalid("arguments." + key) }
        return value
    }
    private func optional<T: Decodable>(_ type: T.Type, _ key: String, _ values: [String: Value]) throws -> T? {
        try values[key].map { try MCPArguments.decode(type, from: $0) }
    }
    private static func result<T: Encodable>(_ output: T) throws -> CallTool.Result {
        let data = try JSONEncoder().encode(output)
        return try .init(content: [.text(String(decoding: data, as: UTF8.self))],
                     structuredContent: try JSONDecoder().decode(Value.self, from: data), isError: false)
    }
    private static func error(_ code: String, _ message: String) -> CallTool.Result {
        .init(content: [.text("\(code): \(message)")],
              structuredContent: .object(["code": .string(code), "message": .string(message)]), isError: true)
    }
}

private struct ModelsResult: Encodable { let providers: [ProviderSummary]; let models: [ModelData] }
private struct RecordsResult: Encodable { let records: [ResolveSlateRecord] }

private struct RecognitionResult: Encodable {
    let records: [ResolveSlateRecord]
    let warnings: [String]
    let pageCount: Int
    let provider: String
    let model: String
    let ocr: OcrSummary?
    let usage: TokenUsage?
    init(_ result: RecognitionData) {
        records = result.result.records.map { .init(cardNumber: $0.cardNumber, videoCode: $0.videoCode,
            scene: $0.scene, shot: $0.shot, take: $0.take, takeStatus: $0.takeStatus,
            comments: $0.comments, reviewRequiredFields: $0.reviewRequiredFields ?? []) }
        warnings = result.result.warnings
        pageCount = result.pageCount; provider = result.provider; model = result.model
        ocr = result.ocr; usage = result.usage
    }
}

/// Return bounded pages instead of embedding a 10,000-row table in every
/// conversation. Totals explicitly distinguish returned slices from the full merge.
private struct MCPMergeResult: Encodable {
    let canExport: Bool, outputPath: String?
    let rowCount: Int, matchedRecordCount: Int, changedCellCount: Int, reviewIssueCount: Int
    let cameraFpsMatchedMaterialCount: Int, shootDayMatchedMaterialCount: Int
    let headers: [String], rows: [[String]], warnings: [String]
    let statuses: [ResolveRecordStatus?], changes: [ResolveCSVChange]
    let warningCount: Int, statusCount: Int, changeCount: Int, offset: Int, limit: Int
    init(_ result: ResolveMergeResult, canExport: Bool, outputPath: String?, offset: Int, limit: Int) {
        self.canExport = canExport; self.outputPath = outputPath; self.offset = offset; self.limit = limit
        rowCount = result.table.rows.count; matchedRecordCount = result.matchedRecordCount
        changedCellCount = result.changedCellCount; reviewIssueCount = result.reviewIssueCount
        cameraFpsMatchedMaterialCount = result.cameraFpsMatchedMaterialCount
        shootDayMatchedMaterialCount = result.shootDayMatchedMaterialCount
        headers = result.table.headers; rows = Array(result.table.rows.dropFirst(offset).prefix(limit))
        warnings = Array(result.warnings.dropFirst(offset).prefix(limit))
        statuses = Array(result.statuses.dropFirst(offset).prefix(limit))
        changes = Array(result.changes.dropFirst(offset).prefix(limit))
        warningCount = result.warnings.count; statusCount = result.statuses.count; changeCount = result.changes.count
    }
}

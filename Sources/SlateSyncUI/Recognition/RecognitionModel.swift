import Foundation
import Observation
import SlateSyncDomain

/// Mutable, secret-free result projection owned by the window session. Every
/// commit is converted back to the persisted canonical record shape.
struct EditableRecognitionRecord: Identifiable, Hashable, Sendable {
    let id: String
    let sourcePage: Int?
    var cardNumber: String
    var videoCode: String
    var scene: String
    var shot: String
    var take: String
    var takeStatus: String
    var description: String
    var comments: String
    let shotSize: String?
    let cameraPosition: String?
    let confidence: RecognitionConfidence?
    let reviewRequiredFields: [String]?

    init(_ value: RecognitionRecord) {
        id = value.id; sourcePage = value.sourcePage; cardNumber = value.cardNumber ?? ""
        videoCode = value.videoCode ?? ""; scene = value.scene ?? ""; shot = value.shot ?? ""
        take = value.take ?? ""; takeStatus = value.takeStatus?.rawValue ?? ""
        description = value.description ?? ""; comments = value.comments ?? ""
        shotSize = value.shotSize; cameraPosition = value.cameraPosition
        confidence = value.confidence; reviewRequiredFields = value.reviewRequiredFields
    }

    init(_ value: PersistedRecognitionRecord, fallbackID: String) {
        id = value.id ?? fallbackID; sourcePage = value.sourcePage; cardNumber = value.cardNumber ?? ""
        videoCode = value.videoCode ?? ""; scene = value.scene ?? ""; shot = value.shot ?? ""
        take = value.take ?? ""; takeStatus = value.takeStatus?.rawValue ?? ""
        description = value.description ?? ""; comments = value.comments ?? ""
        shotSize = value.shotSize; cameraPosition = value.cameraPosition
        confidence = value.confidence; reviewRequiredFields = value.reviewRequiredFields
    }

    var persisted: PersistedRecognitionRecord {
        PersistedRecognitionRecord(
            id: id,
            sourcePage: sourcePage,
            cardNumber: cardNumber.nilIfEmpty,
            videoCode: videoCode.nilIfEmpty,
            scene: scene.nilIfEmpty,
            shot: shot.nilIfEmpty,
            take: take.nilIfEmpty,
            takeStatus: LegacyTakeStatusAdapter.status(from: takeStatus),
            description: description.nilIfEmpty,
            comments: comments.nilIfEmpty,
            shotSize: shotSize,
            cameraPosition: cameraPosition,
            confidence: confidence,
            reviewRequiredFields: reviewRequiredFields
        )
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

/// Project-scoped recognition owner. It survives route changes because the
/// composition root retains it with the window session, not with the view.
@MainActor @Observable
public final class RecognitionModel {
    public private(set) var projectID: String?
    public private(set) var operation: OperationState = .idle
    public private(set) var progress: RecognitionProgress?
    public private(set) var result: RecognitionData?
    public private(set) var operationID: UUID?
    public private(set) var providers: [ProviderSummary] = []
    public private(set) var models: [ModelData] = []
    public private(set) var optionsOperation: OperationState = .idle
    public private(set) var resultTableID = UUID()
    public private(set) var slateCSVRecords: [SlateCsvRecord] = []
    public private(set) var slateCSVFilename: String?
    public var flushEditor: (@MainActor () throws -> Void)?
    public var permitsNewOperation: (@MainActor () -> Bool)?
    private(set) var editableRecords: [EditableRecognitionRecord] = []

    private let service: any WorkspaceWorkflowServing
    private let settings: any GlobalSettingsWorkflowServing
    private var recognitionTask: Task<Void, Never>?
    private var progressTask: Task<Void, Never>?
    private var cancelTask: Task<Void, Never>?
    public var didComplete: (@MainActor (NativeRecognitionRequest, RecognitionData) async throws -> Void)?

    public init(
        service: any WorkspaceWorkflowServing,
        settings: any GlobalSettingsWorkflowServing
    ) {
        self.service = service
        self.settings = settings
    }

    /// Provider and model eligibility is projected by Workflow. The view
    /// never reconstructs catalog, credential, or capability rules.
    public func loadOptions() async {
        optionsOperation = .running(label: "正在读取识别选项…")
        do {
            let projection = try await settings.globalSettings()
            providers = projection.providers.filter(\.configured)
            models = projection.models.filter(Self.isEligible)
            optionsOperation = .idle
        } catch {
            optionsOperation = .failed(ProductPrivacy.error(error))
        }
    }

    public func availableModels(providerID: String) -> [ModelData] {
        models.filter { $0.providers.contains(providerID) }
    }

    public func canRecognize(providerID: String, modelID: String) -> Bool {
        providers.contains(where: { $0.id == providerID }) &&
            availableModels(providerID: providerID).contains(where: { $0.id == modelID })
    }

    public func recognize(_ request: NativeRecognitionRequest, flush: @escaping @MainActor () async throws -> Void) {
        guard permitsNewOperation?() != false else { return }
        guard recognitionTask == nil else { return }
        guard commitVisibleEditor() else { return }
        guard let providerID = request.providerID,
              let modelID = request.modelID,
              canRecognize(providerID: providerID, modelID: modelID) else {
            operation = .failed(SlateSyncError(
                code: "RECOGNITION_OPTION_UNAVAILABLE",
                message: "所选 Provider 或模型当前不可用，请刷新后重试"
            ))
            return
        }
        let id = UUID()
        projectID = request.projectID
        operationID = id
        operation = .running(label: "准备识别…")
        progress = nil
        result = nil
        recognitionTask = Task { [weak self] in
            guard let self else { return }
            // File-import security scope remains paired for the complete
            // media/OCR/network operation, including cancellation and errors.
            let scopedURL: URL? = switch request.input {
            case .file(let url): url
            case .bytes: nil
            }
            let accessed = scopedURL?.startAccessingSecurityScopedResource() == true
            defer { if accessed { scopedURL?.stopAccessingSecurityScopedResource() } }
            do {
                try await flush()
                try Task.checkCancellation()
                // Await stream registration before dispatch so progress and
                // execution share the same lazily constructed coordinator.
                let stream = await service.recognitionProgress(projectID: request.projectID)
                try Task.checkCancellation()
                observeProgress(stream, projectID: request.projectID, operationID: id)
                let value = try await service.recognize(request)
                try Task.checkCancellation()
                guard operationID == id else { return }
                try await didComplete?(request, value)
                result = value
                editableRecords = value.result.records.map(EditableRecognitionRecord.init)
                resultTableID = UUID()
                operation = .succeeded(message: "已识别 \(value.result.records.count) 条场记")
            } catch {
                guard operationID == id else { return }
                let wrapped = ProductPrivacy.error(error)
                operation = error is CancellationError || wrapped.code == "RECOGNITION_CANCELED" ? .canceled : .failed(wrapped)
            }
            await finishOperation(id)
        }
    }

    public func importSlateCSV(_ data: Data, filename: String, projectID: String, flush: @escaping @MainActor () async throws -> Void) {
        // File-panel completions can arrive after a Library/close barrier has
        // disabled the view. Enforce admission again at the operation owner.
        guard permitsNewOperation?() != false else { return }
        guard recognitionTask == nil, let local = service as? any LocalSlateWorkflowServing else { return }
        guard commitVisibleEditor() else { return }
        self.projectID = projectID
        operationID = UUID()
        operation = .running(label: "正在读取场记 CSV…")
        recognitionTask = Task { [self] in
            do {
                try await flush()
                let records = try await local.decodeSlateCSV(data)
                try Task.checkCancellation()
                slateCSVRecords = records
                slateCSVFilename = filename
                operation = .succeeded(message: "已载入 \(records.count) 条本地场记")
            } catch { operation = error is CancellationError ? .canceled : .failed(ProductPrivacy.error(error)) }
            recognitionTask = nil
        }
    }

    public func generateLocalRecords(flush: @escaping @MainActor () async throws -> Void,
                                     commit: @escaping @MainActor ([PersistedRecognitionRecord], String) -> Void) {
        guard permitsNewOperation?() != false else { return }
        guard recognitionTask == nil, !slateCSVRecords.isEmpty,
              let local = service as? any LocalSlateWorkflowServing else { return }
        guard commitVisibleEditor() else { return }
        operation = .running(label: "正在生成本地结果…")
        let records = slateCSVRecords
        let filename = slateCSVFilename ?? "场记 CSV"
        recognitionTask = Task { [self] in
            do {
                try await flush()
                let value = await local.localSlateRecords(records)
                try Task.checkCancellation()
                // A local result must not retain a previous Provider response.
                result = nil
                resultTableID = UUID()
                editableRecords = value.enumerated().map { EditableRecognitionRecord($0.element, fallbackID: "slate-csv-\($0.offset)") }
                commit(value, filename)
                operation = .succeeded(message: "已生成 \(value.count) 条本地结果")
            } catch { operation = error is CancellationError ? .canceled : .failed(ProductPrivacy.error(error)) }
            recognitionTask = nil
        }
    }

    public func cancel() {
        guard let projectID, let task = recognitionTask, cancelTask == nil else { return }
        let id = operationID
        operation = .running(label: "正在取消…")
        // Cancel the captured task before awaiting the service; a cancellation
        // during flush must never start a new request after cancel returned.
        task.cancel()
        cancelTask = Task {
            await service.cancelRecognition(projectID: projectID)
            await task.value
            if operationID == id { operation = .canceled }
            cancelTask = nil
        }
    }

    private func commitVisibleEditor() -> Bool {
        // Entering running disables result mutations. Commit the still-mounted
        // cell first so its final 250 ms draft is accepted by receiveResult.
        do { try flushEditor?(); return true }
        catch { operation = .failed(ProductPrivacy.error(error)); return false }
    }

    /// Picker read failures belong to this operation surface, not the media
    /// preparation owner that happens to share the surrounding input form.
    public func report(_ error: Error) {
        operation = .failed(ProductPrivacy.error(error))
    }

    public func drain() async {
        cancel()
        if let cancelTask { await cancelTask.value }
        if let recognitionTask { await recognitionTask.value }
        progressTask?.cancel()
        if let progressTask { await progressTask.value }
        recognitionTask = nil
        progressTask = nil
    }

    public func load(task: TaskData?) {
        guard recognitionTask == nil else { return }
        result = nil
        resultTableID = UUID()
        slateCSVRecords = []
        slateCSVFilename = nil
        let records = task?.editedRecords ?? task?.result?.records ?? []
        editableRecords = records.enumerated().map {
            EditableRecognitionRecord($0.element, fallbackID: "persisted-\($0.offset)")
        }
    }

    /// Recognition and Resolve share one native cell editor, including its
    /// marked-text barrier, keyboard semantics and delayed commit behavior.
    public var resultTable: ResolveCSVTable {
        ResolveCSVTable(headers: ["卡号", "素材编号", "场", "镜", "条", "状态", "描述", "备注"],
            rows: editableRecords.map { [$0.cardNumber, $0.videoCode, $0.scene, $0.shot, $0.take, $0.takeStatus, $0.description, $0.comments] },
            format: .init())
    }

    public func receiveResult(_ cell: CSVCellCommit, commit: @MainActor ([PersistedRecognitionRecord]) -> Void) {
        guard cell.tableID == resultTableID, cell.revision == 0, !operation.isRunning,
              editableRecords.indices.contains(cell.rowID) else { return }
        let fields: [WritableKeyPath<EditableRecognitionRecord, String>] = [\.cardNumber, \.videoCode, \.scene, \.shot, \.take, \.takeStatus, \.description, \.comments]
        guard fields.indices.contains(cell.columnID) else { return }
        update(recordID: editableRecords[cell.rowID].id, path: fields[cell.columnID], value: cell.value, commit: commit)
    }

    public var resolveRecords: [ResolveSlateRecord] {
        // Preserve canonical status and material identity when adapting the
        // editable record projection to the existing SM-05 merger.
        editableRecords.map { row in
            let record = row.persisted
            return ResolveSlateRecord(cardNumber: record.cardNumber, videoCode: record.videoCode,
                scene: record.scene, shot: record.shot, take: record.take, takeStatus: record.takeStatus,
                comments: record.comments, reviewRequiredFields: record.reviewRequiredFields ?? [])
        }
    }

    func update(
        recordID: String,
        path: WritableKeyPath<EditableRecognitionRecord, String>,
        value: String,
        commit: @MainActor ([PersistedRecognitionRecord]) -> Void
    ) {
        guard let index = editableRecords.firstIndex(where: { $0.id == recordID }) else { return }
        editableRecords[index][keyPath: path] = value
        commit(editableRecords.map(\.persisted))
    }

    private func observeProgress(_ stream: AsyncStream<RecognitionProgress>, projectID: String, operationID: UUID) {
        progressTask?.cancel()
        progressTask = Task { [weak self] in
            guard let self else { return }
            for await value in stream {
                guard !Task.isCancelled, self.operationID == operationID,
                      self.projectID == projectID, self.recognitionTask != nil else { return }
                progress = value
                operation = .running(label: value.message)
            }
        }
    }

    private func finishOperation(_ id: UUID) async {
        guard operationID == id else { return }
        progressTask?.cancel()
        await progressTask?.value
        progressTask = nil
        recognitionTask = nil
    }

    private nonisolated static func isEligible(_ model: ModelData) -> Bool {
        if model.verifiedAvailable == false { return false }
        switch model.capabilityStatus {
        case .failed, .unsupported, .canceled, .pending: return false
        default: return true
        }
    }
}

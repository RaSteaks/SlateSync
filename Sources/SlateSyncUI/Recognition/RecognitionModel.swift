import Foundation
import Observation
import SlateSyncDomain

// Product copy uses the shared launch language; user content stays verbatim.

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

/// Restoring a persisted choice must not silently substitute a different
/// Provider or model. Availability is validated only when recognition starts;
/// an explicit Provider change may clear an incompatible model draft.
struct RecognitionOptionSelection: Equatable {
    let providerID: String
    let modelID: String

    static func restored(
        task: TaskData?,
        project: ProjectSettings
    ) -> Self {
        Self(
            // Empty tasks inherit only explicit project defaults. View-local
            // state belongs to the previously selected task and is never a
            // valid fallback for a new task identity.
            providerID: task?.provider ?? project.providerId ?? "",
            modelID: task?.model ?? project.modelId ?? ""
        )
    }

    static func selectingProvider(
        _ providerID: String,
        currentModelID: String,
        availableModels: [ModelData]
    ) -> Self {
        Self(
            providerID: providerID,
            modelID: availableModels.contains(where: { $0.id == currentModelID }) ? currentModelID : ""
        )
    }
}

/// Project-scoped recognition owner. It survives route changes because the
/// composition root retains it with the window session, not with the view.
@MainActor @Observable
public final class RecognitionModel {
    public private(set) var projectID: String?
    public private(set) var operation: OperationState = .idle
    public private(set) var progress: RecognitionProgress?
    public private(set) var result: RecognitionData?
    /// The task whose records are currently represented by the successful
    /// result. Window-level actions use this identity before opening Results.
    public private(set) var resultTaskID: String?
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
    private var optionsGeneration = 0
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
        optionsGeneration += 1
        let request = optionsGeneration
        optionsOperation = .running(label: L10n.tr("正在读取识别选项…"))
        do {
            let projection = try await settings.globalSettings()
            guard optionsGeneration == request else { return }
            providers = projection.providers.filter(\.configured)
            models = projection.models.filter(Self.isEligible)
            optionsOperation = .idle
        } catch {
            guard optionsGeneration == request else { return }
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
        // The canceled worker may finish before its service-side cancellation.
        // Keep admission closed until both owners have drained so a late cancel
        // cannot target or repaint a newly started operation.
        guard recognitionTask == nil, cancelTask == nil else { return }
        guard commitVisibleEditor() else { return }
        guard let providerID = request.providerID,
              let modelID = request.modelID,
              canRecognize(providerID: providerID, modelID: modelID) else {
            operation = .failed(SlateSyncError(
                code: "RECOGNITION_OPTION_UNAVAILABLE",
                message: L10n.tr("所选 Provider 或模型当前不可用，请刷新后重试")
            ))
            return
        }
        let id = UUID()
        projectID = request.projectID
        operationID = id
        operation = .running(label: L10n.tr("准备识别…"))
        progress = nil
        result = nil
        resultTaskID = nil
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
            var terminalState: OperationState = .idle
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
                resultTaskID = request.taskID
                resultTableID = UUID()
                terminalState = .succeeded(message: L10n.tr("已识别 {0} 条场记", [String(describing: value.result.records.count)]))
            } catch {
                guard operationID == id else { return }
                let wrapped = ProductPrivacy.error(error)
                terminalState = error is CancellationError || wrapped.code == "RECOGNITION_CANCELED" ? .canceled : .failed(wrapped)
            }
            await finishOperation(id, state: terminalState)
        }
    }

    public func importSlateCSV(_ data: Data, filename: String, projectID: String, flush: @escaping @MainActor () async throws -> Void) {
        // File-panel completions can arrive after a Library/close barrier has
        // disabled the view. Enforce admission again at the operation owner.
        guard permitsNewOperation?() != false else { return }
        guard recognitionTask == nil, cancelTask == nil,
              let local = service as? any LocalSlateWorkflowServing else { return }
        guard commitVisibleEditor() else { return }
        let id = UUID()
        self.projectID = projectID
        operationID = id
        operation = .running(label: L10n.tr("正在读取场记 CSV…"))
        resultTaskID = nil
        recognitionTask = Task { [self] in
            var terminalState: OperationState = .idle
            do {
                try await flush()
                let records = try await local.decodeSlateCSV(data)
                try Task.checkCancellation()
                if operationID == id {
                    slateCSVRecords = records
                    slateCSVFilename = filename
                    terminalState = .succeeded(message: L10n.tr("已载入 {0} 条本地场记", [String(describing: records.count)]))
                }
            } catch {
                if operationID == id {
                    terminalState = error is CancellationError ? .canceled : .failed(ProductPrivacy.error(error))
                }
            }
            await finishOperation(id, state: terminalState)
        }
    }

    public func generateLocalRecords(
        flush: @escaping @MainActor () async throws -> Void,
        commit: @escaping @MainActor ([PersistedRecognitionRecord], String) -> Void,
        taskID: String? = nil
    ) {
        guard permitsNewOperation?() != false else { return }
        guard recognitionTask == nil, cancelTask == nil, !slateCSVRecords.isEmpty,
              let local = service as? any LocalSlateWorkflowServing else { return }
        guard commitVisibleEditor() else { return }
        let id = UUID()
        operationID = id
        operation = .running(label: L10n.tr("正在生成本地结果…"))
        resultTaskID = nil
        let records = slateCSVRecords
        let filename = slateCSVFilename ?? L10n.tr("场记 CSV")
        recognitionTask = Task { [self] in
            var terminalState: OperationState = .idle
            do {
                try await flush()
                let value = await local.localSlateRecords(records)
                try Task.checkCancellation()
                if operationID == id {
                    // A local result must not retain a previous Provider response.
                    result = nil
                    resultTableID = UUID()
                    editableRecords = value.enumerated().map { EditableRecognitionRecord($0.element, fallbackID: "slate-csv-\($0.offset)") }
                    resultTaskID = taskID
                    commit(value, filename)
                    terminalState = .succeeded(message: L10n.tr("已生成 {0} 条本地结果", [String(describing: value.count)]))
                }
            } catch {
                if operationID == id {
                    terminalState = error is CancellationError ? .canceled : .failed(ProductPrivacy.error(error))
                }
            }
            await finishOperation(id, state: terminalState)
        }
    }

    public func cancel() {
        // A worker can still be draining progress after relinquishing its ID.
        // It no longer accepts cancellation, even before its terminal state is published.
        guard let projectID, let task = recognitionTask, let id = operationID, cancelTask == nil else { return }
        operation = .running(label: L10n.tr("正在取消…"))
        // Cancel the captured task before awaiting the service; a cancellation
        // during flush must never start a new request after cancel returned.
        task.cancel()
        cancelTask = Task {
            await service.cancelRecognition(projectID: projectID)
            await task.value
            // After finishOperation cleared the identity, operationID == id
            // can only mean the task never reached a terminal state itself;
            // never overwrite a result the task already wrote.
            if operationID == id, operation.isRunning { operation = .canceled }
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
        guard recognitionTask == nil, cancelTask == nil else { return }
        // A task switch invalidates the previous operation message and its
        // route action; otherwise a success from task A could open task B's
        // result table after the user changes selection.
        operation = .idle
        progress = nil
        operationID = nil
        result = nil
        resultTaskID = nil
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
        ResolveCSVTable(headers: [L10n.tr("卡号"), L10n.tr("素材编号"), L10n.tr("场"), L10n.tr("镜"), L10n.tr("条"), L10n.tr("状态"), L10n.tr("描述"), L10n.tr("备注")],
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

    private func finishOperation(_ id: UUID, state: OperationState) async {
        guard operationID == id else { return }
        // Clear the identity first: from here on no late cancel, progress
        // event, or completion continuation may adopt this operation — e.g.
        // a cancel() that lands while the progress task is still draining
        // must not repaint a .succeeded result as .canceled.
        operationID = nil
        progressTask?.cancel()
        await progressTask?.value
        progressTask = nil
        recognitionTask = nil
        // Publish completion only after cleanup. An observer of success may
        // immediately load another task or cancel; both must see released owners.
        operation = state
    }

    private nonisolated static func isEligible(_ model: ModelData) -> Bool {
        if model.verifiedAvailable == false { return false }
        // The workbench can dispatch only a probe-confirmed pair. Discovery
        // declarations are shown in Settings but never treated as validation.
        return model.capabilityStatus == .verified
    }
}

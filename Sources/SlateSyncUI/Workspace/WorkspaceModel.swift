import Foundation
import Observation
import SlateSyncDomain

/// Window-owned workspace state. The model publishes only the selected task
/// snapshot; persistence is serialized by `WorkspaceAutosave`, and every
/// selection change crosses the same flush barrier before generation changes.
@MainActor @Observable
public final class WorkspaceModel {
    public private(set) var projectID: String?
    public private(set) var tasks: [TaskListItem] = []
    public private(set) var selectedTaskID: String?
    public private(set) var selectedTask: TaskData?
    public private(set) var generation = 0
    public private(set) var projectSettings = ProjectSettings()
    public private(set) var scenarios: [ScenarioSummary] = []
    public private(set) var operation: OperationState = .idle
    public private(set) var autosaveError: SlateSyncError?
    public private(set) var isDirty = false
    public var searchText = ""
    public var customPrompt = "" {
        didSet {
            guard !isPublishingSnapshot, customPrompt != oldValue else { return }
            scheduleAutosave()
        }
    }

    private let service: any WorkspaceWorkflowServing
    private let autosave: WorkspaceAutosave
    private var isPublishingSnapshot = false
    private var autosaveScheduleTask: Task<Void, Never>?
    private var autosaveObservation: Task<Void, Never>?
    private var editRevision = 0
    private var isClosed = false
    public private(set) var isTransitioning = false
    public var prepareSelectionChange: (@MainActor () async throws -> Void)?
    public var flushEditor: (@MainActor () throws -> Void)?
    public var acquireProject: (@MainActor (String) throws -> Void)?
    public var releaseProject: (@MainActor (String) -> Void)?
    public var didSelectTask: (@MainActor (TaskData?) -> Void)?
    public var permitsNewOperation: (@MainActor () -> Bool)?
    public var didFailRuntimeClose: (@MainActor () -> Void)?

    public func requireStableSelection() throws {
        guard !isTransitioning else { throw transitionError }
    }

    public init(service: any WorkspaceWorkflowServing) {
        self.service = service
        autosave = WorkspaceAutosave { projectID, taskID, snapshot in
            try await service.saveTask(projectID: projectID, taskID: taskID, task: snapshot)
        }
        autosaveObservation = Task { [weak self, states = autosave.states] in
            for await state in states {
                guard let self else { return }
                guard state.revision == editRevision else { continue }
                autosaveError = state.error.map(ProductPrivacy.error)
                isDirty = state.pending
            }
        }
    }

    public var filteredTasks: [TaskListItem] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return tasks }
        return tasks.filter {
            ($0.filename ?? "").localizedCaseInsensitiveContains(query) ||
                ($0.id ?? "").localizedCaseInsensitiveContains(query)
        }
    }

    public func activate(projectID newProjectID: String) async throws {
        guard !isTransitioning, permitsNewOperation?() != false else { throw transitionError }
        isTransitioning = true
        defer { isTransitioning = false }
        let oldProjectID = projectID
        try acquireProject?(newProjectID)
        var didActivate = false
        defer {
            if !didActivate, oldProjectID != newProjectID { releaseProject?(newProjectID) }
        }
        // Even reopening the same project must flush before refreshing its
        // persisted projection. Otherwise its unsaved editor is overwritten.
        try await flush()
        try await prepareSelectionChange?()
        // A completing operation may have staged data while the first flush
        // was suspended. Drain first, then persist its final state.
        try await flush()
        let loaded = try await service.listTasks(projectID: newProjectID)
        let candidate = loaded.compactMap(\.id).first
        let task: TaskData?
        if let candidate { task = try await service.loadTask(projectID: newProjectID, taskID: candidate) }
        else { task = nil }
        let settings: ProjectSettings
        if let library = service as? any ProjectLibraryWorkflowServing {
            settings = try await library.project(id: newProjectID).settings
        } else { settings = task?.projectSettingsSnapshot ?? .init() }
        let availableScenarios = try await (service as? any LocalSlateWorkflowServing)?.listScenarios(projectID: newProjectID) ?? []
        if let projectID, projectID != newProjectID {
            try await closeRuntimeProject(projectID)
        }
        // Publish identity and data together only after every fallible read
        // succeeds; a failed target load leaves the old project operable.
        projectID = newProjectID
        generation += 1
        tasks = loaded
        projectSettings = settings
        scenarios = availableScenarios
        publish(task, id: candidate)
        operation = .idle
        didActivate = true
        if let oldProjectID, oldProjectID != newProjectID { releaseProject?(oldProjectID) }
    }

    public func reloadTasks(selecting preferredID: String? = nil) async throws {
        guard let projectID else { return }
        let requestGeneration = generation
        operation = .running(label: "正在读取任务…")
        do {
            let loaded = try await service.listTasks(projectID: projectID)
            guard requestGeneration == generation, self.projectID == projectID else { return }
            tasks = loaded
            operation = .idle
            let candidate = preferredID ?? selectedTaskID ?? loaded.compactMap(\.id).first
            if let candidate, loaded.contains(where: { $0.id == candidate }) {
                try await loadTask(id: candidate, projectID: projectID, generation: requestGeneration)
            } else {
                publish(nil, id: nil)
            }
        } catch {
            guard requestGeneration == generation else { return }
            operation = .failed(ProductPrivacy.error(error))
            throw error
        }
    }

    public func selectTask(_ id: String) async throws {
        guard id != selectedTaskID, let projectID else { return }
        guard !isTransitioning, permitsNewOperation?() != false else { throw transitionError }
        isTransitioning = true
        defer { isTransitioning = false }
        do {
            try await flush()
            try await prepareSelectionChange?()
            // A completing operation may have staged data while the first
            // flush was suspended. Drain first, then persist its final state.
            try await flush()
            generation += 1
            try await loadTask(id: id, projectID: projectID, generation: generation)
        } catch {
            operation = .failed(ProductPrivacy.error(error))
            throw error
        }
    }

    public func createTask() async {
        guard let projectID, !isTransitioning, permitsNewOperation?() != false else { return }
        isTransitioning = true
        defer { isTransitioning = false }
        do {
            try await flush()
            try await prepareSelectionChange?()
            // A completing operation may have staged data while the first
            // flush was suspended. Drain first, then persist its final state.
            try await flush()
            operation = .running(label: "正在新建任务…")
            let task = TaskData(
                projectId: projectID,
                projectSettingsSnapshot: projectSettings,
                status: "draft",
                filename: "未命名场记单",
                customPrompt: ""
            )
            let id = try await service.saveTask(projectID: projectID, taskID: nil, task: task)
            generation += 1
            try await reloadTasks(selecting: id)
            operation = .succeeded(message: "任务已创建")
        } catch {
            operation = .failed(ProductPrivacy.error(error))
        }
    }

    public func deleteSelectedTask() async {
        guard let selectedTaskID else { return }
        await deleteTask(id: selectedTaskID)
    }

    /// Deletes the row that owned the contextual action. A context menu does
    /// not implicitly change List selection on macOS, so using the selected
    /// task here could otherwise remove an unrelated task.
    public func deleteTask(id taskID: String) async {
        guard let projectID, !isTransitioning, permitsNewOperation?() != false else { return }
        isTransitioning = true
        defer { isTransitioning = false }
        do {
            try await flush()
            try await prepareSelectionChange?()
            // A completing operation may have staged data while the first
            // flush was suspended. Drain first, then persist its final state.
            try await flush()
            operation = .running(label: "正在删除任务…")
            try await service.deleteTask(projectID: projectID, taskID: taskID)
            generation += 1
            if selectedTaskID == taskID { publish(nil, id: nil) }
            try await reloadTasks()
            operation = .succeeded(message: "任务已删除")
        } catch {
            operation = .failed(ProductPrivacy.error(error))
        }
    }

    public func flush() async throws {
        do {
            // A focused AppKit cell can still own a local draft. Commit it
            // synchronously before joining the shared persistence enqueue.
            try flushEditor?()
            // didSet cannot await the actor. Join the enqueue task first so a
            // route/selection barrier can never overtake the latest edit.
            if let autosaveScheduleTask { await autosaveScheduleTask.value }
            autosaveScheduleTask = nil
            try await autosave.flush()
            autosaveError = nil
        } catch {
            autosaveError = ProductPrivacy.error(error)
            throw error
        }
    }

    public func retryAutosave() async {
        do {
            try await autosave.retry()
            autosaveError = nil
        } catch {
            autosaveError = ProductPrivacy.error(error)
        }
    }

    public func close() async throws {
        guard !isTransitioning else { throw transitionError }
        isTransitioning = true
        defer { isTransitioning = false }
        try await flush()
        try await prepareSelectionChange?()
        // A completing operation may have staged data while the first flush
        // was suspended. Drain first, then persist its final state.
        try await flush()
        if let projectID { try await closeRuntimeProject(projectID) }
        try await autosave.close()
        isClosed = true
        autosaveObservation?.cancel()
        await autosaveObservation?.value
        if let projectID { releaseProject?(projectID) }
    }

    /// Result edits enter the same ordered enqueue chain as prompt edits.
    /// The writer owns the 250 ms timer; no delayed stale snapshot can
    /// overtake a subsequent general edit or navigation flush.
    public func stageEditedRecords(_ records: [PersistedRecognitionRecord]) {
        guard let selectedTask else { return }
        let snapshot = selectedTask.replacingEditedRecords(records)
        self.selectedTask = snapshot
        enqueue(snapshot, delay: .milliseconds(250))
    }

    public func stageCSV(_ table: ResolveCSVTable, filename: String?) {
        guard let selectedTask else { return }
        let snapshot = selectedTask.replacingCSV(table, filename: filename)
        self.selectedTask = snapshot
        enqueue(snapshot, delay: .milliseconds(250))
    }

    public func stageMedia(_ document: PreparedDocument) {
        guard let selectedTask else { return }
        let snapshot = selectedTask.replacingMedia(document)
        self.selectedTask = snapshot
        enqueue(snapshot)
    }

    public func stageMetadata(_ scan: ScanResult, directoryName: String) {
        guard let selectedTask else { return }
        let snapshot = selectedTask.replacingMetadata(scan, directoryName: directoryName)
        self.selectedTask = snapshot
        enqueue(snapshot)
    }

    public func stageLocalRecords(_ records: [PersistedRecognitionRecord], filename: String) {
        guard let selectedTask else { return }
        let snapshot = selectedTask.replacingLocalRecords(records, filename: filename)
        self.selectedTask = snapshot
        enqueue(snapshot)
    }

    /// Provider/model/accuracy/Scenario controls are task-owned choices. Stage
    /// the complete immutable task snapshot so a route switch or window close
    /// persists the selection through the same 500 ms writer as other drafts.
    public func stageRecognitionOptions(
        providerID: String?,
        modelID: String?,
        accuracyMode: ProjectSettings.AccuracyMode,
        scenarioID: String?
    ) {
        guard let selectedTask else { return }
        let provider = providerID?.trimmingCharacters(in: .whitespacesAndNewlines)
        let model = modelID?.trimmingCharacters(in: .whitespacesAndNewlines)
        let scenario = scenarioID?.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedProvider = provider?.isEmpty == false ? provider : nil
        let normalizedModel = model?.isEmpty == false ? model : nil
        let normalizedScenario = scenario?.isEmpty == false ? scenario : nil
        guard selectedTask.provider != normalizedProvider ||
                selectedTask.model != normalizedModel ||
                selectedTask.accuracyMode != accuracyMode ||
                selectedTask.scenarioId != normalizedScenario else { return }
        let snapshot = selectedTask.replacingRecognitionOptions(
            provider: normalizedProvider,
            model: normalizedModel,
            accuracyMode: accuracyMode,
            scenarioID: normalizedScenario
        )
        self.selectedTask = snapshot
        enqueue(snapshot)
    }

    private func loadTask(id: String, projectID: String, generation expected: Int) async throws {
        operation = .running(label: "正在读取任务…")
        let task = try await service.loadTask(projectID: projectID, taskID: id)
        guard expected == generation, self.projectID == projectID else { return }
        publish(task, id: id)
        operation = .idle
    }

    private func publish(_ task: TaskData?, id: String?) {
        isPublishingSnapshot = true
        selectedTask = task
        selectedTaskID = id
        customPrompt = task?.customPrompt ?? ""
        isPublishingSnapshot = false
        didSelectTask?(task)
    }

    public func adoptProjectSettings(_ project: ProjectData) {
        guard project.id == projectID else { return }
        projectSettings = project.settings
    }

    public func deactivate() async {
        // Only called after the shared Library barrier and successful archive/
        // delete. Keep the reusable writer open for the next project.
        await autosave.reset()
        editRevision += 1
        isDirty = false
        autosaveError = nil
        if let projectID { releaseProject?(projectID) }
        projectID = nil
        tasks = []
        generation += 1
        publish(nil, id: nil)
        operation = .idle
    }

    private func scheduleAutosave() {
        guard let selectedTask else { return }
        let snapshot = selectedTask.replacingCustomPrompt(customPrompt)
        self.selectedTask = snapshot
        enqueue(snapshot)
    }

    private var transitionError: SlateSyncError {
        .init(code: "WORKSPACE_BUSY", message: "正在切换任务，请稍后重试", retryable: true)
    }

    private func closeRuntimeProject(_ id: String) async throws {
        do { try await service.closeProject(id: id) }
        catch {
            // A partially closed store is a terminal recovery state, unlike
            // an autosave failure where the editor can safely retry in place.
            didFailRuntimeClose?()
            throw error
        }
    }

    private func enqueue(_ snapshot: TaskData, delay: Duration? = nil) {
        guard let projectID, !isClosed else { return }
        let taskID = selectedTaskID
        editRevision += 1
        isDirty = true
        let previous = autosaveScheduleTask
        autosaveScheduleTask = Task {
            await previous?.value
            await autosave.schedule(projectID: projectID, taskID: taskID, snapshot: snapshot, delay: delay)
            autosaveError = await autosave.error()
        }
    }
}

private extension TaskData {
    /// TaskData is immutable by contract; editor updates therefore create a
    /// complete replacement instead of mutating a shared persistence object.
    func replacingCustomPrompt(_ customPrompt: String) -> TaskData {
        replacing(customPrompt: customPrompt, editedRecords: editedRecords)
    }

    func replacingEditedRecords(_ editedRecords: [PersistedRecognitionRecord]) -> TaskData {
        replacing(customPrompt: customPrompt, editedRecords: editedRecords)
    }

    func replacingCSV(_ table: ResolveCSVTable, filename: String?) -> TaskData {
        replacing(customPrompt: customPrompt, editedRecords: editedRecords, csv: table, csvFilename: filename)
    }

    func replacingMedia(_ document: PreparedDocument) -> TaskData {
        replacing(customPrompt: customPrompt, editedRecords: editedRecords, media: document)
    }

    func replacingMetadata(_ scan: ScanResult, directoryName: String) -> TaskData {
        replacing(customPrompt: customPrompt, editedRecords: editedRecords, scan: scan, directoryName: directoryName)
    }

    func replacingLocalRecords(_ records: [PersistedRecognitionRecord], filename: String) -> TaskData {
        replacing(customPrompt: customPrompt, editedRecords: records, localFilename: filename)
    }

    func replacingRecognitionOptions(
        provider: String?,
        model: String?,
        accuracyMode: ProjectSettings.AccuracyMode,
        scenarioID: String?
    ) -> TaskData {
        replacing(
            customPrompt: customPrompt,
            editedRecords: editedRecords,
            recognitionOptions: .init(provider: provider, model: model, accuracyMode: accuracyMode, scenarioID: scenarioID)
        )
    }

    private func replacing(
        customPrompt: String?,
        editedRecords: [PersistedRecognitionRecord]?,
        csv: ResolveCSVTable? = nil,
        csvFilename: String? = nil,
        media: PreparedDocument? = nil,
        scan: ScanResult? = nil,
        directoryName: String? = nil,
        localFilename: String? = nil,
        recognitionOptions: TaskRecognitionOptions? = nil
    ) -> TaskData {
        let nextProvider: String? = recognitionOptions == nil ? provider : recognitionOptions?.provider
        let nextModel: String? = recognitionOptions == nil ? model : recognitionOptions?.model
        let nextAccuracy: ProjectSettings.AccuracyMode? = recognitionOptions == nil ? accuracyMode : recognitionOptions?.accuracyMode
        let nextScenario: String? = recognitionOptions == nil ? scenarioId : recognitionOptions?.scenarioID
        return TaskData(
            id: id,
            projectId: projectId,
            projectSettingsSnapshot: projectSettingsSnapshot,
            status: localFilename == nil ? status : "completed",
            filename: localFilename ?? media?.filename ?? filename,
            fileType: fileType,
            fileSize: fileSize,
            pageCount: media?.pages.count ?? pageCount,
            imageDataGroups: media?.pages.map { $0.views.map { $0.image.dataURL } } ?? imageDataGroups,
            resolveCsvBase64: resolveCsvBase64,
            resolveCsvFilename: csvFilename ?? resolveCsvFilename,
            resolveCsvTable: csv ?? resolveCsvTable,
            resolveCsvEdits: resolveCsvEdits,
            slateMetadata: scan?.metadata.map {
                PersistedSlateMetadata(materialKey: $0.materialKey, sourceName: $0.sourceName,
                    clipName: $0.clipName, sensorFps: $0.sensorFps, shootDay: $0.shootDay)
            } ?? slateMetadata,
            slateWarnings: scan?.warnings ?? slateWarnings,
            missingMetadataKeys: scan?.missingKeys ?? missingMetadataKeys,
            slateDirectoryName: directoryName ?? slateDirectoryName,
            scenarioId: localFilename == nil ? nextScenario : nil,
            scenarioMatch: localFilename == nil ? scenarioMatch : nil,
            scenarioFingerprint: localFilename == nil ? scenarioFingerprint : nil,
            provider: localFilename == nil ? nextProvider : "local",
            model: localFilename == nil ? nextModel : "slate-csv",
            customPrompt: customPrompt,
            accuracyMode: localFilename == nil ? nextAccuracy : .standard,
            result: localFilename == nil ? result : PersistedRecognitionSheet(sheetTitle: localFilename, records: editedRecords ?? []),
            usage: localFilename == nil ? usage : nil,
            durationMs: localFilename == nil ? durationMs : 0,
            ocrSummary: localFilename == nil ? ocrSummary : nil,
            diagnosticSessionId: localFilename == nil ? diagnosticSessionId : nil,
            editedRecords: editedRecords,
            createdAt: createdAt,
            updatedAt: updatedAt
        )
    }
}

private struct TaskRecognitionOptions {
    let provider: String?
    let model: String?
    let accuracyMode: ProjectSettings.AccuracyMode
    let scenarioID: String?
}

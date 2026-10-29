import Foundation
import SlateSyncDomain
import SlateSyncMedia

public actor RecognitionLimiter {
    private var limit: Int
    private var active = Set<UUID>()
    private var waiting: [(UUID, CheckedContinuation<Void, Error>)] = []

    public init(limit: Int = 1) { self.limit = min(16, max(1, limit)) }
    public func acquire(_ id: UUID) throws {
        guard active.count < limit else { throw RecognitionFailure.globalBusy }
        active.insert(id)
    }
    public func acquireQueued(_ id: UUID) async throws {
        try Task.checkCancellation()
        if active.count < limit { active.insert(id); return }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                waiting.append((id, continuation))
                if Task.isCancelled { cancelWaiting(id) }
            }
        } onCancel: { Task { await self.cancelWaiting(id) } }
    }
    private func cancelWaiting(_ id: UUID) {
        guard let index = waiting.firstIndex(where: { $0.0 == id }) else { return }
        waiting.remove(at: index).1.resume(throwing: CancellationError())
    }
    public func release(_ id: UUID) {
        cancelWaiting(id)
        guard active.remove(id) != nil else { return }
        dispatchWaiting()
    }
    private func dispatchWaiting() {
        while active.count < limit, !waiting.isEmpty {
            let (next, continuation) = waiting.removeFirst()
            active.insert(next)
            continuation.resume()
        }
    }
    public func setLimit(_ value: Int) {
        limit = min(16, max(1, value))
        dispatchWaiting()
    }
    public func activeCount() -> Int { active.count }
}

public actor RecognitionCoordinator: RecognitionServing {
    public typealias MediaFactory = @Sendable () -> MediaOCRWorkflow

    private struct ActiveOperation {
        let projectID: String
        let task: Task<RecognitionData, Error>
    }

    private let registry: ProviderRegistry?
    private let pipeline: RecognitionPagePipeline?
    private let client: ProviderRecognitionClient?
    private let mediaFactory: MediaFactory?
    private let clearMediaSession: @Sendable (String) async -> Void
    private let closeMediaResources: @Sendable () async -> Void
    private let scenarioPersistence: (any ScenarioMatchingPersistence)?
    private let persistence: (any RecognitionPersistence)?
    private let limiter: RecognitionLimiter
    private let settings: GlobalSettingValues
    private let clock: any ProviderClock
    private let workflowConfiguration: @Sendable () async throws -> WorkflowConfig
    private let failoverState = RecognitionFailoverState()
    private let recoveryCache = RecognitionRecoveryCache()
    private var observers: [String: [UUID: AsyncStream<RecognitionProgress>.Continuation]] = [:]
    private var operations: [UUID: ActiveOperation] = [:]
    private var lastPercent: [UUID: Int] = [:]
    private var closed = false
    private var closeTask: Task<Void, Never>?

    /// Retains the old lightweight construction for UI wiring that only needs
    /// progress/cancel. recognize(_:) fails until runtime dependencies exist.
    public init() {
        registry = nil; pipeline = nil; client = nil; mediaFactory = nil
        clearMediaSession = { _ in }; closeMediaResources = {}
        scenarioPersistence = nil; persistence = nil; limiter = RecognitionLimiter()
        settings = .init(); clock = SystemProviderClock(); workflowConfiguration = { .init() }
    }

    public init(
        registry: ProviderRegistry,
        client: ProviderRecognitionClient,
        mediaFactory: @escaping MediaFactory,
        clearMediaSession: @escaping @Sendable (String) async -> Void = { _ in },
        closeMediaResources: @escaping @Sendable () async -> Void = {},
        scenarioPersistence: (any ScenarioMatchingPersistence)? = nil,
        persistence: (any RecognitionPersistence)? = nil,
        settings: GlobalSettingValues = .init(),
        limiter: RecognitionLimiter? = nil,
        clock: any ProviderClock = SystemProviderClock(),
        workflowConfiguration: @escaping @Sendable () async throws -> WorkflowConfig = { .init() }
    ) {
        self.registry = registry; self.client = client
        pipeline = RecognitionPagePipeline(client: client); self.mediaFactory = mediaFactory
        self.clearMediaSession = clearMediaSession; self.closeMediaResources = closeMediaResources
        self.scenarioPersistence = scenarioPersistence; self.persistence = persistence
        self.settings = settings
        self.limiter = limiter ?? RecognitionLimiter(limit: RecognitionRuntimeOptions.globalConcurrency(settings[.maxConcurrentRecognitions]))
        self.clock = clock
        self.workflowConfiguration = workflowConfiguration
    }

    public func progress(for projectID: String) -> AsyncStream<RecognitionProgress> {
        let observerID = UUID()
        return AsyncStream { continuation in
            observers[projectID, default: [:]][observerID] = continuation
            continuation.onTermination = { @Sendable [weak self] _ in
                Task { await self?.removeObserver(projectID: projectID, id: observerID) }
            }
        }
    }

    public func recognize(_ request: NativeRecognitionRequest) async throws -> RecognitionData {
        guard !closed else { throw RecognitionFailure.closed }
        guard !request.projectID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let registry, let pipeline, let mediaFactory else {
            throw SlateSyncError(code: "RECOGNITION_CONFIGURATION", message: "识别运行时尚未配置", status: 500)
        }
        let id = UUID()
        let scenarioPersistence = scenarioPersistence, persistence = persistence
        let settings = settings, clock = clock, workflowConfiguration = workflowConfiguration
        let failoverState = failoverState, recoveryCache = recoveryCache, limiter = limiter
        let coordinator = self
        let task = Task<RecognitionData, Error> {
            do {
                try await limiter.acquireQueued(id)
                let result = try await Self.perform(
                    request: request, operationID: id, registry: registry,
                    pipeline: pipeline, media: mediaFactory(),
                    scenarioPersistence: scenarioPersistence, persistence: persistence,
                    settings: settings, workflowConfiguration: workflowConfiguration, clock: clock, failoverState: failoverState,
                    recoveryCache: recoveryCache,
                    publish: { event in await coordinator.publish(operationID: id, projectID: request.projectID, event: event) }
                )
                await coordinator.finishOperation(id)
                return result
            } catch is CancellationError {
                await coordinator.finishOperation(id)
                throw RecognitionFailure.canceled
            } catch {
                await coordinator.finishOperation(id)
                throw error
            }
        }
        operations[id] = .init(projectID: request.projectID, task: task)
        lastPercent[id] = 0
        return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }

    public func cancel(projectID: String) async { _ = await cancelAndWait(projectID: projectID) }

    @discardableResult
    public func cancelAndWait(projectID: String) async -> Bool {
        let values = operations.values.filter { $0.projectID == projectID }
        guard !values.isEmpty else { await clearMediaSession(projectID); return false }
        values.forEach { $0.task.cancel() }
        for value in values { _ = try? await value.task.value }
        await clearMediaSession(projectID)
        broadcast(projectID: projectID, .init(phase: "canceled", completed: 0, total: 0, message: "识别已停止", percent: 100))
        return true
    }

    public func close() async {
        if let closeTask { await closeTask.value; return }
        closed = true
        let tasks = operations.values.map(\.task), client = client, recoveryCache = recoveryCache, closeMediaResources = closeMediaResources
        let task = Task {
            tasks.forEach { $0.cancel() }
            for value in tasks { _ = try? await value.value }
            if let client { await client.close() }
            await closeMediaResources()
            await recoveryCache.clearAll()
        }
        closeTask = task
        await task.value
        for (_, values) in observers { values.values.forEach { $0.finish() } }
        observers.removeAll(); operations.removeAll(); lastPercent.removeAll()
    }

    public func activeOperationCount() -> Int { operations.count }
    public func observerCount() -> Int { observers.values.reduce(0) { $0 + $1.count } }

    private func publish(operationID: UUID, projectID: String, event: RecognitionProgress) {
        guard operations[operationID] != nil, !closed else { return }
        let requested = event.percent ?? lastPercent[operationID] ?? 0
        let percent = min(100, max(lastPercent[operationID] ?? 0, requested))
        lastPercent[operationID] = percent
        broadcast(projectID: projectID, .init(phase: event.phase, completed: event.completed, total: event.total, message: event.message, percent: percent, pageNumber: event.pageNumber, warning: event.warning))
    }

    private func broadcast(projectID: String, _ event: RecognitionProgress) {
        observers[projectID]?.values.forEach { $0.yield(event) }
    }

    private func finishOperation(_ id: UUID) async {
        operations.removeValue(forKey: id); lastPercent.removeValue(forKey: id)
        await limiter.release(id)
        if operations.isEmpty { await failoverState.reset() }
    }

    private func removeObserver(projectID: String, id: UUID) {
        observers[projectID]?.removeValue(forKey: id)
        if observers[projectID]?.isEmpty == true { observers.removeValue(forKey: projectID) }
    }

    private nonisolated static func perform(
        request: NativeRecognitionRequest,
        operationID: UUID,
        registry: ProviderRegistry,
        pipeline: RecognitionPagePipeline,
        media: MediaOCRWorkflow,
        scenarioPersistence: (any ScenarioMatchingPersistence)?,
        persistence: (any RecognitionPersistence)?,
        settings globalSettings: GlobalSettingValues,
        workflowConfiguration: @Sendable () async throws -> WorkflowConfig,
        clock: any ProviderClock,
        failoverState: RecognitionFailoverState,
        recoveryCache: RecognitionRecoveryCache,
        publish: @escaping @Sendable (RecognitionProgress) async -> Void
    ) async throws -> RecognitionData {
        let started = clock.nowMilliseconds()
        do {
            try Task.checkCancellation()
            await publish(.init(phase: "starting", completed: 0, total: 0, message: "正在准备识别", percent: 0))
            let project = try await persistence?.recognitionProject(projectID: request.projectID)
            try Task.checkCancellation()
            // Reload content at operation admission; its path remains frozen
            // for this process. Invalid first reads fail before external work.
            let workflow = try await workflowConfiguration()
            let projectSettings = request.settings ?? project?.settings ?? .init(resolve: workflow.resolve)
            let selected = try RecognitionRouteResolver.resolve(
                request: try pair(request.providerID, request.modelID),
                project: try pair(projectSettings.providerId, projectSettings.modelId),
                global: globalSettings
            )
            let providerID = selected.providerID, modelID = selected.modelID
            let provider = try await registry.descriptor(providerID: providerID)
            let model = try await registry.resolveModel(providerID: providerID, modelID: modelID)
            let backups = try ProviderModelSelection.decodeAndValidateChain(
                nonempty(globalSettings[.recognitionFailoverChain]) ?? "[]"
            )
            if (!backups.isEmpty || nonempty(globalSettings[.defaultProviderID]) != nil),
               model.capabilityStatus != .verified {
                throw SlateSyncError(code: "MODEL_NOT_VERIFIED", message: "所选模型尚未在当前配置下验证", status: 400)
            }
            let candidates = FailoverChain.plan(primary: selected, chain: backups)
            let accuracy = projectSettings.accuracyMode
            let artifact: MediaOCRArtifact
            do {
                artifact = try await media.run(
                    input: request.input, session: request.projectID,
                    accuracy: accuracy == .high ? .high : .standard,
                    cacheEnabled: request.cacheEnabled, legacyRequest: request.legacyRequest,
                    progress: { mediaProgress in
                        let percent = min(35, mediaProgress.total > 0 ? (mediaProgress.completed * 35 / mediaProgress.total) : 0)
                        Task {
                            await publish(.init(
                                phase: "ocr", completed: mediaProgress.completed,
                                total: mediaProgress.total, message: "正在进行本地 OCR",
                                percent: percent
                            ))
                        }
                    },
                    preparedDocument: request.preparedDocument
                )
            } catch { await media.close(); throw error }
            try Task.checkCancellation()
            let structureStarted = clock.nowMilliseconds()
            let scenario = try await scenarioSelection(explicitID: projectSettings.scenarioId, projectID: request.projectID, artifact: artifact, resolve: projectSettings.resolve, matching: workflow.scenario.matching, persistence: scenarioPersistence)
            try Task.checkCancellation()
            let engine = ScenarioProfileEngine()
            var pageInstructions: [Int: String] = [:]
            for (page, profile) in scenario.profiles { pageInstructions[page] = await engine.promptInstruction(profile) }
            let prompts = (
                primary: RecognitionPrompts.compose(base: RecognitionPrompts.system, customPrompt: projectSettings.customPrompt, slateCSV: request.slateCSVRecords, fieldFormats: projectSettings.resolve.fieldFormats, comments: projectSettings.resolve.comments),
                audit: RecognitionPrompts.compose(base: RecognitionPrompts.audit, customPrompt: projectSettings.customPrompt, slateCSV: request.slateCSVRecords, fieldFormats: projectSettings.resolve.fieldFormats, comments: projectSettings.resolve.comments),
                review: RecognitionPrompts.compose(base: RecognitionPrompts.review, customPrompt: projectSettings.customPrompt, slateCSV: request.slateCSVRecords, fieldFormats: projectSettings.resolve.fieldFormats, comments: projectSettings.resolve.comments)
            )
            let pages = artifact.document.pages.map { page -> RecognitionPageInput in
                let evidence = artifact.evidence.indices.contains(page.pageNumber - 1) ? artifact.evidence[page.pageNumber - 1] : ""
                let core = artifact.coreEvidence.indices.contains(page.pageNumber - 1) ? artifact.coreEvidence[page.pageNumber - 1] : ""
                return .init(pageNumber: page.pageNumber, views: page.views, fullOCREvidence: evidence, coreOCREvidence: core,
                             scenarioInstruction: pageInstructions[page.pageNumber] ?? "",
                             layoutInstruction: artifact.optimization?.instruction(pageNumber: page.pageNumber) ?? "",
                             optimizationIdentity: artifact.optimization?.identity ?? "",
                             reviewImageProvider: artifact.optimization?.reviewProvider(page: page,
                                fullEvidence: artifact.outcome.result?.pages.first(where: { $0.pageNumber == page.pageNumber })?.views.first,
                                originalEvidence: core))
            }
            let modelStarted = clock.nowMilliseconds()
            let output = try await pipeline.run(
                pages: pages, provider: provider, model: model, accuracy: accuracy,
                formats: projectSettings.resolve.fieldFormats, prompts: prompts,
                pageConcurrency: RecognitionRuntimeOptions.pageConcurrency(globalSettings[.modelPageConcurrency]),
                timeoutMilliseconds: RecognitionRuntimeOptions.timeoutMilliseconds(globalSettings[.modelRequestTimeoutMS]),
                maximumTimeoutRetries: RecognitionRuntimeOptions.maximumTimeoutRetries(globalSettings[.modelRequestMaxRetries]),
                maximumRequestBytes: request.maximumRequestBytes,
                filename: request.filename, progress: { event in Task { await publish(event) } },
                candidates: candidates, registry: registry, failoverState: failoverState,
                recoveryCache: recoveryCache,
                recoveryID: request.taskID.map { "\(request.projectID):\($0)" }
            )
            var stageDurations = artifact.stageDurationsMs
            stageDurations["structure"] = max(0, Int(modelStarted - structureStarted))
            stageDurations["model"] = max(0, Int(clock.nowMilliseconds() - modelStarted))
            await media.close()
            try Task.checkCancellation()
            await publish(.init(phase: "merge", completed: pages.count, total: pages.count, message: "正在合并逐页结果并检查场、镜、次连续性", percent: 97))
            var warnings = output.result.warnings
            warnings += artifact.optimization?.diagnostics ?? []
            if let warning = artifact.summary.warning { warnings.insert(warning, at: 0) }
            if let warning = scenario.selection?.warning { warnings.append(warning) }
            var sheet = RecognitionSheet(sheetTitle: output.result.sheetTitle, records: output.result.records, warnings: warnings)
            let duration = max(0, Int((clock.nowMilliseconds() - started).rounded()))
            let ocr = publicOCR(artifact.summary)
            let defaults = RecognitionDefaults(providerId: providerID, modelId: model.publicID, customPrompt: projectSettings.customPrompt)
            var diagnosticID: String?, taskID: String?
            if let persistence {
                let diagnostic = RecognitionDiagnostic(provider: providerID, model: model.publicID, pageCount: pages.count, recordCount: sheet.records.count, durationMs: duration, stageCount: output.stageCount, ocr: ocr, warningCount: warnings.count, error: nil,
                    scenarioPages: scenario.decisions, stageDurationsMs: stageDurations)
                diagnosticID = try await persistence.saveDiagnostic(projectID: request.projectID, sessionID: nil, payload: try JSONEncoder().encode(diagnostic))
                try Task.checkCancellation()
                let savedSheet = persisted(sheet)
                let task = TaskData(projectId: request.projectID, projectSettingsSnapshot: projectSettings, status: "completed", filename: request.filename, pageCount: pages.count, scenarioId: scenario.selection?.id, scenarioMatch: scenario.selection?.match, scenarioFingerprint: scenario.selection?.fingerprint, provider: providerID, model: model.publicID, customPrompt: projectSettings.customPrompt, accuracyMode: accuracy, result: savedSheet, usage: output.usage, durationMs: duration, ocrSummary: ocr, diagnosticSessionId: diagnosticID, editedRecords: savedSheet.records)
                taskID = try await persistence.saveTask(projectID: request.projectID, taskID: request.taskID, payload: try JSONEncoder().encode(task))
                try Task.checkCancellation()
                try await persistence.touchRecognitionActivity(projectID: request.projectID)
            }
            try Task.checkCancellation()
            // Learning is auxiliary and starts only after recognition/task save
            // succeeded. No candidate becomes a formal template automatically.
            if let scenarioPersistence {
                for decision in scenario.decisions {
                    guard !Task.isCancelled, let digest = artifact.sourceDigests[decision.pageNumber] else { break }
                    do {
                        try await scenarioPersistence.saveScenarioObservation(projectID: request.projectID,
                            observation: .init(sourceDigest: digest, decision: decision))
                    } catch {
                        let warning = "识别结果已完成，场记版式观察未保存"
                        if !sheet.warnings.contains(warning) {
                            sheet = .init(sheetTitle: sheet.sheetTitle, records: sheet.records, warnings: sheet.warnings + [warning])
                        }
                        await publish(.init(phase: "scenario", completed: pages.count, total: pages.count,
                            message: warning, warning: StructuredLogRedactor.redactText(error.localizedDescription)))
                    }
                }
            }
            await publish(.init(phase: "complete", completed: pages.count, total: pages.count, message: "识别完成，共 \(sheet.records.count) 条记录", percent: 100))
            // Persist the recognition-stage detector output so later export
            // stages can dedupe by the stable `type:key` identity instead of
            // reporting the same anomaly twice.
            let sequenceAnomalies = (try? SequenceAnomalyDetector.detect(sheet.records.map(SequenceAnomalyDetector.Input.init))) ?? []
            return RecognitionData(provider: providerID, model: model.publicID, durationMs: duration, pageCount: pages.count, accuracyMode: accuracy, usage: output.usage, ocr: ocr, scenario: scenario.selection, result: sheet, sequenceAnomalies: sequenceAnomalies, projectId: request.projectID, projectSettingsSnapshot: projectSettings, lastRecognitionDefaults: defaults, diagnosticSessionId: diagnosticID, taskId: taskID)
        } catch is CancellationError {
            await media.close(); throw RecognitionFailure.canceled
        } catch let error as SlateSyncError {
            await media.close()
            if error.code == RecognitionFailure.canceled.code { throw RecognitionFailure.canceled }
            if let persistence {
                let diagnostic = RecognitionDiagnostic(provider: nil, model: nil, pageCount: 0, recordCount: 0, durationMs: max(0, Int((clock.nowMilliseconds() - started).rounded())), stageCount: 0, ocr: nil, warningCount: 0, error: error, scenarioPages: nil, stageDurationsMs: nil)
                _ = try? await persistence.saveDiagnostic(projectID: request.projectID, sessionID: nil, payload: JSONEncoder().encode(diagnostic))
            }
            throw error
        } catch {
            await media.close(); throw SlateSyncError.wrapped(error)
        }
    }

    private nonisolated static func scenarioSelection(explicitID: String?, projectID: String, artifact: MediaOCRArtifact, resolve: ProjectSettings.ResolveSettings, matching: ScenarioMatchingConfig, persistence: (any ScenarioMatchingPersistence)?) async throws -> (profiles: [Int: ScenarioProfile], selection: ScenarioSelection?, decisions: [ScenarioPageDecision]) {
        guard let persistence else { return ([:], nil, []) }
        if let explicitID = nonempty(explicitID) {
            do {
                let data = try await persistence.loadScenario(projectID: projectID, scenarioID: explicitID)
                let profile = try await ScenarioProfileEngine().normalize(data.profile)
                return (Dictionary(uniqueKeysWithValues: artifact.document.pages.map { ($0.pageNumber, profile) }),
                        .init(id: data.id, match: "selected", score: 1, fingerprint: data.fingerprint), [])
            } catch is CancellationError { throw RecognitionFailure.canceled }
            catch let error as SlateSyncError where error.code != "ENOENT" { throw error }
            catch { throw SlateSyncError(code: "SCENARIO_NOT_FOUND", message: "场记结构不存在", status: 400) }
        }
        guard artifact.outcome.result?.blockCount ?? 0 > 0 else { return ([:], .init(match: "fallback", score: 0, warning: "本次没有可用 OCR 结构证据，未自动匹配场记结构。"), []) }
        do {
            let service = ScenarioMatchingService(projectID: projectID, persistence: persistence)
            let decisions = try await service.evaluate(input: artifact.observation, resolve: resolve, matching: matching)
            var profiles: [Int: ScenarioProfile] = [:]
            for decision in decisions {
                if let data = decision.profile {
                    profiles[decision.pageNumber] = .init(schemaVersion: data.schemaVersion, fingerprintVersion: data.fingerprintVersion,
                        fingerprint: data.fingerprint, label: data.label, layout: data.layout, fields: data.fields,
                        recognition: data.recognition, output: data.output, structure: decision.candidate?.structure ?? data.structure)
                } else if decision.status == .candidate { profiles[decision.pageNumber] = decision.candidate }
            }
            let statuses = Set(decisions.map(\.status))
            let allReused = !decisions.isEmpty && decisions.allSatisfy { $0.status == .reused }
            let ids = Set(decisions.compactMap { $0.profile?.id })
            let shared = allReused && ids.count == 1 ? decisions.first?.profile : nil
            let warning: String?
            if allReused { warning = nil }
            else if decisions.contains(where: { $0.candidate != nil && $0.status != .reused }) {
                warning = "部分页面版式尚未确认，已使用当前页面证据识别；新版式可在项目设置中确认，不会自动新增正式模板。"
            } else {
                warning = "部分页面缺少可靠表头，已使用当前页面证据继续识别，未创建版式候选。"
            }
            return (profiles, .init(id: shared?.id, match: statuses.count == 1 ? (statuses.first?.rawValue ?? "insufficient") : "mixed",
                score: allReused ? (decisions.compactMap(\.score).min() ?? 0) : 0, fingerprint: shared?.fingerprint, warning: warning), decisions)
        } catch {
            if error is CancellationError { throw error }
            return ([:], .init(match: "fallback", score: 0, warning: "场记结构学习失败，已继续使用默认规则：\(StructuredLogRedactor.redactText(error.localizedDescription))"), [])
        }
    }

    private nonisolated static func publicOCR(_ value: OCRSummary) -> OcrSummary {
        .init(enabled: value.enabled, available: value.available, used: value.used, cacheHit: value.cacheHit, engine: value.engine?.rawValue ?? "disabled", model: value.model, profile: value.profile, profileLabel: value.profileLabel, detectionModel: value.detectionModel, recognitionModel: value.recognitionModel, recognitionBatchSize: value.recognitionBatchSize, device: value.device, pageCount: value.pageCount, viewCount: value.viewCount, blockCount: value.blockCount, lowConfidenceBlockCount: value.lowConfidenceBlockCount, durationMs: value.durationMs, warning: value.warning)
    }

    private nonisolated static func persisted(_ sheet: RecognitionSheet) -> PersistedRecognitionSheet {
        .init(sheetTitle: sheet.sheetTitle, records: sheet.records.map { .init(id: $0.id, sourcePage: $0.sourcePage, cardNumber: $0.cardNumber, videoCode: $0.videoCode, scene: $0.scene, shot: $0.shot, take: $0.take, takeStatus: $0.takeStatus, description: $0.description, comments: $0.comments, shotSize: $0.shotSize, cameraPosition: $0.cameraPosition, confidence: $0.confidence, reviewRequiredFields: $0.reviewRequiredFields) }, warnings: sheet.warnings)
    }

    private nonisolated static func nonempty(_ value: String?) -> String? {
        guard let value else { return nil }; let text = value.trimmingCharacters(in: .whitespacesAndNewlines); return text.isEmpty ? nil : text
    }

    private nonisolated static func pair(_ provider: String?, _ model: String?) throws -> ProviderModelSelection? {
        let provider = nonempty(provider), model = nonempty(model)
        if provider == nil, model == nil { return nil }
        guard let provider, let model else { throw RecognitionFailure.providerNotConfigured }
        return .init(providerID: provider, modelID: model)
    }
}

private struct RecognitionDiagnostic: Codable, Sendable {
    let provider: String?
    let model: String?
    let pageCount: Int
    let recordCount: Int
    let durationMs: Int
    let stageCount: Int
    let ocr: OcrSummary?
    let warningCount: Int
    let error: SlateSyncError?
    let scenarioPages: [ScenarioPageDecision]?
    let stageDurationsMs: [String: Int]?
}

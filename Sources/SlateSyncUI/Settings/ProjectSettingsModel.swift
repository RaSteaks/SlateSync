import Observation
import SlateSyncDomain

// Product copy uses the shared launch language; user content stays verbatim.

/// Project-scoped settings draft. It never reads or writes provider
/// credentials; the immutable draft is committed by one atomic façade call.
@MainActor @Observable
public final class ProjectSettingsModel {
    public private(set) var project: ProjectData?
    public private(set) var operation: OperationState = .idle
    public private(set) var scenarios: [ScenarioSummary] = []
    public private(set) var scenarioCandidates: [ScenarioCandidate] = []
    public private(set) var scenarioOperation: OperationState = .idle
    public private(set) var scenarioMergePreview: ScenarioMergePreview?
    public private(set) var lastScenarioMerge: ScenarioMergeReceipt?
    public var name = ""
    public var description = ""
    public var settings = ProjectSettings()
    public var onSaved: (@MainActor (ProjectData) -> Void)?
    private let service: any ProjectLibraryWorkflowServing & ProjectContextWorkflowServing
    private var generation = 0
    private var mergeAdjustedSelection: ScenarioMergeReceipt?

    /// Project context is a required capability, including Scenario reads.
    public init(service: any ProjectLibraryWorkflowServing & ProjectContextWorkflowServing) { self.service = service }

    public func flushIfNeeded() async throws {
        guard !operation.isRunning, !scenarioOperation.isRunning else {
            throw SlateSyncError(code: "PROJECT_SETTINGS_BUSY", message: L10n.tr("项目设置正在读取或保存，请稍后重试"), retryable: true)
        }
        guard let project else { return }
        guard name != project.name || description != project.description || settings != project.settings else { return }
        await save()
        if case .failed(let error) = operation { throw error }
    }

    public func load(projectID: String?) async {
        // A same-project reappearance preserves its current settings draft.
        if projectID == project?.id { await refreshScenarios(); return }
        generation += 1
        project = nil
        scenarios = []; scenarioCandidates = []; scenarioOperation = .idle
        scenarioMergePreview = nil; lastScenarioMerge = nil
        mergeAdjustedSelection = nil
        guard let projectID else {
            project = nil
            return
        }
        let request = generation
        operation = .running(label: L10n.tr("正在读取项目设置…"))
        do {
            let value = try await service.project(id: projectID)
            guard generation == request else { return }
            project = value
            name = value.name
            description = value.description
            settings = value.settings
            operation = .idle
            await refreshScenarios()
        } catch {
            guard generation == request else { return }
            operation = .failed(ProductPrivacy.error(error))
        }
    }

    public func save() async {
        guard let project, !operation.isRunning, !scenarioOperation.isRunning else { return }
        let cleanedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanedName.isEmpty else {
            operation = .failed(.init(code: "PROJECT_NAME_REQUIRED", message: L10n.tr("项目名称不能为空")))
            return
        }
        let draft = settings
        let request = generation
        operation = .running(label: L10n.tr("正在保存…"))
        do {
            try draft.validate()
            let saved = try await service.updateProject(
                id: project.id,
                name: cleanedName,
                description: description,
                settings: draft
            )
            // A late save for project A must not replace project B's identity
            // while its visible draft is being edited.
            guard request == generation, self.project?.id == project.id else { return }
            self.project = saved
            onSaved?(saved)
            operation = .succeeded(message: L10n.tr("项目设置已保存"))
        } catch {
            guard request == generation, self.project?.id == project.id else { return }
            operation = .failed(ProductPrivacy.error(error))
        }
    }

    public func refreshScenarios() async {
        guard let project, !operation.isRunning, !scenarioOperation.isRunning else { return }
        let request = generation
        scenarioOperation = .running(label: L10n.tr("正在读取场记版式…"))
        do {
            guard try await loadScenarioValues(projectID: project.id, request: request) else { return }
            scenarioOperation = .idle
        } catch {
            guard generation == request, self.project?.id == project.id else { return }
            scenarioOperation = .failed(ProductPrivacy.error(error))
        }
    }

    public func confirmCandidate(_ candidate: ScenarioCandidate, label: String, existingProfileID: String?) async {
        guard let project, !operation.isRunning, !scenarioOperation.isRunning else { return }
        let request = generation
        scenarioOperation = .running(label: L10n.tr("正在确认场记版式…"))
        do {
            let saved = try await service.confirmScenarioCandidate(projectID: project.id, candidateID: candidate.id,
                label: label, existingProfileID: existingProfileID)
            guard generation == request, self.project?.id == project.id else { return }
            // Publish the committed profile without reloading unrelated settings
            // drafts. A refresh failure cannot turn a successful save into a retry.
            scenarios.removeAll { $0.id == saved.id }
            scenarios.append(.init(id: saved.id, label: saved.label, fingerprint: saved.fingerprint,
                fingerprintVersion: saved.fingerprintVersion, schemaVersion: saved.schemaVersion,
                sampleCount: saved.sampleCount, fieldCount: 10, createdAt: saved.createdAt,
                updatedAt: saved.updatedAt, lastUsedAt: saved.lastUsedAt))
            scenarioCandidates.removeAll { $0.profile.fingerprint == candidate.profile.fingerprint }
            scenarioOperation = .succeeded(message: L10n.tr("场记版式已确认"))
        } catch {
            guard generation == request, self.project?.id == project.id else { return }
            scenarioOperation = .failed(ProductPrivacy.error(error))
        }
    }

    public func clearScenarioMergePreview() { scenarioMergePreview = nil }

    public func previewScenarioMerge(sourceID: String, targetID: String) async {
        guard let project, !operation.isRunning, !scenarioOperation.isRunning else { return }
        let request = generation
        scenarioMergePreview = nil
        scenarioOperation = .running(label: L10n.tr("正在读取合并预览…"))
        do {
            let preview = try await service.previewScenarioMerge(projectID: project.id, sourceID: sourceID, targetID: targetID)
            guard generation == request, self.project?.id == project.id else { return }
            scenarioMergePreview = preview; scenarioOperation = .idle
        } catch {
            guard generation == request, self.project?.id == project.id else { return }
            scenarioOperation = .failed(ProductPrivacy.error(error))
        }
    }

    public func commitScenarioMerge() async {
        guard let project, let preview = scenarioMergePreview, !operation.isRunning, !scenarioOperation.isRunning else { return }
        let request = generation
        scenarioOperation = .running(label: L10n.tr("正在合并版式…"))
        do {
            let receipt = try await service.mergeScenarioProfiles(projectID: project.id, preview: preview)
            guard generation == request, self.project?.id == project.id else { return }
            lastScenarioMerge = receipt; scenarioMergePreview = nil
            scenarios.removeAll { $0.id == receipt.sourceID }
            if settings.scenarioId == receipt.sourceID {
                mergeAdjustedSelection = receipt
                settings.scenarioId = receipt.targetID
            } else { mergeAdjustedSelection = nil }
            do {
                guard try await loadScenarioValues(projectID: project.id, request: request) else { return }
                scenarioOperation = .succeeded(message: L10n.tr("版式已合并，可撤销"))
            } catch {
                guard generation == request else { return }
                scenarioOperation = .failed(.init(code: "SCENARIO_REFRESH", message: L10n.tr("操作已完成，列表刷新失败，请刷新版式列表")))
            }
        } catch {
            guard generation == request, self.project?.id == project.id else { return }
            scenarioOperation = .failed(ProductPrivacy.error(error))
        }
    }

    public func undoScenarioMerge() async {
        guard let project, let receipt = lastScenarioMerge, !operation.isRunning, !scenarioOperation.isRunning else { return }
        let request = generation
        scenarioOperation = .running(label: L10n.tr("正在撤销版式合并…"))
        do {
            try await service.undoScenarioMerge(projectID: project.id, receiptID: receipt.id)
            guard generation == request, self.project?.id == project.id else { return }
            lastScenarioMerge = nil; scenarioMergePreview = nil
            if mergeAdjustedSelection?.id == receipt.id, settings.scenarioId == receipt.targetID {
                settings.scenarioId = receipt.sourceID
            }
            mergeAdjustedSelection = nil
            do {
                guard try await loadScenarioValues(projectID: project.id, request: request) else { return }
                scenarioOperation = .succeeded(message: L10n.tr("版式合并已撤销"))
            } catch {
                guard generation == request else { return }
                scenarioOperation = .failed(.init(code: "SCENARIO_REFRESH", message: L10n.tr("操作已完成，列表刷新失败，请刷新版式列表")))
            }
        } catch {
            guard generation == request, self.project?.id == project.id else { return }
            scenarioOperation = .failed(ProductPrivacy.error(error))
        }
    }

    private func loadScenarioValues(projectID: String, request: Int) async throws -> Bool {
        let profiles = try await service.listScenarios(projectID: projectID)
        let candidates = try await service.listScenarioCandidates(projectID: projectID)
        let receipt = try await service.latestScenarioMerge(projectID: projectID)
        guard generation == request, project?.id == projectID else { return false }
        scenarios = profiles; scenarioCandidates = candidates; lastScenarioMerge = receipt
        // Old saved selections continue to resolve through aliases; only this
        // draft's selection is canonicalized, never its other unsaved fields.
        if let selected = settings.scenarioId,
           let canonical = profiles.first(where: { $0.aliases?.contains(selected) == true }) {
            settings.scenarioId = canonical.id
        }
        return true
    }
}

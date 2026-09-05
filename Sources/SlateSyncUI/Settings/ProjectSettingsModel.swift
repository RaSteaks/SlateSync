import Observation
import SlateSyncDomain

/// Project-scoped settings draft. It never reads or writes provider
/// credentials; the immutable draft is committed by one atomic façade call.
@MainActor @Observable
public final class ProjectSettingsModel {
    public private(set) var project: ProjectData?
    public private(set) var operation: OperationState = .idle
    public private(set) var scenarios: [ScenarioSummary] = []
    public var name = ""
    public var description = ""
    public var settings = ProjectSettings()
    public var onSaved: (@MainActor (ProjectData) -> Void)?
    private let service: any ProjectLibraryWorkflowServing
    private var generation = 0

    public init(service: any ProjectLibraryWorkflowServing) { self.service = service }

    public func flushIfNeeded() async throws {
        guard !operation.isRunning else {
            throw SlateSyncError(code: "PROJECT_SETTINGS_BUSY", message: "项目设置正在读取或保存，请稍后重试", retryable: true)
        }
        guard let project else { return }
        guard name != project.name || description != project.description || settings != project.settings else { return }
        await save()
        if case .failed(let error) = operation { throw error }
    }

    public func load(projectID: String?) async {
        // A same-project reappearance preserves its current settings draft.
        guard projectID != project?.id else { return }
        generation += 1
        project = nil
        guard let projectID else {
            project = nil
            return
        }
        let request = generation
        operation = .running(label: "正在读取项目设置…")
        do {
            let value = try await service.project(id: projectID)
            let scenarios = try await (service as? any LocalSlateWorkflowServing)?.listScenarios(projectID: projectID) ?? []
            guard generation == request else { return }
            project = value
            self.scenarios = scenarios
            name = value.name
            description = value.description
            settings = value.settings
            operation = .idle
        } catch {
            guard generation == request else { return }
            operation = .failed(ProductPrivacy.error(error))
        }
    }

    public func save() async {
        guard let project, !operation.isRunning else { return }
        let cleanedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanedName.isEmpty else {
            operation = .failed(.init(code: "PROJECT_NAME_REQUIRED", message: "项目名称不能为空"))
            return
        }
        let draft = settings
        let request = generation
        operation = .running(label: "正在保存…")
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
            operation = .succeeded(message: "项目设置已保存")
        } catch {
            guard request == generation, self.project?.id == project.id else { return }
            operation = .failed(ProductPrivacy.error(error))
        }
    }
}

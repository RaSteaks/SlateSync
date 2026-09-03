import Observation
import SlateSyncDomain

@MainActor @Observable
public final class ProjectLibraryModel {
    public private(set) var library: LibraryInfo?
    public private(set) var projects: [ProjectSummary] = []
    public private(set) var isLoading = false
    public private(set) var error: SlateSyncError?
    public var createName = ""
    public var createDescription = ""
    public var showsCreateSheet = false

    private let service: any ProjectLibraryServing
    private var loadGeneration = 0

    public init(service: any ProjectLibraryServing) {
        self.service = service
    }

    public func load() async {
        loadGeneration += 1
        let generation = loadGeneration
        isLoading = true
        error = nil
        do {
            async let library = service.libraryInfo()
            async let projects = service.listProjects()
            let snapshot = try await (library, projects)
            guard generation == loadGeneration else { return }
            self.library = snapshot.0
            self.projects = snapshot.1
        } catch {
            guard generation == loadGeneration else { return }
            self.error = .wrapped(error)
        }
        if generation == loadGeneration { isLoading = false }
    }

    public func createProject() async -> ProjectSummary? {
        guard !createName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            error = .init(code: "PROJECT_NAME_REQUIRED", message: "请输入项目名称")
            return nil
        }
        isLoading = true
        error = nil
        do {
            let project = try await service.createProject(
                name: createName,
                description: createDescription
            )
            projects.insert(project.summary, at: 0)
            createName = ""
            createDescription = ""
            showsCreateSheet = false
            isLoading = false
            return project.summary
        } catch {
            self.error = .wrapped(error)
            isLoading = false
            return nil
        }
    }
}

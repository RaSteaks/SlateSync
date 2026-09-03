import SlateSyncDomain
import SlateSyncPersistence
import SlateSyncUI
import SwiftUI

@main
@MainActor
struct SlateSyncApp: App {
    @State private var navigation: AppNavigationModel
    @State private var projects: ProjectLibraryModel

    init() {
        let service: any ProjectLibraryServing
        do {
            service = try ProjectLibraryStore()
        } catch {
            // Keep the app debuggable when the data root cannot be opened; the
            // project-library screen will surface the actionable error.
            service = UnavailableProjectLibraryService(error: .wrapped(error))
        }
        _navigation = State(initialValue: AppNavigationModel())
        _projects = State(initialValue: ProjectLibraryModel(service: service))
    }

    var body: some Scene {
        WindowGroup("SlateSync") {
            AppRootView(navigation: navigation, projects: projects)
                .frame(minWidth: 960, minHeight: 600)
        }
        .defaultSize(width: 1440, height: 900)
        .commands {
            CommandGroup(after: .newItem) {
                Button("新建项目") {
                    navigation.selection = .projects
                    projects.showsCreateSheet = true
                }
                .keyboardShortcut("n", modifiers: .command)
            }
        }

        Settings {
            SettingsRootView()
        }
    }
}

private actor UnavailableProjectLibraryService: ProjectLibraryServing {
    private let error: SlateSyncError

    init(error: SlateSyncError) {
        self.error = error
    }

    func libraryInfo() async throws -> LibraryInfo { throw error }
    func listProjects() async throws -> [ProjectSummary] { throw error }
    func createProject(name: String, description: String) async throws -> ProjectData { throw error }
}

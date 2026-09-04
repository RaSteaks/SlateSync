import Foundation
import SlateSyncDomain
import SlateSyncPersistence
import SlateSyncUI
import SwiftUI

@main
@MainActor
struct SlateSyncApp: App {
    @State private var navigation: AppNavigationModel
    @State private var projects: ProjectLibraryModel
    @State private var runtimeModel: SlateSyncRuntimeModel

    init() {
        let locator: ApplicationSupportLocator
        if let resolved = try? ApplicationSupportLocator() {
            locator = resolved
        } else {
            // Keep the process launchable when Application Support is
            // temporarily unavailable; the settings status can still expose
            // the degraded bootstrap while no user directory is overwritten.
            locator = ApplicationSupportLocator(
                root: FileManager.default.temporaryDirectory
                    .appending(path: "SlateSync-unavailable-\(UUID().uuidString)", directoryHint: .isDirectory)
            )
        }

        let service: any ProjectLibraryServing
        do {
            service = try ProjectLibraryStore(applicationSupportRoot: locator.url)
        } catch {
            // Keep the app debuggable when the data root cannot be opened; the
            // project-library screen will surface the actionable error.
            service = UnavailableProjectLibraryService(error: .wrapped(error))
        }
        let runtime = SlateSyncRuntime(locator: locator)
        _navigation = State(initialValue: AppNavigationModel())
        _projects = State(initialValue: ProjectLibraryModel(service: service))
        _runtimeModel = State(initialValue: SlateSyncRuntimeModel(runtime: runtime))
    }

    var body: some Scene {
        WindowGroup("SlateSync") {
            AppRootView(navigation: navigation, projects: projects)
                .frame(minWidth: 960, minHeight: 600)
                .task {
                    await runtimeModel.bootstrap()
                }
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
            SettingsRootView(runtimeModel: runtimeModel)
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

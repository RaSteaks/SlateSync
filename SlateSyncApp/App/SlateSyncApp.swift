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
        let usesDegradedRoot: Bool
        if let resolved = try? ApplicationSupportLocator() {
            locator = resolved
            usesDegradedRoot = false
        } else {
            // Keep the process launchable when Application Support is
            // temporarily unavailable; the settings status can still expose
            // the degraded bootstrap while no user directory is overwritten.
            locator = ApplicationSupportLocator(
                root: FileManager.default.temporaryDirectory
                    .appending(path: "SlateSync-unavailable-\(UUID().uuidString)", directoryHint: .isDirectory)
            )
            usesDegradedRoot = true
        }

        let runtime = SlateSyncRuntime(locator: locator)
        // The service resolves settings.json.libraryPath on first use. A
        // successful Library activation therefore takes effect after relaunch,
        // while UI tests and degraded startup remain inside their own root.
        let service = ProjectLibraryStartupService(
            locator: locator,
            machineSettings: runtime.machineSettingsStore,
            forceIsolatedRoot: usesDegradedRoot
        )
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

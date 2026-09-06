import SlateSyncDomain
import SwiftUI

public struct AppRootView: View {
    @AppStorage("appearance") private var appearance = "system"
    @AppStorage("density") private var density = "comfortable"
    @Bindable private var session: AppSessionModel
    @Bindable private var projects: ProjectLibraryModel
    private let workspace: WorkspaceModel
    private let recognition: RecognitionModel
    private let csv: ResolveCSVModel
    private let metadata: MetadataScanModel
    private let media: MediaInputModel
    private let projectSettings: ProjectSettingsModel
    private let logs: LogsModel
    private let help: HelpModel
    private let termination: TerminationCoordinator
    private let settingsRevision: Int

    public init(
        session: AppSessionModel,
        projects: ProjectLibraryModel,
        workspace: WorkspaceModel,
        recognition: RecognitionModel,
        csv: ResolveCSVModel,
        metadata: MetadataScanModel,
        media: MediaInputModel,
        projectSettings: ProjectSettingsModel,
        logs: LogsModel,
        help: HelpModel,
        termination: TerminationCoordinator,
        settingsRevision: Int = 0
    ) {
        self.session = session
        self.projects = projects
        self.workspace = workspace
        self.recognition = recognition
        self.csv = csv
        self.metadata = metadata
        self.media = media
        self.projectSettings = projectSettings
        self.logs = logs
        self.help = help
        self.termination = termination
        self.settingsRevision = settingsRevision
    }

    public var body: some View {
        NavigationSplitView {
            SidebarView(selection: routeBinding)
                .navigationSplitViewColumnWidth(min: 190, ideal: 230, max: 280)
        } detail: {
            detail
        }
        .tint(SlateSyncTheme.accent)
        .preferredColorScheme(appearance == "dark" ? .dark : appearance == "light" ? .light : nil)
        .controlSize(density == "compact" ? .small : .regular)
        .safeAreaInset(edge: .top) { sessionError }
        .focusedSceneValue(\.slateSyncActions, focusedActions)
        .disabled(termination.isDraining || termination.isMutatingLibrary || termination.restartRequired || workspace.isTransitioning)
        .safeAreaInset(edge: .bottom) {
            if termination.restartRequired { Text("项目库已更新，请退出并重新打开 SlateSync。").padding(12) }
            // Recognition remains window-owned across Library/Logs/Help routes.
            // Its status and recovery message must not disappear with a tab.
            if recognition.operation.isRunning {
                HStack { ProgressView().controlSize(.small); Text(recognition.progress?.message ?? "正在处理场记…"); Spacer(); Button("取消") { recognition.cancel() } }.padding(10)
            } else if case .failed(let error) = recognition.operation {
                Label(error.message, systemImage: "exclamationmark.triangle").padding(10)
            } else if case .succeeded(let message) = recognition.operation {
                Text(message).font(.caption).padding(8)
            }
        }
    }

    @ViewBuilder private var detail: some View {
        switch session.route {
        case .projects:
            ProjectLibraryView(
                model: projects,
                onOpen: { project in Task { await session.openProject(project) } },
                onSettings: { project in Task { await session.showProjectSettings(project) } }
            )
        case .workspace:
            WorkspaceView(
                workspace: workspace,
                recognition: recognition,
                csv: csv,
                metadata: metadata,
                media: media,
                settingsRevision: settingsRevision
            )
        case .projectSettings:
            ProjectSettingsView(
                model: projectSettings,
                recognition: recognition,
                projectID: session.projectID,
                settingsRevision: settingsRevision
            )
        case .logs:
            LogsView(model: logs, recognition: recognition)
        case .help:
            HelpView(model: help)
        }
    }

    private var routeBinding: Binding<SidebarDestination> {
        Binding(
            get: { session.route },
            set: { destination in Task { await session.navigate(to: destination) } }
        )
    }

    private var focusedActions: SlateSyncFocusedActions {
        // Menu commands do not inherit the disabled state of the content
        // view. Withdraw their closures while an application barrier is held.
        if termination.isDraining || termination.isMutatingLibrary || termination.restartRequired || workspace.isTransitioning {
            return SlateSyncFocusedActions(newProject: nil, newTask: nil, save: nil, cancelRecognition: nil)
        }
        return SlateSyncFocusedActions(
            newProject: {
                Task {
                    await session.navigate(to: .projects)
                    if session.route == .projects { projects.showsCreateSheet = true }
                }
            },
            newTask: FocusedActionAvailability.permitsNewTask(
                route: session.route,
                projectID: session.projectID
            ) ? { Task { await workspace.createTask() } } : nil,
            save: session.route == .workspace ? { Task { try? await workspace.flush() } } : nil,
            cancelRecognition: recognition.operation.isRunning ? { recognition.cancel() } : nil
        )
    }

    @ViewBuilder private var sessionError: some View {
        if let error = session.navigationError {
            HStack {
                Label(error.message, systemImage: "exclamationmark.triangle")
                Spacer()
                Button("重试保存") { Task { await workspace.retryAutosave() } }
                Button("关闭") { session.clearError() }
            }
            .padding(10)
            .background(.bar)
            .accessibilityElement(children: .combine)
        } else if let error = termination.error {
            HStack {
                Label(error.message, systemImage: "exclamationmark.triangle")
                Spacer()
                // Close/quit failures include IME composition and Library
                // barriers; an autosave retry is not valid for those owners.
                Button("关闭") { termination.clearError() }
            }
            .padding(10)
            .background(.bar)
            .accessibilityElement(children: .combine)
        }
    }
}

import SlateSyncDomain
import SwiftUI

// Product copy uses the shared launch language; user content stays verbatim.

public struct AppRootView: View {
    // Each window starts with visible navigation, independent of AppKit's
    // saved split-view geometry from another project or test launch.
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var workspaceEntryPoint = WorkspaceEntryPoint.input
    // Completion events are observed at the window boundary so they remain
    // observable while WorkspaceView is replaced by another route. The task
    // key prevents a result dot from following a user into a different task.
    @State private var unseenSectionsByTask: [String: Set<WorkspaceSection>] = [:]
    @State private var activeWorkspaceSection = WorkspaceSection.input
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
    private let settingsNavigation: SettingsNavigationModel
    private let termination: TerminationCoordinator
    private let settingsRevision: Int
    private let globalSettings: GlobalSettingsModel?

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
        settingsNavigation: SettingsNavigationModel,
        termination: TerminationCoordinator,
        settingsRevision: Int = 0,
        globalSettings: GlobalSettingsModel? = nil
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
        self.settingsNavigation = settingsNavigation
        self.termination = termination
        self.settingsRevision = settingsRevision
        self.globalSettings = globalSettings
    }

    public var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            SidebarView(selection: routeBinding, currentProjectName: currentProjectName)
                .navigationSplitViewColumnWidth(min: 190, ideal: 230, max: 280)
        } detail: {
            detail
        }
        .tint(SlateSyncTheme.accent)
        .preferredColorScheme(appearance == "dark" ? .dark : appearance == "light" ? .light : nil)
        .controlSize(density == "compact" ? .small : .regular)
        // One scene-level preference drives native controls and content metrics.
        .environment(\.slateSyncDensity, SlateSyncDensity(rawValue: density) ?? .comfortable)
        .safeAreaInset(edge: .top) { sessionError }
        .focusedSceneValue(\.slateSyncActions, focusedActions)
        .disabled(termination.isDraining || termination.isMutatingLibrary || termination.restartRequired || workspace.isTransitioning || session.openingProjectName != nil)
        .overlay {
            // Attach to the entire split view so the panel is window-centered,
            // outside the disabled content, without resizing the project list.
            if let name = session.openingProjectName {
                ZStack {
                    Color.black.opacity(0.12).ignoresSafeArea()
                        .accessibilityHidden(true)
                    ProjectOpeningProgressPanel(
                        projectName: name,
                        stage: workspace.activationStage ?? L10n.tr("正在保存项目设置…")
                    )
                    .padding(24)
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            if termination.restartRequired { Text(L10n.tr("项目库已更新，请退出并重新打开 SlateSync。")).padding(12) }
            // Recognition remains window-owned across Library/Logs/Help routes.
            // Its status and recovery message must not disappear with a tab.
            if recognition.operation.isRunning {
                SlateStatusBar(message: recognition.progress?.message ?? L10n.tr("正在处理场记…"), busy: true) {
                    Button(L10n.tr("取消")) { recognition.cancel() }
                }
            } else if case .failed(let error) = recognition.operation {
                SlateStatusBar(message: error.message, tone: .error) {
                    SettingsLink { Text(L10n.tr("检查识别配置")) }
                }
            } else if case .succeeded(let message) = recognition.operation, canViewRecognitionResult {
                // Completion never steals focus or seizes the current page;
                // the status bar only offers the route to the new results.
                SlateStatusBar(message: message, tone: .success) {
                    Button(L10n.tr("查看识别结果")) {
                        workspaceEntryPoint = .result
                        if session.route != .workspace {
                            Task { await session.navigate(to: .workspace) }
                        }
                    }
                }
            } else if case .succeeded(let message) = recognition.operation {
                SlateStatusBar(message, tone: .success)
            }
        }
        .onChange(of: recognition.operation) { _, newValue in
            guard case .succeeded = newValue,
                  let taskID = recognition.resultTaskID,
                  taskID == session.taskID,
                  !recognition.editableRecords.isEmpty,
                  !(session.route == .workspace && activeWorkspaceSection == .result) else { return }
            markUnseen(.result, for: taskID)
        }
        .onChange(of: csv.operation) { _, newValue in
            guard case .succeeded = newValue,
                  let taskID = session.taskID,
                  !(session.route == .workspace && activeWorkspaceSection == .csv) else { return }
            markUnseen(.csv, for: taskID)
        }
        .onChange(of: session.projectID) { _, _ in
            // Task IDs are only meaningful inside their active project; drop
            // the old ledger when the window acquires a different project.
            unseenSectionsByTask.removeAll()
            activeWorkspaceSection = .input
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
                settingsRevision: settingsRevision,
                globalSettings: globalSettings,
                entryPoint: workspaceEntryPoint,
                unseenSections: unseenSectionsBinding,
                onSectionChanged: { activeWorkspaceSection = $0 },
                onEntryPointConsumed: { workspaceEntryPoint = .input }
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
            HelpView(
                model: help,
                settingsNavigation: settingsNavigation,
                hasProject: session.projectID != nil,
                hasTask: session.taskID != nil,
                onOpenProjectLibrary: { Task { await session.navigate(to: .projects) } },
                onOpenProjectSettings: { Task { await session.navigate(to: .projectSettings) } },
                onEnterCurrentTask: {
                    workspaceEntryPoint = .input
                    Task { await session.navigate(to: .workspace) }
                },
                onOpenLogs: { Task { await session.navigate(to: .logs) } },
                onOpenCSV: {
                    workspaceEntryPoint = .resolveCSV
                    Task { await session.navigate(to: .workspace) }
                }
            )
        }
    }

    private var routeBinding: Binding<SidebarDestination> {
        Binding(
            get: { session.route },
            set: { destination in Task { await session.navigate(to: destination) } }
        )
    }

    private var currentProjectName: String? {
        guard let projectID = session.projectID else { return nil }
        // A saved settings rename is newer than the library projection. The
        // ID guard prevents another project's retained draft from leaking into
        // the current window while its settings view is being replaced.
        if let project = projectSettings.project, project.id == projectID {
            return project.name
        }
        return (projects.activeProjects + projects.archivedProjects)
            .first(where: { $0.id == projectID })?.name
    }

    private var canViewRecognitionResult: Bool {
        guard let taskID = session.taskID else { return false }
        return recognition.resultTaskID == taskID && !recognition.editableRecords.isEmpty
    }

    private var unseenSectionsBinding: Binding<Set<WorkspaceSection>> {
        Binding(
            get: {
                guard let taskID = session.taskID else { return [] }
                return unseenSectionsByTask[taskID] ?? []
            },
            set: { value in
                guard let taskID = session.taskID else { return }
                if value.isEmpty {
                    unseenSectionsByTask.removeValue(forKey: taskID)
                } else {
                    unseenSectionsByTask[taskID] = value
                }
            })
    }

    private func markUnseen(_ section: WorkspaceSection, for taskID: String) {
        unseenSectionsByTask[taskID, default: []].insert(section)
    }

    private var focusedActions: SlateSyncFocusedActions {
        // Menu commands do not inherit the disabled state of the content
        // view. Withdraw their closures while an application barrier is held.
        if termination.isDraining || termination.isMutatingLibrary || termination.restartRequired || workspace.isTransitioning || session.openingProjectName != nil {
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
            SlateStatusBar(message: error.message, tone: .error) {
                Button(L10n.tr("重试保存")) { Task { await workspace.retryAutosave() } }
                Button(L10n.tr("关闭")) { session.clearError() }
            }
        } else if let error = termination.error {
            // Close/quit errors belong to termination, not to autosave retry.
            SlateStatusBar(message: error.message, tone: .error) {
                Button(L10n.tr("关闭")) { termination.clearError() }
            }
        }
    }
}

/// Stable, compact geometry keeps changing stage text from moving the dialog.
/// Indeterminate progress reports activity without inventing a percentage.
struct ProjectOpeningProgressPanel: View {
    let projectName: String
    let stage: String

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text(L10n.tr("正在打开项目")).font(.headline)
                Text(projectName).font(.subheadline).foregroundStyle(.secondary)
                    .lineLimit(1).help(projectName)
            }
            ProgressView().progressViewStyle(.linear)
                .accessibilityLabel(L10n.tr("正在打开项目"))
            Text(stage).font(.callout).foregroundStyle(.secondary)
                .lineLimit(2).frame(minHeight: 34, alignment: .topLeading)
        }
        .padding(24)
        .frame(maxWidth: 360, alignment: .leading)
        // Opening feedback is a transient floating panel; keep the dimming
        // scrim separate so the panel itself can sample the window content.
        .slateGlassSurface(.panel)
        .shadow(color: .black.opacity(0.15), radius: 20, y: 8)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("project.opening.progress")
    }
}

import AppKit
import Foundation
import SlateSyncDomain
import SlateSyncPersistence
import SlateSyncUI
import SlateSyncWorkflow
import SwiftUI

@main
@MainActor
struct SlateSyncApp: App {
    @NSApplicationDelegateAdaptor(SlateSyncAppDelegate.self) private var appDelegate
    private let workflow: SlateSyncWorkflowFacade
    @State private var globalSettings: GlobalSettingsModel
    @State private var paddleInstaller: PaddleInstallerModel
    @State private var termination: TerminationCoordinator
    private let projectOwnership = ProjectWindowOwnership()
    private let preferences: UserDefaults

    init() {
        let locator: ApplicationSupportLocator
        let usesDegradedRoot: Bool
        if let resolved = try? ApplicationSupportLocator() {
            locator = resolved
            usesDegradedRoot = false
        } else {
            // Keep launch recoverable if Application Support is unavailable;
            // the UUID root cannot collide with or overwrite user data.
            locator = ApplicationSupportLocator(
                root: FileManager.default.temporaryDirectory
                    .appending(path: "SlateSync-unavailable-\(UUID().uuidString)", directoryHint: .isDirectory)
            )
            usesDegradedRoot = true
        }

        // Explicit UI-test roots isolate every side effect, including secrets
        // and preferences; changing a filesystem path alone is insufficient.
        let isolated = usesDegradedRoot || ProcessInfo.processInfo.environment["SLATESYNC_TEST_ROOT"]?.isEmpty == false
        preferences = isolated ? UserDefaults(suiteName: "SlateSync.isolated.\(locator.url.lastPathComponent)")! : .standard
        let runtime = SlateSyncRuntime(
            locator: locator,
            environment: isolated ? [:] : ProcessInfo.processInfo.environment,
            keychainBackend: isolated ? IsolatedAppKeychain() : nil
        )
        let library = ProjectLibraryStartupService(
            locator: locator,
            machineSettings: runtime.machineSettingsStore,
            forceIsolatedRoot: usesDegradedRoot
        )
        let localLogs = LocalLogStore(
            directory: locator.url.appending(path: "logs", directoryHint: .isDirectory)
        )
        // Production installation accepts only the bundled pinned manifest.
        // A missing resource resolves to a nonexistent in-bundle path and the
        // installer fails closed instead of consulting the launch directory.
        let requirementsURL = Bundle.main.url(forResource: "requirements-ocr", withExtension: "txt")
            ?? Bundle.main.bundleURL.appending(path: "Contents/Resources/requirements-ocr.txt")
        let paddleInstaller = PaddleOCRInstallerService(
            userDataRoot: locator.url,
            requirementsURL: requirementsURL
        )
        // This façade is the only cross-layer composition boundary. Views and
        // feature models receive protocol surfaces and never open stores,
        // Keychain, OCR processes, or Provider transports themselves.
        let workflow = SlateSyncWorkflowFacade(
            library: library,
            runtime: runtime,
            logs: localLogs,
            paddleInstaller: paddleInstaller,
            allowsExternalOperations: !isolated
        )
        self.workflow = workflow
        _globalSettings = State(initialValue: GlobalSettingsModel(service: workflow))
        _paddleInstaller = State(initialValue: PaddleInstallerModel(service: workflow))
        _termination = State(initialValue: TerminationCoordinator(lifecycle: workflow))
    }

    var body: some Scene {
        WindowGroup("SlateSync", id: "main") {
            // Each WindowGroup content instance constructs an independent
            // AppSessionModel and focused feature models. Only the actor façade
            // and global Settings scene are shared across windows.
            SlateSyncWindowRoot(workflow: workflow, termination: termination, projectOwnership: projectOwnership)
                .defaultAppStorage(preferences)
                .frame(minWidth: 960, minHeight: 600)
                .task {
                    appDelegate.termination = termination
                    termination.applicationDrain = { [globalSettings, paddleInstaller] in
                        await globalSettings.drain()
                        await paddleInstaller.drain()
                    }
                }
        }
        .defaultSize(width: 1440, height: 900)
        .commands { SlateSyncCommands() }

        Settings {
            SettingsRootView(settings: globalSettings, paddleInstaller: paddleInstaller)
                .defaultAppStorage(preferences)
                .disabled(termination.isDraining || termination.isMutatingLibrary || termination.restartRequired)
        }
    }
}

/// Ephemeral credentials for explicitly isolated launches. This backend never
/// calls Security.framework or writes secret bytes to the fixture directory.
private actor IsolatedAppKeychain: KeychainBackend {
    private struct Item { let data: Data; let ownership: Data }
    private var items: [String: [String: Item]] = [:]
    func read(service: String, account: String) -> Data? { items[service]?[account]?.data }
    func write(_ data: Data, service: String, account: String) {
        items[service, default: [:]][account] = Item(data: data, ownership: Data(UUID().uuidString.utf8))
    }
    func createIfAbsent(_ data: Data, service: String, account: String) -> KeychainCreateResult {
        guard items[service]?[account] == nil else { return .alreadyExists }
        write(data, service: service, account: account)
        return .created(ownership: items[service]![account]!.ownership)
    }
    func delete(service: String, account: String) { items[service]?[account] = nil }
    func deleteIfMatching(_ expected: Data, service: String, account: String, ownership: Data?) -> KeychainConditionalDeleteResult {
        guard let item = items[service]?[account] else { return .notFound }
        guard item.data == expected, ownership == nil || ownership == item.ownership else { return .valueChanged }
        delete(service: service, account: account)
        return .removed
    }
}

@MainActor
private struct SlateSyncWindowRoot: View {
    private let termination: TerminationCoordinator
    @State private var windowID: UUID
    @State private var projects: ProjectLibraryModel
    @State private var workspace: WorkspaceModel
    @State private var recognition: RecognitionModel
    @State private var csv: ResolveCSVModel
    @State private var metadata: MetadataScanModel
    @State private var media: MediaInputModel
    @State private var projectSettings: ProjectSettingsModel
    @State private var logs: LogsModel
    @State private var help: HelpModel
    @State private var session: AppSessionModel

    init(workflow: SlateSyncWorkflowFacade, termination: TerminationCoordinator, projectOwnership: ProjectWindowOwnership) {
        self.termination = termination
        let windowID = UUID()
        _windowID = State(initialValue: windowID)
        let workspace = WorkspaceModel(service: workflow)
        workspace.acquireProject = { try projectOwnership.acquire(projectID: $0, windowID: windowID) }
        workspace.releaseProject = { projectOwnership.release(projectID: $0, windowID: windowID) }
        let recognition = RecognitionModel(service: workflow, settings: workflow)
        _projects = State(initialValue: ProjectLibraryModel(
            service: workflow,
            workspaceBarrier: { try await workspace.flush() }
        ))
        _workspace = State(initialValue: workspace)
        _recognition = State(initialValue: recognition)
        _csv = State(initialValue: ResolveCSVModel(service: workflow))
        _metadata = State(initialValue: MetadataScanModel(service: workflow))
        _media = State(initialValue: MediaInputModel(service: workflow))
        _projectSettings = State(initialValue: ProjectSettingsModel(service: workflow))
        _logs = State(initialValue: LogsModel(service: workflow))
        _help = State(initialValue: HelpModel())
        _session = State(initialValue: AppSessionModel(workspace: workspace))
    }

    var body: some View {
        AppRootView(
            session: session,
            projects: projects,
            workspace: workspace,
            recognition: recognition,
            csv: csv,
            metadata: metadata,
            media: media,
            projectSettings: projectSettings,
            logs: logs,
            help: help,
            termination: termination
        )
        .task {
            workspace.permitsNewOperation = { [weak termination] in
                guard let termination else { return false }
                return !termination.isDraining && !termination.isMutatingLibrary && !termination.restartRequired
            }
            workspace.didFailRuntimeClose = termination.requireRestart
            csv.permitsNewOperation = { [weak termination, weak recognition] in
                guard let termination, let recognition else { return false }
                return !recognition.operation.isRunning && !termination.isDraining && !termination.isMutatingLibrary && !termination.restartRequired
            }
            // Picker completions and drag/drop reach models independently of
            // Form.disabled, so every input owner shares the same admission.
            media.permitsNewOperation = csv.permitsNewOperation
            metadata.permitsNewOperation = csv.permitsNewOperation
            recognition.permitsNewOperation = { [weak termination, weak workspace] in
                guard let termination, let workspace else { return false }
                return !workspace.isTransitioning && !termination.isDraining &&
                    !termination.isMutatingLibrary && !termination.restartRequired
            }
            projects.mutationCoordinator = termination.performLibraryMutation
            projects.didChangeLibrary = { await termination.refreshProjects(activeIDs: $0) }
            projects.didRequireRestart = termination.requireRestart
            session.flushProjectSettings = { [weak projectSettings] in try await projectSettings?.flushIfNeeded() }
            workspace.flushEditor = { [weak csv, weak recognition] in
                try csv?.flushEditor?()
                try recognition?.flushEditor?()
            }
            csv.onTableChange = { [weak workspace] table, filename in workspace?.stageCSV(table, filename: filename) }
            media.onPrepared = { [weak workspace] document in workspace?.stageMedia(document) }
            metadata.onResult = { [weak workspace] result, name in workspace?.stageMetadata(result, directoryName: name) }
            projectSettings.onSaved = { [weak workspace] in workspace?.adoptProjectSettings($0) }
            // Selection callbacks run with publication, before a subsequent
            // file-import action can start; view onChange would race that work.
            workspace.didSelectTask = { [weak csv, weak recognition, weak media, weak metadata] task in
                csv?.load(task: task)
                recognition?.load(task: task)
                media?.load(task: task)
                metadata?.load(task: task)
            }
            workspace.prepareSelectionChange = { [weak recognition, weak metadata, weak media, weak csv] in
                await csv?.drain()
                await recognition?.drain()
                await metadata?.drain()
                await media?.drain()
            }
            recognition.didComplete = { [weak workspace] request, _ in
                // The coordinator persisted recognition first. Refresh that
                // exact task before another autosave can replace its result
                // with the pre-recognition draft snapshot.
                guard let workspace, workspace.projectID == request.projectID else { return }
                try await workspace.reloadTasks(selecting: request.taskID)
            }
            await termination.registerWindow(
                id: windowID,
                workspace: workspace,
                recognition: recognition,
                csv: csv,
                metadata: metadata,
                media: media,
                settings: projectSettings,
                refresh: { [weak workspace, weak session, weak projects] activeIDs in
                    if let id = workspace?.projectID, !activeIDs.contains(id) {
                        await workspace?.deactivate()
                        session?.reconcileClosedProject()
                    }
                    await projects?.load()
                }
            )
        }
        .background {
            // The adapter vetoes close before the view disappears. On failure
            // the registered window still owns its draft and can retry.
            WindowLifecycleBridge(close: {
                guard !termination.isDraining, !termination.isMutatingLibrary else {
                    throw SlateSyncError(code: "LIBRARY_BUSY", message: "项目库正在更新，请稍后关闭窗口", retryable: true)
                }
                try await projectSettings.flushIfNeeded()
                try await workspace.close()
                await csv.drain()
                logs.stopPolling()
                await termination.unregisterWindow(id: windowID)
            }, failure: termination.reportCloseFailure, visibility: logs.setWindowVisible)
                .frame(width: 0, height: 0)
        }
    }
}

/// Narrow AppKit lifecycle bridge. All business cleanup remains awaitable in
/// TerminationCoordinator; this adapter only translates the async result into
/// AppKit's terminate-later reply.
@MainActor
final class SlateSyncAppDelegate: NSObject, NSApplicationDelegate {
    weak var termination: TerminationCoordinator?
    private var isAwaitingTerminationReply = false

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // The WindowGroup installs its lifecycle owner asynchronously. An
        // unusually early Quit must fail closed instead of bypassing every
        // settings, installer, window and persistence drain.
        guard let termination else { return .terminateCancel }
        guard !isAwaitingTerminationReply else { return .terminateLater }
        // Quit does not pass through windowShouldClose. Commit every focused
        // native editor before any asynchronous store drain, respecting IME.
        for window in sender.windows {
            if let editor = window.firstResponder as? NSTextView, editor.hasMarkedText() {
                termination.reportCloseFailure(SlateSyncError(code: "EDIT_COMPOSITION", message: "请先完成当前文字输入，再退出"))
                return .terminateCancel
            }
            guard window.makeFirstResponder(nil) else { return .terminateCancel }
        }
        isAwaitingTerminationReply = true
        Task {
            let shouldTerminate = await termination.requestTermination()
            isAwaitingTerminationReply = false
            sender.reply(toApplicationShouldTerminate: shouldTerminate)
        }
        return .terminateLater
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(
        _ sender: NSApplication,
        hasVisibleWindows flag: Bool
    ) -> Bool {
        // Returning true lets SwiftUI's WindowGroup own window creation and
        // restoration rather than manufacturing NSWindow instances here.
        true
    }
}

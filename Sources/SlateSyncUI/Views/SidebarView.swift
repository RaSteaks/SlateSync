import AppKit
import SlateSyncDomain
import SwiftUI

// Product copy uses the shared launch language; user content stays verbatim.

/// One native source list: the library, the current project (its settings and
/// its tasks) and the support pages. Tasks live here rather than in a second
/// column, so a task is chosen exactly where the project is. There is no brand
/// header and no footer: Settings opens from ⌘, and appearance follows the
/// system unless overridden in Settings.
public struct SidebarView: View {
    // Use the native column's minimum for content as well: collapse/reveal
    // can temporarily propose less than that width to the hosting view.
    static let minimumColumnWidth: CGFloat = 190

    /// A sidebar row is either a destination or one of the project's tasks.
    private enum Item: Hashable {
        case destination(SidebarDestination)
        case task(String)
    }

    @Binding private var selection: SidebarDestination
    private let currentProjectName: String?
    private let workspace: WorkspaceModel?
    /// The task whose recognition is running, so its row shows activity from
    /// any page.
    private let runningTaskID: String?
    // Native List needs synchronous selection feedback while the workspace
    // retains its committed task until the editor barrier and load succeed.
    @State private var pendingItem: Item?
    @State private var pendingDeletion: String?

    public init(
        selection: Binding<SidebarDestination>,
        currentProjectName: String? = nil,
        workspace: WorkspaceModel? = nil,
        runningTaskID: String? = nil
    ) {
        _selection = selection
        self.currentProjectName = currentProjectName
        self.workspace = workspace
        self.runningTaskID = runningTaskID
    }

    /// Tasks exist only while a project is open and a workspace model is wired.
    private var taskModel: WorkspaceModel? {
        currentProjectName != nil ? workspace : nil
    }

    public var body: some View {
        List(selection: listSelection) {
            Section {
                sidebarRow(.projects)
            }
            // The project section exists only while a project is open; the
            // library screen has nothing of a project to show.
            if currentProjectName != nil {
                Section {
                    sidebarRow(.projectSettings)
                    taskRows
                } header: {
                    projectHeader
                }
            }
            Section(L10n.tr("支持")) {
                sidebarRow(.logs)
                sidebarRow(.help)
            }
        }
        .listStyle(.sidebar)
        // Icons stay monochrome; the accent belongs to the selection only.
        .listItemTint(.monochrome)
        .safeAreaInset(edge: .top, spacing: 0) {
            if let taskModel {
                SlateSearchField(
                    title: L10n.tr("搜索任务"), text: Bindable(taskModel).searchText,
                    identifier: "workspace.task.search")
                    .padding(.horizontal, 12).padding(.bottom, 6)
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if let taskModel {
                VStack(spacing: 0) {
                    if case .failed(let error) = taskModel.operation {
                        SlateStatusBar(error.message, tone: .error)
                    }
                    newTaskBar(taskModel)
                }
            }
        }
        // Keep inset text and native rows at a readable width while the
        // outer viewport follows AppKit down to zero. Without both frames,
        // insets wrap during reveal or their minimum pushes the detail pane.
        .frame(minWidth: Self.minimumColumnWidth, maxWidth: .infinity, alignment: .leading)
        .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
        .sidebarResizeBoundary()
        .navigationTitle("SlateSync")
        .confirmationDialog(
            L10n.tr("删除任务？"),
            isPresented: Binding(get: { pendingDeletion != nil }, set: { if !$0 { pendingDeletion = nil } }),
            titleVisibility: .visible
        ) {
            if let id = pendingDeletion, let taskModel {
                Button(L10n.tr("删除任务"), role: .destructive) {
                    Task { await taskModel.deleteTask(id: id) }
                    pendingDeletion = nil
                }
            }
            Button(L10n.tr("取消"), role: .cancel) { pendingDeletion = nil }
        } message: {
            Text(L10n.tr("任务的场记单与校对结果将被删除。"))
        }
        .accessibilityIdentifier("sidebar")
    }

    // MARK: Project section

    /// The project's own name titles its group. (New-task lives at the foot of
    /// the sidebar, away from the system's collapse chevron at this edge.) The
    /// header keeps one line at every reveal width so the list never shifts.
    private var projectHeader: some View {
        HStack(spacing: 8) {
            if let currentProjectName {
                Text(currentProjectName)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(currentProjectName)
                    .accessibilityLabel(L10n.tr("当前项目：{0}", [currentProjectName]))
                    .accessibilityIdentifier("sidebar.currentProjectName")
            }
            Spacer(minLength: 0)
        }
    }

    /// New-task action pinned to the foot of the sidebar. It answers the click
    /// immediately — the button turns into a spinner and is disabled — so a slow
    /// save never looks like a dead button that invites repeated clicks.
    private func newTaskBar(_ taskModel: WorkspaceModel) -> some View {
        HStack(spacing: 8) {
            Button {
                Task { await taskModel.createTask() }
            } label: {
                if taskModel.isCreatingTask {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text(L10n.tr("正在新建任务…"))
                    }
                } else {
                    Label(L10n.tr("新建任务"), systemImage: "plus")
                }
            }
            .buttonStyle(.borderless)
            .foregroundStyle(taskModel.isCreatingTask ? Color.secondary : Color.primary)
            .disabled(taskModel.isCreatingTask || taskModel.isTransitioning)
            .help(L10n.tr("新建任务"))
            .accessibilityIdentifier(AccessibilityID.taskCreate)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
    }

    /// Task rows come from the model's cached valid rows, so selection and
    /// progress updates never re-filter the whole list. With no tasks the
    /// workspace stays reachable through its own row (import creates a task).
    @ViewBuilder private var taskRows: some View {
        if let taskModel {
            if taskModel.tasks.isEmpty {
                if taskModel.isCreatingTask { creatingRow }
                else if !taskModel.operation.isRunning { sidebarRow(.workspace) }
            } else if !taskModel.searchText.isEmpty, taskModel.filteredTasks.isEmpty {
                Text(L10n.tr("无匹配任务")).foregroundStyle(.secondary)
            } else {
                ForEach(taskModel.selectableTasks, id: \.id) { task in
                    SidebarTaskRow(task: task, isRunning: task.id == runningTaskID)
                        .equatable()
                        .tag(Item.task(task.id!))
                        .contextMenu {
                            Button(L10n.tr("删除任务"), role: .destructive) {
                                pendingDeletion = task.id
                            }
                        }
                }
                if taskModel.isCreatingTask { creatingRow }
            }
        } else {
            sidebarRow(.workspace)
        }
    }

    /// Placeholder row shown the instant a task is being created.
    private var creatingRow: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text(L10n.tr("正在新建任务…")).foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: Selection

    private var listSelection: Binding<Item?> {
        Binding(
            get: {
                if let pendingItem { return pendingItem }
                if selection == .workspace, let id = taskModel?.selectedTaskID,
                   taskModel?.selectableTasks.contains(where: { $0.id == id }) == true {
                    return .task(id)
                }
                return .destination(selection)
            },
            set: { item in
                guard let item else { return }
                switch item {
                case .destination(let destination):
                    selection = destination
                case .task(let id):
                    guard let taskModel, pendingItem == nil, !taskModel.isTransitioning else { return }
                    guard id != taskModel.selectedTaskID || selection != .workspace else { return }
                    // Acknowledge the click before scheduling asynchronous
                    // work, and ignore native selection echoes while pending;
                    // otherwise the old committed ID can send the highlight
                    // back and forth.
                    pendingItem = item
                    Task {
                        defer { pendingItem = nil }
                        // A failed barrier is presented by WorkspaceModel.operation
                        // and leaves both the task and the route unchanged.
                        do {
                            if id != taskModel.selectedTaskID { try await taskModel.selectTask(id) }
                            selection = .workspace
                        } catch {}
                    }
                }
            }
        )
    }

    private func sidebarRow(_ destination: SidebarDestination) -> some View {
        // Icons stay neutral; the accent belongs to the selection only.
        Label {
            Text(destination.title)
        } icon: {
            Image(systemName: destination.symbol).foregroundStyle(.secondary)
        }
            .tag(Item.destination(destination))
            .accessibilityIdentifier("sidebar.\(destination.rawValue)")
    }
}

/// Row values change only when their task summary changes; selecting another
/// task does not require rebuilding all offscreen labels and context menus.
private struct SidebarTaskRow: View, Equatable {
    let task: TaskListItem
    /// A live run shows the spinner even before the saved status says so.
    let isRunning: Bool

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool { lhs.task == rhs.task && lhs.isRunning == rhs.isRunning }

    private var name: String { task.filename ?? L10n.tr("未命名任务") }

    var body: some View {
        // The glyph encodes the file type; only failure and live processing
        // add a trailing mark. Every state also has a spoken label.
        HStack(spacing: 6) {
            Label {
                Text(name).lineLimit(1).truncationMode(.middle).help(name)
            } icon: {
                Image(systemName: fileSymbol).foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            trailingMark
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(L10n.tr("{0}，{1}", [name, task.statusTitle]))
    }

    private var fileSymbol: String {
        let ext = (task.filename as NSString?)?.pathExtension.lowercased() ?? ""
        return ext == "pdf" || ext.isEmpty ? "doc" : "photo"
    }

    /// Failure shows a single orange triangle and live processing a small
    /// spinner; every other state is silent.
    @ViewBuilder private var trailingMark: some View {
        if isRunning || task.status == "processing" {
            ProgressView().controlSize(.small).help(L10n.tr("识别中"))
        } else if task.status == "failed" {
            Image(systemName: "exclamationmark.triangle").foregroundStyle(SlateSyncTheme.warning)
                .help(task.statusTitle)
        }
    }
}

extension TaskListItem {
    /// Translate display text only; persisted status values remain untouched.
    /// Shared by the sidebar task rows and the workspace header facts.
    var statusTitle: String {
        switch status {
        case "draft": L10n.tr("待处理")
        case "completed": L10n.tr("已完成")
        case "processing": L10n.tr("处理中")
        case "failed": L10n.tr("失败")
        case "cancelled": L10n.tr("已取消")
        default: status
        }
    }
}

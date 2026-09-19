import SlateSyncDomain
import SwiftUI

// Product copy uses the shared launch language; user content stays verbatim.

/// Reusable lazy task source list. Stable task IDs drive selection even when
/// refresh or an asynchronous completion changes the surrounding projection.
public struct TaskRailView: View {
    @Environment(\.slateSyncDensity) private var density
    @Bindable private var model: WorkspaceModel
    @State private var pendingDeletion: String?
    // Native List needs synchronous selection feedback while the workspace
    // retains its committed task until the editor barrier and load succeed.
    @State private var pendingSelection: String?
    public init(model: WorkspaceModel) { self.model = model }

    public var body: some View {
        VStack(spacing: 0) {
            // Keep task identity separate from its search field; counts reflect
            // the full project and do not change meaning while filtering.
            HStack {
                Text(L10n.tr("项目任务")).font(.headline)
                Spacer()
                Text(model.tasks.count, format: .number)
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            .padding(.horizontal, density.panelPadding)
            .padding(.top, density.panelPadding)
            HStack {
                SlateSearchField(title: L10n.tr("搜索任务"), text: $model.searchText, identifier: "workspace.task.search")
                Button(L10n.tr("新建任务"), systemImage: "plus") { Task { await model.createTask() } }
                    .labelStyle(.iconOnly).help(L10n.tr("新建任务"))
                    .tint(Color.secondary)
                    .accessibilityIdentifier(AccessibilityID.taskCreate)
            }.padding(density.panelPadding)
            Divider()
            List(selection: selection) {
                // The model caches valid rows when tasks/search change, keeping
                // selection and progress updates free of full-list filtering.
                ForEach(model.selectableTasks, id: \.id) { task in
                    TaskRailRow(task: task)
                        .equatable()
                        .tag(task.id!)
                        .contextMenu {
                            Button(L10n.tr("删除任务"), role: .destructive) {
                                pendingDeletion = task.id
                            }
                        }
                }
            }
            // Overlay keeps empty and populated lists in one stable viewport.
            .overlay {
                if model.tasks.isEmpty, !model.operation.isRunning {
                    SlateEmptyState(title: L10n.tr("没有任务"), symbol: "doc.badge.plus", message: L10n.tr("创建任务后即可导入场记单。")) {
                        Button(L10n.tr("新建任务")) { Task { await model.createTask() } }
                    }
                } else if !model.searchText.isEmpty, model.filteredTasks.isEmpty {
                    SlateEmptyState(title: L10n.tr("无匹配任务"), symbol: "magnifyingglass", message: L10n.tr("尝试其他文件名，或清除搜索。")) {
                        Button(L10n.tr("清除搜索")) { model.searchText = "" }
                    }
                }
            }
        }
        .confirmationDialog(
            L10n.tr("删除任务？"), isPresented: Binding(get: { pendingDeletion != nil }, set: { if !$0 { pendingDeletion = nil } }),
            titleVisibility: .visible
        ) {
            if let id = pendingDeletion {
                Button(L10n.tr("删除任务"), role: .destructive) {
                    Task { await model.deleteTask(id: id) }
                    pendingDeletion = nil
                }
            }
            Button(L10n.tr("取消"), role: .cancel) { pendingDeletion = nil }
        } message: {
            Text(L10n.tr("任务的场记单与校对结果将被删除。"))
        }
        .safeAreaInset(edge: .bottom) {
            if case .failed(let error) = model.operation { SlateStatusBar(error.message, tone: .error) }
        }
    }

    private var selection: Binding<String?> {
        Binding(
            get: { pendingSelection ?? model.selectedTaskID },
            set: { id in
                // Acknowledge the click before scheduling asynchronous work.
                // Ignore native selection echoes while pending; otherwise the
                // old committed ID can send the highlight back and forth.
                guard let id, pendingSelection == nil, !model.isTransitioning,
                      id != model.selectedTaskID else { return }
                pendingSelection = id
                Task {
                    defer { pendingSelection = nil }
                    // Failure is presented by WorkspaceModel.operation; clearing
                    // the pending ID then restores the still-valid old selection.
                    try? await model.selectTask(id)
                }
            }
        )
    }
}

/// Row values change only when their task summary changes; selecting another
/// task does not require rebuilding all offscreen labels and context menus.
private struct TaskRailRow: View, Equatable {
    @Environment(\.slateSyncDensity) private var density
    let task: TaskListItem

    // Environment updates still refresh row geometry; task equality avoids
    // rebuilding unrelated records when only the current selection changes.
    nonisolated static func == (lhs: Self, rhs: Self) -> Bool { lhs.task == rhs.task }
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(task.filename ?? L10n.tr("未命名任务")).fontWeight(.medium)
                .lineLimit(1).help(task.filename ?? L10n.tr("未命名任务"))
            HStack {
                // Symbol and text carry status together, including without color.
                Label(statusTitle, systemImage: statusSymbol)
                Spacer()
                Text(L10n.tr("{0} 条", [String(describing: task.recordCount)]))
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, density.rowPadding)
    }
    private var statusSymbol: String {
        switch task.status {
        case "completed": "checkmark.circle"
        case "processing": "arrow.triangle.2.circlepath"
        case "failed": "exclamationmark.circle"
        case "cancelled": "minus.circle"
        default: "doc"
        }
    }
    // Translate display text only; persisted status values remain untouched.
    private var statusTitle: String {
        switch task.status {
        case "draft": L10n.tr("待处理")
        case "completed": L10n.tr("已完成")
        case "processing": L10n.tr("处理中")
        case "failed": L10n.tr("失败")
        case "cancelled": L10n.tr("已取消")
        default: task.status
        }
    }

}

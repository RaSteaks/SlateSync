import SwiftUI
import SlateSyncDomain

/// Reusable lazy task source list. Stable task IDs drive selection even when
/// refresh or an asynchronous completion changes the surrounding projection.
public struct TaskRailView: View {
    @Bindable private var model: WorkspaceModel
    @State private var pendingDeletion: String?
    public init(model: WorkspaceModel) { self.model = model }

    public var body: some View {
        VStack(spacing: 0) {
            HStack {
                TextField("搜索任务", text: $model.searchText)
                    .textFieldStyle(.roundedBorder)
                Button("新建任务", systemImage: "plus") { Task { await model.createTask() } }
                    .labelStyle(.iconOnly)
                    .accessibilityIdentifier(AccessibilityID.taskCreate)
            }.padding(10)
            List(selection: selection) {
                // Filter missing IDs before ForEach so each element always
                // produces exactly one row. Conditional row builders force
                // SwiftUI to inspect every task to determine List row counts.
                ForEach(model.filteredTasks.filter { $0.id != nil }, id: \.id) { task in
                    TaskRailRow(task: task)
                        .equatable()
                        .tag(task.id!)
                        .contextMenu {
                            Button("删除任务", role: .destructive) {
                                pendingDeletion = task.id
                            }
                        }
                }
            }
            if model.tasks.isEmpty, !model.operation.isRunning {
                ContentUnavailableView("没有任务", systemImage: "doc.badge.plus")
            }
        }
        .confirmationDialog("删除任务？", isPresented: Binding(get: { pendingDeletion != nil }, set: { if !$0 { pendingDeletion = nil } }), titleVisibility: .visible) {
            if let id = pendingDeletion {
                Button("删除任务", role: .destructive) { Task { await model.deleteTask(id: id) }; pendingDeletion = nil }
            }
            Button("取消", role: .cancel) { pendingDeletion = nil }
        } message: { Text("任务的场记单与校对结果将被删除。") }
        .safeAreaInset(edge: .bottom) {
            if case .failed(let error) = model.operation { Text(error.message).foregroundStyle(.red).padding(8) }
        }
    }

    private var selection: Binding<String?> {
        Binding(
            get: { model.selectedTaskID },
            set: { id in if let id { Task { try? await model.selectTask(id) } } }
        )
    }
}

/// Row values change only when their task summary changes; selecting another
/// task does not require rebuilding all offscreen labels and context menus.
private struct TaskRailRow: View, Equatable {
    let task: TaskListItem
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(task.filename ?? "未命名任务").lineLimit(1)
            HStack {
                Text(task.status)
                Spacer()
                Text("\(task.recordCount) 条")
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
        }
    }
}

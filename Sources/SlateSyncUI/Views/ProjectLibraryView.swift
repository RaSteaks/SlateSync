import SlateSyncDomain
import SwiftUI

public struct ProjectLibraryView: View {
    @Bindable private var model: ProjectLibraryModel
    private let onOpen: (ProjectSummary) -> Void

    public init(model: ProjectLibraryModel, onOpen: @escaping (ProjectSummary) -> Void) {
        self.model = model
        self.onOpen = onOpen
    }

    public var body: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 240), spacing: 14)], spacing: 14) {
                ForEach(model.projects) { project in
                    ProjectCard(project: project, onOpen: { onOpen(project) })
                }
            }
            .padding(20)
        }
        .overlay {
            if model.isLoading, model.projects.isEmpty { ProgressView("正在读取项目库…") }
        }
        .overlay {
            if !model.isLoading, model.projects.isEmpty, model.error == nil {
                ContentUnavailableView(
                    "还没有项目",
                    systemImage: "film.stack",
                    description: Text("创建项目后即可导入场记单并开始识别。")
                )
            }
        }
        .navigationTitle("项目库")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("新建项目", systemImage: "plus") { model.showsCreateSheet = true }
                    .keyboardShortcut("n", modifiers: .command)
                    .accessibilityIdentifier("project.create")
            }
        }
        .safeAreaInset(edge: .bottom) {
            if let error = model.error {
                HStack {
                    Label(error.message, systemImage: "exclamationmark.triangle")
                    Spacer()
                    if error.retryable { Button("重试") { Task { await model.load() } } }
                }
                .padding(12)
                .background(.bar)
                .accessibilityIdentifier("project.error")
            }
        }
        .sheet(isPresented: $model.showsCreateSheet) {
            CreateProjectSheet(model: model)
        }
        .task { await model.load() }
    }
}
private struct ProjectCard: View {
    let project: ProjectSummary
    let onOpen: () -> Void

    var body: some View {
        Button(action: onOpen) {
            VStack(alignment: .leading, spacing: 12) {
                Rectangle()
                    .fill(SlateSyncTheme.accent)
                    .frame(height: 3)
                    .accessibilityHidden(true)
                Label(project.name, systemImage: "film.stack")
                    .font(.headline)
                    .lineLimit(1)
                Text(project.description.isEmpty ? "暂无描述" : project.description)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, minHeight: 38, alignment: .topLeading)
                Text("\(project.taskCount) 个任务")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
            .padding(16)
            .background(SlateSyncTheme.evidenceSurface, in: .rect(cornerRadius: 12))
            .overlay(.separator, in: .rect(cornerRadius: 12).stroke(lineWidth: 1))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("打开项目 \(project.name)")
    }
}

private struct CreateProjectSheet: View {
    @Bindable var model: ProjectLibraryModel
    @Environment(\.dismiss) private var dismiss
    @FocusState private var focusedField: Field?

    private enum Field { case name, description }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("新建项目").font(.title2.bold())
            Text("项目会保存在当前 Project Library 中。")
                .foregroundStyle(.secondary)
            Form {
                TextField("项目名称", text: $model.createName)
                    .focused($focusedField, equals: .name)
                    .accessibilityIdentifier("project.name")
                TextField("描述", text: $model.createDescription, axis: .vertical)
                    .lineLimit(2...4)
                    .focused($focusedField, equals: .description)
            }
            HStack {
                Spacer()
                Button("取消", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("创建") { Task { _ = await model.createProject() } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.isLoading)
                    .accessibilityIdentifier("project.create.confirm")
            }
        }
        .padding(24)
        .frame(width: 440)
        .onAppear { focusedField = .name }
    }
}

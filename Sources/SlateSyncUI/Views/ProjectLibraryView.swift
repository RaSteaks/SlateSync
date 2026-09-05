import SlateSyncDomain
import SwiftUI
import UniformTypeIdentifiers

public struct ProjectLibraryView: View {
    @Bindable private var model: ProjectLibraryModel
    private let onOpen: (ProjectSummary) -> Void
    private let onSettings: (ProjectSummary) -> Void
    @State private var importsProject = false
    @State private var importsLibrary = false
    @State private var relocatesLibrary = false
    @State private var exportProject: ProjectSummary?
    @State private var showsRename = false
    @State private var choosesExportDirectory = false
    @State private var exportsLibrary = false
    @State private var pendingArchive: ProjectSummary?

    public init(
        model: ProjectLibraryModel,
        onOpen: @escaping (ProjectSummary) -> Void,
        onSettings: @escaping (ProjectSummary) -> Void = { _ in }
    ) {
        self.model = model
        self.onOpen = onOpen
        self.onSettings = onSettings
    }

    public var body: some View {
        List(selection: $model.selection) {
            Section("活跃项目") {
                ForEach(model.activeProjects) { project in
                    ProjectRow(project: project, archived: false)
                        .tag(project.id)
                        .contextMenu { actions(for: project) }
                        .onTapGesture(count: 2) { onOpen(project) }
                }
            }
            if !model.archivedProjects.isEmpty {
                Section("已归档") {
                    ForEach(model.archivedProjects) { project in
                        ProjectRow(project: project, archived: true)
                            .tag(project.id)
                            .contextMenu { actions(for: project) }
                    }
                }
            }
        }
        .overlay {
            if model.isLoading, model.activeProjects.isEmpty { ProgressView("正在读取项目库…") }
            if !model.isLoading, model.activeProjects.isEmpty, model.archivedProjects.isEmpty, model.error == nil {
                ContentUnavailableView(
                    "还没有项目",
                    systemImage: "film.stack",
                    description: Text("创建项目后即可导入场记单并开始识别。")
                )
            }
        }
        .navigationTitle(model.library?.name ?? "项目库")
        .toolbar { toolbar }
        .safeAreaInset(edge: .bottom) { errorBanner }
        .sheet(isPresented: $model.showsCreateSheet) {
            CreateProjectSheet(model: model) { project in onOpen(project) }
        }
        .sheet(item: $model.projectPendingDeletion) { project in
            ProjectDeletionSheet(model: model, project: project)
        }
        .alert("重命名项目库", isPresented: $showsRename) {
            TextField("项目库名称", text: $model.libraryNameDraft)
            Button("取消", role: .cancel) {}
            Button("重命名") { Task { await model.renameLibrary() } }
        } message: {
            Text("只修改项目库显示名称，不改变项目数据。")
        }
        .confirmationDialog("归档项目？", isPresented: Binding(get: { pendingArchive != nil }, set: { if !$0 { pendingArchive = nil } }), titleVisibility: .visible) {
            if let project = pendingArchive {
                Button("归档“\(project.name)”") { Task { await model.archive(project) }; pendingArchive = nil }
            }
            Button("取消", role: .cancel) { pendingArchive = nil }
        } message: { Text("归档项目可以从项目库恢复。") }
        .fileImporter(isPresented: $importsProject, allowedContentTypes: [.slateSyncProjectPackage]) { result in
            if case .success(let url) = result { scoped(url) { await model.importProject(from: $0) } }
        }
        .fileImporter(isPresented: $importsLibrary, allowedContentTypes: [.slateSyncLibraryPackage]) { result in
            if case .success(let url) = result { scoped(url) { await model.importLibrary(from: $0) } }
        }
        .fileImporter(isPresented: $relocatesLibrary, allowedContentTypes: [.folder]) { result in
            if case .success(let url) = result { scoped(url) { await model.relocateLibrary(to: $0) } }
        }
        .fileImporter(
            isPresented: $choosesExportDirectory,
            allowedContentTypes: [.folder]
        ) { result in
            if case .success(let directory) = result {
                if exportsLibrary {
                    let target = directory.appending(path: "SlateSync.slatesync-library", directoryHint: .isDirectory)
                    scoped(directory) { _ in await model.exportLibrary(to: target) }
                } else if let project = exportProject {
                    let target = directory.appending(path: "\(project.name).slatesync-project", directoryHint: .isDirectory)
                    scoped(directory) { _ in await model.export(project, to: target) }
                }
            }
            exportProject = nil
            exportsLibrary = false
        }
        .task { await model.load() }
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            if let project = model.selectedProject, project.archivedAt == nil {
                Button("打开", systemImage: "arrow.right.circle") { onOpen(project) }
            }
            Menu("项目库操作", systemImage: "ellipsis.circle") {
                Button("导入项目…") { importsProject = true }
                if let project = model.selectedProject {
                    Button("导出“\(project.name)”…") { exportProject = project; exportsLibrary = false; choosesExportDirectory = true }
                }
                Button("导出项目库…") { exportsLibrary = true; choosesExportDirectory = true }
                Divider()
                Button("切换项目库…") { importsLibrary = true }
                Button("移动项目库…") { relocatesLibrary = true }
                Button("重命名项目库…") { showsRename = true }
            }
            Button("新建项目", systemImage: "plus") { model.showsCreateSheet = true }
                .accessibilityIdentifier(AccessibilityID.projectCreate)
        }
    }

    @ViewBuilder private func actions(for project: ProjectSummary) -> some View {
        if project.archivedAt == nil {
            Button("打开") { onOpen(project) }
            Button("项目设置…") { onSettings(project) }
            Button("归档…") { pendingArchive = project }
        } else {
            Button("恢复") { Task { await model.restore(project) } }
        }
        Divider()
        Button("永久删除…", role: .destructive) { model.requestDeletion(project) }
    }

    private func scoped(_ url: URL, action: @escaping @MainActor (URL) async -> Void) {
        // Keep the panel grant alive through the entire async transfer,
        // including its failure/cleanup path and destination directory writes.
        Task {
            let accessed = url.startAccessingSecurityScopedResource()
            defer { if accessed { url.stopAccessingSecurityScopedResource() } }
            await action(url)
        }
    }

    @ViewBuilder private var errorBanner: some View {
        if model.libraryRestartRequired {
            HStack {
                Label("项目库已切换；重启 SlateSync 后生效。", systemImage: "arrow.clockwise.circle")
                Spacer()
            }
            .padding(12).background(.bar)
        } else if let error = model.error {
            HStack {
                Label(error.message, systemImage: "exclamationmark.triangle")
                Spacer()
                Button("关闭") { model.clearError() }
                if error.retryable { Button("重试") { Task { await model.load() } } }
            }
            .padding(12)
            .background(.bar)
            .accessibilityIdentifier("project.error")
        }
    }
}

private struct ProjectRow: View {
    let project: ProjectSummary
    let archived: Bool

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: archived ? "archivebox" : "film.stack")
                .foregroundStyle(archived ? .secondary : SlateSyncTheme.accent)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(project.name).font(.headline)
                if !project.description.isEmpty {
                    Text(project.description).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer()
            Text("\(project.taskCount) 个任务")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 5)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(project.name)，\(archived ? "已归档" : "活跃")，\(project.taskCount) 个任务")
    }
}

private struct CreateProjectSheet: View {
    @Bindable var model: ProjectLibraryModel
    let onCreated: (ProjectSummary) -> Void
    @Environment(\.dismiss) private var dismiss
    @FocusState private var focusesName: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("新建项目").font(.title2.bold())
            Form {
                TextField("项目名称", text: $model.createName)
                    .focused($focusesName)
                    .accessibilityIdentifier("project.name")
                TextField("描述（可选）", text: $model.createDescription, axis: .vertical)
                    .lineLimit(2...4)
            }
            if let error = model.error { Text(error.message).foregroundStyle(.red) }
            HStack {
                Spacer()
                Button("取消", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("创建") {
                    Task { if let project = await model.createProject() { onCreated(project) } }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(model.isLoading)
                .accessibilityIdentifier(AccessibilityID.projectCreateConfirm)
            }
        }
        .padding(24)
        .frame(width: 440)
        .onAppear { focusesName = true }
        .interactiveDismissDisabled(model.isLoading)
    }
}

private struct ProjectDeletionSheet: View {
    @Bindable var model: ProjectLibraryModel
    let project: ProjectSummary
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("永久删除项目", systemImage: "trash")
                .font(.title2.bold()).foregroundStyle(.red)
            Text("此操作不可撤销。请输入 **\(project.name)** 以确认。")
            TextField("项目名称", text: $model.deletionConfirmation)
                .accessibilityIdentifier("project.delete.confirmation")
            if let error = model.error { Text(error.message).foregroundStyle(.red) }
            HStack {
                Spacer()
                Button("取消", role: .cancel) { dismiss() }
                Button("永久删除", role: .destructive) { Task { await model.confirmDeletion() } }
                    .disabled(model.deletionConfirmation != project.name || model.isLoading)
            }
        }
        .padding(24)
        .frame(width: 460)
        .interactiveDismissDisabled(model.isLoading)
    }
}

private extension UTType {
    static let slateSyncProjectPackage = UTType(exportedAs: "com.slatesync.project-package", conformingTo: .package)
    static let slateSyncLibraryPackage = UTType(exportedAs: "com.slatesync.library-package", conformingTo: .package)
}

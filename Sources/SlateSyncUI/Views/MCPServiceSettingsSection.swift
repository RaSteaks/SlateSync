import SwiftUI
import UniformTypeIdentifiers
import SlateSyncDomain

/// One native importer owns every path selection. Service state and client
/// registration feedback remain separate, and grants are optional at startup.
struct MCPServiceSettingsSection: View {
    @Bindable var model: MCPSettingsModel
    @State private var selectsPath = false
    @State private var selectionKind: SelectionKind = .executable
    @State private var selectionError: String?

    private enum SelectionKind {
        case executable, directories, source
        var types: [UTType] { self == .executable ? [.item] : [.folder] }
        var allowsMultiple: Bool { self == .directories }
    }

    var body: some View {
        Section(L10n.tr("服务管理")) {
            LabeledContent(L10n.tr("服务状态")) {
                Label(model.statusText, systemImage: model.isRunning ? "checkmark.circle" : "stop.circle")
                    .foregroundStyle(model.isRunning ? SlateSyncTheme.success : .secondary)
                    .accessibilityIdentifier("settings.mcp.status")
            }
            HStack {
                Button(L10n.tr("一键启动 MCP"), systemImage: "play.fill") { model.start() }
                    .slatePrimaryActionStyle()
                    .disabled(!model.canStart)
                    .accessibilityIdentifier("settings.mcp.start")
                Button(L10n.tr("停止 MCP"), systemImage: "stop.fill") { model.stop() }
                    .disabled(!model.isRunning || model.isBusy)
                    .accessibilityIdentifier("settings.mcp.stop")
            }
            Text(L10n.tr("自动查找组件并构建后启动。首次构建需要 Xcode / Swift 和网络，后续使用增量构建。无需先选择授权目录。"))
                .font(.caption).foregroundStyle(.secondary)
            Toggle(L10n.tr("随 SlateSync 自动启动 / 停止"), isOn: Binding(get: { model.automaticallyStarts }, set: { model.setAutomaticallyStarts($0) }))
                .disabled(model.isBusy)
                .accessibilityIdentifier("settings.mcp.automatic")
            Text(L10n.tr("启用后立即启动，下次打开 SlateSync 时自动启动；关闭开关或退出应用时停止服务和全部客户端连接。关闭设置窗口不会停止服务。"))
                .font(.caption).foregroundStyle(.secondary)
            if case .running(let label) = model.operation { ProgressView(label) }
            if model.isBusy && !model.isRunning {
                Button(L10n.tr("取消")) { model.cancelPreparation() }
                    .accessibilityIdentifier("settings.mcp.cancel")
            }
            if case .failed(let error) = model.operation { SlateInlineError(error.message) }

            VStack(alignment: .leading, spacing: 8) {
                Text(L10n.tr("添加到客户端"))
                ViewThatFits(in: .horizontal) {
                    HStack { clientButtons }
                    VStack(alignment: .leading) { clientButtons }
                }
                Text(L10n.tr("使用官方命令行工具添加用户级配置；需要时先自动构建并启动服务。Codex 更新 slatesync 条目，Claude Code 保留已有不同配置。"))
                    .font(.caption).foregroundStyle(.secondary)
                if case .running(let label) = model.clientOperation { ProgressView(label) }
                if case .succeeded(let message) = model.clientOperation {
                    Label(message, systemImage: "checkmark.circle").font(.caption).foregroundStyle(SlateSyncTheme.success)
                }
                if case .failed(let error) = model.clientOperation { SlateInlineError(error.message) }
            }

            VStack(alignment: .leading, spacing: 8) {
                Text(L10n.tr("授权目录（可选）"))
                Text(L10n.tr("未授权目录时仍可启动、连接和查看工具；读取素材或导出文件前，再添加对应目录并重启服务。"))
                    .font(.caption).foregroundStyle(.secondary)
                ForEach(model.configuration.directories, id: \.self) { path in
                    HStack {
                        Text(verbatim: path).font(.caption.monospaced()).textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer()
                        Button(L10n.tr("移除")) { model.configuration.directories.removeAll { $0 == path } }
                            .accessibilityLabel(L10n.tr("移除目录 {0}", [path]))
                    }
                }
                Button(L10n.tr("添加授权目录…"), systemImage: "folder.badge.plus") { select(.directories) }
                    .accessibilityIdentifier("settings.mcp.directories.choose")
                Toggle(L10n.tr("允许模型请求"), isOn: $model.configuration.allowsModelRequests)
                    .accessibilityIdentifier("settings.mcp.allowModels")
                Text(L10n.tr("默认仅启用本地工具。允许模型请求后，图片和 OCR 文字可发送给已配置的模型服务，并可能产生 API 费用。"))
                    .font(.caption).foregroundStyle(.secondary)
            }.disabled(model.isRunning || model.isBusy)

            DisclosureGroup(L10n.tr("高级设置")) {
                VStack(alignment: .leading, spacing: 8) {
                    LabeledContent(L10n.tr("启动程序")) {
                        TextField(L10n.tr("留空自动查找"), text: $model.configuration.executablePath)
                            .accessibilityIdentifier("settings.mcp.executable")
                    }
                    Button(L10n.tr("选择启动程序…"), systemImage: "folder") { select(.executable) }
                        .accessibilityIdentifier("settings.mcp.executable.choose")
                    if let source = model.configuration.sourceDirectory {
                        Text(verbatim: source).font(.caption.monospaced()).textSelection(.enabled)
                    }
                    Button(L10n.tr("选择源码目录…"), systemImage: "folder") { select(.source) }
                        .accessibilityIdentifier("settings.mcp.source.choose")
                    Text(L10n.tr("仅在自动查找失败或源码移动后设置。源码目录须包含 MCP/Package.swift 和 script/run_mcp.sh；更改配置前请先停止服务。"))
                        .font(.caption).foregroundStyle(.secondary)
                }.disabled(model.isRunning || model.isBusy)
            }
            .accessibilityIdentifier("settings.mcp.advanced")
            if let selectionError { SlateInlineError(selectionError) }
        }
        // Multiple fileImporter modifiers on this Section masked the launcher
        // picker. A typed route now shares one presenter, like WorkspaceView.
        .fileImporter(isPresented: $selectsPath, allowedContentTypes: selectionKind.types,
                      allowsMultipleSelection: selectionKind.allowsMultiple) { result in
            switch result {
            case .success(let urls):
                guard let url = urls.first else { return }
                switch selectionKind {
                case .executable:
                    model.configuration.executablePath = url.path
                    model.configuration.sourceDirectory = nil
                case .source:
                    model.configuration.sourceDirectory = url.path
                    model.configuration.executablePath = ""
                case .directories:
                    for url in urls where !model.configuration.directories.contains(url.path) {
                        model.configuration.directories.append(url.path)
                    }
                }
                selectionError = nil
            case .failure:
                selectionError = L10n.tr("无法选择路径，请重试。")
            }
        }
    }

    private var clientButtons: some View {
        ForEach(MCPClient.allCases, id: \.self) { client in
            Button(L10n.tr("添加到 {0}", [client.displayName])) { model.install(client: client) }
                .disabled(model.isBusy)
                .accessibilityIdentifier("settings.mcp.add." + client.rawValue)
        }
    }

    private func select(_ kind: SelectionKind) {
        selectionKind = kind
        selectsPath = true
    }
}

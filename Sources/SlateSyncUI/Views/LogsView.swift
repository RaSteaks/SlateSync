import SlateSyncDomain
import SwiftUI

public struct LogsView: View {
    @Bindable private var model: LogsModel
    private let recognition: RecognitionModel
    private let opener: any WorkspaceOpening

    public init(model: LogsModel, recognition: RecognitionModel, opener: any WorkspaceOpening = SystemWorkspaceOpener()) {
        self.model = model
        self.recognition = recognition
        self.opener = opener
    }

    public var body: some View {
        VStack(spacing: 0) {
            HStack {
                Menu("级别", systemImage: "line.3.horizontal.decrease.circle") {
                    ForEach(ProductLogSeverity.allCases, id: \.self) { severity in
                        Toggle(severity.title, isOn: severityBinding(severity))
                    }
                }
                TextField("分类", text: $model.category).frame(maxWidth: 180)
                Button("刷新", systemImage: "arrow.clockwise") { Task { await model.refresh() } }
                Button("打开日志文件夹", systemImage: "folder") {
                    Task { opener.openDirectory(await model.directory()) }
                }
                Spacer()
                if recognition.operation.isRunning {
                    Label("识别进行中", systemImage: "viewfinder")
                        .foregroundStyle(SlateSyncTheme.accent)
                }
            }.padding(10)
            Divider()
            if model.entries.isEmpty, !model.isRefreshing {
                ContentUnavailableView("暂无日志", systemImage: "doc.text.magnifyingglass", description: Text("日志仅保留脱敏的产品事件。"))
            } else {
                List(model.entries) { entry in
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Image(systemName: entry.severity.symbol).foregroundStyle(entry.severity.color)
                        Text(entry.timestamp, format: .dateTime.hour().minute().second())
                            .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        Text(entry.category).font(.caption.monospaced()).frame(width: 96, alignment: .leading)
                        VStack(alignment: .leading) {
                            Text(entry.message)
                            Text(entry.event).font(.caption.monospaced()).foregroundStyle(.secondary)
                        }
                    }.accessibilityElement(children: .combine)
                }.accessibilityIdentifier(AccessibilityID.logsList)
            }
        }
        .navigationTitle("运行日志")
        .safeAreaInset(edge: .bottom) {
            if model.degraded {
                Label("部分日志无法读取，已保留可用记录。可刷新重试。", systemImage: "exclamationmark.triangle")
                    .padding(10)
            }
        }
        .onAppear { model.startPolling() }
        .onDisappear { model.stopPolling() }
        .onChange(of: model.category) { Task { await model.refresh() } }
        .onChange(of: model.selectedSeverities) { Task { await model.refresh() } }
    }

    private func severityBinding(_ severity: ProductLogSeverity) -> Binding<Bool> {
        Binding(
            get: { model.selectedSeverities.contains(severity) },
            set: { enabled in
                if enabled { model.selectedSeverities.insert(severity) }
                else { model.selectedSeverities.remove(severity) }
            }
        )
    }
}

private extension ProductLogSeverity {
    var title: String { switch self { case .debug: "调试"; case .info: "信息"; case .warning: "警告"; case .error: "错误" } }
    var symbol: String { switch self { case .debug: "ladybug"; case .info: "info.circle"; case .warning: "exclamationmark.triangle"; case .error: "xmark.octagon" } }
    var color: Color { switch self { case .debug: .secondary; case .info: .blue; case .warning: .orange; case .error: .red } }
}

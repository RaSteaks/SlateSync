import SwiftUI

public struct AppRootView: View {
    @Bindable private var navigation: AppNavigationModel
    private let projects: ProjectLibraryModel

    public init(navigation: AppNavigationModel, projects: ProjectLibraryModel) {
        self.navigation = navigation
        self.projects = projects
    }

    public var body: some View {
        NavigationSplitView {
            SidebarView(selection: $navigation.selection)
                .navigationSplitViewColumnWidth(min: 190, ideal: 230, max: 280)
        } detail: {
            detail
        }
        .tint(SlateSyncTheme.accent)
    }

    @ViewBuilder
    private var detail: some View {
        switch navigation.selection {
        case .projects:
            ProjectLibraryView(model: projects) { _ in navigation.selection = .workspace }
        case .workspace:
            PlaceholderFeatureView(
                title: "工作台",
                symbol: "rectangle.3.group",
                message: "场记输入、识别、校对和 CSV 回填将在迁移阶段接入。"
            )
        case .projectSettings:
            PlaceholderFeatureView(title: "项目设置", symbol: "slider.horizontal.3", message: "项目级 Provider、格式和迁移设置。")
        case .logs:
            PlaceholderFeatureView(title: "运行日志", symbol: "doc.text.magnifyingglass", message: "原生日志读取与诊断会在工作流迁移阶段接入。")
        case .help:
            PlaceholderFeatureView(title: "帮助", symbol: "questionmark.circle", message: "SlateSync 使用说明与故障恢复入口。")
        }
    }
}
private struct PlaceholderFeatureView: View {
    let title: String
    let symbol: String
    let message: String

    var body: some View {
        ContentUnavailableView(title, systemImage: symbol, description: Text(message))
            .navigationTitle(title)
            .accessibilityIdentifier("feature.\(title)")
    }
}

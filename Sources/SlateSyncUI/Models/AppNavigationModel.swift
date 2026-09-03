import Observation

public enum SidebarDestination: String, CaseIterable, Identifiable, Sendable {
    case projects
    case workspace
    case projectSettings
    case logs
    case help

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .projects: "项目库"
        case .workspace: "工作台"
        case .projectSettings: "项目设置"
        case .logs: "运行日志"
        case .help: "帮助"
        }
    }

    public var symbol: String {
        switch self {
        case .projects: "square.grid.2x2"
        case .workspace: "rectangle.3.group"
        case .projectSettings: "slider.horizontal.3"
        case .logs: "doc.text.magnifyingglass"
        case .help: "questionmark.circle"
        }
    }
}

@MainActor @Observable
public final class AppNavigationModel {
    public var selection: SidebarDestination = .projects
    public init() {}
}

import SlateSyncDomain

public enum OperationState: Equatable, Sendable {
    case idle
    case running(label: String)
    case succeeded(message: String)
    case failed(SlateSyncError)
    case canceled

    public var isRunning: Bool {
        if case .running = self { return true }
        return false
    }
}

public enum AccessibilityID {
    public static let sidebar = "sidebar"
    public static let projectCreate = "project.create"
    public static let projectCreateConfirm = "project.create.confirm"
    public static let workspaceHeading = "workspace.heading"
    public static let taskCreate = "task.create"
    public static let recognize = "recognition.start"
    public static let recognitionCancel = "recognition.cancel"
    public static let csvTable = "csv.table"
    public static let logsList = "logs.list"
    public static let helpSearch = "help.search"
}

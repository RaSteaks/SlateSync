import SwiftUI

/// Focused commands are offered only when the visible route owns the action.
/// A retained project identity must not make Command-N mutate a hidden workspace.
enum FocusedActionAvailability {
    static func permitsNewTask(route: SidebarDestination, projectID: String?) -> Bool {
        route == .workspace && projectID != nil
    }
}

/// Commands and toolbar actions share these focused closures so menu items
/// always target the front window's current state owner.
public struct SlateSyncFocusedActions {
    public var newProject: (() -> Void)?
    public var newTask: (() -> Void)?
    public var save: (() -> Void)?
    public var cancelRecognition: (() -> Void)?

    public init(
        newProject: (() -> Void)? = nil,
        newTask: (() -> Void)? = nil,
        save: (() -> Void)? = nil,
        cancelRecognition: (() -> Void)? = nil
    ) {
        self.newProject = newProject
        self.newTask = newTask
        self.save = save
        self.cancelRecognition = cancelRecognition
    }
}

private struct SlateSyncFocusedActionsKey: FocusedValueKey {
    typealias Value = SlateSyncFocusedActions
}

public extension FocusedValues {
    var slateSyncActions: SlateSyncFocusedActions? {
        get { self[SlateSyncFocusedActionsKey.self] }
        set { self[SlateSyncFocusedActionsKey.self] = newValue }
    }
}

public struct SlateSyncCommands: Commands {
    @FocusedValue(\.slateSyncActions) private var actions
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow
    public init() {}

    public var body: some Commands {
        CommandGroup(replacing: .newItem) {
            // Reserve Command-N for the frozen task action and give window
            // creation a distinct shortcut that also works with no window.
            Button("新建窗口") { openWindow(id: "main") }
                .keyboardShortcut("n", modifiers: [.command, .option])
            Button("新建项目") { actions?.newProject?() }
                .keyboardShortcut("n", modifiers: [.command, .shift])
                .disabled(actions?.newProject == nil)
            Button("新建任务") { actions?.newTask?() }
                .keyboardShortcut("n", modifiers: .command)
                .disabled(actions?.newTask == nil)
        }
        // `.saveItem` also owns Close on macOS. Rebuild that small group with
        // SwiftUI's current-window action so Settings and WindowGroup retain
        // ⌘W without leaving the system Save beside our focused Save.
        CommandGroup(replacing: .saveItem) {
            Button("关闭窗口") { dismissWindow() }
                .keyboardShortcut("w", modifiers: .command)
            Divider()
            Button("保存") { actions?.save?() }
                .keyboardShortcut("s", modifiers: .command)
                .disabled(actions?.save == nil)
        }
        CommandMenu("识别") {
            Button("取消当前识别") { actions?.cancelRecognition?() }
                .keyboardShortcut(".", modifiers: .command)
                .disabled(actions?.cancelRecognition == nil)
        }
    }
}

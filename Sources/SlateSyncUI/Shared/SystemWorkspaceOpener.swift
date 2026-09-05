import AppKit
import Foundation

public protocol WorkspaceOpening {
    @MainActor func openDirectory(_ url: URL)
}

/// Narrow system adapter used only for the user-requested "open logs folder"
/// action; no path is copied into logs or accessibility values.
public struct SystemWorkspaceOpener: WorkspaceOpening {
    public init() {}
    @MainActor public func openDirectory(_ url: URL) {
        NSWorkspace.shared.open(url)
    }
}

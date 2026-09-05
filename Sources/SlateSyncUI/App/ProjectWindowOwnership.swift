import Foundation
import SlateSyncDomain

/// Application-scoped ownership map, injected into window sessions. Different
/// projects may be edited concurrently; a second writer for the same project
/// is rejected explicitly instead of racing independent autosave snapshots.
@MainActor
public final class ProjectWindowOwnership {
    private var owners: [String: UUID] = [:]
    public init() {}

    public func acquire(projectID: String, windowID: UUID) throws {
        guard owners[projectID] == nil || owners[projectID] == windowID else {
            throw SlateSyncError(code: "PROJECT_OPEN_IN_OTHER_WINDOW", message: "此项目已在另一个窗口打开，请在该窗口继续编辑", retryable: true)
        }
        owners[projectID] = windowID
    }

    public func release(projectID: String, windowID: UUID) {
        if owners[projectID] == windowID { owners[projectID] = nil }
    }
}

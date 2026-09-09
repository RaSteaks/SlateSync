import Foundation
import SlateSyncDomain

/// Per-feature admission predicates for every picker/drop/button input owner.
/// The predicates are split per feature on purpose: independent editors stay
/// usable while recognition runs, and a CSV-shaped reason can never block a
/// media edit. Form.disabled still applies; these closures close the gap for
/// async picker completions and drag/drop, which reach models directly.
@MainActor
public enum WindowAdmission {
    /// Shared freeze conditions: a termination drain, a library mutation, or
    /// a restart-required failure. No feature may start work under them.
    public static func shared(_ termination: TerminationCoordinator) -> @MainActor () -> Bool {
        { !termination.isDraining && !termination.isMutatingLibrary && !termination.restartRequired }
    }

    /// Media input waits only for the shared freeze; a running selection is
    /// owned by MediaInputModel's request generations.
    public static func media(_ termination: TerminationCoordinator) -> @MainActor () -> Bool {
        shared(termination)
    }

    /// Metadata scanning waits for the shared freeze like media; a superseded
    /// scan is drained with the workspace selection barrier.
    public static func metadata(_ termination: TerminationCoordinator) -> @MainActor () -> Bool {
        shared(termination)
    }

    /// CSV import additionally waits for a running recognition, because its
    /// table would replace the recognition-merged evidence.
    public static func csv(_ termination: TerminationCoordinator, recognition: RecognitionModel) -> @MainActor () -> Bool {
        let shared = shared(termination)
        return { !recognition.operation.isRunning && shared() }
    }

    /// Recognition waits for the shared freeze and a stable workspace
    /// selection, because its writes target the selected task.
    public static func recognition(_ termination: TerminationCoordinator, workspace: WorkspaceModel) -> @MainActor () -> Bool {
        let shared = shared(termination)
        return { !workspace.isTransitioning && shared() }
    }
}

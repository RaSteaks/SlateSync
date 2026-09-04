import Observation
import SlateSyncDomain
import SlateSyncPersistence

/// Main-actor adapter for the runtime actor. It exposes only the
/// secret-free bootstrap snapshot to SwiftUI; provider key bytes remain behind
/// SlateSyncRuntime's Keychain methods.
@MainActor @Observable
public final class SlateSyncRuntimeModel {
    public private(set) var snapshot: SlateSyncRuntimeSnapshot?
    public private(set) var isBootstrapping = false

    private let runtime: SlateSyncRuntime

    public init(runtime: SlateSyncRuntime) {
        self.runtime = runtime
    }

    public func bootstrap() async {
        guard !isBootstrapping else { return }
        isBootstrapping = true
        snapshot = await runtime.bootstrap()
        isBootstrapping = false
    }

    public func retryLegacyMigration() async {
        guard !isBootstrapping else { return }
        isBootstrapping = true
        snapshot = await runtime.retryLegacyMigration()
        isBootstrapping = false
    }
}

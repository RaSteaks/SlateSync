import Foundation
import Observation
import SlateSyncDomain

/// Route-scoped reader with an explicit polling lifetime. The recognition
/// operation remains owned above this model and is never canceled here.
@MainActor @Observable
public final class LogsModel {
    public private(set) var entries: [ProductLogEntry] = []
    public private(set) var isRefreshing = false
    public private(set) var degraded = false
    public var selectedSeverities = Set<ProductLogSeverity>()
    public var category = ""
    public var limit = 500
    private let service: any LogWorkflowServing
    private var pollingTask: Task<Void, Never>?
    private var generation = 0
    private var routeVisible = false
    private var windowVisible = true
    public var isPolling: Bool { pollingTask != nil }

    public init(service: any LogWorkflowServing) { self.service = service }

    public func refresh() async {
        generation += 1
        let request = generation
        isRefreshing = true
        let result = await service.logSnapshot(
            limit: limit,
            severities: selectedSeverities,
            category: category.isEmpty ? nil : category
        )
        // Filter changes supersede old reads; stopped/hidden readers may
        // finish cleanup but cannot republish an obsolete projection.
        guard request == generation, !Task.isCancelled else { return }
        entries = result.entries
        degraded = result.degraded
        isRefreshing = false
    }

    public func startPolling() {
        routeVisible = true
        updatePolling()
    }

    public func setWindowVisible(_ visible: Bool) {
        windowVisible = visible
        updatePolling()
    }

    private func updatePolling() {
        guard routeVisible && windowVisible else { cancelPolling(); return }
        guard pollingTask == nil else { return }
        pollingTask = Task { [weak self] in
            while !Task.isCancelled {
                guard self != nil else { return }
                await self?.refresh()
                try? await Task.sleep(for: .seconds(3))
            }
        }
    }

    public func stopPolling() {
        routeVisible = false
        cancelPolling()
    }

    private func cancelPolling() {
        generation += 1
        isRefreshing = false
        pollingTask?.cancel()
        pollingTask = nil
    }

    public func directory() async -> URL { await service.logsDirectory() }
}

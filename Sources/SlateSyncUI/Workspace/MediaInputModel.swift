import Foundation
import Observation
import SlateSyncDomain

/// Window-owned media preparation survives route changes. Each selection owns
/// one awaited task and a paired security scope; a late decode can only release
/// its own resources. Persisted tasks restore through the same Media façade.
@MainActor @Observable
public final class MediaInputModel {
    public private(set) var document: PreparedDocument?
    public private(set) var operation: OperationState = .idle
    public var pageIndex = 0
    public var onPrepared: (@MainActor (PreparedDocument) -> Void)?
    public var permitsNewOperation: (@MainActor () -> Bool)?
    public var canAcceptInput: Bool { permitsNewOperation?() != false }
    private let service: any MediaInputWorkflowServing
    private var task: Task<Void, Never>?
    private var generation = 0

    public init(service: any MediaInputWorkflowServing) { self.service = service }

    public func select(_ url: URL) {
        // Apply the shared admission policy below every picker/drop entry.
        // Restoring an already selected task remains an internal read path.
        guard canAcceptInput else { return }
        replace { [service] in
            let accessed = url.startAccessingSecurityScopedResource()
            defer { if accessed { url.stopAccessingSecurityScopedResource() } }
            return try await service.prepareInput(.file(url))
        }
    }

    public func load(task value: TaskData?) {
        guard let groups = value?.imageDataGroups, !groups.isEmpty else {
            generation += 1
            task?.cancel()
            document = nil
            pageIndex = 0
            operation = .idle
            return
        }
        replace(persist: false) { [service] in
            try await service.restoreInput(groups: groups, filename: value?.filename ?? "场记单")
        }
    }

    public func cancel() { task?.cancel() }

    public func drain() async {
        generation += 1
        task?.cancel()
        await task?.value
        task = nil
    }

    public func report(_ error: Error) { operation = .failed(ProductPrivacy.error(error)) }

    private func replace(persist: Bool = true, prepare: @escaping @Sendable () async throws -> PreparedDocument) {
        generation += 1
        let request = generation
        let previous = task
        previous?.cancel()
        operation = .running(label: "正在准备场记单…")
        task = Task { [weak self] in
            await previous?.value
            guard let self, request == generation, !Task.isCancelled else { return }
            do {
                let value = try await prepare()
                try Task.checkCancellation()
                guard request == generation else { return }
                document = value
                pageIndex = 0
                if persist { onPrepared?(value) }
                operation = .succeeded(message: "已准备 \(value.pages.count) 页")
            } catch {
                guard request == generation else { return }
                operation = error is CancellationError ? .canceled : .failed(ProductPrivacy.error(error))
            }
            if request == generation { task = nil }
        }
    }
}

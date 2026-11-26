import Foundation
import Observation
import SlateSyncDomain

// Product copy uses the shared launch language; user content stays verbatim.

/// Window-owned media preparation survives route changes. Each selection owns
/// one awaited task and a paired security scope; a late decode can only release
/// its own resources. Persisted tasks restore through the same Media façade.
@MainActor @Observable
public final class MediaInputModel {
    public private(set) var originalBytes: Data?
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
        select(.init(url: url))
    }

    public func plan(_ urls: [URL]) async throws -> [MediaIntakePart] {
        var result: [MediaIntakePart] = []
        for url in urls {
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            result += try await service.intakeParts(for: url)
        }
        return result
    }

    public func select(_ part: MediaIntakePart) {
        guard canAcceptInput else { return }
        replace { [service] in
            let access = part.url.startAccessingSecurityScopedResource()
            defer { if access { part.url.stopAccessingSecurityScopedResource() } }
            return try await service.previewPart(part)
        }
    }

    public func waitForPreparation() async { await task?.value }

    public func load(task value: TaskData?) {
        // Restoration belongs to a different task even if its preparation fails.
        document = nil
        originalBytes = nil
        pageIndex = 0
        guard let groups = value?.imageDataGroups, !groups.isEmpty else {
            generation += 1
            task?.cancel()
            operation = .idle
            return
        }
        replace(persist: false) { [service] in
            let filename = value?.filename ?? L10n.tr("场记单")
            if let bytes = value?.production?.originalMedia {
                return try await .init(document: service.restorePreview(groups: groups, filename: filename), original: bytes)
            }
            return try await .init(document: service.restoreInput(groups: groups, filename: filename), original: nil)
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

    private func replace(persist: Bool = true, prepare: @escaping @Sendable () async throws -> MediaIntakePreview) {
        generation += 1
        let request = generation
        let previous = task
        previous?.cancel()
        operation = .running(label: L10n.tr("正在准备场记单…"))
        task = Task { [weak self] in
            await previous?.value
            guard let self, request == generation, !Task.isCancelled else { return }
            do {
                let value = try await prepare()
                try Task.checkCancellation()
                guard request == generation else { return }
                originalBytes = value.original
                document = value.document
                pageIndex = 0
                if persist { onPrepared?(value.document) }
                operation = .succeeded(message: L10n.tr("已准备 {0} 页", [String(describing: value.document.pages.count)]))
            } catch {
                guard request == generation else { return }
                operation = error is CancellationError ? .canceled : .failed(ProductPrivacy.error(error))
            }
            if request == generation { task = nil }
        }
    }
}

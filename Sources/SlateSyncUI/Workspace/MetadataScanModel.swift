import Foundation
import Observation
import SlateSyncDomain

/// Metadata directory scans are generation-bound so a late directory result
/// cannot replace the snapshot chosen by a newer file-panel action.
@MainActor @Observable
public final class MetadataScanModel {
    public private(set) var result: ScanResult?
    public private(set) var operation: OperationState = .idle
    private let service: any WorkspaceWorkflowServing
    private var generation = 0
    private var scanTask: Task<Void, Never>?
    public var onResult: (@MainActor (ScanResult, String) -> Void)?
    public var permitsNewOperation: (@MainActor () -> Bool)?

    public init(service: any WorkspaceWorkflowServing) { self.service = service }
    public func report(_ error: Error) { operation = .failed(ProductPrivacy.error(error)) }

    public func scan(_ directory: URL, expectedKeys: [String] = []) {
        // A late file-panel completion must honor recognition/close barriers.
        guard permitsNewOperation?() != false else { return }
        let previous = scanTask
        previous?.cancel()
        generation += 1
        let request = generation
        operation = .running(label: "正在扫描场记元数据…")
        scanTask = Task { [weak self] in
            guard let self else { return }
            // Superseding scans remain in an awaited chain until their
            // filesystem work and scoped URL have actually been released.
            await previous?.value
            guard !Task.isCancelled, request == generation else { return }
            let accessed = directory.startAccessingSecurityScopedResource()
            defer { if accessed { directory.stopAccessingSecurityScopedResource() } }
            do {
                let value = try await service.scanMetadata(
                    directory: directory,
                    options: SlateMetadataScanOptions(expectedKeys: expectedKeys)
                )
                guard request == generation, !Task.isCancelled else { return }
                result = value
                onResult?(value, directory.lastPathComponent)
                operation = .succeeded(message: "已读取 \(value.metadata.count) 条元数据")
            } catch is CancellationError {
                guard request == generation else { return }
                operation = .canceled
            } catch {
                guard request == generation else { return }
                operation = .failed(ProductPrivacy.error(error))
            }
            if request == generation { scanTask = nil }
        }
    }

    public func cancel() {
        generation += 1
        scanTask?.cancel()
        // Retain the handle so a later drain also joins canceled work.
        operation = .canceled
    }

    public func drain() async {
        generation += 1
        scanTask?.cancel()
        if let scanTask { await scanTask.value }
        self.scanTask = nil
        if operation.isRunning { operation = .canceled }
    }

    public func load(task: TaskData?) {
        // Task selection resets scan results synchronously; the preceding
        // selection barrier has already joined the previous directory scan.
        result = task.map { task in
            ScanResult(metadata: (task.slateMetadata ?? []).map {
                ScannedSlateMetadata(sourceName: $0.sourceName ?? "", clipName: $0.clipName ?? "", materialKey: $0.materialKey,
                    sensorFps: $0.sensorFps ?? "", shootDay: $0.shootDay ?? "")
            }, warnings: task.slateWarnings ?? [], stats: .init(visitedDirectories: 0, prunedDirectories: 0,
                skippedDeepDirectories: 0, discoveredSlateFiles: 0, readSlateFiles: 0, learnedStructures: 0),
                missingKeys: task.missingMetadataKeys ?? [])
        }
        operation = .idle
    }
}

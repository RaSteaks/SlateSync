import Foundation
import SlateSyncDomain

public actor ModelCapabilityProbeService {
    public typealias ProgressSink = @Sendable (ModelProbeProgress) -> Void
    public typealias Save = @Sendable (String, Int, [ModelCapabilityProbeResult]) async throws -> Void
    public static let marker = "ss-7q"
    public static let timeoutMilliseconds = 30_000
    /// Exact synthetic oracle from the retained JavaScript implementation.
    /// It contains `SS-7Q`; the marker is deliberately absent from prompts.
    public static let syntheticProbePNGBase64 = "iVBORw0KGgoAAAANSUhEUgAAAMAAAABACAAAAABpBycDAAAAvklEQVR4nO3Vyw7EIAxD0fz/T7dL1JaAeUgW1fVqJMDJ6WbiOjzhXmA1ANwB4A4AdwC4A8AdAO40APHM0KlaWisYawYAAEA6pr2EurGQ0pd+qcbjiRUBpH0AtEcA0ioA2iMAaRWA78v0Lz09jSzCYgAAANgJGCrqjBEvl4Par3qXOhSAchnA1FRljHj5RwC5FMDArP5lAFNT5Vn9y9sAUYl6ugJ41SsKAAAAHB4A7gBwB4A7ANwB4A4AdwC4cwNDxuNd0vBXMwAAAABJRU5ErkJggg=="

    private let registry: ProviderRegistry
    private let client: ProviderRecognitionClient
    private let save: Save?
    private let now: @Sendable () -> Date
    private var batches: [String: Task<ModelProbeResult, Error>] = [:]

    public init(registry: ProviderRegistry, client: ProviderRecognitionClient, save: Save? = nil, now: @escaping @Sendable () -> Date = Date.init) {
        self.registry = registry; self.client = client; self.save = save; self.now = now
    }

    public func probe(providerID: String, modelIDs: [String], progress: ProgressSink? = nil) async throws -> ModelProbeResult {
        guard batches[providerID] == nil else { throw RecognitionFailure.probeBusy }
        let provider = try await registry.descriptor(providerID: providerID)
        // Preserve caller order while filtering duplicates; completion order
        // may differ, but result/progress model indexes remain deterministic.
        var seen = Set<String>()
        let ids = modelIDs.filter {
            ProviderCatalog.isValidModelID($0) && !ProviderCatalog.isExcluded($0) && seen.insert($0).inserted
        }
        let revision = provider.revision ?? 0, client = client, now = now
        let task = Task {
            var output = Array<ModelCapabilityProbeResult?>(repeating: nil, count: ids.count)
            var next = 0, completed = 0
            try await withThrowingTaskGroup(of: (Int, ModelCapabilityProbeResult).self) { group in
                func enqueue() {
                    guard next < ids.count else { return }
                    let index = next, id = ids[index]; next += 1
                    group.addTask { (index, await Self.probeOne(id: id, provider: provider, client: client, now: now)) }
                }
                enqueue(); enqueue()
                while let (index, result) = try await group.next() {
                    output[index] = result; completed += 1
                    progress?(.init(providerId: providerID, revision: provider.revision, model: ids[index], completed: completed, total: ids.count, percent: ids.isEmpty ? 100 : Double((completed * 100) / ids.count), result: result))
                    enqueue()
                }
            }
            let values = output.compactMap { $0 }
            // Child probes translate cancellation into explicit per-model
            // results so callers can display deterministic progress. Preserve
            // the parent task's state separately for the batch-level result.
            let canceled = Task.isCancelled || values.contains { $0.capabilityStatus == .canceled }
            return ModelProbeResult(canceled: canceled, revision: provider.revision, results: values, completed: values.count, total: ids.count)
        }
        batches[providerID] = task
        defer { batches.removeValue(forKey: providerID) }
        do {
            let result = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
            // An explicitly canceled batch is terminal but must not race a
            // later provider edit by publishing its stale capability cache.
            guard !result.canceled else { return result }
            guard (try? await registry.descriptor(providerID: providerID).revision) == provider.revision else { return .init(canceled: true, revision: provider.revision, results: result.results, completed: result.completed, total: result.total) }
            if let save { try await save(providerID, revision, result.results) }
            return result
        } catch is CancellationError { return .init(canceled: true, revision: provider.revision, results: [], completed: 0, total: ids.count) }
    }

    public func cancel(providerID: String) async -> Bool {
        guard let task = batches[providerID] else { return false }
        task.cancel(); _ = try? await task.value; batches.removeValue(forKey: providerID); return true
    }

    public func close() async {
        let values = Array(batches.values); values.forEach { $0.cancel() }
        for task in values { _ = try? await task.value }
        batches.removeAll()
    }

    private nonisolated static func probeOne(id: String, provider: ProviderDescriptor, client: ProviderRecognitionClient, now: @Sendable () -> Date) async -> ModelCapabilityProbeResult {
        let checkedAt = ISO8601DateFormatter().string(from: now())
        do {
            guard let png = Data(base64Encoded: syntheticProbePNGBase64) else { throw RecognitionFailure.invalidInput }
            let image = try ProviderImage(data: png, mimeType: "image/png", width: 192, height: 64)
            let model = ResolvedModel(publicID: id, apiID: id, providerID: provider.id, label: id, imageDetail: .low, jsonMode: provider.jsonMode, capabilityStatus: .pending, revision: provider.revision)
            let schema: JSONValue = .object([
                "type": .string("object"), "additionalProperties": .boolean(false),
                "properties": .object([
                    "ok": .object(["type": .string("boolean")]),
                    "marker": .object(["type": .string("string")]),
                ]),
                "required": .array([.string("ok"), .string("marker")]),
            ])
            let response = try await client.recognize(.init(
                provider: provider, model: model, stage: .review,
                filename: "SlateSync capability probe", providerImages: [image],
                systemPrompt: "请识别图片中唯一的黑色大写文本，并仅返回 JSON；ok 必须为 true，marker 必须是你读到的文本的小写形式。",
                schema: schema, timeoutMilliseconds: timeoutMilliseconds,
                maximumTimeoutRetries: 0
            ))
            let value = try ProviderRecognitionClient.structuredJSON(from: response.text)
            guard case .object(let fields) = value, case .boolean(true)? = fields["ok"],
                  case .string(marker)? = fields["marker"] else { throw RecognitionFailure.invalidStructuredJSON }
            return .init(supported: true, model: id, transport: provider.transport, checkedAt: checkedAt, message: "视觉与结构化输出验证通过", capabilityStatus: .verified)
        } catch is CancellationError {
            return .init(supported: false, model: id, transport: provider.transport, checkedAt: checkedAt, message: "验证已取消", capabilityStatus: .canceled)
        } catch let error as SlateSyncError {
            if error.code == RecognitionFailure.canceled.code { return .init(supported: false, model: id, transport: provider.transport, checkedAt: checkedAt, message: "验证已取消", capabilityStatus: .canceled) }
            return .init(supported: false, model: id, transport: provider.transport, status: error.status, checkedAt: checkedAt, message: String(StructuredLogRedactor.redactText(error.message).prefix(500)), capabilityStatus: .failed)
        } catch {
            return .init(supported: false, model: id, transport: provider.transport, checkedAt: checkedAt, message: "视觉能力验证失败", capabilityStatus: .failed)
        }
    }
}

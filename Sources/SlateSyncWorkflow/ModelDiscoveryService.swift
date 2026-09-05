import Foundation
import SlateSyncDomain

public actor ModelDiscoveryService {
    private struct CacheEntry: Sendable {
        let createdAt: Double
        let value: ModelDiscoveryResult
    }

    public static let timeoutMilliseconds = 15_000
    public static let cacheTTLMilliseconds: Double = 5 * 60 * 1_000

    private let registry: ProviderRegistry
    private let transport: any ProviderHTTPTransporting
    private let clock: any ProviderClock
    private let now: @Sendable () -> Date
    private var cache: [String: CacheEntry] = [:]
    private var activeProviders = Set<String>()

    public init(
        registry: ProviderRegistry,
        transport: any ProviderHTTPTransporting,
        clock: any ProviderClock = SystemProviderClock(),
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.registry = registry
        self.transport = transport
        self.clock = clock
        self.now = now
    }

    public func discover(providerID: String, forceRefresh: Bool = false) async throws -> ModelDiscoveryResult {
        let provider = try await registry.descriptor(providerID: providerID)
        let legacyModel = providerID == "openai-compatible" ? await registry.setting(.openAICompatibleModel) : nil
        let key = [providerID, provider.baseURL.absoluteString, legacyModel ?? "", provider.revision.map(String.init) ?? "-"].joined(separator: "\u{1f}")
        if !forceRefresh, let cached = cache[key], clock.nowMilliseconds() - cached.createdAt < Self.cacheTTLMilliseconds { return cached.value }
        guard activeProviders.insert(providerID).inserted else { throw RecognitionFailure.discoveryBusy }
        defer { activeProviders.remove(providerID) }

        do {
            let response = try await transport.send(.init(
                provider: provider, purpose: .discovery, method: .get,
                timeoutMilliseconds: Self.timeoutMilliseconds
            ))
            let result = try await decode(response.body, provider: provider, modelsEndpointAvailable: true)
            cache[key] = .init(createdAt: clock.nowMilliseconds(), value: result)
            return result
        } catch let error as SlateSyncError {
            if provider.kind == .custom, [404, 405, 501].contains(error.status ?? -1) {
                let result = try await decode(Data("{}".utf8), provider: provider, modelsEndpointAvailable: false)
                cache[key] = .init(createdAt: clock.nowMilliseconds(), value: result)
                return result
            }
            // Configuration errors are actionable and must never masquerade as
            // successful static discovery. Runtime endpoint failures retain a
            // secret-free fallback so the settings UI remains usable offline.
            if error.status == 400 { throw error }
            let result = try await fallback(provider: provider, warning: error.message)
            cache[key] = .init(createdAt: clock.nowMilliseconds(), value: result)
            return result
        }
    }

    public func invalidate(providerID: String? = nil) async {
        if let providerID { cache = cache.filter { !$0.key.hasPrefix(providerID + "\u{1f}") } }
        else { cache.removeAll() }
        await registry.invalidate(providerID: providerID)
    }

    private func decode(_ data: Data, provider: ProviderDescriptor, modelsEndpointAvailable: Bool) async throws -> ModelDiscoveryResult {
        let root: JSONValue
        do { root = try JSONDecoder().decode(JSONValue.self, from: data) }
        catch {
            if provider.kind == .custom { return try await customUnavailable(provider: provider) }
            throw RecognitionFailure.invalidResponse
        }
        guard case .object(let fields) = root else { throw RecognitionFailure.invalidResponse }
        let candidates: [JSONValue]
        if case .array(let values)? = fields["data"] { candidates = values }
        else if case .array(let values)? = fields["models"] { candidates = values }
        else if provider.kind == .custom { return try await customUnavailable(provider: provider) }
        else { throw RecognitionFailure.invalidResponse }

        let custom = await registry.customConfiguration(providerID: provider.id)
        var usable: [ModelData] = [], pending: [ModelData] = [], failed: [ModelData] = []
        var unsupported: [ModelDiscoveryResult.UnsupportedModel] = []
        for candidate in candidates {
            guard let remote = RemoteModel(candidate), ProviderCatalog.isValidModelID(remote.id) else {
                if let id = RemoteModel.rawID(candidate) { unsupported.append(.init(id: String(id.prefix(220)), reason: "模型 ID 无效", capabilityStatus: .unsupported)) }
                continue
            }
            guard !ProviderCatalog.isExcluded(remote.id) else { unsupported.append(.init(id: remote.id, reason: "模型类型不支持场记图片识别", capabilityStatus: .unsupported)); continue }
            let fixed = ProviderCatalog.fixedModels(providerID: provider.id).first { ($0.apiId ?? $0.id) == remote.id }
            guard ProviderCatalog.allowsRemote(providerID: provider.id, modelID: remote.id, hasModalities: remote.hasModalities, acceptsVision: remote.acceptsVision, fixed: fixed != nil) else {
                unsupported.append(.init(id: remote.id, reason: "模型不在当前 Provider 的视觉识别集合中", capabilityStatus: .unsupported))
                continue
            }
            let cached = custom?.capabilityCache?[remote.id]
            let status: ModelCapabilityStatus
            if let cached, cached.revision == provider.revision,
               [.failed, .canceled, .verified].contains(cached.status) {
                status = cached.status
            }
            else if remote.hasModalities { status = remote.acceptsVision ? .declared : .unsupported }
            else if fixed != nil || ProviderCatalog.isKnownVisionFamily(remote.id) { status = .inferred }
            else { status = provider.kind == .custom ? .pending : .unsupported }
            if status == .unsupported { unsupported.append(.init(id: remote.id, reason: "接口未声明 image 输入与 text 输出", capabilityStatus: .unsupported)); continue }
            let profile = ProviderCatalog.qualityProfile(remote.id)
            let quality = fixed?.qualityScore ?? profile.score
            let value = fixed?.valueScore ?? ProviderCatalog.calculateValueScore(quality: quality, inputPrice: remote.inputPrice, outputPrice: remote.outputPrice)
            let model = ModelData(
                id: fixed?.id ?? remote.id, label: fixed?.label ?? remote.label,
                description: fixed?.description ?? (status == .pending ? "等待显式视觉能力验证" : profile.description),
                providers: [provider.id], vendor: remote.vendor ?? ProviderCatalog.vendor(for: remote.id),
                imageDetail: fixed?.imageDetail ?? provider.imageDetail, directId: fixed?.directId,
                apiId: remote.id, openRouterStructuredOutputs: provider.id == "openrouter" ? remote.supportsJSONSchema : true,
                fixed: fixed != nil, fixedPriority: fixed?.fixedPriority, discovered: true,
                verifiedAvailable: [.declared, .inferred, .verified].contains(status),
                qualityScore: quality, valueScore: value,
                qualityLabel: fixed?.qualityLabel ?? ProviderCatalog.qualityLabel(quality), valueLabel: fixed?.valueLabel ?? ProviderCatalog.valueLabel(value),
                capabilityStatus: status,
                capabilitySource: cached?.capabilitySource ?? (remote.hasModalities ? "API architecture" : "maintained model family"),
                capabilityMessage: bounded(cached?.message, 500), capabilityCheckedAt: bounded(cached?.checkedAt, 80),
                qualitySource: fixed?.qualitySource ?? (quality == nil ? nil : "SlateSync 维护的模型族参考评级"), qualityUpdatedAt: fixed?.qualityUpdatedAt ?? (quality == nil ? nil : "2026-08-02"),
                valueSource: fixed?.valueSource ?? (value == nil ? nil : "接口实时价格"), valueUpdatedAt: fixed?.valueUpdatedAt ?? (value == nil ? nil : ISO8601DateFormatter().string(from: now()))
            )
            switch status { case .failed: failed.append(model); case .pending, .canceled: pending.append(model); default: usable.append(model) }
        }

        if let custom {
            for modelID in custom.manualModelIds where !contains(modelID, in: usable + pending + failed) && !unsupported.contains(where: { $0.id == modelID }) {
                let entry = custom.capabilityCache?[modelID]
                let status: ModelCapabilityStatus = entry?.revision == custom.revision ? (entry?.status ?? .pending) : .pending
                let model = manual(modelID, provider: provider, status: status, verification: entry)
                switch status { case .verified: usable.append(model); case .failed: failed.append(model); default: pending.append(model) }
            }
        }

        usable = dedupe(usable)
        pending = dedupe(pending).filter { model in !contains(model.apiId ?? model.id, in: usable + failed) && !unsupported.contains(where: { $0.id == (model.apiId ?? model.id) }) }
        failed = dedupe(failed).filter { model in !contains(model.apiId ?? model.id, in: usable) }
        let resolved = usable.compactMap { model -> ResolvedModel? in
            guard let status = model.capabilityStatus, [.declared, .inferred, .verified].contains(status) else { return nil }
            return .init(publicID: model.id, apiID: model.apiId ?? model.id, providerID: provider.id, label: model.label, imageDetail: model.imageDetail ?? provider.imageDetail, jsonMode: provider.id == "openrouter" && model.openRouterStructuredOutputs == false ? .jsonObject : provider.jsonMode, capabilityStatus: status, revision: provider.revision)
        }
        await registry.register(resolved, providerID: provider.id, revision: provider.revision)
        return result(provider: provider, source: .api, availableCount: modelsEndpointAvailable ? Set(candidates.compactMap(RemoteModel.rawID)).count : nil, usable: ProviderCatalog.sort(usable), pending: pending, failed: failed, unsupported: unsupported, endpointAvailable: modelsEndpointAvailable, warning: modelsEndpointAvailable ? nil : "接口未提供 /models；请从手动模型 ID 中选择并验证。")
    }

    private func customUnavailable(provider: ProviderDescriptor) async throws -> ModelDiscoveryResult {
        let custom = await registry.customConfiguration(providerID: provider.id)
        var usable: [ModelData] = [], pending: [ModelData] = [], failed: [ModelData] = []
        for modelID in custom?.manualModelIds ?? [] {
            let verification = custom?.capabilityCache?[modelID]
            let status: ModelCapabilityStatus = verification?.revision == provider.revision ? (verification?.status ?? .pending) : .pending
            let model = manual(modelID, provider: provider, status: status, verification: verification)
            switch status {
            case .verified: usable.append(model)
            case .failed: failed.append(model)
            default: pending.append(model)
            }
        }
        let resolved = usable.map {
            ResolvedModel(publicID: $0.id, apiID: $0.apiId ?? $0.id, providerID: provider.id, label: $0.label, imageDetail: $0.imageDetail ?? provider.imageDetail, jsonMode: provider.jsonMode, capabilityStatus: .verified, revision: provider.revision)
        }
        await registry.register(resolved, providerID: provider.id, revision: provider.revision)
        return result(provider: provider, source: .api, availableCount: nil, usable: usable, pending: pending, failed: failed, unsupported: [], endpointAvailable: false, warning: "接口未提供 /models；请从手动模型 ID 中选择并验证。")
    }

    private func fallback(provider: ProviderDescriptor, warning: String) async throws -> ModelDiscoveryResult {
        if provider.kind == .custom { return try await customUnavailable(provider: provider) }
        let fixed = ProviderCatalog.fixedModels(providerID: provider.id)
        return result(provider: provider, source: .staticFallback, availableCount: nil, usable: fixed, pending: [], failed: [], unsupported: [], endpointAvailable: true, warning: bounded(warning, 500))
    }

    private func result(provider: ProviderDescriptor, source: ModelDiscoverySource, availableCount: Int?, usable: [ModelData], pending: [ModelData], failed: [ModelData], unsupported: [ModelDiscoveryResult.UnsupportedModel], endpointAvailable: Bool, warning: String?) -> ModelDiscoveryResult {
        .init(provider: provider.id, source: source, refreshedAt: ISO8601DateFormatter().string(from: now()), availableModelCount: availableCount, visionModelCount: usable.count, fixedModelCount: usable.filter { $0.fixed == true }.count, models: usable, pendingModelCount: pending.count, modelsEndpointAvailable: endpointAvailable, warning: warning, pendingModels: pending, unsupportedModelCount: unsupported.count, unsupportedModels: unsupported, failedModelCount: failed.count, failedModels: failed, statusCounts: .init(usable: usable.count, pending: pending.count, unsupported: unsupported.count, failed: failed.count))
    }

    private func manual(_ id: String, provider: ProviderDescriptor, status: ModelCapabilityStatus, verification: CustomProviderCapabilityVerification?) -> ModelData {
        .init(id: id, label: id, description: status == .verified ? "自定义接口模型" : "自定义接口模型，等待能力验证", providers: [provider.id], vendor: ProviderCatalog.vendor(for: id), imageDetail: provider.imageDetail, apiId: id, fixed: false, discovered: false, verifiedAvailable: status == .verified, capabilityStatus: status, capabilitySource: bounded(verification?.capabilitySource, 120) ?? "manual", capabilityMessage: bounded(verification?.message, 500), capabilityCheckedAt: bounded(verification?.checkedAt, 80))
    }
    private func contains(_ id: String, in models: [ModelData]) -> Bool { models.contains { ($0.apiId ?? $0.id) == id } }
    private func dedupe(_ values: [ModelData]) -> [ModelData] { var seen = Set<String>(); return values.filter { seen.insert($0.apiId ?? $0.id).inserted } }
    private func bounded(_ value: String?, _ limit: Int) -> String? { value.map { String(StructuredLogRedactor.redactText($0).prefix(limit)) } }
}

private struct RemoteModel {
    let id: String
    let label: String
    let vendor: String?
    let inputs: [String]
    let outputs: [String]
    let supportedParameters: [String]
    let inputPrice: Double?
    let outputPrice: Double?
    var hasModalities: Bool { !inputs.isEmpty || !outputs.isEmpty }
    var acceptsVision: Bool { inputs.contains("image") && outputs.contains("text") }
    var supportsJSONSchema: Bool { supportedParameters.contains { $0.lowercased().contains("response_format") || $0.lowercased().contains("structured") } }

    init?(_ value: JSONValue) {
        guard let id = Self.rawID(value) else { return nil }
        self.id = id
        if case .object(let fields) = value {
            self.label = Self.string(fields["name"]) ?? id
            self.vendor = Self.string(fields["owned_by"]) ?? Self.string(fields["vendor"])
            let architecture: [String: JSONValue]
            if case .object(let object)? = fields["architecture"] { architecture = object } else { architecture = [:] }
            self.inputs = Self.strings(architecture["input_modalities"] ?? fields["input_modalities"])
            self.outputs = Self.strings(architecture["output_modalities"] ?? fields["output_modalities"])
            self.supportedParameters = Self.strings(fields["supported_parameters"])
            let pricing: [String: JSONValue]
            if case .object(let object)? = fields["pricing"] { pricing = object } else { pricing = [:] }
            self.inputPrice = Self.perMillion(pricing["prompt"] ?? pricing["input"] ?? pricing["input_per_token"] ?? pricing["inputPerToken"])
            self.outputPrice = Self.perMillion(pricing["completion"] ?? pricing["output"] ?? pricing["output_per_token"] ?? pricing["outputPerToken"])
        } else { self.label = id; self.vendor = nil; self.inputs = []; self.outputs = []; self.supportedParameters = []; self.inputPrice = nil; self.outputPrice = nil }
    }
    static func rawID(_ value: JSONValue) -> String? {
        if case .string(let id) = value { return id.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard case .object(let fields) = value else { return nil }
        return ["id", "model", "name"].compactMap { string(fields[$0]) }.first?.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    private static func string(_ value: JSONValue?) -> String? { if case .string(let text)? = value { return text }; return nil }
    private static func strings(_ value: JSONValue?) -> [String] { guard case .array(let values)? = value else { return [] }; return values.compactMap(string).map { $0.lowercased() } }
    private static func perMillion(_ value: JSONValue?) -> Double? {
        let number: Double?
        switch value { case .number(let raw)?: number = raw; case .string(let raw)?: number = Double(raw); default: number = nil }
        guard let number, number.isFinite, number >= 0 else { return nil }
        return number * 1_000_000
    }
}

import Foundation
import SlateSyncDomain

/// A secret-free snapshot used to explain invalidation and restore explicitly chosen roles.
public struct ProviderSelections: Equatable, Sendable {
    public var primary: ProviderModelSelection?
    public var backups: [ProviderModelSelection]

    public init(_ values: GlobalSettingValues) {
        let provider = values[.defaultProviderID] ?? ""
        let model = values[.defaultModelID] ?? ""
        primary = provider.isEmpty || model.isEmpty ? nil : .init(providerID: provider, modelID: model)
        backups = (try? ProviderModelSelection.decodeAndValidateChain(values[.recognitionFailoverChain] ?? "[]")) ?? []
    }

    /// Predict only this operation's revocation. Never derive the restoration
    /// baseline from a possibly stale projection after a partial credential write.
    func removing(_ providerID: String) -> Self {
        var value = self
        if value.primary?.providerID == providerID { value.primary = nil }
        value.backups.removeAll { $0.providerID == providerID }
        return value
    }

    func contains(_ providerID: String) -> Bool {
        primary?.providerID == providerID || backups.contains { $0.providerID == providerID }
    }
}

/// Commands rebase on committed state instead of submitting a stale full-page draft.
public enum ProviderSelectionChange: Sendable {
    case setDefault(ProviderModelSelection?)
    case addBackup(ProviderModelSelection)
    case removeBackup(ProviderModelSelection)
    case moveBackup(ProviderModelSelection, Int)
    case removeService(String)
    case restore(providerID: String, original: ProviderSelections, expected: ProviderSelections)

    func applying(to snapshot: GlobalSettingsProjection) throws -> (values: GlobalSettingValues, providers: [CustomProviderConfiguration]) {
        var selections = ProviderSelections(snapshot.values)
        var providers = snapshot.customProviders
        func requireVerified(_ pair: ProviderModelSelection) throws {
            guard ProviderPresentation.isVerified(pair, in: snapshot) else {
                throw SlateSyncError(code: "MODEL_NOT_VERIFIED", message: L10n.tr("请先验证所选模型。"))
            }
        }
        switch self {
        case .setDefault(let pair):
            if let pair { try requireVerified(pair) }
            selections.primary = pair
        case .addBackup(let pair):
            try requireVerified(pair)
            if !selections.backups.contains(pair) { selections.backups.append(pair) }
        case .removeBackup(let pair):
            selections.backups.removeAll { $0 == pair }
        case .moveBackup(let pair, let offset):
            guard let index = selections.backups.firstIndex(of: pair),
                  selections.backups.indices.contains(index + offset) else { break }
            selections.backups.swapAt(index, index + offset)
        case .removeService(let id):
            providers.removeAll { $0.id == id }
            if selections.primary?.providerID == id { selections.primary = nil }
            selections.backups.removeAll { $0.providerID == id }
        case .restore(let id, let original, let expected):
            guard selections == expected else {
                throw SlateSyncError(code: "PROVIDER_SELECTION_CHANGED", message: L10n.tr("默认或备用模型已改变，请重新选择用途。"))
            }
            if let pair = original.primary, pair.providerID == id, ProviderPresentation.isVerified(pair, in: snapshot) {
                selections.primary = pair
            }
            for (index, pair) in original.backups.enumerated()
                where pair.providerID == id && ProviderPresentation.isVerified(pair, in: snapshot) && !selections.backups.contains(pair) {
                selections.backups.insert(pair, at: min(index, selections.backups.count))
            }
        }
        var values = snapshot.values
        values[.defaultProviderID] = selections.primary?.providerID
        values[.defaultModelID] = selections.primary?.modelID
        values[.recognitionFailoverChain] = try ProviderModelSelection.encodeChain(selections.backups)
        try GlobalSettingsValidator.validateProviderSelections(values)
        return (values, providers)
    }
}

/// Presentation derives eligibility from current proof, never from discovery heuristics.
enum ProviderPresentation {
    /// One rule serves immediate commits, full-page draft saves and model pickers.
    static func isVerified(_ pair: ProviderModelSelection, in snapshot: GlobalSettingsProjection,
                           customProviders: [CustomProviderConfiguration]? = nil) -> Bool {
        if let custom = (customProviders ?? snapshot.customProviders).first(where: { $0.id == pair.providerID }) {
            let legacy = custom.id == ProviderKind.openAICompatible.rawValue
                && pair.modelID == ProviderKind.openAICompatible.rawValue + "/custom"
            let physical = snapshot.models.first { $0.id == pair.modelID && $0.providers.contains(pair.providerID) }?.apiId
                ?? (legacy ? custom.manualModelIds.first ?? pair.modelID : pair.modelID)
            guard custom.manualModelIds.contains(physical), let proof = custom.capabilityCache?[physical] else { return false }
            return proof.revision == custom.revision && proof.status == .verified
        }
        return snapshot.models.contains { $0.id == pair.modelID && $0.providers.contains(pair.providerID)
            && $0.capabilityStatus == .verified && $0.verifiedAvailable != false }
    }

    static func models(providerID: String, snapshot: GlobalSettingsProjection?, discovery: ModelDiscoveryResult?, probe: ModelProbeResult? = nil) -> [ModelData] {
        var byID: [String: ModelData] = [:]
        let discovered = (discovery?.models ?? []) + (discovery?.pendingModels ?? []) + (discovery?.failedModels ?? [])
        for model in discovered { byID[model.apiId ?? model.id] = model }
        for unsupported in discovery?.unsupportedModels ?? [] {
            byID[unsupported.id] = .init(id: unsupported.id, label: unsupported.id, description: "", providers: [providerID],
                                        capabilityStatus: .unsupported, capabilityMessage: unsupported.reason)
        }
        // Static candidates cannot erase an explicit API rejection. Only current
        // persisted probe outcomes may supersede discovery's capability judgment.
        for model in snapshot?.models.filter({ $0.providers.contains(providerID) }) ?? [] {
            let id = model.apiId ?? model.id
            let hasProof = [.verified, .failed, .canceled].contains(model.capabilityStatus)
            if let negative = byID[id], negative.capabilityStatus == .unsupported, !hasProof {
                byID[id] = .init(id: model.id, label: model.label, description: model.description,
                    providers: [providerID], apiId: id, verifiedAvailable: false,
                    capabilityStatus: .unsupported, capabilityMessage: negative.capabilityMessage)
            } else if hasProof || byID[id] == nil {
                byID[id] = model
            }
        }
        if let custom = snapshot?.customProviders.first(where: { $0.id == providerID }) {
            for id in custom.manualModelIds {
                let cached = custom.capabilityCache?[id]
                let proof = cached?.revision == custom.revision ? cached : nil
                let old = byID[id]
                let hasProof = [.verified, .failed, .canceled].contains(proof?.status)
                if old?.capabilityStatus == .unsupported, !hasProof { continue }
                let status = proof?.status ?? .pending
                byID[id] = .init(id: old?.id ?? id, label: old?.label ?? id, description: "", providers: [providerID], apiId: id,
                    verifiedAvailable: status == .verified, capabilityStatus: status, capabilityMessage: proof?.message)
            }
        }
        // Transient results enrich diagnostics, never grant eligibility over a
        // newer snapshot (or proof invalidated by a subsequent configuration edit).
        let customRevision = snapshot?.customProviders.first { $0.id == providerID }?.revision
        if let probe, !probe.canceled, probe.revision == customRevision {
            for result in probe.results {
                guard let current = byID[result.model], current.capabilityStatus == result.capabilityStatus,
                      [.verified, .failed, .canceled].contains(current.capabilityStatus) else { continue }
                byID[result.model] = .init(id: current.id, label: current.label, description: current.description,
                    providers: current.providers, apiId: current.apiId, verifiedAvailable: current.verifiedAvailable,
                    capabilityStatus: current.capabilityStatus, capabilityMessage: result.message)
            }
        }
        return byID.values.sorted {
            let lhs = rank($0.capabilityStatus), rhs = rank($1.capabilityStatus)
            return lhs == rhs ? $0.label.localizedStandardCompare($1.label) == .orderedAscending : lhs < rhs
        }
    }

    /// Anonymous custom endpoints stay usable; only providers declaring an auth requirement are gated.
    static func canUseModels(requiresCredential: Bool, hasSavedCredential: Bool, draftKey: String = "") -> Bool {
        !requiresCredential || hasSavedCredential || !draftKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    static func rank(_ status: ModelCapabilityStatus?) -> Int {
        switch status { case .verified: 0; case .failed, .canceled: 2; case .unsupported: 3; default: 1 }
    }

    static func status(_ status: ModelCapabilityStatus?) -> String {
        switch status {
        case .verified: L10n.tr("识别验证通过")
        case .failed: L10n.tr("验证失败")
        case .unsupported: L10n.tr("不支持识别")
        case .canceled: L10n.tr("验证已取消")
        default: L10n.tr("待验证")
        }
    }

    static func discoverySummary(_ result: ModelDiscoveryResult) -> String {
        let models = result.models + (result.pendingModels ?? []) + (result.failedModels ?? [])
        let known = Set(models.map { $0.apiId ?? $0.id } + (result.unsupportedModels ?? []).map(\.id)).count
        let verified = Set(models.filter { $0.capabilityStatus == .verified && $0.verifiedAvailable != false }.map { $0.apiId ?? $0.id }).count
        if result.source != .api || result.modelsEndpointAvailable == false {
            return L10n.tr("未确认连接，显示本地模型目录")
        }
        return L10n.tr("已发现 {0} 个模型，其中已验证 {1} 个", [String(result.availableModelCount ?? known), String(verified)])
    }

    static func probeSummary(_ result: ModelProbeResult) -> String {
        let passed = result.results.filter { $0.capabilityStatus == .verified }.count
        let canceled = result.results.filter { $0.capabilityStatus == .canceled }.count + max(0, result.total - result.completed)
        let failed = result.results.filter { $0.capabilityStatus != .verified && $0.capabilityStatus != .canceled }.count
        return L10n.tr("通过 {0} 个，失败 {1} 个，取消 {2} 个", [String(passed), String(failed), String(canceled)])
    }

    static func errorMessage(_ error: SlateSyncError) -> String {
        switch error.status {
        case 401, 403: L10n.tr("鉴权或权限不足：请检查或替换 API Key。")
        case 402: L10n.tr("账户余额或额度不足：请前往服务商账户检查。")
        case 429: L10n.tr("请求过于频繁或达到额度限制：请稍后重试并检查服务商账户。")
        case 404, 405, 501: L10n.tr("无法获取 /models；请检查基础地址，或手动填写模型 ID 后验证。")
        default: L10n.message(error.message)
        }
    }
}

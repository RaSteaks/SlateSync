import Foundation
import SlateSyncDomain

public enum ProviderCatalog {
    public struct Definition: Hashable, Sendable {
        public let id: String
        public let label: String
        public let defaultBaseURL: String
        public let baseURLSetting: GlobalSettingKey
        public let transport: ProviderTransport
        public let jsonMode: ProviderJSONMode
        public let credentialRequired: Bool
    }

    public static let definitions: [Definition] = [
        .init(id: "openai", label: "OpenAI 官方 API", defaultBaseURL: "https://api.openai.com/v1", baseURLSetting: .openAIBaseUrl, transport: .responses, jsonMode: .jsonSchema, credentialRequired: true),
        .init(id: "openrouter", label: "OpenRouter API", defaultBaseURL: "https://openrouter.ai/api/v1", baseURLSetting: .openRouterBaseUrl, transport: .chatCompletions, jsonMode: .jsonSchema, credentialRequired: true),
        .init(id: "tokenplan", label: "阿里云 Token Plan", defaultBaseURL: "https://dashscope.aliyuncs.com/compatible-mode/v1", baseURLSetting: .tokenPlanBaseUrl, transport: .chatCompletions, jsonMode: .jsonSchema, credentialRequired: true),
        .init(id: "dashscope", label: "阿里云百炼（DashScope）", defaultBaseURL: "https://dashscope.aliyuncs.com/compatible-mode/v1", baseURLSetting: .dashScopeBaseUrl, transport: .chatCompletions, jsonMode: .jsonSchema, credentialRequired: true),
        .init(id: "openai-compatible", label: "OpenAI 兼容 API", defaultBaseURL: "", baseURLSetting: .openAICompatibleBaseUrl, transport: .chatCompletions, jsonMode: .jsonObject, credentialRequired: true),
    ]

    /// Curated records intentionally omit raw price data. Public value scores
    /// retain the frozen catalog's user-facing ranking without exposing cost.
    public static let models: [ModelData] = [
        model("qwen/qwen3.7-flash", "Qwen 3.7 Flash", "快速中文视觉识别", ["openrouter"], quality: 76, value: 96, structured: false),
        model("openai/gpt-5.6-luna", "GPT-5.6 Luna", "高吞吐视觉识别", ["openai", "openrouter"], direct: "gpt-5.6-luna", detail: .original, quality: 88, value: 78),
        model("openai/gpt-5.6-terra", "GPT-5.6 Terra", "高准确率视觉识别", ["openai", "openrouter"], direct: "gpt-5.6-terra", detail: .original, quality: 95, value: 71),
        model("openai/gpt-4o-mini", "GPT-4o mini", "稳定基准模型", ["openai", "openrouter"], direct: "gpt-4o-mini", quality: 74, value: 91),
        model("qwen3.7-plus", "Qwen 3.7 Plus", "Token Plan 高质量中文视觉识别", ["tokenplan"], quality: 87, value: 83),
        model("qwen3.8-max", "Qwen 3.8 Max", "百炼多模态旗舰 · 高精度视觉推理", ["tokenplan", "dashscope"], quality: 93, value: 78),
        model("qwen3.7-max", "Qwen 3.7 Max", "百炼多模态视觉理解", ["dashscope"], quality: 91, value: 80),
        model("qwen3.6-flash", "Qwen 3.6 Flash", "Token Plan 快速中文视觉识别", ["tokenplan"], quality: 76, value: 88),
        model("qwen3.6-plus", "Qwen 3.6 Plus", "Token Plan 均衡视觉识别（团队版）", ["tokenplan"], quality: 84, value: 85),
        model("qwen-vl-max-latest", "Qwen VL Max", "百炼高精度中文视觉理解", ["dashscope"], quality: 90, value: 82),
        model("qwen3-vl-plus-latest", "Qwen3 VL Plus", "百炼均衡中文视觉识别", ["dashscope"], quality: 85, value: 88),
        model("qwen-vl-plus-latest", "Qwen VL Plus", "百炼快速中文视觉识别", ["dashscope"], quality: 78, value: 90),
    ]

    public static func definition(id: String) -> Definition? {
        definitions.first { $0.id == id }
    }

    public static func fixedModels(providerID: String) -> [ModelData] {
        models.enumerated().compactMap { index, source in
            guard source.providers.contains(providerID) else { return nil }
            let apiID = providerID == "openai" ? (source.directId ?? source.id) : source.id
            return ModelData(
                id: source.id,
                label: source.label,
                description: source.description,
                providers: [providerID],
                vendor: vendor(for: apiID),
                imageDetail: source.imageDetail,
                directId: source.directId,
                apiId: apiID,
                openRouterStructuredOutputs: source.openRouterStructuredOutputs,
                fixed: true,
                fixedPriority: index,
                discovered: false,
                verifiedAvailable: false,
                qualityScore: source.qualityScore,
                valueScore: source.valueScore,
                qualityLabel: qualityLabel(source.qualityScore),
                valueLabel: valueLabel(source.valueScore),
                capabilityStatus: .declared,
                capabilitySource: "SlateSync maintained catalog",
                qualitySource: "SlateSync 维护的模型族参考评级",
                qualityUpdatedAt: source.qualityUpdatedAt,
                valueSource: "内置价格目录",
                valueUpdatedAt: source.valueUpdatedAt
            )
        }
    }

    public static func resolveFixed(providerID: String, modelID: String) -> ResolvedModel? {
        guard let model = fixedModels(providerID: providerID).first(where: {
            $0.id == modelID || $0.apiId == modelID || $0.directId == modelID
        }) else { return nil }
        let mode: ProviderJSONMode = providerID == "openrouter" && model.openRouterStructuredOutputs == false ? .jsonObject : .jsonSchema
        return ResolvedModel(
            publicID: model.id,
            apiID: model.apiId ?? model.id,
            providerID: providerID,
            label: model.label,
            imageDetail: model.imageDetail ?? .high,
            jsonMode: mode,
            capabilityStatus: model.capabilityStatus ?? .declared
        )
    }

    public static func isValidModelID(_ value: String) -> Bool {
        (1...220).contains(JavaScriptCompatibility.utf16Length(value)) &&
            value.range(of: #"^[A-Za-z0-9][A-Za-z0-9._:/@-]*$"#, options: .regularExpression) != nil
    }

    public static func isExcluded(_ value: String) -> Bool {
        let id = value.lowercased()
        return ["embedding", "tts", "whisper", "audio", "realtime", "moderation", "image", "dall-e", "sora"].contains { id.contains($0) }
    }

    public static func isKnownVisionFamily(_ value: String) -> Bool {
        let id = value.lowercased()
        return id.contains("gpt-4") || id.contains("gpt-5") || id.contains("qwen") && (id.contains("vl") || id.contains("3.6") || id.contains("3.7") || id.contains("3.8")) || id.contains("claude-3") || id.contains("claude-4") || id.contains("gemini") || id.contains("pixtral")
    }

    /// Provider-specific admission prevents a generic image flag from making
    /// an unlicensed or non-catalog model selectable on constrained APIs.
    public static func allowsRemote(providerID: String, modelID: String, hasModalities: Bool, acceptsVision: Bool, fixed: Bool) -> Bool {
        if fixed { return true }
        switch providerID {
        case "openai": return openAIProfile(modelID) != nil
        case "tokenplan":
            return modelID.range(of: #"^qwen3\.(?:8-max(?:-preview)?|7-plus|6-(?:plus|flash))(?:-\d{4}-\d{2}-\d{2})?$"#, options: [.regularExpression, .caseInsensitive]) != nil
        case "dashscope":
            return modelID.range(of: #"^qwen(?:\d(?:\.\d+)?)?-vl(?:-[\w.-]+)?$|^qwen-vl-(?:max|plus)(?:-[\w.-]+)?$|^qwen3\.(?:8-max|7-max)(?:-[\w.-]+)?$"#, options: [.regularExpression, .caseInsensitive]) != nil
        case "openrouter": return hasModalities && acceptsVision
        case "openai-compatible": return hasModalities ? acceptsVision : isKnownVisionFamily(modelID)
        default: return hasModalities ? acceptsVision : isKnownVisionFamily(modelID)
        }
    }

    public static func qualityProfile(_ modelID: String) -> (score: Double?, description: String) {
        if let profile = openAIProfile(modelID) { return profile }
        let id = modelID.lowercased()
        if id.contains("qwen3.8-max") { return (93, "高精度中文视觉推理") }
        if id.contains("qwen3.7-max") { return (91, "高精度多模态视觉理解") }
        if id.contains("qwen3.7-plus") { return (87, "高质量中文视觉识别") }
        if id.contains("qwen3.7-flash") || id.contains("qwen3.6-flash") { return (76, "快速中文视觉识别") }
        if id.contains("qwen3.6-plus") || id.contains("qwen3-vl") { return (84, "均衡中文视觉识别") }
        if id.contains("qwen") && (id.contains("vl") || id.contains("vision")) { return (id.contains("thinking") ? 84 : 79, "中文文档与 OCR 视觉模型") }
        if id.range(of: #"claude-(?:3|4).*opus"#, options: .regularExpression) != nil { return (97, "质量优先视觉理解") }
        if id.range(of: #"claude-(?:3|4).*sonnet"#, options: .regularExpression) != nil { return (91, "高质量视觉理解") }
        if id.range(of: #"claude-(?:3|4).*haiku"#, options: .regularExpression) != nil { return (77, "快速视觉理解") }
        if id.contains("gemini") && (id.contains("pro") || id.contains("ultra") || id.contains("vision")) { return (94, "高质量多模态理解") }
        if id.contains("gemini") && id.contains("flash") { return (id.contains("lite") ? 74 : 86, "高吞吐多模态识别") }
        if id.contains("llama") && id.contains("vision") || id.contains("pixtral") || id.contains("mistral") && id.contains("vision") { return (78, "开放视觉理解模型") }
        return (nil, "API 声明支持图像输入与文本输出")
    }

    public static func calculateValueScore(quality: Double?, inputPrice: Double?, outputPrice: Double?) -> Double? {
        guard let quality, inputPrice != nil || outputPrice != nil else { return nil }
        let effective = (inputPrice ?? 0) + (outputPrice ?? 0) * 0.2
        let costScore = max(20, 100 - 28 * log10(1 + effective))
        return (quality * 0.7 + costScore * 0.3).rounded()
    }

    public static func qualityLabel(_ score: Double?) -> String {
        guard let score else { return "精度暂无数据" }
        switch score { case 96...: return "S"; case 90..<96: return "A+"; case 84..<90: return "A"; case 77..<84: return "B+"; default: return "B" }
    }

    public static func valueLabel(_ score: Double?) -> String {
        guard let score else { return "价格未知" }
        switch score { case 90...: return "S"; case 84..<90: return "A+"; case 78..<84: return "A"; case 70..<78: return "B+"; default: return "B" }
    }

    public static func vendor(for modelID: String) -> String {
        if let prefix = modelID.split(separator: "/").first, modelID.contains("/") { return String(prefix).lowercased() }
        let id = modelID.lowercased()
        if id.hasPrefix("gpt") || id.hasPrefix("o3") || id.hasPrefix("o4") { return "openai" }
        if id.contains("qwen") { return "qwen" }
        if id.contains("claude") { return "anthropic" }
        if id.contains("gemini") || id.contains("gemma") { return "google" }
        return "other"
    }

    public static func sort(_ values: [ModelData]) -> [ModelData] {
        values.sorted { left, right in
            if (left.fixed ?? false) != (right.fixed ?? false) { return left.fixed == true }
            if left.fixed == true, right.fixed == true {
                if left.fixedPriority != right.fixedPriority { return (left.fixedPriority ?? .max) < (right.fixedPriority ?? .max) }
            }
            if left.valueScore != right.valueScore { return (left.valueScore ?? -.infinity) > (right.valueScore ?? -.infinity) }
            if left.qualityScore != right.qualityScore { return (left.qualityScore ?? -.infinity) > (right.qualityScore ?? -.infinity) }
            return left.label.localizedStandardCompare(right.label) == .orderedAscending
        }
    }

    private static func model(
        _ id: String,
        _ label: String,
        _ description: String,
        _ providers: [String],
        direct: String? = nil,
        detail: ImageDetail = .high,
        quality: Double,
        value: Double,
        structured: Bool = true
    ) -> ModelData {
        ModelData(
            id: id, label: label, description: description, providers: providers,
            imageDetail: detail, directId: direct, openRouterStructuredOutputs: structured,
            qualityScore: quality, valueScore: value,
            qualityUpdatedAt: "2026-08-02", valueUpdatedAt: "2026-08-02"
        )
    }

    private static func openAIProfile(_ modelID: String) -> (score: Double?, description: String)? {
        let id = modelID.lowercased().replacingOccurrences(of: "openai/", with: "")
        let profiles: [(String, Double, String)] = [
            (#"^gpt-5\.6(?:-sol)?(?:-\d{4}-\d{2}-\d{2})?$"#, 100, "旗舰视觉理解"),
            (#"^gpt-5\.6-terra(?:-\d{4}-\d{2}-\d{2})?$"#, 95, "高准确率视觉识别"),
            (#"^gpt-5\.6-luna(?:-\d{4}-\d{2}-\d{2})?$"#, 88, "高吞吐视觉识别"),
            (#"^gpt-5\.5-pro(?:-\d{4}-\d{2}-\d{2})?$"#, 98, "高准确率专业模型"),
            (#"^gpt-5\.5(?:-\d{4}-\d{2}-\d{2})?$"#, 95, "高准确率通用模型"),
            (#"^gpt-5\.4-pro(?:-\d{4}-\d{2}-\d{2})?$"#, 97, "高准确率专业模型"),
            (#"^gpt-5\.4-mini(?:-\d{4}-\d{2}-\d{2})?$"#, 89, "快速视觉识别"),
            (#"^gpt-5\.4-nano(?:-\d{4}-\d{2}-\d{2})?$"#, 76, "轻量批量识别"),
            (#"^gpt-5\.4(?:-\d{4}-\d{2}-\d{2})?$"#, 94, "高准确率视觉理解"),
            (#"^gpt-5\.2-pro(?:-\d{4}-\d{2}-\d{2})?$"#, 94, "上一代专业模型"),
            (#"^gpt-5\.2(?:-\d{4}-\d{2}-\d{2})?$"#, 90, "上一代高质量模型"),
            (#"^gpt-5\.1(?:-\d{4}-\d{2}-\d{2})?$"#, 87, "上一代通用模型"),
            (#"^gpt-5-(?:pro|mini|nano)(?:-\d{4}-\d{2}-\d{2})?$|^gpt-5(?:-\d{4}-\d{2}-\d{2})?$"#, 88, "通用视觉推理"),
            (#"^o3(?:-pro)?(?:-\d{4}-\d{2}-\d{2})?$|^o4-mini(?:-\d{4}-\d{2}-\d{2})?$"#, 87, "视觉推理模型"),
            (#"^gpt-4\.1(?:-mini|-nano)?(?:-\d{4}-\d{2}-\d{2})?$|^gpt-4o(?:-mini)?(?:-\d{4}-\d{2}-\d{2})?$"#, 84, "稳定视觉理解"),
        ]
        for (pattern, score, description) in profiles where id.range(of: pattern, options: .regularExpression) != nil { return (score, description) }
        return nil
    }
}

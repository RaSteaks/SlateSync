import Foundation
import SlateSyncDomain

public enum ProviderCatalog {
    /// A bounded set of provider-specific options that the native form can
    /// explain and validate. Arbitrary authentication headers intentionally
    /// never enter this metadata surface.
    public struct AdvancedOption: Hashable, Sendable, Identifiable {
        public let key: GlobalSettingKey
        public let title: String
        public let description: String
        public let defaultValue: String
        public let isRequired: Bool

        public var id: GlobalSettingKey { key }

        public init(
            key: GlobalSettingKey,
            title: String,
            description: String,
            defaultValue: String = "",
            isRequired: Bool = false
        ) {
            self.key = key
            self.title = title
            self.description = description
            self.defaultValue = defaultValue
            self.isRequired = isRequired
        }
    }

    public struct Definition: Hashable, Sendable {
        public let id: String
        public let kind: ProviderKind
        public let label: String
        public let defaultBaseURL: String
        public let baseURLSetting: GlobalSettingKey
        public let transport: ProviderTransport
        public let jsonMode: ProviderJSONMode
        public let credentialRequired: Bool
        public let serviceDescription: String
        public let websiteURL: String?
        public let apiKeyURL: String?
        public let documentationURL: String?
        public let apiKeyHint: String
        public let protocolDescription: String
        public let modelHint: String
        public let helpSectionID: String
        public let advancedOptions: [AdvancedOption]

        public init(
            id: String,
            kind: ProviderKind,
            label: String,
            defaultBaseURL: String,
            baseURLSetting: GlobalSettingKey,
            transport: ProviderTransport,
            jsonMode: ProviderJSONMode,
            credentialRequired: Bool,
            serviceDescription: String = "",
            websiteURL: String? = nil,
            apiKeyURL: String? = nil,
            documentationURL: String? = nil,
            apiKeyHint: String = "",
            protocolDescription: String = "",
            modelHint: String = "",
            helpSectionID: String = "providers",
            advancedOptions: [AdvancedOption] = []
        ) {
            self.id = id
            self.kind = kind
            self.label = label
            self.defaultBaseURL = defaultBaseURL
            self.baseURLSetting = baseURLSetting
            self.transport = transport
            self.jsonMode = jsonMode
            self.credentialRequired = credentialRequired
            self.serviceDescription = serviceDescription
            self.websiteURL = websiteURL
            self.apiKeyURL = apiKeyURL
            self.documentationURL = documentationURL
            self.apiKeyHint = apiKeyHint
            self.protocolDescription = protocolDescription
            self.modelHint = modelHint
            self.helpSectionID = helpSectionID
            self.advancedOptions = advancedOptions
        }
    }

    public static let definitions: [Definition] = [
        .init(
            id: "openai",
            kind: .openAI,
            label: "OpenAI 官方 API",
            defaultBaseURL: "https://api.openai.com/v1",
            baseURLSetting: .openAIBaseUrl,
            transport: .responses,
            jsonMode: .jsonSchema,
            credentialRequired: true,
            serviceDescription: "使用 OpenAI 官方 Responses API 进行视觉识别。API Key 由 OpenAI 控制台创建，应用不会读取或回显已保存的密钥。",
            websiteURL: "https://platform.openai.com",
            apiKeyURL: "https://platform.openai.com/api-keys",
            documentationURL: "https://platform.openai.com/docs/guides/vision",
            apiKeyHint: "填写 OpenAI 创建的 API Key，不要添加 Bearer 前缀。",
            protocolDescription: "OpenAI Responses API；应用会在 Base URL 后追加 /responses。",
            modelHint: "模型列表与视觉能力以服务端响应为准；项目和任务仍各自保存当前模型选择。"
        ),
        .init(
            id: "openrouter",
            kind: .openRouter,
            label: "OpenRouter API",
            defaultBaseURL: "https://openrouter.ai/api/v1",
            baseURLSetting: .openRouterBaseUrl,
            transport: .chatCompletions,
            jsonMode: .jsonSchema,
            credentialRequired: true,
            serviceDescription: "通过 OpenRouter 的 OpenAI 兼容接口访问多个视觉模型。模型和能力状态来自现有发现、验证流程。",
            websiteURL: "https://openrouter.ai",
            apiKeyURL: "https://openrouter.ai/keys",
            documentationURL: "https://openrouter.ai/docs/quickstart#using-the-openai-sdk",
            apiKeyHint: "填写 OpenRouter 创建的 API Key，不需要添加 Bearer 前缀。",
            protocolDescription: "OpenAI 兼容的 Chat Completions；应用会在 Base URL 后追加 /chat/completions。",
            modelHint: "模型 ID 使用 OpenRouter 返回的完整值，例如供应商前缀也属于 ID 的一部分。",
            advancedOptions: [
                .init(
                    key: .openRouterSiteUrl,
                    title: "站点 URL",
                    description: "可选，对应 HTTP-Referer，用于标识请求来源；留空时不发送该请求头。",
                    defaultValue: "https://github.com/RaSteaks/SlateSync"
                ),
                .init(
                    key: .openRouterAppTitle,
                    title: "应用名称",
                    description: "可选，对应 X-OpenRouter-Title；用于来源标识，不影响基本连接。",
                    defaultValue: "SlateSync"
                ),
            ]
        ),
        .init(
            id: "tokenplan",
            kind: .tokenPlan,
            label: "阿里云 Token Plan",
            defaultBaseURL: "https://dashscope.aliyuncs.com/compatible-mode/v1",
            baseURLSetting: .tokenPlanBaseUrl,
            transport: .chatCompletions,
            jsonMode: .jsonSchema,
            credentialRequired: true,
            serviceDescription: "使用阿里云 Token Plan 的兼容模式接口进行视觉识别，额度与模型权限由阿里云账户控制。",
            websiteURL: "https://www.aliyun.com/product/ai/tokenplan",
            apiKeyURL: "https://bailian.console.aliyun.com/",
            documentationURL: "https://help.aliyun.com/zh/model-studio/developer-reference/compatibility-of-openai-with-dashscope",
            apiKeyHint: "填写阿里云百炼或 Token Plan 创建的 API Key，不要添加 Bearer 前缀。",
            protocolDescription: "OpenAI 兼容的 Chat Completions；应用会在 Base URL 后追加 /chat/completions。",
            modelHint: "只会把服务端声明并通过视觉筛选的模型纳入可用列表。"
        ),
        .init(
            id: "dashscope",
            kind: .dashScope,
            label: "阿里云百炼（DashScope）",
            defaultBaseURL: "https://dashscope.aliyuncs.com/compatible-mode/v1",
            baseURLSetting: .dashScopeBaseUrl,
            transport: .chatCompletions,
            jsonMode: .jsonSchema,
            credentialRequired: true,
            serviceDescription: "使用阿里云百炼兼容模式访问通义系列视觉模型，模型权限和余额由百炼控制台管理。",
            websiteURL: "https://bailian.console.aliyun.com/",
            apiKeyURL: "https://bailian.console.aliyun.com/",
            documentationURL: "https://help.aliyun.com/zh/model-studio/developer-reference/compatibility-of-openai-with-dashscope",
            apiKeyHint: "填写百炼控制台创建的 API Key，不要添加 Bearer 前缀。",
            protocolDescription: "OpenAI 兼容的 Chat Completions；应用会在 Base URL 后追加 /chat/completions。",
            modelHint: "模型 ID 保留服务端真实值；列表成功不代表每个模型都可用于当前识别任务。"
        ),
        .init(
            id: "openai-compatible",
            kind: .openAICompatible,
            label: "OpenAI 兼容 API",
            defaultBaseURL: "",
            baseURLSetting: .openAICompatibleBaseUrl,
            transport: .chatCompletions,
            jsonMode: .jsonObject,
            credentialRequired: true,
            serviceDescription: "连接支持 OpenAI 请求格式的第三方服务或本地服务。请向服务维护者确认 Base URL、模型 ID 和认证方式。",
            apiKeyHint: "填写服务方要求的密钥，不要添加 Bearer 前缀；匿名本地服务仍需由服务方确认是否支持。",
            protocolDescription: "默认使用 Chat Completions；可在高级选项中切换 Responses 和 JSON 行为。",
            modelHint: "必须填写服务方提供的真实模型 ID；能力验证可能会产生一次模型调用。",
            advancedOptions: [
                .init(
                    key: .openAICompatibleModel,
                    title: "模型 ID",
                    description: "服务方公开的真实模型 ID；该字段用于兼容接口无法自动列出模型时的请求。",
                    defaultValue: "your-vision-model",
                    isRequired: true
                ),
                .init(
                    key: .openAICompatibleAPIMode,
                    title: "API 协议",
                    description: "选择服务实际支持的请求形状。默认是 Chat Completions。",
                    defaultValue: "chat-completions"
                ),
                .init(
                    key: .openAICompatibleJSONMode,
                    title: "JSON 模式",
                    description: "控制结构化识别结果的请求方式；默认使用 JSON Object。",
                    defaultValue: "json_object"
                ),
                .init(
                    key: .openAICompatibleImageDetail,
                    title: "图像细节",
                    description: "发送给兼容服务的图像细节级别；具体支持范围由服务方决定。",
                    defaultValue: "high"
                ),
            ]
        ),
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
            let apiID = ProviderKind(id: providerID) == .openAI ? (source.directId ?? source.id) : source.id
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
        let mode: ProviderJSONMode = ProviderKind(id: providerID) == .openRouter && model.openRouterStructuredOutputs == false ? .jsonObject : .jsonSchema
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
        switch ProviderKind(id: providerID) {
        case .openAI: return openAIProfile(modelID) != nil
        case .tokenPlan:
            return modelID.range(of: #"^qwen3\.(?:8-max(?:-preview)?|7-plus|6-(?:plus|flash))(?:-\d{4}-\d{2}-\d{2})?$"#, options: [.regularExpression, .caseInsensitive]) != nil
        case .dashScope:
            return modelID.range(of: #"^qwen(?:\d(?:\.\d+)?)?-vl(?:-[\w.-]+)?$|^qwen-vl-(?:max|plus)(?:-[\w.-]+)?$|^qwen3\.(?:8-max|7-max)(?:-[\w.-]+)?$"#, options: [.regularExpression, .caseInsensitive]) != nil
        case .openRouter: return hasModalities && acceptsVision
        case .openAICompatible: return hasModalities ? acceptsVision : isKnownVisionFamily(modelID)
        case .none: return hasModalities ? acceptsVision : isKnownVisionFamily(modelID)
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

import Foundation
import SlateSyncDomain

/// Presets only prefill a custom-provider draft. They never create wire IDs or
/// claim a capability before the user's configured model passes a live probe.
public struct ProviderPreset: Hashable, Sendable, Identifiable {
    public enum Category: String, Hashable, Sendable {
        case direct
        case aggregator
    }

    public let id: String
    public let name: String
    public let category: Category
    public let baseURL: String
    public let transport: ProviderTransport
    public let jsonMode: ProviderJSONMode
    public let suggestedModelID: String?
    public let websiteURL: URL
    public let keyURL: URL
    public let documentationURL: URL
    public let notes: String
}

public enum ProviderPresets {
    public static let all: [ProviderPreset] = [
        .init(id: "stepfun", name: "阶跃 StepFun", category: .direct, baseURL: "https://api.stepfun.com/v1", transport: .chatCompletions, jsonMode: .jsonSchema, suggestedModelID: nil, websiteURL: URL(string: "https://platform.stepfun.com")!, keyURL: URL(string: "https://platform.stepfun.com/interface-key")!, documentationURL: URL(string: "https://platform.stepfun.com/docs/guide/json_mode")!, notes: "全档兼容；请从平台选择支持视觉的模型。"),
        .init(id: "siliconflow", name: "硅基流动 SiliconFlow", category: .direct, baseURL: "https://api.siliconflow.cn/v1", transport: .chatCompletions, jsonMode: .jsonSchema, suggestedModelID: nil, websiteURL: URL(string: "https://siliconflow.cn")!, keyURL: URL(string: "https://cloud.siliconflow.cn/account/ak")!, documentationURL: URL(string: "https://docs.siliconflow.cn")!, notes: "模型以 /models 为准；请选支持视觉的模型。"),
        .init(id: "volcano-ark", name: "火山方舟 Volcano Ark", category: .direct, baseURL: "https://ark.cn-beijing.volces.com/api/v3", transport: .chatCompletions, jsonMode: .jsonSchema, suggestedModelID: nil, websiteURL: URL(string: "https://www.volcengine.com/product/ark")!, keyURL: URL(string: "https://console.volcengine.com/ark")!, documentationURL: URL(string: "https://www.volcengine.com/docs/82379")!, notes: "模型 ID 为推理接入点，需手动填写；早期模型可能不支持结构化输出，探针会验证实际档位。"),
        .init(id: "deepseek", name: "DeepSeek", category: .direct, baseURL: "https://api.deepseek.com/v1", transport: .chatCompletions, jsonMode: .jsonObject, suggestedModelID: "deepseek-flash", websiteURL: URL(string: "https://www.deepseek.com")!, keyURL: URL(string: "https://platform.deepseek.com/api_keys")!, documentationURL: URL(string: "https://api-docs.deepseek.com")!, notes: "建议 JSON Object；请先验证所选模型的视觉输入与结构化输出。"),
        .init(id: "moonshot", name: "Kimi（月之暗面）", category: .direct, baseURL: "https://api.moonshot.cn/v1", transport: .chatCompletions, jsonMode: .jsonObject, suggestedModelID: nil, websiteURL: URL(string: "https://platform.moonshot.cn")!, keyURL: URL(string: "https://platform.moonshot.cn/console/api-keys")!, documentationURL: URL(string: "https://platform.moonshot.cn/docs")!, notes: "使用 vision 系列；模型以服务端实际可用列表为准。"),
        .init(id: "bigmodel", name: "智谱 BigModel", category: .direct, baseURL: "https://open.bigmodel.cn/api/paas/v4", transport: .chatCompletions, jsonMode: .jsonSchema, suggestedModelID: nil, websiteURL: URL(string: "https://open.bigmodel.cn")!, keyURL: URL(string: "https://open.bigmodel.cn/usercenter/proj-mgmt/apikeys")!, documentationURL: URL(string: "https://open.bigmodel.cn/dev/api")!, notes: "data URL 前缀与 VLM×response_format 待实测；探针失败时自动降档。"),
        .init(id: "qianfan", name: "百度千帆", category: .direct, baseURL: "https://qianfan.baidubce.com/v2", transport: .chatCompletions, jsonMode: .jsonSchema, suggestedModelID: nil, websiteURL: URL(string: "https://qianfan.cloud.baidu.com")!, keyURL: URL(string: "https://console.bce.baidu.com/qianfan")!, documentationURL: URL(string: "https://cloud.baidu.com/doc/WENXINWORKSHOP")!, notes: "VL×json_schema 待实测；探针将记录实际成功档位。"),
        .init(id: "hunyuan", name: "腾讯混元", category: .direct, baseURL: "https://api.hunyuan.cloud.tencent.com/v1", transport: .chatCompletions, jsonMode: .prompt, suggestedModelID: nil, websiteURL: URL(string: "https://hunyuan.tencent.com")!, keyURL: URL(string: "https://console.cloud.tencent.com/hunyuan")!, documentationURL: URL(string: "https://cloud.tencent.com/document/product/1729")!, notes: "兼容接口未声明 response_format；请使用 api.hunyuan.cloud.tencent.com 域名。"),
        .init(id: "minimax", name: "MiniMax", category: .direct, baseURL: "https://api.minimax.io/v1", transport: .chatCompletions, jsonMode: .prompt, suggestedModelID: nil, websiteURL: URL(string: "https://www.minimax.io")!, keyURL: URL(string: "https://platform.minimax.io")!, documentationURL: URL(string: "https://platform.minimax.io/docs")!, notes: "标准兼容端点；未确认 response_format，建议从 Prompt 档验证。"),
        .init(id: "aihubmix", name: "AiHubMix", category: .aggregator, baseURL: "https://aihubmix.com/v1", transport: .chatCompletions, jsonMode: .jsonSchema, suggestedModelID: nil, websiteURL: URL(string: "https://aihubmix.com")!, keyURL: URL(string: "https://aihubmix.com")!, documentationURL: URL(string: "https://docs.aihubmix.com")!, notes: "聚合中转；结构化与视觉能力取决于上游模型，需逐模型验证。"),
        .init(id: "302-ai", name: "302.AI", category: .aggregator, baseURL: "https://api.302.ai/v1", transport: .chatCompletions, jsonMode: .jsonSchema, suggestedModelID: nil, websiteURL: URL(string: "https://302.ai")!, keyURL: URL(string: "https://302.ai")!, documentationURL: URL(string: "https://doc.302.ai")!, notes: "聚合中转；视觉与结构化透传需逐模型验证。"),
    ]
}

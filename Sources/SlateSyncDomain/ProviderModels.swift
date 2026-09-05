import Foundation

public enum ProviderEndpointPurpose: String, Codable, Hashable, Sendable {
    case discovery
    case recognition
    case probe
}

/// Immutable, secret-free provider routing selected by ProviderRegistry.
public struct ProviderDescriptor: Codable, Hashable, Sendable {
    public let id: String
    public let label: String
    public let kind: ProviderKind
    public let baseURL: URL
    public let transport: ProviderTransport
    public let jsonMode: ProviderJSONMode
    public let imageDetail: ImageDetail
    public let credentialRequired: Bool
    public let revision: Int?
    public let openRouterSiteURL: String?
    public let isLegacyCompatible: Bool

    public init(
        id: String,
        label: String,
        kind: ProviderKind,
        baseURL: URL,
        transport: ProviderTransport,
        jsonMode: ProviderJSONMode = .jsonSchema,
        imageDetail: ImageDetail = .high,
        credentialRequired: Bool = true,
        revision: Int? = nil,
        openRouterSiteURL: String? = nil,
        isLegacyCompatible: Bool = false
    ) {
        self.id = id
        self.label = label
        self.kind = kind
        self.baseURL = baseURL
        self.transport = transport
        self.jsonMode = jsonMode
        self.imageDetail = imageDetail
        self.credentialRequired = credentialRequired
        self.revision = revision
        self.openRouterSiteURL = openRouterSiteURL
        self.isLegacyCompatible = isLegacyCompatible
    }

    /// URLComponents appends one path component without inheriting endpoint
    /// query, fragment, or userinfo from untrusted configuration.
    public func endpoint(for purpose: ProviderEndpointPurpose) throws -> URL {
        let suffix: String
        switch purpose {
        case .discovery: suffix = "models"
        case .recognition, .probe:
            suffix = transport == .responses ? "responses" : "chat/completions"
        }
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            throw RecognitionFailure.invalidURL
        }
        var path = components.percentEncodedPath
        while path.hasSuffix("/") { path.removeLast() }
        components.percentEncodedPath = path + "/" + suffix
        components.query = nil
        components.fragment = nil
        guard let url = components.url else { throw RecognitionFailure.invalidURL }
        return url
    }
}

/// A public compatibility ID can differ from the physical model ID sent to a
/// provider (notably OpenAI direct IDs and the legacy custom alias).
public struct ResolvedModel: Codable, Hashable, Sendable {
    public let publicID: String
    public let apiID: String
    public let providerID: String
    public let label: String
    public let imageDetail: ImageDetail
    public let jsonMode: ProviderJSONMode
    public let capabilityStatus: ModelCapabilityStatus
    public let revision: Int?

    public init(
        publicID: String,
        apiID: String,
        providerID: String,
        label: String,
        imageDetail: ImageDetail = .high,
        jsonMode: ProviderJSONMode = .jsonSchema,
        capabilityStatus: ModelCapabilityStatus = .declared,
        revision: Int? = nil
    ) {
        self.publicID = publicID
        self.apiID = apiID
        self.providerID = providerID
        self.label = label
        self.imageDetail = imageDetail
        self.jsonMode = jsonMode
        self.capabilityStatus = capabilityStatus
        self.revision = revision
    }

    public var isUsable: Bool {
        [.declared, .inferred, .verified].contains(capabilityStatus)
    }
}

/// The request body is transient JSON bytes. Authorization is intentionally
/// absent and is resolved by URLSessionProviderTransport at the final moment.
public struct ProviderTransportRequest: Sendable {
    public enum Method: String, Sendable { case get = "GET", post = "POST" }

    public let provider: ProviderDescriptor
    public let purpose: ProviderEndpointPurpose
    public let method: Method
    public let body: Data?
    public let timeoutMilliseconds: Int
    public let maximumTimeoutRetries: Int

    public init(
        provider: ProviderDescriptor,
        purpose: ProviderEndpointPurpose,
        method: Method,
        body: Data? = nil,
        timeoutMilliseconds: Int,
        maximumTimeoutRetries: Int = 0
    ) {
        self.provider = provider
        self.purpose = purpose
        self.method = method
        self.body = body
        self.timeoutMilliseconds = timeoutMilliseconds
        self.maximumTimeoutRetries = maximumTimeoutRetries
    }
}

public struct ProviderTransportResponse: Sendable {
    public let status: Int
    public let headers: [String: String]
    public let body: Data
    public let attemptCount: Int

    public init(status: Int, headers: [String: String] = [:], body: Data, attemptCount: Int = 1) {
        self.status = status
        self.headers = headers
        self.body = body
        self.attemptCount = attemptCount
    }
}

public enum RecognitionFailure {
    public static let unknownProvider = SlateSyncError(code: "PROVIDER_UNKNOWN", message: "未知 API 服务商", status: 400)
    public static let providerNotConfigured = SlateSyncError(code: "PROVIDER_NOT_CONFIGURED", message: "API 服务商尚未配置", status: 400)
    public static let unsupportedModel = SlateSyncError(code: "MODEL_UNSUPPORTED", message: "所选模型不支持当前 API 服务商", status: 400)
    public static let invalidURL = SlateSyncError(code: "PROVIDER_URL", message: "API Base URL 无效", status: 400)
    public static let invalidInput = SlateSyncError(code: "RECOGNITION_INPUT", message: "页面图片输入无效", status: 400)
    public static let requestTooLarge = SlateSyncError(code: "REQUEST_TOO_LARGE", message: "识别请求超过大小限制", status: 413)
    public static let discoveryBusy = SlateSyncError(code: "DISCOVERY_BUSY", message: "模型发现正在运行", retryable: true, status: 409)
    public static let probeBusy = SlateSyncError(code: "MODEL_PROBE_BUSY", message: "模型能力验证正在运行", retryable: true, status: 409)
    public static let timeout = SlateSyncError(code: "MODEL_TIMEOUT", message: "模型请求超时", retryable: true, status: 504)
    public static let connection = SlateSyncError(code: "MODEL_CONNECTION", message: "无法连接模型服务", retryable: true, status: 502)
    public static let invalidResponse = SlateSyncError(code: "MODEL_RESPONSE", message: "模型服务返回无效数据", status: 502, providerError: true)
    public static let invalidStructuredJSON = SlateSyncError(code: "MODEL_JSON", message: "模型返回的数据不是有效 JSON", status: 502, providerError: true)
    public static let globalBusy = SlateSyncError(code: "RECOGNITION_BUSY", message: "识别任务已达到全局并发上限", retryable: true, status: 429)
    public static let canceled = SlateSyncError(code: "RECOGNITION_CANCELED", message: "识别已取消")
    public static let closed = SlateSyncError(code: "RECOGNITION_CLOSED", message: "识别服务已关闭")

    public static func provider(message: String, status: Int) -> SlateSyncError {
        SlateSyncError(code: "PROVIDER_ERROR", message: message, retryable: status == 429 || status >= 500, status: status, providerError: true)
    }

    public static func page(_ error: any Error, page: Int, count: Int) -> SlateSyncError {
        let source = SlateSyncError.wrapped(error, code: "PAGE_RECOGNITION")
        if source.code == canceled.code { return canceled }
        return SlateSyncError(
            code: source.code,
            message: "第 \(page)/\(count) 页识别失败：\(source.message)",
            retryable: source.retryable,
            status: source.status,
            providerError: source.providerError
        )
    }
}

import Foundation

/// Swift aliases for the transport-level contracts. `Data` is the native
/// representation of the Electron `ArrayBuffer`/`ArrayBufferView` payload,
/// while `SlateSyncError` carries the same stable AppError fields.
public typealias BinaryPayload = Data
public typealias AppError = SlateSyncError

/// Native representation of the shared `Result<T>` envelope. The explicit
/// discriminator keeps IPC responses typed without introducing an unbounded
/// dictionary at the transport boundary.
public enum DomainResult<Value: Codable & Hashable & Sendable>: Codable, Hashable, Sendable {
    case success(Value)
    case failure(SlateSyncError)

    private enum CodingKeys: String, CodingKey {
        case ok
        case data
        case error
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        if try values.decode(Bool.self, forKey: .ok) {
            guard values.contains(.data), !values.contains(.error) else {
                throw DiscriminatedResultSupport.decodingError(
                    decoder,
                    "成功结果包含非法分支字段"
                )
            }
            self = .success(try values.decode(Value.self, forKey: .data))
        } else {
            guard !values.contains(.data), values.contains(.error) else {
                throw DiscriminatedResultSupport.decodingError(
                    decoder,
                    "失败结果包含非法分支字段"
                )
            }
            self = .failure(try values.decode(SlateSyncError.self, forKey: .error))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .success(let value):
            try values.encode(true, forKey: .ok)
            try values.encode(value, forKey: .data)
        case .failure(let error):
            try values.encode(false, forKey: .ok)
            try values.encode(error, forKey: .error)
        }
    }
}

public enum ProviderKind: String, Codable, Hashable, Sendable {
    case builtin
    case custom
}

public enum ProviderTransport: String, Codable, Hashable, Sendable {
    case chatCompletions = "chat-completions"
    case responses
}

public enum ProviderJSONMode: String, Codable, Hashable, Sendable {
    case jsonSchema = "json_schema"
    case jsonObject = "json_object"
    case prompt
}

public enum ImageDetail: String, Codable, Hashable, Sendable {
    case auto
    case low
    case high
    case original
}

public enum ModelCapabilityStatus: String, Codable, Hashable, Sendable {
    case declared
    case inferred
    case verified
    case pending
    case unsupported
    case failed
    case canceled
}

public struct ProviderSummary: Codable, Hashable, Sendable {
    public let id: String
    public let label: String
    public let configured: Bool
    public let requiredEnv: [String]
    public let type: ProviderKind?
    public let editable: Bool?

    public init(
        id: String,
        label: String,
        configured: Bool,
        requiredEnv: [String] = [],
        type: ProviderKind? = nil,
        editable: Bool? = nil
    ) {
        self.id = id
        self.label = label
        self.configured = configured
        self.requiredEnv = requiredEnv
        self.type = type
        self.editable = editable
    }
}

public struct CustomProviderCapabilityVerification: Codable, Hashable, Sendable {
    public let status: ModelCapabilityStatus
    public let revision: Int
    public let checkedAt: String?
    public let transport: ProviderTransport?
    public let capabilitySource: String?
    public let message: String?

    // A missing or malformed revision must remain distinguishable from an
    // explicit revision 1. The validator uses this bit to discard legacy cache
    // entries that are not cryptographically/semantically bound to a provider
    // configuration revision.
    internal let hasExplicitRevision: Bool

    public init(
        status: ModelCapabilityStatus,
        revision: Int,
        checkedAt: String? = nil,
        transport: ProviderTransport? = nil,
        capabilitySource: String? = nil,
        message: String? = nil
    ) {
        self.status = status
        self.revision = revision
        self.checkedAt = checkedAt
        self.transport = transport
        self.capabilitySource = capabilitySource
        self.message = message
        self.hasExplicitRevision = true
    }

    private enum CodingKeys: String, CodingKey {
        case status
        case revision
        case checkedAt
        case transport
        case capabilitySource
        case message
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        // Invalid probe statuses are represented as pending and discarded by
        // CustomProviderValidator, matching the JavaScript cache sanitizer.
        status = (try? values.decode(ModelCapabilityStatus.self, forKey: .status)) ?? .pending
        let decodedRevision = Self.decodeRevision(values)
        revision = decodedRevision.value
        hasExplicitRevision = decodedRevision.isValid
        // Optional diagnostic fields are deliberately tolerant. A malformed
        // message must not make otherwise valid cache entries disappear.
        checkedAt = try? values.decode(String.self, forKey: .checkedAt)
        transport = (try? values.decode(String.self, forKey: .transport)).flatMap {
            ProviderTransport(rawValue: $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
        }
        capabilitySource = try? values.decode(String.self, forKey: .capabilitySource)
        message = try? values.decode(String.self, forKey: .message)
    }

    private static func decodeRevision(
        _ values: KeyedDecodingContainer<CodingKeys>
    ) -> (value: Int, isValid: Bool) {
        guard values.contains(.revision) else { return (0, false) }
        if let value = try? values.decode(JSONValue.self, forKey: .revision),
           let revision = javascriptInteger(value) {
            return (revision, true)
        }
        return (0, false)
    }

    private static func javascriptInteger(_ value: JSONValue) -> Int? {
        guard let number = JavaScriptCompatibility.number(value),
              number.isFinite,
              number.rounded() == number,
              number >= 1,
              number <= 9_007_199_254_740_991 else {
            return nil
        }
        return Int(number)
    }
}

/// The persisted custom-provider record deliberately excludes key material.
public struct CustomProviderConfiguration: Codable, Hashable, Sendable {
    public let id: String
    public let name: String
    public let label: String?
    public let baseUrl: String
    public let transport: ProviderTransport
    public let jsonMode: ProviderJSONMode
    public let imageDetail: ImageDetail
    public let manualModelIds: [String]
    public let revision: Int
    public let capabilityCache: [String: CustomProviderCapabilityVerification]?

    public init(
        id: String,
        name: String,
        label: String? = nil,
        baseUrl: String,
        transport: ProviderTransport = .chatCompletions,
        jsonMode: ProviderJSONMode = .jsonSchema,
        imageDetail: ImageDetail = .high,
        manualModelIds: [String] = [],
        revision: Int = 1,
        capabilityCache: [String: CustomProviderCapabilityVerification]? = nil
    ) {
        self.id = id
        self.name = name
        self.label = label
        self.baseUrl = baseUrl
        self.transport = transport
        self.jsonMode = jsonMode
        self.imageDetail = imageDetail
        self.manualModelIds = manualModelIds
        self.revision = revision
        self.capabilityCache = capabilityCache
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case label
        case baseUrl
        case url
        case transport
        case jsonMode
        case imageDetail
        case manualModelIds
        case models
        case revision
        case capabilityCache
        case verification
        case capabilityVerification
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let decodedID = try values.decode(String.self, forKey: .id)
        let decodedLabel = try values.decodeIfPresent(String.self, forKey: .label)
        let decodedName = try values.decodeIfPresent(String.self, forKey: .name)
            ?? decodedLabel
            ?? ""
        let primaryBaseURL = try values.decodeIfPresent(String.self, forKey: .baseUrl)
        let legacyBaseURL = try values.decodeIfPresent(String.self, forKey: .url)
        guard let decodedBaseURL = [primaryBaseURL, legacyBaseURL]
                .compactMap({ $0 })
                .first(where: { !$0.isEmpty }) else {
            throw SlateSyncError(code: "CUSTOM_PROVIDER_INVALID", message: "缺少接口 Base URL")
        }
        let decodedModels = try values.decodeIfPresent([String].self, forKey: .manualModelIds)
            ?? values.decodeIfPresent([String].self, forKey: .models)
            ?? []
        let decodedCache = try values.decodeIfPresent(
            [String: CustomProviderCapabilityVerification].self,
            forKey: .capabilityCache
        ) ?? values.decodeIfPresent(
            [String: CustomProviderCapabilityVerification].self,
            forKey: .verification
        ) ?? values.decodeIfPresent(
            [String: CustomProviderCapabilityVerification].self,
            forKey: .capabilityVerification
        )
        let normalized = try CustomProviderValidator.normalize(
            CustomProviderConfiguration(
                id: decodedID,
                name: decodedName,
                label: decodedLabel,
                baseUrl: decodedBaseURL,
                transport: Self.decodeTransport(values),
                jsonMode: Self.decodeJSONMode(values),
                imageDetail: Self.decodeImageDetail(values),
                manualModelIds: decodedModels,
                revision: Self.decodeRevision(values),
                capabilityCache: decodedCache
            )
        )
        id = normalized.id
        name = normalized.name
        label = normalized.label
        baseUrl = normalized.baseUrl
        transport = normalized.transport
        jsonMode = normalized.jsonMode
        imageDetail = normalized.imageDetail
        manualModelIds = normalized.manualModelIds
        revision = normalized.revision
        capabilityCache = normalized.capabilityCache
    }

    private static func decodeTransport(
        _ values: KeyedDecodingContainer<CodingKeys>
    ) -> ProviderTransport {
        guard let raw = try? values.decode(String.self, forKey: .transport) else {
            return .chatCompletions
        }
        return ProviderTransport(
            rawValue: raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        ) ?? .chatCompletions
    }

    private static func decodeJSONMode(
        _ values: KeyedDecodingContainer<CodingKeys>
    ) -> ProviderJSONMode {
        guard let raw = try? values.decode(String.self, forKey: .jsonMode) else {
            return .jsonSchema
        }
        return ProviderJSONMode(
            rawValue: raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        ) ?? .jsonSchema
    }

    private static func decodeImageDetail(
        _ values: KeyedDecodingContainer<CodingKeys>
    ) -> ImageDetail {
        guard let raw = try? values.decode(String.self, forKey: .imageDetail) else {
            return .high
        }
        return ImageDetail(rawValue: raw) ?? .high
    }

    private static func decodeRevision(
        _ values: KeyedDecodingContainer<CodingKeys>
    ) -> Int {
        guard let value = try? values.decode(JSONValue.self, forKey: .revision),
              let number = JavaScriptCompatibility.number(value),
              number.isFinite,
              number.rounded() == number,
              number >= 1,
              number <= 9_007_199_254_740_991 else { return 1 }
        return Int(number)
    }

    public func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(id, forKey: .id)
        try values.encode(name, forKey: .name)
        try values.encode(label ?? name, forKey: .label)
        try values.encode(baseUrl, forKey: .baseUrl)
        try values.encode(transport, forKey: .transport)
        try values.encode(jsonMode, forKey: .jsonMode)
        try values.encode(imageDetail, forKey: .imageDetail)
        try values.encode(manualModelIds, forKey: .manualModelIds)
        try values.encode(revision, forKey: .revision)
        try values.encodeIfPresent(capabilityCache, forKey: .capabilityCache)
    }

    public func summary(keyConfigured: Bool = false) -> CustomProviderSummary {
        CustomProviderSummary(
            id: id,
            name: name,
            label: label,
            baseUrl: baseUrl,
            transport: transport,
            jsonMode: jsonMode,
            imageDetail: imageDetail,
            manualModelIds: manualModelIds,
            revision: revision,
            keyConfigured: keyConfigured,
            capabilityCache: capabilityCache
        )
    }
}

public struct CustomProviderSummary: Codable, Hashable, Sendable {
    public let id: String
    public let name: String
    public let label: String?
    public let baseUrl: String
    public let transport: ProviderTransport
    public let jsonMode: ProviderJSONMode
    public let imageDetail: ImageDetail
    public let manualModelIds: [String]
    public let revision: Int
    public let keyConfigured: Bool
    public let capabilityCache: [String: CustomProviderCapabilityVerification]?

    public init(
        id: String,
        name: String,
        label: String? = nil,
        baseUrl: String,
        transport: ProviderTransport = .chatCompletions,
        jsonMode: ProviderJSONMode = .jsonSchema,
        imageDetail: ImageDetail = .high,
        manualModelIds: [String] = [],
        revision: Int = 1,
        keyConfigured: Bool = false,
        capabilityCache: [String: CustomProviderCapabilityVerification]? = nil
    ) {
        self.id = id
        self.name = name
        self.label = label
        self.baseUrl = baseUrl
        self.transport = transport
        self.jsonMode = jsonMode
        self.imageDetail = imageDetail
        self.manualModelIds = manualModelIds
        self.revision = revision
        self.keyConfigured = keyConfigured
        self.capabilityCache = capabilityCache
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case label
        case baseUrl
        case transport
        case jsonMode
        case imageDetail
        case manualModelIds
        case revision
        case keyConfigured
        case capabilityCache
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        let decodedLabel = try values.decodeIfPresent(String.self, forKey: .label)
        name = try values.decodeIfPresent(String.self, forKey: .name) ?? decodedLabel ?? ""
        label = decodedLabel ?? name
        baseUrl = try values.decode(String.self, forKey: .baseUrl)
        transport = try values.decodeIfPresent(ProviderTransport.self, forKey: .transport) ?? .chatCompletions
        jsonMode = try values.decodeIfPresent(ProviderJSONMode.self, forKey: .jsonMode) ?? .jsonSchema
        imageDetail = try values.decodeIfPresent(ImageDetail.self, forKey: .imageDetail) ?? .high
        manualModelIds = try values.decodeIfPresent([String].self, forKey: .manualModelIds) ?? []
        revision = try values.decodeIfPresent(Int.self, forKey: .revision) ?? 1
        keyConfigured = try values.decodeIfPresent(Bool.self, forKey: .keyConfigured) ?? false
        capabilityCache = try values.decodeIfPresent([String: CustomProviderCapabilityVerification].self, forKey: .capabilityCache)
    }

    public func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(id, forKey: .id)
        try values.encode(name, forKey: .name)
        try values.encode(label ?? name, forKey: .label)
        try values.encode(baseUrl, forKey: .baseUrl)
        try values.encode(transport, forKey: .transport)
        try values.encode(jsonMode, forKey: .jsonMode)
        try values.encode(imageDetail, forKey: .imageDetail)
        try values.encode(manualModelIds, forKey: .manualModelIds)
        try values.encode(revision, forKey: .revision)
        try values.encode(keyConfigured, forKey: .keyConfigured)
        try values.encodeIfPresent(capabilityCache, forKey: .capabilityCache)
    }

    public var persistedConfiguration: CustomProviderConfiguration {
        CustomProviderConfiguration(
            id: id,
            name: name,
            label: label,
            baseUrl: baseUrl,
            transport: transport,
            jsonMode: jsonMode,
            imageDetail: imageDetail,
            manualModelIds: manualModelIds,
            revision: revision,
            capabilityCache: capabilityCache
        )
    }
}

public struct CustomProviderConfigRequest: Codable, Hashable, Sendable {
    public let id: String?
    public let providerId: String?
    public let name: String
    public let baseUrl: String
    public let transport: ProviderTransport?
    public let jsonMode: ProviderJSONMode?
    public let imageDetail: ImageDetail?
    public let manualModelIds: [String]?
    /// Transient input only; this field is part of the IPC request wire shape
    /// but is never accepted by a persisted configuration snapshot.
    public let apiKey: String?
    public let replaceApiKey: Bool?
    public let clearApiKey: Bool?

    public init(
        id: String? = nil,
        providerId: String? = nil,
        name: String,
        baseUrl: String,
        transport: ProviderTransport? = nil,
        jsonMode: ProviderJSONMode? = nil,
        imageDetail: ImageDetail? = nil,
        manualModelIds: [String]? = nil,
        apiKey: String? = nil,
        replaceApiKey: Bool? = nil,
        clearApiKey: Bool? = nil
    ) {
        self.id = id
        self.providerId = providerId
        self.name = name
        self.baseUrl = baseUrl
        self.transport = transport
        self.jsonMode = jsonMode
        self.imageDetail = imageDetail
        self.manualModelIds = manualModelIds
        self.apiKey = apiKey
        self.replaceApiKey = replaceApiKey
        self.clearApiKey = clearApiKey
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case providerId
        case name
        case baseUrl
        case transport
        case jsonMode
        case imageDetail
        case manualModelIds
        case apiKey
        case replaceApiKey
        case clearApiKey
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decodeIfPresent(String.self, forKey: .id)
        providerId = try values.decodeIfPresent(String.self, forKey: .providerId)
        name = try values.decode(String.self, forKey: .name)
        baseUrl = try values.decode(String.self, forKey: .baseUrl)
        transport = try values.decodeIfPresent(ProviderTransport.self, forKey: .transport)
        jsonMode = try values.decodeIfPresent(ProviderJSONMode.self, forKey: .jsonMode)
        imageDetail = try values.decodeIfPresent(ImageDetail.self, forKey: .imageDetail)
        manualModelIds = try values.decodeIfPresent([String].self, forKey: .manualModelIds)
        apiKey = try values.decodeIfPresent(String.self, forKey: .apiKey)
        replaceApiKey = try values.decodeIfPresent(Bool.self, forKey: .replaceApiKey)
        clearApiKey = try values.decodeIfPresent(Bool.self, forKey: .clearApiKey)
    }

    public func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encodeIfPresent(id, forKey: .id)
        try values.encodeIfPresent(providerId, forKey: .providerId)
        try values.encode(name, forKey: .name)
        try values.encode(baseUrl, forKey: .baseUrl)
        try values.encodeIfPresent(transport, forKey: .transport)
        try values.encodeIfPresent(jsonMode, forKey: .jsonMode)
        try values.encodeIfPresent(imageDetail, forKey: .imageDetail)
        try values.encodeIfPresent(manualModelIds, forKey: .manualModelIds)
        // This is the transient IPC boundary. GlobalConfigStore only accepts
        // CustomProviderConfiguration, which deliberately has no apiKey field.
        try values.encodeIfPresent(apiKey, forKey: .apiKey)
        try values.encodeIfPresent(replaceApiKey, forKey: .replaceApiKey)
        try values.encodeIfPresent(clearApiKey, forKey: .clearApiKey)
    }
}

public typealias CustomProviderConfig = CustomProviderSummary
public typealias NewCustomProviderRequest = CustomProviderConfigRequest

public struct UpdateCustomProviderRequest: Codable, Hashable, Sendable {
    public let id: String
    public let providerId: String?
    public let name: String
    public let baseUrl: String
    public let transport: ProviderTransport?
    public let jsonMode: ProviderJSONMode?
    public let imageDetail: ImageDetail?
    public let manualModelIds: [String]?
    public let apiKey: String?
    public let replaceApiKey: Bool?
    public let clearApiKey: Bool?

    public init(id: String, request: CustomProviderConfigRequest) {
        self.id = id
        providerId = request.providerId
        name = request.name
        baseUrl = request.baseUrl
        transport = request.transport
        jsonMode = request.jsonMode
        imageDetail = request.imageDetail
        manualModelIds = request.manualModelIds
        apiKey = request.apiKey
        replaceApiKey = request.replaceApiKey
        clearApiKey = request.clearApiKey
    }

    public var configRequest: CustomProviderConfigRequest {
        CustomProviderConfigRequest(
            id: id,
            providerId: providerId,
            name: name,
            baseUrl: baseUrl,
            transport: transport,
            jsonMode: jsonMode,
            imageDetail: imageDetail,
            manualModelIds: manualModelIds,
            apiKey: apiKey,
            replaceApiKey: replaceApiKey,
            clearApiKey: clearApiKey
        )
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case providerId
        case name
        case baseUrl
        case transport
        case jsonMode
        case imageDetail
        case manualModelIds
        case apiKey
        case replaceApiKey
        case clearApiKey
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        providerId = try values.decodeIfPresent(String.self, forKey: .providerId)
        name = try values.decode(String.self, forKey: .name)
        baseUrl = try values.decode(String.self, forKey: .baseUrl)
        transport = try values.decodeIfPresent(ProviderTransport.self, forKey: .transport)
        jsonMode = try values.decodeIfPresent(ProviderJSONMode.self, forKey: .jsonMode)
        imageDetail = try values.decodeIfPresent(ImageDetail.self, forKey: .imageDetail)
        manualModelIds = try values.decodeIfPresent([String].self, forKey: .manualModelIds)
        apiKey = try values.decodeIfPresent(String.self, forKey: .apiKey)
        replaceApiKey = try values.decodeIfPresent(Bool.self, forKey: .replaceApiKey)
        clearApiKey = try values.decodeIfPresent(Bool.self, forKey: .clearApiKey)
    }

    public func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(id, forKey: .id)
        try values.encodeIfPresent(providerId, forKey: .providerId)
        try values.encode(name, forKey: .name)
        try values.encode(baseUrl, forKey: .baseUrl)
        try values.encodeIfPresent(transport, forKey: .transport)
        try values.encodeIfPresent(jsonMode, forKey: .jsonMode)
        try values.encodeIfPresent(imageDetail, forKey: .imageDetail)
        try values.encodeIfPresent(manualModelIds, forKey: .manualModelIds)
        // Keep update requests wire-compatible while leaving persistence to
        // the separate non-secret configuration record.
        try values.encodeIfPresent(apiKey, forKey: .apiKey)
        try values.encodeIfPresent(replaceApiKey, forKey: .replaceApiKey)
        try values.encodeIfPresent(clearApiKey, forKey: .clearApiKey)
    }
}

public struct CustomProviderDeleteRequest: Codable, Hashable, Sendable {
    public let id: String
    public let confirm: Bool?

    public init(id: String, confirm: Bool? = nil) {
        self.id = id
        self.confirm = confirm
    }
}

public typealias DeleteCustomProviderRequest = CustomProviderDeleteRequest

public struct ModelData: Codable, Hashable, Sendable {
    public let id: String
    public let label: String
    public let description: String
    public let providers: [String]
    public let vendor: String?
    public let imageDetail: ImageDetail?
    public let directId: String?
    public let apiId: String?
    public let openRouterStructuredOutputs: Bool?
    public let fixed: Bool?
    public let fixedPriority: Int?
    public let discovered: Bool?
    public let verifiedAvailable: Bool?
    public let qualityScore: Double?
    public let valueScore: Double?
    public let qualityLabel: String?
    public let valueLabel: String?
    public let capabilityStatus: ModelCapabilityStatus?
    public let capabilitySource: String?
    public let capabilityMessage: String?
    public let capabilityCheckedAt: String?
    public let qualitySource: String?
    public let qualityUpdatedAt: String?
    public let valueSource: String?
    public let valueUpdatedAt: String?
    public let priceUpdatedAt: String?

    public init(
        id: String,
        label: String,
        description: String,
        providers: [String],
        vendor: String? = nil,
        imageDetail: ImageDetail? = nil,
        directId: String? = nil,
        apiId: String? = nil,
        openRouterStructuredOutputs: Bool? = nil,
        fixed: Bool? = nil,
        fixedPriority: Int? = nil,
        discovered: Bool? = nil,
        verifiedAvailable: Bool? = nil,
        qualityScore: Double? = nil,
        valueScore: Double? = nil,
        qualityLabel: String? = nil,
        valueLabel: String? = nil,
        capabilityStatus: ModelCapabilityStatus? = nil,
        capabilitySource: String? = nil,
        capabilityMessage: String? = nil,
        capabilityCheckedAt: String? = nil,
        qualitySource: String? = nil,
        qualityUpdatedAt: String? = nil,
        valueSource: String? = nil,
        valueUpdatedAt: String? = nil,
        priceUpdatedAt: String? = nil
    ) {
        self.id = id
        self.label = label
        self.description = description
        self.providers = providers
        self.vendor = vendor
        self.imageDetail = imageDetail
        self.directId = directId
        self.apiId = apiId
        self.openRouterStructuredOutputs = openRouterStructuredOutputs
        self.fixed = fixed
        self.fixedPriority = fixedPriority
        self.discovered = discovered
        self.verifiedAvailable = verifiedAvailable
        self.qualityScore = qualityScore
        self.valueScore = valueScore
        self.qualityLabel = qualityLabel
        self.valueLabel = valueLabel
        self.capabilityStatus = capabilityStatus
        self.capabilitySource = capabilitySource
        self.capabilityMessage = capabilityMessage
        self.capabilityCheckedAt = capabilityCheckedAt
        self.qualitySource = qualitySource
        self.qualityUpdatedAt = qualityUpdatedAt
        self.valueSource = valueSource
        self.valueUpdatedAt = valueUpdatedAt
        self.priceUpdatedAt = priceUpdatedAt
    }
}

public enum OcrEngineID: String, Codable, Hashable, Sendable {
    case vision
    case paddleocr
}

public struct OcrEngineStatus: Codable, Hashable, Sendable {
    public let id: String
    public let label: String
    public let mode: String
    public let enabled: Bool
    public let available: Bool
    public let required: Bool
    public let language: String?
    public let recognitionLevel: String?
    public let usesLanguageCorrection: Bool?
    public let minimumConfidence: Double?
    public let maxBlocksPerView: Int?
    public let modelVersion: String?
    public let preset: String?
    public let presetLabel: String?
    public let profile: String?
    public let profileLabel: String?
    public let detectionModel: String?
    public let recognitionModel: String?
    public let recognitionBatchSize: Int?
    public let textDetLimitSideLen: Int?
    public let device: String?

    public init(
        id: String,
        label: String,
        mode: String,
        enabled: Bool,
        available: Bool,
        required: Bool,
        language: String? = nil,
        recognitionLevel: String? = nil,
        usesLanguageCorrection: Bool? = nil,
        minimumConfidence: Double? = nil,
        maxBlocksPerView: Int? = nil,
        modelVersion: String? = nil,
        preset: String? = nil,
        presetLabel: String? = nil,
        profile: String? = nil,
        profileLabel: String? = nil,
        detectionModel: String? = nil,
        recognitionModel: String? = nil,
        recognitionBatchSize: Int? = nil,
        textDetLimitSideLen: Int? = nil,
        device: String? = nil
    ) {
        self.id = id
        self.label = label
        self.mode = mode
        self.enabled = enabled
        self.available = available
        self.required = required
        self.language = language
        self.recognitionLevel = recognitionLevel
        self.usesLanguageCorrection = usesLanguageCorrection
        self.minimumConfidence = minimumConfidence
        self.maxBlocksPerView = maxBlocksPerView
        self.modelVersion = modelVersion
        self.preset = preset
        self.presetLabel = presetLabel
        self.profile = profile
        self.profileLabel = profileLabel
        self.detectionModel = detectionModel
        self.recognitionModel = recognitionModel
        self.recognitionBatchSize = recognitionBatchSize
        self.textDetLimitSideLen = textDetLimitSideLen
        self.device = device
    }
}

public struct OcrSelection: Codable, Hashable, Sendable {
    public let id: OcrEngineID?
    public let label: String
    public let mode: String
    public let reason: String
    public let available: Bool
    public let enabled: Bool
    public let required: Bool

    public init(
        id: OcrEngineID?,
        label: String,
        mode: String,
        reason: String,
        available: Bool,
        enabled: Bool,
        required: Bool
    ) {
        self.id = id
        self.label = label
        self.mode = mode
        self.reason = reason
        self.available = available
        self.enabled = enabled
        self.required = required
    }
}

public struct ScenarioMatchingConfig: Codable, Hashable, Sendable {
    public var threshold: Double
    public var ambiguityMargin: Double

    public init(threshold: Double = 0.85, ambiguityMargin: Double = 0.05) {
        self.threshold = threshold
        self.ambiguityMargin = ambiguityMargin
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        // Electron applies Number(value) at this strict config boundary, so
        // hand-edited numeric strings such as `1e-1` follow the same parser
        // before the range checks below decide whether they are valid.
        threshold = JavaScriptCompatibility.number(
            try values.decodeIfPresent(JSONValue.self, forKey: .threshold)
        ) ?? 0.85
        ambiguityMargin = JavaScriptCompatibility.number(
            try values.decodeIfPresent(JSONValue.self, forKey: .ambiguityMargin)
        ) ?? 0.05
        try validate()
    }

    private enum CodingKeys: String, CodingKey {
        case threshold
        case ambiguityMargin
    }

    public func validate() throws {
        guard threshold.isFinite, (0.5...1).contains(threshold) else {
            throw SlateSyncError(code: "CONFIG_INVALID", message: "scenario.matching.threshold 必须是 0.5–1 之间的数字")
        }
        guard ambiguityMargin.isFinite, (0...0.5).contains(ambiguityMargin) else {
            throw SlateSyncError(code: "CONFIG_INVALID", message: "scenario.matching.ambiguityMargin 必须是 0–0.5 之间的数字")
        }
    }
}

public struct WorkflowConfig: Codable, Hashable, Sendable {
    public struct Slate: Codable, Hashable, Sendable {
        public var maxDirectoryDepth: Int

        public init(maxDirectoryDepth: Int = 4) {
            self.maxDirectoryDepth = maxDirectoryDepth
        }

        private enum CodingKeys: String, CodingKey {
            case maxDirectoryDepth
        }

        public init(from decoder: any Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            let raw = try values.decodeIfPresent(JSONValue.self, forKey: .maxDirectoryDepth)
            let number = JavaScriptCompatibility.number(raw)
            // Keep conversion safe for malformed hand-edited values; the
            // enclosing WorkflowConfig validation reports the range error.
            if let number, number.isFinite, number.rounded() == number,
               number >= Double(Int.min), number <= Double(Int.max) {
                maxDirectoryDepth = Int(number)
            } else {
                maxDirectoryDepth = 0
            }
        }
    }

    public struct Scenario: Codable, Hashable, Sendable {
        public var matching: ScenarioMatchingConfig

        public init(matching: ScenarioMatchingConfig = .init()) {
            self.matching = matching
        }
    }

    public var slate: Slate
    public var scenario: Scenario
    public var resolve: ProjectSettings.ResolveSettings

    public init(
        slate: Slate = .init(),
        scenario: Scenario = .init(),
        resolve: ProjectSettings.ResolveSettings = .init()
    ) {
        self.slate = slate
        self.scenario = scenario
        self.resolve = resolve
    }

    private enum CodingKeys: String, CodingKey {
        case slate
        case scenario
        case resolve
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        slate = try values.decodeIfPresent(Slate.self, forKey: .slate) ?? .init()
        scenario = try values.decodeIfPresent(Scenario.self, forKey: .scenario) ?? .init()
        resolve = try values.decodeIfPresent(ProjectSettings.ResolveSettings.self, forKey: .resolve) ?? .init()
        try validate()
    }

    public func validate() throws {
        guard (1...12).contains(slate.maxDirectoryDepth) else {
            throw SlateSyncError(code: "CONFIG_INVALID", message: "slate.maxDirectoryDepth 必须是 1–12 的整数")
        }
        try scenario.matching.validate()
        try resolve.fieldFormats.validate()
        try resolve.comments.validate()
    }
}

public struct UploadLimits: Codable, Hashable, Sendable {
    public let acceptedTypes: [String]
    public let maxBytes: Int
    public let maxRequestBytes: Int

    public init(acceptedTypes: [String], maxBytes: Int, maxRequestBytes: Int = 0) {
        self.acceptedTypes = acceptedTypes
        self.maxBytes = maxBytes
        self.maxRequestBytes = maxRequestBytes
    }
}

public struct ConfigData: Codable, Hashable, Sendable {
    public let providers: [ProviderSummary]
    public let models: [ModelData]
    public let ocr: OcrEngineStatus
    public let ocrEngines: [OcrEngineStatus]
    public let ocrSelection: OcrSelection
    public let upload: UploadLimits
    public let workflow: WorkflowConfig
    public let customProviders: [CustomProviderSummary]?

    public init(
        providers: [ProviderSummary],
        models: [ModelData],
        ocr: OcrEngineStatus,
        ocrEngines: [OcrEngineStatus],
        ocrSelection: OcrSelection,
        upload: UploadLimits,
        workflow: WorkflowConfig,
        customProviders: [CustomProviderSummary]? = nil
    ) {
        self.providers = providers
        self.models = models
        self.ocr = ocr
        self.ocrEngines = ocrEngines
        self.ocrSelection = ocrSelection
        self.upload = upload
        self.workflow = workflow
        self.customProviders = customProviders
    }
}

public struct RecognitionDefaults: Codable, Hashable, Sendable {
    public let providerId: String
    public let modelId: String
    public let customPrompt: String

    public init(providerId: String, modelId: String, customPrompt: String = "") {
        self.providerId = providerId
        self.modelId = modelId
        self.customPrompt = customPrompt
    }
}

public struct ValidatedLibraryInfo: Codable, Hashable, Sendable {
    public let id: String
    public let name: String
    public let formatVersion: Int
    public let path: String
    public let projectCount: Int

    public init(id: String, name: String, formatVersion: Int = 1, path: String, projectCount: Int = 0) {
        self.id = id
        self.name = name
        self.formatVersion = formatVersion
        self.path = path
        self.projectCount = projectCount
    }
}

/// Result unions use enum cases so a canceled response cannot accidentally
/// carry success-only fields into the IPC wire shape.
public enum LibraryImportResult: Codable, Hashable, Sendable {
    case canceled
    case imported(ValidatedLibraryInfo)

    public init(
        canceled: Bool,
        restartRequired: Bool = false,
        library: ValidatedLibraryInfo? = nil
    ) throws {
        if canceled {
            guard !restartRequired, library == nil else {
                throw DiscriminatedResultSupport.initializationError("项目库导入取消结果字段无效")
            }
            self = .canceled
        } else {
            guard restartRequired, let library else {
                throw DiscriminatedResultSupport.initializationError("项目库导入成功结果字段无效")
            }
            self = .imported(library)
        }
    }

    public var canceled: Bool {
        if case .canceled = self { return true }
        return false
    }

    public var restartRequired: Bool { !canceled }

    public var library: ValidatedLibraryInfo? {
        guard case .imported(let library) = self else { return nil }
        return library
    }

    private enum CodingKeys: String, CodingKey {
        case canceled
        case restartRequired
        case library
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let canceled = try values.decode(Bool.self, forKey: .canceled)
        if canceled {
            guard !values.contains(.restartRequired), !values.contains(.library) else {
                throw DiscriminatedResultSupport.decodingError(decoder, "项目库导入取消结果包含非法分支字段")
            }
            self = .canceled
        } else {
            guard try values.decodeIfPresent(Bool.self, forKey: .restartRequired) == true,
                  values.contains(.library) else {
                throw DiscriminatedResultSupport.decodingError(decoder, "项目库导入成功结果缺少必需字段")
            }
            self = .imported(try values.decode(ValidatedLibraryInfo.self, forKey: .library))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .canceled:
            try values.encode(true, forKey: .canceled)
        case .imported(let library):
            try values.encode(false, forKey: .canceled)
            try values.encode(true, forKey: .restartRequired)
            try values.encode(library, forKey: .library)
        }
    }
}

public enum LibraryExportResult: Codable, Hashable, Sendable {
    case canceled
    case exported(ValidatedLibraryInfo)

    public init(canceled: Bool, library: ValidatedLibraryInfo? = nil) throws {
        if canceled {
            guard library == nil else {
                throw DiscriminatedResultSupport.initializationError("项目库导出取消结果字段无效")
            }
            self = .canceled
        } else {
            guard let library else {
                throw DiscriminatedResultSupport.initializationError("项目库导出成功结果缺少项目库")
            }
            self = .exported(library)
        }
    }

    public var canceled: Bool {
        if case .canceled = self { return true }
        return false
    }

    public var library: ValidatedLibraryInfo? {
        guard case .exported(let library) = self else { return nil }
        return library
    }

    private enum CodingKeys: String, CodingKey {
        case canceled
        case library
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let canceled = try values.decode(Bool.self, forKey: .canceled)
        if canceled {
            guard !values.contains(.library) else {
                throw DiscriminatedResultSupport.decodingError(decoder, "项目库导出取消结果包含非法分支字段")
            }
            self = .canceled
        } else {
            guard values.contains(.library) else {
                throw DiscriminatedResultSupport.decodingError(decoder, "项目库导出成功结果缺少项目库")
            }
            self = .exported(try values.decode(ValidatedLibraryInfo.self, forKey: .library))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .canceled:
            try values.encode(true, forKey: .canceled)
        case .exported(let library):
            try values.encode(false, forKey: .canceled)
            try values.encode(library, forKey: .library)
        }
    }
}

public typealias LibraryLocationResult = LibraryImportResult

public struct LibraryRenameRequest: Codable, Hashable, Sendable {
    public let name: String

    public init(name: String) {
        self.name = name
    }
}

public enum LibraryRenameResult: Codable, Hashable, Sendable {
    case canceled
    case renamed(LibraryInfo)

    public init(canceled: Bool, restartRequired: Bool = false, library: LibraryInfo? = nil) throws {
        if canceled {
            guard !restartRequired, library == nil else {
                throw DiscriminatedResultSupport.initializationError("项目库重命名取消结果字段无效")
            }
            self = .canceled
        } else {
            guard restartRequired, let library else {
                throw DiscriminatedResultSupport.initializationError("项目库重命名成功结果字段无效")
            }
            self = .renamed(library)
        }
    }

    public var canceled: Bool {
        if case .canceled = self { return true }
        return false
    }

    public var restartRequired: Bool { !canceled }

    public var library: LibraryInfo? {
        guard case .renamed(let library) = self else { return nil }
        return library
    }

    private enum CodingKeys: String, CodingKey {
        case canceled
        case restartRequired
        case library
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let canceled = try values.decode(Bool.self, forKey: .canceled)
        if canceled {
            guard !values.contains(.restartRequired), !values.contains(.library) else {
                throw DiscriminatedResultSupport.decodingError(decoder, "项目库重命名取消结果包含非法分支字段")
            }
            self = .canceled
        } else {
            guard try values.decodeIfPresent(Bool.self, forKey: .restartRequired) == true,
                  values.contains(.library) else {
                throw DiscriminatedResultSupport.decodingError(decoder, "项目库重命名成功结果缺少必需字段")
            }
            self = .renamed(try values.decode(LibraryInfo.self, forKey: .library))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .canceled:
            try values.encode(true, forKey: .canceled)
        case .renamed(let library):
            try values.encode(false, forKey: .canceled)
            try values.encode(true, forKey: .restartRequired)
            try values.encode(library, forKey: .library)
        }
    }
}

public enum ProjectImportResult: Codable, Hashable, Sendable {
    case canceled
    case imported(ProjectData)

    public init(canceled: Bool, project: ProjectData? = nil) throws {
        if canceled {
            guard project == nil else {
                throw DiscriminatedResultSupport.initializationError("项目导入取消结果字段无效")
            }
            self = .canceled
        } else {
            guard let project else {
                throw DiscriminatedResultSupport.initializationError("项目导入成功结果缺少项目")
            }
            self = .imported(project)
        }
    }

    public var canceled: Bool {
        if case .canceled = self { return true }
        return false
    }

    public var project: ProjectData? {
        guard case .imported(let project) = self else { return nil }
        return project
    }

    private enum CodingKeys: String, CodingKey {
        case canceled
        case project
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let canceled = try values.decode(Bool.self, forKey: .canceled)
        if canceled {
            guard !values.contains(.project) else {
                throw DiscriminatedResultSupport.decodingError(decoder, "项目导入取消结果包含非法分支字段")
            }
            self = .canceled
        } else {
            guard values.contains(.project) else {
                throw DiscriminatedResultSupport.decodingError(decoder, "项目导入成功结果缺少项目")
            }
            self = .imported(try values.decode(ProjectData.self, forKey: .project))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .canceled:
            try values.encode(true, forKey: .canceled)
        case .imported(let project):
            try values.encode(false, forKey: .canceled)
            try values.encode(project, forKey: .project)
        }
    }
}

public enum ProjectExportResult: Codable, Hashable, Sendable {
    case canceled
    case exported(project: ProjectSummary, path: String)

    public init(canceled: Bool, project: ProjectSummary? = nil, path: String? = nil) throws {
        if canceled {
            guard project == nil, path == nil else {
                throw DiscriminatedResultSupport.initializationError("项目导出取消结果字段无效")
            }
            self = .canceled
        } else {
            guard let project, let path else {
                throw DiscriminatedResultSupport.initializationError("项目导出成功结果字段无效")
            }
            self = .exported(project: project, path: path)
        }
    }

    public var canceled: Bool {
        if case .canceled = self { return true }
        return false
    }

    public var project: ProjectSummary? {
        guard case .exported(let project, _) = self else { return nil }
        return project
    }

    public var path: String? {
        guard case .exported(_, let path) = self else { return nil }
        return path
    }

    private enum CodingKeys: String, CodingKey {
        case canceled
        case project
        case path
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let canceled = try values.decode(Bool.self, forKey: .canceled)
        if canceled {
            guard !values.contains(.project), !values.contains(.path) else {
                throw DiscriminatedResultSupport.decodingError(decoder, "项目导出取消结果包含非法分支字段")
            }
            self = .canceled
        } else {
            guard values.contains(.project), values.contains(.path) else {
                throw DiscriminatedResultSupport.decodingError(decoder, "项目导出成功结果缺少必需字段")
            }
            self = .exported(
                project: try values.decode(ProjectSummary.self, forKey: .project),
                path: try values.decode(String.self, forKey: .path)
            )
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .canceled:
            try values.encode(true, forKey: .canceled)
        case .exported(let project, let path):
            try values.encode(false, forKey: .canceled)
            try values.encode(project, forKey: .project)
            try values.encode(path, forKey: .path)
        }
    }
}

public struct ProjectRequest: Codable, Hashable, Sendable {
    public let id: String?
    public let name: String?
    public let description: String?
    public let settings: ProjectSettings?

    public init(id: String? = nil, name: String? = nil, description: String? = nil, settings: ProjectSettings? = nil) {
        self.id = id
        self.name = name
        self.description = description
        self.settings = settings
    }
}

public struct ProjectIdRequest: Codable, Hashable, Sendable {
    public let id: String

    public init(id: String) {
        self.id = id
    }
}

public struct ProjectScopedRequest: Codable, Hashable, Sendable {
    public let projectId: String

    public init(projectId: String) {
        self.projectId = projectId
    }
}

public struct ProjectTaskRequest: Codable, Hashable, Sendable {
    public let projectId: String
    public let task: TaskSaveData

    public init(projectId: String, task: TaskSaveData) {
        self.projectId = projectId
        self.task = task
    }
}

public struct ProjectTaskIdRequest: Codable, Hashable, Sendable {
    public let projectId: String
    public let id: String

    public init(projectId: String, id: String) {
        self.projectId = projectId
        self.id = id
    }
}

public struct ScenarioIdRequest: Codable, Hashable, Sendable {
    public let projectId: String
    public let id: String

    public init(projectId: String, id: String) {
        self.projectId = projectId
        self.id = id
    }
}

public struct ScenarioImportRequest: Codable, Hashable, Sendable {
    public let projectId: String
    public let profile: ScenarioProfile

    public init(projectId: String, profile: ScenarioProfile) {
        self.projectId = projectId
        self.profile = profile
    }
}

public struct ModelsRequest: Codable, Hashable, Sendable {
    public let providerId: String
    public let forceRefresh: Bool?

    public init(providerId: String, forceRefresh: Bool? = nil) {
        self.providerId = providerId
        self.forceRefresh = forceRefresh
    }
}

public struct ProviderKeyRequest: Codable, Hashable, Sendable {
    public let provider: String
    public let apiKey: String

    public init(provider: String, apiKey: String) {
        self.provider = provider
        self.apiKey = apiKey
    }

    private enum CodingKeys: String, CodingKey {
        case provider
        case apiKey
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        provider = try values.decode(String.self, forKey: .provider)
        apiKey = try values.decode(String.self, forKey: .apiKey)
    }

    public func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(provider, forKey: .provider)
        // This is the transient IPC boundary. Persistence accepts only the
        // separate non-secret configuration record.
        try values.encode(apiKey, forKey: .apiKey)
    }
}

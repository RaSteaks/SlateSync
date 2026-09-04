import Foundation

/// Shared validation for persisted custom-provider records. The rules mirror
/// `lib/custom-provider.mjs` so native reads cannot publish a record that the
/// existing Main process would reject or expose unsanitized.
public enum CustomProviderValidator {
    public static let idPrefix = "openai-compatible:"

    /// Normalizes an IPC create/update request and generates the same UUID
    /// shaped ID as Electron when the request has no usable ID.
    public static func normalizeRequest(
        _ request: CustomProviderConfigRequest
    ) throws -> CustomProviderConfiguration {
        // Update callers may use the additive `providerId` alias instead of
        // `id`; prefer the canonical field but keep both request spellings
        // useful before the full native settings editor is introduced.
        let id = try normalizeID(
            request.id ?? request.providerId,
            generateIfMissing: true
        )
        return try normalize(
            CustomProviderConfiguration(
                id: id,
                name: request.name,
                baseUrl: request.baseUrl,
                transport: request.transport ?? .chatCompletions,
                jsonMode: request.jsonMode ?? .jsonSchema,
                imageDetail: request.imageDetail ?? .high,
                manualModelIds: request.manualModelIds ?? []
            )
        )
    }

    public static func normalize(
        _ provider: CustomProviderConfiguration
    ) throws -> CustomProviderConfiguration {
        let id = try normalizeID(provider.id)
        let name = try normalizeName(provider.name)
        let baseURL = try normalizeBaseURL(provider.baseUrl)
        let revision = normalizeRevision(provider.revision)

        return CustomProviderConfiguration(
            id: id,
            name: name,
            label: name,
            baseUrl: baseURL,
            transport: provider.transport,
            jsonMode: provider.jsonMode,
            imageDetail: provider.imageDetail,
            manualModelIds: normalizeModelIDs(provider.manualModelIds),
            revision: revision,
            capabilityCache: normalizeCapabilityCache(provider.capabilityCache, revision: revision)
        )
    }

    /// Invalid records are discarded while loading an old snapshot, matching
    /// the JavaScript sanitizer and keeping one malformed entry from blocking
    /// access to otherwise valid global settings.
    public static func sanitize(
        _ providers: [CustomProviderConfiguration]
    ) -> [CustomProviderConfiguration] {
        var result: [CustomProviderConfiguration] = []
        var seenIDs = Set<String>()
        var seenNames = Set<String>()

        for provider in providers {
            guard let normalized = try? normalize(provider) else { continue }
            let nameKey = normalized.name.lowercased()
            guard seenIDs.insert(normalized.id).inserted,
                  seenNames.insert(nameKey).inserted else {
                continue
            }
            result.append(normalized)
        }
        return result
    }

    public static func normalizeID(
        _ value: String?,
        generateIfMissing: Bool = false
    ) throws -> String {
        let raw = (value ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if raw.isEmpty, generateIfMissing {
            return idPrefix + UUID().uuidString.lowercased()
        }
        if raw == "openai-compatible" { return raw }

        let pattern = #"^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$"#
        guard raw.hasPrefix(idPrefix),
              raw.dropFirst(idPrefix.count).range(
                of: pattern,
                options: [.regularExpression, .caseInsensitive]
              ) != nil else {
            throw invalid("接口 ID 无效")
        }
        return idPrefix + raw.dropFirst(idPrefix.count).lowercased()
    }

    private static func normalizeName(_ value: String?) throws -> String {
        let name = (value ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard (1...60).contains(name.unicodeScalars.count),
              !name.unicodeScalars.contains(where: isControlScalar) else {
            throw invalid("接口名称需为 1–60 个字符且不能包含控制字符")
        }
        return name
    }

    private static func normalizeBaseURL(_ value: String) throws -> String {
        guard let normalized = HTTPURLNormalizer.normalize(
            value,
            trailingSlashPolicy: .removeAll
        ) else {
            throw invalid("Base URL 必须是无账号、查询参数和片段的 http(s) URL")
        }
        return normalized
    }

    private static func normalizeModelIDs(_ values: [String]) -> [String] {
        let pattern = #"^[A-Za-z0-9][A-Za-z0-9._:/@-]*$"#
        var seen = Set<String>()
        return values.compactMap { value in
            let modelID = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard (1...220).contains(JavaScriptCompatibility.utf16Length(modelID)),
                  modelID.range(of: pattern, options: .regularExpression) != nil,
                  seen.insert(modelID).inserted else {
                return nil
            }
            return modelID
        }
    }

    private static func normalizeRevision(_ value: Int) -> Int {
        // Keep the boundary aligned with JavaScript's Number safe integer
        // range even though Swift's Int can represent larger values.
        let maximumSafeInteger = 9_007_199_254_740_991
        return value > 0 && value <= maximumSafeInteger ? value : 1
    }

    private static func normalizeCapabilityCache(
        _ value: [String: CustomProviderCapabilityVerification]?,
        revision: Int
    ) -> [String: CustomProviderCapabilityVerification]? {
        guard let value else { return nil }
        let allowedStatuses: Set<ModelCapabilityStatus> = [.verified, .failed, .canceled]
        var result: [String: CustomProviderCapabilityVerification] = [:]

        for (modelID, entry) in value {
            guard isValidModelID(modelID),
                  allowedStatuses.contains(entry.status),
                  entry.hasExplicitRevision,
                  entry.revision == revision else {
                continue
            }
            result[modelID] = CustomProviderCapabilityVerification(
                status: entry.status,
                revision: revision,
                checkedAt: entry.checkedAt,
                transport: entry.transport,
                capabilitySource: entry.capabilitySource.map {
                    truncateUTF16(StructuredLogRedactor.redactText($0), maximumLength: 120)
                } ?? "probe",
                message: entry.message.map {
                    truncateUTF16(StructuredLogRedactor.redactText($0), maximumLength: 500)
                }
            )
        }
        return result
    }

    private static func truncateUTF16(_ value: String, maximumLength: Int) -> String {
        // Electron applies String#slice to these diagnostic fields, which is
        // measured in UTF-16 code units rather than Swift grapheme clusters.
        String(decoding: value.utf16.prefix(maximumLength), as: UTF16.self)
    }

    private static func isValidModelID(_ value: String) -> Bool {
        let pattern = #"^[A-Za-z0-9][A-Za-z0-9._:/@-]*$"#
        return (1...220).contains(JavaScriptCompatibility.utf16Length(value)) &&
            value.range(of: pattern, options: .regularExpression) != nil
    }

    private static func isControlScalar(_ scalar: UnicodeScalar) -> Bool {
        scalar.value <= 0x1F || (0x7F...0x9F).contains(scalar.value)
    }

    private static func invalid(_ message: String) -> SlateSyncError {
        SlateSyncError(code: "CUSTOM_PROVIDER_INVALID", message: message)
    }
}

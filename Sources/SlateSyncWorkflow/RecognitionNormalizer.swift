import Foundation
import SlateSyncDomain

/// Reproduces the retained JavaScript normalization boundary before page
/// results are merged or persisted, including UTF-16-compatible field rules.
public enum RecognitionNormalizer {
    public static func normalize(_ value: JSONValue, pageNumber: Int) throws -> RecognitionSheet {
        guard case .object(let root) = value, case .array(let rows)? = root["records"] else {
            throw SlateSyncError(code: "MODEL_JSON", message: "模型返回的数据不包含 records 数组", status: 502, providerError: true)
        }
        let sheetTitle = clean(string(root["sheetTitle"]))
        let warnings: [String]
        if case .array(let values)? = root["warnings"] {
            warnings = values.compactMap { if case .string(let text) = $0 { return text }; return nil }
        } else { warnings = [] }

        let records = rows.enumerated().map { index, value -> RecognitionRecord in
            let fields: [String: JSONValue]
            if case .object(let object) = value { fields = object } else { fields = [:] }
            let confidence = RecognitionConfidence(rawValue: string(fields["confidence"]) ?? "") ?? .low
            return RecognitionRecord(
                id: "record-page-\(pageNumber)-\(index)", sourcePage: pageNumber,
                cardNumber: normalizeCard(string(fields["cardNumber"])),
                videoCode: normalizeVideo(string(fields["videoCode"])),
                scene: normalizeScene(string(fields["scene"]), width: 3),
                shot: normalizeNumber(string(fields["shot"]), width: 2),
                take: normalizeNumber(string(fields["take"]), width: 2),
                takeStatus: LegacyTakeStatusAdapter.status(
                    value: string(fields["takeStatus"]),
                    legacyGoodTake: boolean(fields["goodTake"])
                ),
                description: clean(string(fields["description"])),
                comments: clean(string(fields["comments"])),
                shotSize: clean(string(fields["shotSize"])),
                cameraPosition: clean(string(fields["cameraPosition"])),
                confidence: confidence,
                reviewRequiredFields: stringArray(fields["reviewRequiredFields"])
            )
        }
        return RecognitionSheet(sheetTitle: sheetTitle, records: records, warnings: warnings)
    }

    public static func format(_ sheet: RecognitionSheet, formats: ResolveFieldFormats) -> RecognitionSheet {
        let sceneWidth = width(formats.scene, fallback: 3)
        let shotWidth = width(formats.shot, fallback: 2)
        let takeWidth = width(formats.take, fallback: 2)
        return RecognitionSheet(sheetTitle: sheet.sheetTitle, records: sheet.records.map { record in
            RecognitionRecord(
                id: record.id, sourcePage: record.sourcePage,
                cardNumber: normalizeCard(record.cardNumber), videoCode: normalizeVideo(record.videoCode),
                scene: normalizeScene(record.scene, width: sceneWidth),
                shot: normalizeNumber(record.shot, width: shotWidth), take: normalizeNumber(record.take, width: takeWidth),
                takeStatus: record.takeStatus, description: record.description, comments: record.comments,
                shotSize: record.shotSize, cameraPosition: record.cameraPosition,
                confidence: record.confidence, reviewRequiredFields: record.reviewRequiredFields
            )
        }, warnings: sheet.warnings)
    }

    public static func aggregateUsage(_ values: [TokenUsage?]) -> TokenUsage? {
        func total(_ keyPath: KeyPath<TokenUsage, Int?>) -> Int? {
            let numbers = values.compactMap { $0?[keyPath: keyPath] }.filter { $0 >= 0 }
            return numbers.isEmpty ? nil : numbers.reduce(0, +)
        }
        let result = TokenUsage(
            promptTokens: total(\.promptTokens), completionTokens: total(\.completionTokens),
            totalTokens: total(\.totalTokens), inputTokens: total(\.inputTokens), outputTokens: total(\.outputTokens)
        )
        return [result.promptTokens, result.completionTokens, result.totalTokens, result.inputTokens, result.outputTokens].allSatisfy { $0 == nil } ? nil : result
    }

    public static func normalizeCard(_ value: String?) -> String? {
        guard let normalized = clean(value)?.uppercased() else { return nil }
        let compact = normalized.replacingOccurrences(of: #"[\s_-]+"#, with: "", options: .regularExpression)
        guard let match = compact.wholeMatch(of: /^([A-Z])(\d{1,6})$/), let number = Int(match.output.2) else { return normalized }
        return "\(match.output.1)\(String(format: "%03d", number))"
    }

    public static func normalizeVideo(_ value: String?) -> String? {
        guard let normalized = clean(value)?.uppercased() else { return nil }
        let compact = normalized.replacingOccurrences(of: #"\s+"#, with: "", options: .regularExpression)
        let digits = compact.hasPrefix("C") ? String(compact.dropFirst()) : compact
        guard !digits.isEmpty, digits.allSatisfy(\.isNumber) else { return normalized }
        var trimmed = digits
        while trimmed.count > 3, trimmed.first == "0" { trimmed.removeFirst() }
        guard trimmed.count <= 3 else { return nil }
        let padded = String(repeating: "0", count: 3 - trimmed.count) + trimmed
        return padded.first == "0" ? "C" + padded : nil
    }

    public static func normalizeScene(_ value: String?, width: Int) -> String? {
        guard let normalized = clean(ResolveCSVNormalization.chineseNumeralsToArabic(value))?.uppercased() else { return nil }
        let regex = try? NSRegularExpression(pattern: #"(\d+)\s*([A-Z]+)?"#)
        let range = NSRange(normalized.startIndex..., in: normalized)
        let parts = (regex?.matches(in: normalized, range: range) ?? []).compactMap { match -> String? in
            guard let numberRange = Range(match.range(at: 1), in: normalized), let number = Int(normalized[numberRange]), number < 1_000_000 else { return nil }
            let suffix = match.range(at: 2).location == NSNotFound ? "" : Range(match.range(at: 2), in: normalized).map { String(normalized[$0]) } ?? ""
            return suffix.isEmpty ? String(number) : "\(number)\(suffix)"
        }
        guard !parts.isEmpty else { return nil }
        if parts.count > 1 || parts[0].contains(where: \.isLetter) { return parts.joined(separator: " / ") }
        return String(repeating: "0", count: max(0, width - parts[0].count)) + parts[0]
    }

    public static func normalizeNumber(_ value: String?, width: Int) -> String? {
        guard let text = clean(ResolveCSVNormalization.chineseNumeralsToArabic(value)),
              let match = text.firstMatch(of: /\d+/), let number = Int(match.output), number < 1_000_000 else { return nil }
        let digits = String(number)
        return String(repeating: "0", count: max(0, width - digits.count)) + digits
    }

    public static func materialKey(_ record: RecognitionRecord) -> String? {
        guard let card = normalizeCard(record.cardNumber), let video = normalizeVideo(record.videoCode) else { return nil }
        return card + video
    }

    public static func videoOrdinal(_ value: String?) -> Int? {
        guard let value = normalizeVideo(value) else { return nil }
        return Int(value.dropFirst())
    }

    private static func clean(_ value: String?) -> String? {
        guard let value else { return nil }
        let result = value.precomposedStringWithCompatibilityMapping.trimmingCharacters(in: .whitespacesAndNewlines)
        return result.isEmpty ? nil : result
    }

    private static func width(_ value: String, fallback: Int) -> Int {
        let text = value.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        return (1...6).contains(text.count) && text.allSatisfy { $0 == "X" } ? text.count : fallback
    }

    private static func string(_ value: JSONValue?) -> String? { if case .string(let text)? = value { return text }; return nil }
    private static func boolean(_ value: JSONValue?) -> Bool? { if case .boolean(let flag)? = value { return flag }; return nil }
    private static func stringArray(_ value: JSONValue?) -> [String]? {
        guard case .array(let values)? = value else { return nil }
        let result = values.compactMap(string)
        return result.isEmpty ? nil : Array(NSOrderedSet(array: result)) as? [String]
    }
}

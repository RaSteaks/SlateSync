import CryptoKit
import Foundation
import SlateSyncDomain

/// Deterministic Scenario Profile learning compatible with fingerprint v1.
/// OCR engines remain out of scope: callers provide normalized page/view data.
public actor ScenarioProfileEngine: ScenarioProfileProcessing {
    public static let schemaVersion = 1
    public static let fingerprintVersion = 1

    private struct FieldDefinition {
        let label: String
        let aliases: [String]
    }

    private struct Block {
        let text: String
        let confidence: Double
        let bbox: [Double]
    }

    private static let definitions: [(String, FieldDefinition)] = [
        ("cardNumber", .init(label: "卷号", aliases: ["卷号", "卡号", "卡", "card", "reel"])),
        ("videoCode", .init(label: "视频码", aliases: ["视频号", "视频码", "条号", "clip", "clip name"])),
        ("scene", .init(label: "场次", aliases: ["场次", "场景", "scene"])),
        ("shot", .init(label: "镜", aliases: ["镜", "镜号", "shot"])),
        ("take", .init(label: "次", aliases: ["次", "条次", "take"])),
        ("takeStatus", .init(label: "条次状态", aliases: ["过", "保", "废条", "状态", "status"])),
        ("description", .init(label: "拍摄内容", aliases: ["拍摄内容", "内容", "内容/视效说明", "description"])),
        ("comments", .init(label: "备注", aliases: ["备注", "注释", "comment", "comments"])),
        ("shotSize", .init(label: "景别", aliases: ["景别", "shot size"])),
        ("cameraPosition", .init(label: "机位", aliases: ["机位", "camera position"])),
    ]

    public init() {}

    public func profile(from input: ScenarioObservationInput, resolve: ProjectSettings.ResolveSettings) throws -> ScenarioProfile {
        var pages: [ScenarioPageShape] = []
        var allBlocks: [Block] = []
        for page in input.pages {
            try Task.checkCancellation()
            var shapes: [ScenarioViewShape] = []
            for view in page.views {
                let blocks = view.blocks.compactMap { raw -> Block? in
                    let text = Self.token(raw.text)
                    guard !text.isEmpty, let bbox = Self.bbox(raw.bboxNormalized) else { return nil }
                    return Block(text: text, confidence: raw.confidence.isFinite ? raw.confidence : 0, bbox: bbox)
                }
                allBlocks.append(contentsOf: blocks)
                shapes.append(ScenarioViewShape(width: view.width, height: view.height, orientation: Self.orientation(width: view.width, height: view.height), blockCount: blocks.count))
            }
            // The typed input is already integral; like JavaScript integer(),
            // preserve explicit zero/negative page numbers instead of repairing.
            pages.append(ScenarioPageShape(pageNumber: page.pageNumber, views: shapes))
        }

        let headerTokens = Self.uniqueSorted(allBlocks.filter { $0.bbox[1] <= 0.35 }.map(\.text).filter { $0.utf16.count <= 40 })
        let cameraGroups = Self.uniqueSorted(allBlocks.map(\.text).filter {
            // The v1 JavaScript regex sees normalized lowercase Latin tokens,
            // so only Chinese-numeral 机 labels match this first alternative.
            $0.range(of: #"^[一二三四]机$"#, options: .regularExpression) != nil ||
                $0.range(of: #"^[a-d]cam$"#, options: [.regularExpression, .caseInsensitive]) != nil
        })
        let columns = Self.quantized(allBlocks.map { ($0.bbox[0] + $0.bbox[2]) / 2 })
        let rows = Self.quantized(allBlocks.map { ($0.bbox[1] + $0.bbox[3]) / 2 })
        let layout = ScenarioLayout(pages: pages, headerTokens: headerTokens, cameraGroups: cameraGroups, columnBands: columns, rowBands: rows, blockCount: allBlocks.count)
        let aliases = Self.detectAliases(headerTokens)
        let profiles = Self.fieldProfiles(aliases: aliases, blocks: allBlocks)
        let fields = ScenarioFields(
            cardNumber: profiles["cardNumber"]!, videoCode: profiles["videoCode"]!,
            scene: profiles["scene"]!, shot: profiles["shot"]!, take: profiles["take"]!,
            takeStatus: profiles["takeStatus"]!, description: profiles["description"]!,
            comments: profiles["comments"]!, shotSize: profiles["shotSize"]!,
            cameraPosition: profiles["cameraPosition"]!
        )
        let fingerprint = Self.fingerprint(layout)
        return ScenarioProfile(
            schemaVersion: Self.schemaVersion,
            fingerprintVersion: Self.fingerprintVersion,
            fingerprint: fingerprint,
            label: Self.label(input.filename).isEmpty ? "自动学习场记结构" : Self.label(input.filename),
            layout: layout,
            fields: fields,
            recognition: ScenarioRecognitionConfig(
                headerTokens: headerTokens,
                promptHints: ["优先依据当前 Profile 提供的字段区域、表头和行列结构识别；结构不确定时返回 null，不要猜测。"]
            ),
            output: ScenarioOutputConfig(resolve: resolve)
        )
    }

    /// Normalizes imported v1 profiles before comparison or publication.
    /// Future versions fail closed so this phase never invents schema v2 data.
    public func normalize(_ profile: ScenarioProfile) throws -> ScenarioProfile {
        guard profile.schemaVersion == Self.schemaVersion,
              profile.fingerprintVersion == Self.fingerprintVersion else {
            throw SlateSyncError(code: "SCENARIO_VERSION", message: "场记结构版本不受支持")
        }
        try profile.output.resolve.fieldFormats.validate()
        try profile.output.resolve.comments.validate()
        let layout = ScenarioLayout(
            pages: profile.layout.pages.map { page in
                ScenarioPageShape(pageNumber: page.pageNumber, views: page.views.map { view in
                    ScenarioViewShape(width: view.width, height: view.height, orientation: Self.trimmed(view.orientation).isEmpty ? "unknown" : Self.trimmed(view.orientation), blockCount: view.blockCount)
                })
            },
            headerTokens: Self.uniqueSorted(profile.layout.headerTokens.map(Self.token)),
            cameraGroups: Self.uniqueSorted(profile.layout.cameraGroups.map(Self.token)),
            columnBands: Self.normalizedBands(profile.layout.columnBands),
            rowBands: Self.normalizedBands(profile.layout.rowBands),
            blockCount: profile.layout.blockCount
        )
        let fields = ScenarioFields(
            cardNumber: try Self.normalizedField(profile.fields.cardNumber, definition: Self.definitions[0].1),
            videoCode: try Self.normalizedField(profile.fields.videoCode, definition: Self.definitions[1].1),
            scene: try Self.normalizedField(profile.fields.scene, definition: Self.definitions[2].1),
            shot: try Self.normalizedField(profile.fields.shot, definition: Self.definitions[3].1),
            take: try Self.normalizedField(profile.fields.take, definition: Self.definitions[4].1),
            takeStatus: try Self.normalizedField(profile.fields.takeStatus, definition: Self.definitions[5].1),
            description: try Self.normalizedField(profile.fields.description, definition: Self.definitions[6].1),
            comments: try Self.normalizedField(profile.fields.comments, definition: Self.definitions[7].1),
            shotSize: try Self.normalizedField(profile.fields.shotSize, definition: Self.definitions[8].1),
            cameraPosition: try Self.normalizedField(profile.fields.cameraPosition, definition: Self.definitions[9].1)
        )
        let fingerprint = profile.fingerprint.trimmingCharacters(in: .whitespacesAndNewlines)
        if !fingerprint.isEmpty,
           fingerprint.range(of: #"^[0-9a-f]{32}$"#, options: .regularExpression) == nil {
            throw SlateSyncError(code: "SCENARIO_FINGERPRINT", message: "场记结构指纹无效")
        }
        let hints = Array(profile.recognition.promptHints.map { Self.utf16Prefix($0.trimmingCharacters(in: .whitespacesAndNewlines), limit: 1_000) }.filter { !$0.isEmpty }.prefix(20))
        return ScenarioProfile(
            schemaVersion: Self.schemaVersion,
            fingerprintVersion: Self.fingerprintVersion,
            fingerprint: fingerprint.isEmpty ? Self.fingerprint(layout) : fingerprint,
            label: Self.label(profile.label).isEmpty ? "自动学习场记结构" : Self.label(profile.label),
            layout: layout,
            fields: fields,
            recognition: ScenarioRecognitionConfig(headerTokens: Self.uniqueSorted(profile.recognition.headerTokens.map(Self.token)), promptHints: hints),
            output: profile.output
        )
    }

    public func similarity(_ left: ScenarioProfile, _ right: ScenarioProfile) throws -> Double {
        // The public primitive mirrors scenarioSimilarity rather than assuming
        // callers already normalized imported profiles.
        let normalizedLeft = try normalize(left)
        let normalizedRight = try normalize(right)
        if normalizedLeft.fingerprint == normalizedRight.fingerprint { return 1 }
        let page = Self.pageScore(normalizedLeft.layout.pages, normalizedRight.layout.pages)
        let headers = Self.jaccard(normalizedLeft.layout.headerTokens, normalizedRight.layout.headerTokens)
        let cameras = Self.jaccard(normalizedLeft.layout.cameraGroups, normalizedRight.layout.cameraGroups)
        let columns = Self.bandScore(normalizedLeft.layout.columnBands, normalizedRight.layout.columnBands)
        let rows = Self.bandScore(normalizedLeft.layout.rowBands, normalizedRight.layout.rowBands)
        return ((page * 0.20 + headers * 0.40 + cameras * 0.15 + columns * 0.15 + rows * 0.10) * 1_000_000).rounded() / 1_000_000
    }

    public func promptInstruction(_ profile: ScenarioProfile) -> String {
        let entries: [(String, ScenarioFieldProfile)] = [
            ("cardNumber", profile.fields.cardNumber), ("videoCode", profile.fields.videoCode),
            ("scene", profile.fields.scene), ("shot", profile.fields.shot), ("take", profile.fields.take),
            ("takeStatus", profile.fields.takeStatus), ("description", profile.fields.description),
            ("comments", profile.fields.comments), ("shotSize", profile.fields.shotSize),
            ("cameraPosition", profile.fields.cameraPosition),
        ]
        let regions = entries.compactMap { name, field in field.region.map { "\(name)=\($0.map(Self.jsNumber).joined(separator: ","))" } }.joined(separator: "; ")
        let headers = profile.recognition.headerTokens.isEmpty ? "无可靠表头" : profile.recognition.headerTokens.joined(separator: "、")
        let cameras = profile.layout.cameraGroups.isEmpty ? "未确认" : profile.layout.cameraGroups.joined(separator: "、")
        let hints = profile.recognition.promptHints.joined(separator: "；")
        return "\n\n当前场记结构 Profile：\(profile.label)。版式表头：\(headers)。摄影机区块：\(cameras)。字段区域（归一化坐标）：\(regions.isEmpty ? "未确认" : regions)。\(hints.isEmpty ? "" : "补充提示：\(hints)。")这些是版式辅助证据，仍须以当前图片为准；无法确认的字段返回 null。"
    }

    public nonisolated static func fingerprint(_ layout: ScenarioLayout) -> String {
        // stableStringify sorts object keys lexically at every level. This
        // hand-built v1 payload avoids JSONEncoder dictionary-order drift.
        let pageJSON = layout.pages.map { page in
            let views = page.views.map { view in
                "{\"blockCount\":\(view.blockCount),\"height\":\(view.height),\"orientation\":\(json(view.orientation)),\"width\":\(view.width)}"
            }.joined(separator: ",")
            return "{\"pageNumber\":\(page.pageNumber),\"views\":[\(views)]}"
        }.joined(separator: ",")
        let value = "{\"cameraGroups\":\(jsonArray(layout.cameraGroups)),\"columnBands\":\(numberArray(layout.columnBands)),\"headerTokens\":\(jsonArray(layout.headerTokens)),\"pages\":[\(pageJSON)],\"rowBands\":\(numberArray(layout.rowBands)),\"version\":1}"
        return SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined().prefix(32).description
    }

    private static func detectAliases(_ headers: [String]) -> [String: [String]] {
        Dictionary(uniqueKeysWithValues: definitions.map { name, definition in
            let accepted = definition.aliases.map(token)
            return (name, headers.filter { header in accepted.contains { header == $0 || header.contains($0) } })
        })
    }

    private static func fieldProfiles(aliases: [String: [String]], blocks: [Block]) -> [String: ScenarioFieldProfile] {
        Dictionary(uniqueKeysWithValues: definitions.map { name, definition in
            let detected = aliases[name] ?? []
            let matches = blocks.filter { detected.contains($0.text) }
            let region = matches.reduce(nil as [Double]?) { current, block in
                guard let current else { return block.bbox }
                return [min(current[0], block.bbox[0]), min(current[1], block.bbox[1]), max(current[2], block.bbox[2]), max(current[3], block.bbox[3])]
            }
            let allAliases = uniqueSorted((definition.aliases + detected).map(token))
            return (name, ScenarioFieldProfile(label: definition.label, aliases: allAliases, region: region, inherit: ["scene", "shot"].contains(name), required: ["scene", "shot", "take"].contains(name)))
        })
    }

    private static func normalizedField(_ field: ScenarioFieldProfile, definition: FieldDefinition) throws -> ScenarioFieldProfile {
        let region: [Double]?
        if let raw = field.region {
            guard let normalized = bbox(raw) else { throw SlateSyncError(code: "SCENARIO_BBOX", message: "场记结构字段区域无效") }
            region = normalized
        } else { region = nil }
        let label = Self.label(field.label)
        return ScenarioFieldProfile(
            label: label.isEmpty ? definition.label : label,
            aliases: uniqueSorted((definition.aliases + field.aliases).map(token)),
            region: region,
            inherit: field.inherit,
            required: field.required
        )
    }

    private static func pageScore(_ left: [ScenarioPageShape], _ right: [ScenarioPageShape]) -> Double {
        guard let a = left.first?.views.first, let b = right.first?.views.first else { return 0 }
        if a.orientation == b.orientation, a.width != 0, b.width != 0, a.height != 0, b.height != 0 {
            return (min(Double(a.width) / Double(b.width), Double(b.width) / Double(a.width)) + min(Double(a.height) / Double(b.height), Double(b.height) / Double(a.height))) / 2
        }
        return a.orientation == b.orientation ? 0.6 : 0
    }

    private static func jaccard<T: Hashable>(_ left: [T], _ right: [T]) -> Double {
        let a = Set(left), b = Set(right)
        if a.isEmpty && b.isEmpty { return 1 }
        let union = a.union(b).count
        return union == 0 ? 0 : Double(a.intersection(b).count) / Double(union)
    }

    private static func bandScore(_ left: [Double], _ right: [Double]) -> Double {
        guard !left.isEmpty, !right.isEmpty else { return 0 }
        return max(0, 1 - Double(abs(left.count - right.count)) / Double(max(left.count, right.count)))
    }

    private static func bbox(_ value: [Double]) -> [Double]? {
        guard value.count == 4, value.allSatisfy(\.isFinite) else { return nil }
        let rounded = value.map { ($0 * 1_000_000).rounded() / 1_000_000 }
        guard rounded[0] >= 0, rounded[1] >= 0, rounded[2] <= 1, rounded[3] <= 1, rounded[2] >= rounded[0], rounded[3] >= rounded[1] else { return nil }
        return rounded
    }

    private static func quantized(_ values: [Double]) -> [Double] {
        // Array.sort() without a comparator is lexicographic in the v1 JS
        // implementation even for numeric bands (15 precedes 2).
        return Array(Set(values.filter(\.isFinite).map { ($0 / 0.05).rounded() }))
            .sorted { String($0) < String($1) }
    }

    private static func normalizedBands(_ values: [Double]) -> [Double] {
        Array(Set(values.map { $0.isFinite && $0.rounded() == $0 ? $0 : 0 })).sorted { String($0) < String($1) }
    }

    private static func orientation(width: Int, height: Int) -> String {
        guard width != 0, height != 0 else { return "unknown" }
        return width >= height ? "landscape" : "portrait"
    }

    private static func token(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).precomposedStringWithCompatibilityMapping
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression).lowercased()
    }

    private static func trimmed(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "\u{FEFF}")))
    }

    private static func label(_ value: String) -> String {
        utf16Prefix(value.trimmingCharacters(in: .whitespacesAndNewlines), limit: 120)
    }

    private static func utf16Prefix(_ value: String, limit: Int) -> String {
        String(decoding: Array(value.utf16.prefix(limit)), as: UTF16.self)
    }

    private static func uniqueSorted(_ values: [String]) -> [String] { Array(Set(values.filter { !$0.isEmpty })).sorted() }
    private nonisolated static func json(_ value: String) -> String {
        // Keep fingerprint serialization infallible and independent from
        // JSONEncoder output-policy changes while matching JSON string escapes.
        var result = "\""
        for scalar in value.unicodeScalars {
            switch scalar.value {
            case 0x22: result += "\\\""
            case 0x5C: result += "\\\\"
            case 0x08: result += "\\b"
            case 0x0C: result += "\\f"
            case 0x0A: result += "\\n"
            case 0x0D: result += "\\r"
            case 0x09: result += "\\t"
            case 0x00...0x1F: result += String(format: "\\u%04x", scalar.value)
            default: result.append(String(scalar))
            }
        }
        result += "\""
        return result
    }
    private nonisolated static func jsonArray(_ values: [String]) -> String { "[\(values.map(json).joined(separator: ","))]" }
    private nonisolated static func numberArray(_ values: [Double]) -> String { "[\(values.map(jsNumber).joined(separator: ","))]" }
    private nonisolated static func jsNumber(_ value: Double) -> String { value.rounded() == value ? String(Int(value)) : String(value) }
}

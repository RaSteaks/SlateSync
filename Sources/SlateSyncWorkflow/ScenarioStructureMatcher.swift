import CryptoKit
import Foundation
import SlateSyncDomain

/// Printed-header matching deliberately ignores filenames, pixel dimensions,
/// filled rows and core-detail views. V1 fingerprint helpers remain available
/// for historical decoding and differential fixtures, not automatic learning.
public enum ScenarioStructureMatcher {
    private static let definitions: [(String, String, [String])] = [
        ("cardNumber", "卷号", ["卷号", "卡号", "reel", "card"]),
        ("videoCode", "视频码", ["视频码", "视频号", "条号", "clip", "clipname"]),
        ("scene", "场次", ["场次", "场景", "scene"]),
        ("shot", "镜", ["镜", "镜号", "shot"]),
        ("take", "次", ["次", "条次", "take"]),
        ("takeStatus", "状态", ["状态", "条次状态", "过/保/废", "√/x", "status"]),
        ("description", "拍摄内容", ["拍摄内容", "内容", "内容/视效说明", "description"]),
        ("comments", "备注", ["备注", "注释", "comment", "comments"]),
        ("shotSize", "景别", ["景别", "shotsize"]),
        ("cameraPosition", "机位", ["机位", "cameraposition"]),
    ]

    public static func evaluate(_ input: ScenarioObservationInput, profiles: [ScenarioData],
                                confirmedAssociations: [ScenarioConfirmedAssociation] = [],
                                resolve: ProjectSettings.ResolveSettings = .init(),
                                matching: ScenarioMatchingConfig = .init()) throws -> [ScenarioPageDecision] {
        try matching.validate()
        // Validate frozen/external evidence at this boundary. Only persisted
        // manual associations are supplied by the production snapshot reader.
        let associations = try confirmedAssociations.filter { isSufficient($0.structure) }.map {
            (profileID: $0.profileID, structure: $0.structure, fingerprint: try fingerprint($0.structure))
        }
        let byProfile = Dictionary(grouping: associations, by: \.profileID)
        let knownIDs = Set(profiles.filter {
            $0.canonicalID == nil && $0.schemaVersion == 1 && [1, 2].contains($0.fingerprintVersion)
        }.map(\.id))
        return try input.pages.map { page in
            try Task.checkCancellation()
            guard let full = page.views.first else {
                return .init(pageNumber: page.pageNumber, status: .insufficient, candidate: nil)
            }
            let structure = describe(full)
            guard isSufficient(structure) else {
                return .init(pageNumber: page.pageNumber, status: .insufficient, candidate: nil)
            }
            let candidate = try profile(structure, filename: input.filename, resolve: resolve)
            let confirmedIDs = Set(associations.filter { $0.fingerprint == candidate.fingerprint }.map(\.profileID)).intersection(knownIDs)
            let scored = try profiles.compactMap { stored -> (ScenarioData, ScenarioMatchDiagnostic, String)? in
                guard stored.canonicalID == nil, stored.schemaVersion == 1, [1, 2].contains(stored.fingerprintVersion),
                      confirmedIDs.isEmpty || confirmedIDs.contains(stored.id) else { return nil }
                var alternatives = byProfile[stored.id, default: []].map { ($0.structure, $0.fingerprint) }
                if let original = descriptor(stored), isSufficient(original) {
                    alternatives.append((original, try fingerprint(original)))
                }
                // Score a family once using its best confirmed geometry. Its
                // own alternatives cannot become competing second-place hits.
                let best = alternatives.map { (compare(structure, $0.0, profileID: stored.id), $0.1) }.sorted {
                    if $0.0.score != $1.0.score { return $0.0.score > $1.0.score }
                    if $0.1 != $1.1 { return $0.1 < $1.1 }
                    return ($0.0.coverage, $0.0.geometry) > ($1.0.coverage, $1.0.geometry)
                }.first
                guard let best else { return nil }
                return (stored, best.0, best.1)
            }.sorted {
                if $0.1.score != $1.1.score { return $0.1.score > $1.1.score }
                // Input order and last-used timestamps cannot change evaluation.
                return ($0.0.createdAt, $0.0.id) < ($1.0.createdAt, $1.0.id)
            }
            guard let best = scored.first else {
                return .init(pageNumber: page.pageNumber, status: .candidate, candidate: candidate)
            }
            // An exact manual association resolves an otherwise ambiguous
            // prototype match. Conflicting manual associations still abstain.
            let second = scored.dropFirst().first { $0.2 != best.2 || !sameInterpretation($0.0, best.0) }
            let supported = best.1.orderMatches && best.1.coverage >= 0.85 && best.1.score >= matching.threshold
            let ambiguous = supported && (confirmedIDs.count > 1 || second.map {
                best.1.score == $0.1.score || best.1.score - $0.1.score < matching.ambiguityMargin
            } == true)
            return .init(pageNumber: page.pageNumber,
                         status: ambiguous ? .ambiguous : (supported ? .reused : .candidate),
                         candidate: candidate, profile: supported && !ambiguous ? best.0 : nil,
                         score: best.1.score, diagnostics: scored.map(\.1))
        }
    }

    public static func describe(_ view: ScenarioOCRView) -> ScenarioStructure {
        let anchors = view.blocks.compactMap { block -> ScenarioStructure.Anchor? in
            guard block.confidence.isFinite, block.confidence >= 0.5,
                  validBox(block.bboxNormalized) else { return nil }
            let text = token(block.text)
            let field = definitions.first { $0.2.contains(text) }?.0 ?? camera(text)
            guard let field else { return nil }
            return .init(field: field, box: block.bboxNormalized)
        }
        let fields = anchors.filter { !$0.field.hasPrefix("camera:") }
        let bands = fields.map { anchor in
            let center = (anchor.box[1] + anchor.box[3]) / 2
            let tolerance = max(0.025, (anchor.box[3] - anchor.box[1]) * 1.5)
            let nearby = Set(fields.filter { abs(($0.box[1] + $0.box[3]) / 2 - center) <= tolerance }.map(\.field))
            return (center: center, tolerance: tolerance,
                    core: nearby.intersection(["scene", "shot", "take", "videoCode"]).count, fields: nearby.count)
        }
        guard let band = bands.max(by: { ($0.core, $0.fields, -$0.center) < ($1.core, $1.fields, -$1.center) }) else {
            return .init(anchors: [])
        }
        // Find a coherent printed-header band anywhere on the page. A fixed
        // top fraction confuses scan margins with identity and misses low tables.
        let headers = anchors.filter { abs(($0.box[1] + $0.box[3]) / 2 - band.center) <= band.tolerance * 2 }
        return .init(anchors: ordered(Array(Set(headers))))
    }

    public static func isSufficient(_ structure: ScenarioStructure) -> Bool {
        let fields = Set(structure.anchors.filter { !$0.field.hasPrefix("camera:") }.map(\.field))
        let core = fields.intersection(["scene", "shot", "take", "videoCode"])
        return structure.version == 2 && fields.count >= 3 && core.count >= 2
            && structure.anchors.allSatisfy { validBox($0.box) }
            && horizontalSpan(structure.anchors) > 0.1
    }

    public static func descriptor(_ data: ScenarioData) -> ScenarioStructure? {
        guard data.schemaVersion == 1, [1, 2].contains(data.fingerprintVersion) else { return nil }
        if let structure = data.structure { return structure.version == 2 ? structure : nil }
        // Older profiles retain header regions but not the original OCR blocks.
        // Overlapping legacy regions are not repaired by guessing a new column.
        let fields = fieldEntries(data.fields)
        let anchors = fields.compactMap { name, field -> ScenarioStructure.Anchor? in
            guard let box = field.region, validBox(box) else { return nil }
            return .init(field: name, box: box)
        }
        return .init(anchors: ordered(anchors))
    }

    public static func fingerprint(_ structure: ScenarioStructure) throws -> String {
        struct Identity: Encodable { let version: Int; let anchors: [Cell] }
        struct Cell: Encodable { let field: String; let x: Int; let y: Int }
        let positions = normalized(structure.anchors)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let bytes = try encoder.encode(Identity(version: 2, anchors: positions.map {
            .init(field: $0.field, x: Int(($0.box[0] * 50).rounded()), y: Int(($0.box[1] * 50).rounded()))
        }))
        return SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined().prefix(32).description
    }

    private static func compare(_ a: ScenarioStructure, _ b: ScenarioStructure, profileID: String) -> ScenarioMatchDiagnostic {
        let left = normalized(a.anchors), right = normalized(b.anchors)
        let leftFields = left.map(\.field), rightFields = right.map(\.field)
        let common = Set(leftFields).intersection(rightFields)
        let order = leftFields.filter(common.contains) == rightFields.filter(common.contains)
        let coverage = Double(common.count) / Double(max(1, Set(leftFields).union(rightFields).count))
        var distances: [Double] = []
        for field in common {
            let x = left.filter { $0.field == field }, y = right.filter { $0.field == field }
            guard x.count == y.count else { continue }
            distances += zip(x, y).map { abs($0.box[0] - $1.box[0]) + abs($0.box[1] - $1.box[1]) }
        }
        let geometry = distances.isEmpty ? 0 : max(0, 1 - distances.reduce(0, +) / Double(distances.count) * 2)
        let score = order ? coverage * (0.6 + 0.4 * geometry) : 0
        return .init(profileID: profileID, score: score, coverage: coverage, geometry: geometry, orderMatches: order)
    }

    private static func sameInterpretation(_ left: ScenarioData, _ right: ScenarioData) -> Bool {
        // Identical printed geometry cannot choose between conflicting saved
        // instructions. Such profiles require explicit selection or a merge.
        left.recognition.promptHints == right.recognition.promptHints && left.output == right.output
            && zip(fieldEntries(left.fields), fieldEntries(right.fields)).allSatisfy { a, b in
                a.1.inherit == b.1.inherit && a.1.required == b.1.required
            }
    }

    private static func profile(_ structure: ScenarioStructure, filename: String, resolve: ProjectSettings.ResolveSettings) throws -> ScenarioProfile {
        func field(_ index: Int) -> ScenarioFieldProfile {
            let definition = definitions[index]
            let boxes = structure.anchors.filter { $0.field == definition.0 }.map(\.box)
            let region = boxes.first.map { first in boxes.dropFirst().reduce(first) { a, b in
                [min(a[0], b[0]), min(a[1], b[1]), max(a[2], b[2]), max(a[3], b[3])]
            } }
            return .init(label: definition.1, aliases: definition.2, region: region,
                         inherit: ["scene", "shot"].contains(definition.0), required: ["scene", "shot", "take"].contains(definition.0))
        }
        let headers = structure.anchors.compactMap { anchor in definitions.first { $0.0 == anchor.field }?.1 }
        let cameras = structure.anchors.filter { $0.field.hasPrefix("camera:") }.map { String($0.field.dropFirst(7)) }
        return .init(schemaVersion: 1, fingerprintVersion: 2, fingerprint: try fingerprint(structure),
                     label: String(filename.trimmingCharacters(in: .whitespacesAndNewlines).prefix(120)),
                     layout: .init(pages: [], headerTokens: headers, cameraGroups: cameras,
                                   columnBands: [], rowBands: [], blockCount: structure.anchors.count),
                     fields: .init(cardNumber: field(0), videoCode: field(1), scene: field(2), shot: field(3), take: field(4),
                                   takeStatus: field(5), description: field(6), comments: field(7), shotSize: field(8), cameraPosition: field(9)),
                     recognition: .init(headerTokens: headers, promptHints: ["字段区域表示表头位置；按当前页面的列边界读取正文，不能从旧样本继承实际填写值。"]),
                     output: .init(resolve: resolve), structure: structure)
    }

    private static func normalized(_ anchors: [ScenarioStructure.Anchor]) -> [ScenarioStructure.Anchor] {
        guard let minX = anchors.map({ $0.box[0] }).min(), let minY = anchors.map({ $0.box[1] }).min() else { return [] }
        let span = max(0.001, horizontalSpan(anchors))
        // A common scale preserves header-row offsets; independently stretching
        // a nearly flat y axis would amplify tiny scan/OCR jitter.
        return ordered(anchors).map { .init(field: $0.field, box: [
            (($0.box[0] + $0.box[2]) / 2 - minX) / span,
            (($0.box[1] + $0.box[3]) / 2 - minY) / span, 0, 0]) }
    }
    private static func horizontalSpan(_ anchors: [ScenarioStructure.Anchor]) -> Double {
        (anchors.map { $0.box[2] }.max() ?? 0) - (anchors.map { $0.box[0] }.min() ?? 0)
    }
    private static func ordered(_ anchors: [ScenarioStructure.Anchor]) -> [ScenarioStructure.Anchor] {
        anchors.sorted { ($0.box[0], $0.box[1], $0.field) < ($1.box[0], $1.box[1], $1.field) }
    }
    private static func validBox(_ box: [Double]) -> Bool {
        box.count == 4 && box.allSatisfy(\.isFinite) && box[0] >= 0 && box[1] >= 0
            && box[2] <= 1 && box[3] <= 1 && box[2] > box[0] && box[3] > box[1]
    }
    private static func token(_ text: String) -> String {
        text.precomposedStringWithCompatibilityMapping.lowercased().filter { !$0.isWhitespace }
    }
    private static func camera(_ text: String) -> String? {
        for (index, letter) in ["a", "b", "c", "d"].enumerated() {
            if [letter + "机", letter + "cam", ["一", "二", "三", "四"][index] + "机"].contains(text) {
                return "camera:" + letter.uppercased()
            }
        }
        return nil
    }
    private static func fieldEntries(_ f: ScenarioFields) -> [(String, ScenarioFieldProfile)] {
        [("cardNumber", f.cardNumber), ("videoCode", f.videoCode), ("scene", f.scene), ("shot", f.shot),
         ("take", f.take), ("takeStatus", f.takeStatus), ("description", f.description), ("comments", f.comments),
         ("shotSize", f.shotSize), ("cameraPosition", f.cameraPosition)]
    }
}

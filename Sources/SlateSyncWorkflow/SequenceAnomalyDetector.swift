import Foundation
import SlateSyncDomain

/// Stage-neutral input for the sequence checks. Both recognition records and
/// Resolve records carry the same five decision fields, so the detector never
/// needs to know which stage produced the rows.
public struct SequenceAnomalyInput: Sendable {
    public let cardNumber: String?
    public let videoCode: String?
    public let scene: String?
    public let shot: String?
    public let take: String?
    public let reviewRequiredFields: [String]

    public init(
        cardNumber: String?,
        videoCode: String?,
        scene: String?,
        shot: String?,
        take: String?,
        reviewRequiredFields: [String] = []
    ) {
        self.cardNumber = cardNumber
        self.videoCode = videoCode
        self.scene = scene
        self.shot = shot
        self.take = take
        self.reviewRequiredFields = reviewRequiredFields
    }

    public init(_ record: ResolveSlateRecord) {
        self.init(
            cardNumber: record.cardNumber,
            videoCode: record.videoCode,
            scene: record.scene,
            shot: record.shot,
            take: record.take,
            reviewRequiredFields: record.reviewRequiredFields
        )
    }

    public init(_ record: RecognitionRecord) {
        self.init(
            cardNumber: record.cardNumber,
            videoCode: record.videoCode,
            scene: record.scene,
            shot: record.shot,
            take: record.take,
            reviewRequiredFields: record.reviewRequiredFields ?? []
        )
    }
}

/// The single sequence-anomaly authority shared by recognition
/// (`RecognitionPostprocessor`) and CSV export (`ResolveCSVMerger`), covering
/// clip gaps plus duplicate, jumped, regressed and non-one-first takes inside
/// a reel. Messages and ordering are frozen; consumers dedupe reports by the
/// stable `type:key` identity so one anomaly is never shown twice.
public enum SequenceAnomalyDetector {
    public typealias Input = SequenceAnomalyInput

    public static func detect(
        _ records: [SequenceAnomalyInput],
        excluding knownStableKeys: Set<String> = []
    ) throws -> [SlateSequenceAnomaly] {
        struct Entry {
            let input: SequenceAnomalyInput
            let index: Int
            let clip: Int
            let reel: String
        }
        let entries = records.enumerated().compactMap { index, input -> Entry? in
            guard let card = ResolveCSVNormalization.parseCardNumber(input.cardNumber ?? ""),
                  let clip = Int(ResolveCSVNormalization.normalizeClipNumber(input.videoCode ?? "").dropFirst()) else { return nil }
            return Entry(input: input, index: index, clip: clip, reel: "\(card.camera)\(card.reel)")
        }
        var result: [SlateSequenceAnomaly] = []
        let groups = Dictionary(grouping: entries, by: \.reel)
        var reelOrder: [String] = []
        var seenReels = Set<String>()
        for entry in entries where seenReels.insert(entry.reel).inserted { reelOrder.append(entry.reel) }
        for reel in reelOrder {
            guard let group = groups[reel] else { continue }
            let ordered = group.sorted { $0.clip == $1.clip ? $0.index < $1.index : $0.clip < $1.clip }
            for pairIndex in 1..<ordered.count {
                let previous = ordered[pairIndex - 1]
                let current = ordered[pairIndex]
                let key = ResolveCSVNormalization.canonicalMaterialKey(cardNumber: current.input.cardNumber, videoCode: current.input.videoCode)
                if current.clip > previous.clip + 1 {
                    let missingCount = current.clip - previous.clip - 1
                    var labels = (previous.clip + 1..<current.clip).prefix(5).map { "C\(String(format: "%03d", $0))" }
                    if missingCount > 5 { labels.append("等 \(missingCount) 条") }
                    result.append(SlateSequenceAnomaly(key: key, type: "clip-gap", message: "条号从 C\(String(format: "%03d", previous.clip)) 断档到 C\(String(format: "%03d", current.clip))，缺少 \(labels.joined(separator: "、"))，可能漏 \(missingCount) 条"))
                    continue
                }
                guard let previousScene = previous.input.scene, !previousScene.isEmpty,
                      let currentScene = current.input.scene, !currentScene.isEmpty, previousScene == currentScene,
                      let previousTake = Self.unsignedInteger(previous.input.take), let currentTake = Self.unsignedInteger(current.input.take),
                      let previousShot = Self.unsignedInteger(previous.input.shot), let currentShot = Self.unsignedInteger(current.input.shot),
                      Set(current.input.reviewRequiredFields).isDisjoint(with: ["scene", "shot", "take"]) else { continue }
                if previousShot == currentShot, currentTake == previousTake {
                    result.append(SlateSequenceAnomaly(key: key, type: "take-sequence", message: "与上一条同为 \(currentScene) \(current.input.shot ?? "") 镜 \(currentTake) 次，次序可能重复"))
                } else if previousShot == currentShot, currentTake > previousTake + 1 {
                    result.append(SlateSequenceAnomaly(key: key, type: "take-sequence", message: "\(currentScene) \(current.input.shot ?? "") 镜的次从 \(previousTake) 跳到 \(currentTake)，中间可能漏 \(currentTake - previousTake - 1) 条"))
                } else if previousShot == currentShot, currentTake < previousTake {
                    result.append(SlateSequenceAnomaly(key: key, type: "take-sequence", message: "\(currentScene) \(current.input.shot ?? "") 镜的次从 \(previousTake) 回落到 \(currentTake)"))
                } else if previousShot != currentShot, currentTake > 1 {
                    result.append(SlateSequenceAnomaly(key: key, type: "take-sequence", message: "进入 \(currentScene) \(current.input.shot ?? "") 镜的第一条次为 \(currentTake)，通常应从 1 开始"))
                }
            }
        }
        guard !knownStableKeys.isEmpty else { return result }
        return result.filter { !knownStableKeys.contains($0.stableKey) }
    }

    private static func unsignedInteger(_ value: String?) -> Int? {
        guard let value, !value.isEmpty, value.allSatisfy(\.isNumber) else { return nil }
        return Int(value)
    }
}

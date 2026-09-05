import Foundation
import SlateSyncDomain

public enum RecognitionPostprocessor {
    public struct HighAccuracyMerge: Sendable {
        public let result: RecognitionSheet
        public let conflicts: [Conflict]
        public let auditOnlyKeys: [String]
    }
    public struct Conflict: Sendable {
        public let key: String
        public let fields: [String]
        public let primary: RecognitionRecord
        public let audit: RecognitionRecord
    }

    public static func mergePages(
        _ pages: [(pageNumber: Int, sheet: RecognitionSheet)],
        accuracy: ProjectSettings.AccuracyMode,
        formats: ResolveFieldFormats
    ) -> RecognitionSheet {
        var records: [RecognitionRecord] = []
        var warnings: [String] = []
        var title: String?
        for page in pages.sorted(by: { $0.pageNumber < $1.pageNumber }) {
            if title == nil { title = page.sheet.sheetTitle }
            if page.sheet.records.isEmpty { warnings.append("第 \(page.pageNumber) 页未识别到任何视频码。") }
            for (index, source) in page.sheet.records.enumerated() {
                records.append(copy(source, id: "record-page-\(page.pageNumber)-\(index)", sourcePage: page.pageNumber))
            }
            warnings += page.sheet.warnings.map { "第 \(page.pageNumber) 页：\($0)" }
        }
        inherit(&records, warnings: &warnings)
        repair(&records, warnings: &warnings)
        validate(records, accuracy: accuracy, warnings: &warnings)
        return RecognitionNormalizer.format(.init(sheetTitle: title, records: records, warnings: warnings), formats: formats)
    }

    public static func mergeHighAccuracy(_ primary: RecognitionSheet, _ audit: RecognitionSheet) -> HighAccuracyMerge {
        var records: [RecognitionRecord] = []
        var byKey: [String: Int] = [:]
        var warnings = primary.warnings.map { "主识别：\($0)" } + audit.warnings.map { "核心查漏：\($0)" }
        for record in primary.records {
            guard let key = RecognitionNormalizer.materialKey(record) else {
                records.append(record); warnings.append("主识别返回了一条缺少有效卷号或视频码的记录，请人工核对。"); continue
            }
            guard byKey[key] == nil else { warnings.append("主识别重复返回 \(key)，已保留第一条。"); continue }
            byKey[key] = records.count; records.append(record)
        }
        var conflicts: [Conflict] = [], auditOnly: [String] = []
        for auditRecord in audit.records {
            guard let key = RecognitionNormalizer.materialKey(auditRecord) else {
                warnings.append("核心查漏返回了一条缺少有效卷号或视频码的记录，未自动合并。"); continue
            }
            guard let index = byKey[key] else {
                let candidate = lower(auditRecord)
                byKey[key] = records.count; records.append(candidate); auditOnly.append(key)
                warnings.append("\(key) 仅由核心查漏识别到，已暂列查漏候选并等待最终定向确认。")
                continue
            }
            var primaryRecord = records[index], fields: [String] = []
            for field in ["scene", "shot", "take", "takeStatus"] {
                let left = core(primaryRecord, field), right = core(auditRecord, field)
                if left == nil, right != nil { primaryRecord = setting(primaryRecord, field, value: right); primaryRecord = lower(primaryRecord) }
                else if left != nil, right != nil, left != right { fields.append(field) }
            }
            records[index] = primaryRecord
            if !fields.isEmpty { conflicts.append(.init(key: key, fields: fields, primary: primaryRecord, audit: auditRecord)) }
        }
        records.sort { (RecognitionNormalizer.materialKey($0) ?? "~") < (RecognitionNormalizer.materialKey($1) ?? "~") }
        return .init(result: .init(sheetTitle: primary.sheetTitle ?? audit.sheetTitle, records: records, warnings: warnings), conflicts: conflicts, auditOnlyKeys: auditOnly)
    }

    public static func applyReview(_ merge: HighAccuracyMerge, review: RecognitionSheet) -> RecognitionSheet {
        var records = merge.result.records
        var warnings = merge.result.warnings + review.warnings.map { "冲突复核：\($0)" }
        let reviewed = Dictionary(uniqueKeysWithValues: review.records.compactMap { record in RecognitionNormalizer.materialKey(record).map { ($0, record) } })
        for conflict in merge.conflicts {
            guard let index = records.firstIndex(where: { RecognitionNormalizer.materialKey($0) == conflict.key }) else { continue }
            var record = records[index], unresolved: [String] = []
            for field in conflict.fields {
                if let value = reviewed[conflict.key].flatMap({ core($0, field) }) { record = setting(record, field, value: value) }
                else { record = setting(record, field, value: nil); unresolved.append(field) }
            }
            record = lower(record, fields: unresolved)
            records[index] = record
            warnings.append(unresolved.isEmpty ? "\(conflict.key) 的识别冲突已采用第三次定向复核结果。" : "\(conflict.key) 的冲突字段最终仍无法确认，已留空，请人工核对。")
        }
        for key in merge.auditOnlyKeys {
            guard let index = records.firstIndex(where: { RecognitionNormalizer.materialKey($0) == key }) else { continue }
            guard let checked = reviewed[key] else { records.remove(at: index); warnings.append("\(key) 仅在核心查漏中出现，但最终定向复核未确认，已从结果移除。"); continue }
            var record = records[index]
            for field in ["scene", "shot", "take", "takeStatus"] { if let value = core(checked, field) { record = setting(record, field, value: value) } }
            records[index] = lower(record)
            warnings.append("\(key) 已由最终定向复核确认存在，保留为查漏补回记录，请人工复核场/镜/次。")
        }
        return .init(sheetTitle: merge.result.sheetTitle, records: records, warnings: warnings)
    }

    private static func inherit(_ records: inout [RecognitionRecord], warnings: inout [String]) {
        let order = records.indices.sorted {
            let left = records[$0], right = records[$1]
            if (left.sourcePage ?? 0) != (right.sourcePage ?? 0) { return (left.sourcePage ?? 0) < (right.sourcePage ?? 0) }
            let lc = left.cardNumber ?? "~", rc = right.cardNumber ?? "~"
            if lc != rc { return lc < rc }
            return (RecognitionNormalizer.videoOrdinal(left.videoCode) ?? .max) < (RecognitionNormalizer.videoOrdinal(right.videoCode) ?? .max)
        }
        var last: [String: (String?, String?)] = [:]
        for index in order {
            guard let reel = RecognitionNormalizer.normalizeCard(records[index].cardNumber) else { continue }
            let old = records[index], previous = last[reel], reviewed = Set(old.reviewRequiredFields ?? [])
            let scene = old.scene ?? (reviewed.contains("scene") ? nil : previous?.0)
            let shot = old.shot ?? (reviewed.contains("shot") || (old.scene != nil && old.scene != previous?.0) ? nil : previous?.1)
            let inherited = [old.scene == nil && scene != nil ? "场次" : nil, old.shot == nil && shot != nil ? "镜" : nil].compactMap { $0 }
            records[index] = copy(old, scene: scene, shot: shot)
            if !inherited.isEmpty { warnings.append("第 \(old.sourcePage ?? 0) 页 \(reel) \(old.videoCode ?? "未知条号") 的\(inherited.joined(separator: "、"))已按同卷条号顺序的上一条记录继承。") }
            last[reel] = (scene, shot)
        }
    }

    private static func repair(_ records: inout [RecognitionRecord], warnings: inout [String]) {
        var groups: [String: [Int]] = [:]
        for index in records.indices { if let reel = RecognitionNormalizer.normalizeCard(records[index].cardNumber), RecognitionNormalizer.videoOrdinal(records[index].videoCode) != nil { groups[reel, default: []].append(index) } }
        for (reel, indexes) in groups {
            let sorted = indexes.sorted { RecognitionNormalizer.videoOrdinal(records[$0].videoCode)! < RecognitionNormalizer.videoOrdinal(records[$1].videoCode)! }
            if sorted.count >= 3 {
                for position in 1..<(sorted.count - 1) {
                    let a = records[sorted[position - 1]], b = records[sorted[position]], c = records[sorted[position + 1]]
                    guard RecognitionNormalizer.videoOrdinal(b.videoCode) == RecognitionNormalizer.videoOrdinal(a.videoCode)! + 1,
                          RecognitionNormalizer.videoOrdinal(c.videoCode) == RecognitionNormalizer.videoOrdinal(b.videoCode)! + 1,
                          a.scene != nil, a.scene == b.scene, b.scene == c.scene, a.shot != nil, a.shot == c.shot,
                          let firstTake = Int(a.take ?? ""), Int(c.take ?? "") == firstTake + 2,
                          !(b.reviewRequiredFields ?? []).contains(where: { ["shot", "take"].contains($0) }) else { continue }
                    let expected = String(format: "%02d", firstTake + 1)
                    if b.shot != a.shot || b.take != expected {
                        let oldValue = "\(b.shot ?? "空")/\(b.take ?? "空")"
                        records[sorted[position]] = lower(copy(b, scene: b.scene, shot: a.shot, take: expected), fields: ["shot", "take"])
                        warnings.append("第 \(b.sourcePage ?? 0) 页 \(reel) \(b.videoCode ?? "未知条号") 位于连续条号与同镜次序之间，已将镜/次从 \(oldValue) 校正为 \(a.shot!)/\(expected)，请人工复核。")
                    }
                }
            }
            repairDroppedShotTens(&records, indexes: sorted, reel: reel, warnings: &warnings)
        }
    }

    /// Repairs a stable multi-row run such as shot 17 followed by 08/01,
    /// 08/02. Requiring two rows prevents a lone ambiguous digit from being
    /// promoted into an unverified two-digit shot number.
    private static func repairDroppedShotTens(_ records: inout [RecognitionRecord], indexes: [Int], reel: String, warnings: inout [String]) {
        var position = 1
        while position < indexes.count {
            let previous = records[indexes[position - 1]], current = records[indexes[position]]
            guard RecognitionNormalizer.videoOrdinal(current.videoCode) == RecognitionNormalizer.videoOrdinal(previous.videoCode)! + 1,
                  current.scene != nil, current.scene == previous.scene,
                  Int(current.take ?? "") == 1,
                  !(current.reviewRequiredFields ?? []).contains(where: { ["shot", "take"].contains($0) }),
                  let previousShot = Int(previous.shot ?? ""), let currentShot = Int(current.shot ?? "") else {
                position += 1; continue
            }
            let expectedShot = previousShot + 1
            guard currentShot < 10, (10..<100).contains(expectedShot), expectedShot % 10 == currentShot else {
                position += 1; continue
            }
            var run = [position], expectedTake = 2, cursor = position + 1
            while cursor < indexes.count {
                let candidate = records[indexes[cursor]], preceding = records[indexes[cursor - 1]]
                guard RecognitionNormalizer.videoOrdinal(candidate.videoCode) == RecognitionNormalizer.videoOrdinal(preceding.videoCode)! + 1,
                      candidate.scene == current.scene,
                      !(candidate.reviewRequiredFields ?? []).contains(where: { ["shot", "take"].contains($0) }),
                      Int(candidate.shot ?? "") == currentShot, Int(candidate.take ?? "") == expectedTake else { break }
                run.append(cursor); expectedTake += 1; cursor += 1
            }
            guard run.count >= 2 else { position += 1; continue }
            let corrected = String(format: "%02d", expectedShot), recognized = current.shot ?? "空"
            for runPosition in run {
                let index = indexes[runPosition]
                records[index] = lower(copy(records[index], shot: corrected), fields: ["shot"])
            }
            let first = records[indexes[run[0]]], last = records[indexes[run[run.count - 1]]]
            warnings.append("第 \(current.sourcePage ?? 0) 页 \(reel) \(first.videoCode ?? "未知条号")–\(last.videoCode ?? "未知条号") 的镜号连续从 \(previous.shot ?? "空") 进入下一组，已将疑似漏写十位的 \(recognized) 校正为 \(corrected)，请人工复核。")
            position += run.count
        }
    }

    private static func validate(_ records: [RecognitionRecord], accuracy: ProjectSettings.AccuracyMode, warnings: inout [String]) {
        var anomalies = 0
        let grouped = Dictionary(grouping: records) { RecognitionNormalizer.normalizeCard($0.cardNumber) ?? "" }
        for (reel, values) in grouped where !reel.isEmpty {
            let clips = values.compactMap { RecognitionNormalizer.videoOrdinal($0.videoCode) }.sorted()
            for pair in zip(clips, clips.dropFirst()) where pair.1 > pair.0 + 1 { warnings.append("\(reel) 条号 C\(String(format: "%03d", pair.0)) 到 C\(String(format: "%03d", pair.1)) 之间存在缺口，请人工核对。"); anomalies += 1 }
        }
        if anomalies > 0 && accuracy != .high { warnings.append("快速模式仅执行单次识别，以上 \(anomalies) 条序列异常未经过双重校验，建议使用精确模式重新识别。") }
    }

    private static func core(_ record: RecognitionRecord, _ field: String) -> String? {
        switch field { case "scene": return record.scene; case "shot": return record.shot; case "take": return record.take; case "takeStatus": return record.takeStatus?.rawValue; default: return nil }
    }
    private static func setting(_ record: RecognitionRecord, _ field: String, value: String?) -> RecognitionRecord {
        copy(record, scene: field == "scene" ? value : record.scene, shot: field == "shot" ? value : record.shot, take: field == "take" ? value : record.take, status: field == "takeStatus" ? LegacyTakeStatusAdapter.status(from: value) : record.takeStatus)
    }
    private static func lower(_ record: RecognitionRecord, fields: [String] = []) -> RecognitionRecord {
        let required = Array(Set((record.reviewRequiredFields ?? []) + fields)).sorted()
        return copy(record, confidence: record.confidence == .high ? .medium : record.confidence, reviewRequired: required.isEmpty ? nil : required)
    }
    private static func copy(_ r: RecognitionRecord, id: String? = nil, sourcePage: Int? = nil, scene: String?? = nil, shot: String?? = nil, take: String?? = nil, status: TakeStatus?? = nil, confidence: RecognitionConfidence? = nil, reviewRequired: [String]?? = nil) -> RecognitionRecord {
        .init(id: id ?? r.id, sourcePage: sourcePage ?? r.sourcePage, cardNumber: r.cardNumber, videoCode: r.videoCode,
              scene: scene ?? r.scene, shot: shot ?? r.shot, take: take ?? r.take, takeStatus: status ?? r.takeStatus,
              description: r.description, comments: r.comments, shotSize: r.shotSize, cameraPosition: r.cameraPosition,
              confidence: confidence ?? r.confidence, reviewRequiredFields: reviewRequired ?? r.reviewRequiredFields)
    }
}

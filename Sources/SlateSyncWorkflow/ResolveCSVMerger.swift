import Foundation
import SlateSyncDomain

/// Indexed Resolve merge service. All mutation is confined to local value
/// copies so cancellation or validation failure cannot publish a partial table.
public actor ResolveCSVMerger {
    private struct MetadataValue {
        var sensorFPS = ""
        var shootDay = ""
    }

    private struct Candidate {
        let recordIndex: Int
        let key: String
        let fileName: String
        let scene: String
        let shot: String
        let take: String
        let comments: String
        let signature: String
    }

    public init() {}

    public func merge(
        source: ResolveCSVTable,
        records: [ResolveSlateRecord],
        metadata: [PersistedSlateMetadata] = [],
        fieldFormats: ResolveFieldFormats = .init(),
        comments: ResolveComments = .init(),
        edits: [ResolveSparseEdit] = []
    ) throws -> ResolveMergeResult {
        try fieldFormats.validate()
        try comments.validate()
        var headers = source.headers
        guard !headers.isEmpty else { throw SlateSyncError(code: "CSV_EMPTY", message: "尚未载入有效的 Resolve CSV") }
        var rows = source.rows.map { Self.normalizedRow($0, width: headers.count) }
        var columns = try ResolveHeaders.resolve(headers)
        guard ResolveHeaders.hasIdentifier(columns) else { throw SlateSyncError(code: "CSV_COLUMNS", message: "CSV 缺少素材标识列") }
        var warnings: [String] = []
        var addedColumns: [String] = []
        // Electron emits sidecar conflicts before missing-column and row-identity
        // warnings because it builds this index before resolving target columns.
        let metadataIndex = Self.buildMetadataIndex(metadata, warnings: &warnings)

        let required: [(WritableKeyPath<ResolveColumnIndexes, Int>, String)] = metadata.isEmpty
            ? [(\.shot, "Shot"), (\.scene, "Scene"), (\.take, "Take"), (\.comments, "Comments")]
            : [(\.shot, "Shot"), (\.scene, "Scene"), (\.take, "Take"), (\.comments, "Comments"), (\.cameraFPS, "Camera FPS"), (\.shootDay, "Shoot Day")]
        for (path, header) in required where columns[keyPath: path] < 0 {
            headers.append(header)
            rows.indices.forEach { rows[$0].append("") }
            addedColumns.append(header)
            warnings.append("原 CSV 缺少 \(header) 列，已按 Resolve 字段名添加。")
            columns = try ResolveHeaders.resolve(headers)
        }

        let rowIndex = Self.buildRowIndex(rows, columns: columns, warnings: &warnings)
        var rowKeys = Array(repeating: "", count: rows.count)
        for (key, numbers) in rowIndex { for number in numbers { rowKeys[number] = key } }
        var recognizedKeys = Set<String>()
        var recognizedKeyOrder: [String] = []
        for record in records {
            let key = ResolveCSVNormalization.canonicalMaterialKey(cardNumber: record.cardNumber, videoCode: record.videoCode)
            if !key.isEmpty, recognizedKeys.insert(key).inserted { recognizedKeyOrder.append(key) }
        }
        var changes: [ResolveCSVChange] = []
        var updatedRows = Set<Int>()
        var fpsRows = Set<Int>()
        var dayRows = Set<Int>()
        var fpsMaterials = 0
        var dayMaterials = 0
        var missingFPSKeys = Set<String>()
        var missingDayKeys = Set<String>()

        // Sidecar fields depend only on material identity and remain independent
        // from incomplete/conflicting Scene, Shot and Take recognition.
        for key in recognizedKeyOrder {
            try Task.checkCancellation()
            guard let matchedRows = rowIndex[key], !matchedRows.isEmpty else { continue }
            let sidecar = metadataIndex[key]
            if let sidecar, !sidecar.sensorFPS.isEmpty {
                fpsMaterials += 1
                for rowNumber in matchedRows {
                    fpsRows.insert(rowNumber)
                    let previous = ResolveCSVNormalization.clean(rows[rowNumber][columns.cameraFPS])
                    Self.write(sidecar.sensorFPS, field: "cameraFps", column: columns.cameraFPS, row: rowNumber, headers: headers, rows: &rows, changes: &changes, updatedRows: &updatedRows)
                    if !previous.isEmpty, previous != sidecar.sensorFPS {
                        let fileName = Self.rowDisplayName(rows[rowNumber], columns: columns)
                        warnings.append("CSV 第 \(rowNumber + 2) 行 \(fileName.isEmpty ? ResolveCSVNormalization.canonicalKeyToMaterialPrefix(key) : fileName) 已覆盖：\(headers[columns.cameraFPS])“\(previous)”→“\(sidecar.sensorFPS)”。")
                    }
                }
            } else if !metadata.isEmpty { missingFPSKeys.insert(key) }
            if let sidecar, !sidecar.shootDay.isEmpty {
                dayMaterials += 1
                for rowNumber in matchedRows {
                    dayRows.insert(rowNumber)
                    let previous = ResolveCSVNormalization.clean(rows[rowNumber][columns.shootDay])
                    Self.write(sidecar.shootDay, field: "shootDay", column: columns.shootDay, row: rowNumber, headers: headers, rows: &rows, changes: &changes, updatedRows: &updatedRows)
                    if !previous.isEmpty, previous != sidecar.shootDay {
                        let fileName = Self.rowDisplayName(rows[rowNumber], columns: columns)
                        warnings.append("CSV 第 \(rowNumber + 2) 行 \(fileName.isEmpty ? ResolveCSVNormalization.canonicalKeyToMaterialPrefix(key) : fileName) 已覆盖：\(headers[columns.shootDay])“\(previous)”→“\(sidecar.shootDay)”。")
                    }
                }
            } else if !metadata.isEmpty { missingDayKeys.insert(key) }
        }

        let unrecognizedKeys = rowIndex.keys.filter { !recognizedKeys.contains($0) }.sorted(by: ResolveCSVNormalization.compareMaterialKeys)
        let unrecognizedMaterials = unrecognizedKeys.map(ResolveCSVNormalization.canonicalKeyToMaterialPrefix)
        let unrecognizedRows = unrecognizedKeys.flatMap { rowIndex[$0] ?? [] }
        if !unrecognizedMaterials.isEmpty {
            warnings.append("完整性对账：Resolve CSV 中有 \(unrecognizedMaterials.count) 个素材未在场记识别结果中出现（\(ResolveCSVNormalization.compactMaterialRanges(unrecognizedKeys))）。这些行不会自动回填，请检查是否漏页或漏识别。")
        }
        var statuses = Array<ResolveRecordStatus?>(repeating: nil, count: records.count)
        var candidates: [Candidate] = []

        for (index, record) in records.enumerated() {
            if index.isMultiple(of: 256) { try Task.checkCancellation() }
            let key = ResolveCSVNormalization.canonicalMaterialKey(cardNumber: record.cardNumber, videoCode: record.videoCode)
            guard !key.isEmpty, let fileName = ResolveCSVNormalization.materialPrefix(cardNumber: record.cardNumber, videoCode: record.videoCode) else {
                statuses[index] = ResolveRecordStatus(recordIndex: index, status: "missing-key")
                warnings.append("第 \(index + 1) 条缺少卷号，或视频码不是 C0XX 格式，不会写入 CSV。")
                continue
            }
            let scene = ResolveCSVNormalization.normalizeScene(record.scene, format: fieldFormats.scene)
            let shot = ResolveCSVNormalization.normalizeShot(record.shot, format: fieldFormats.shot)
            let take = ResolveCSVNormalization.normalizeTake(record.take, format: fieldFormats.take)
            let missing = [(scene, "场次"), (shot, "镜"), (take, "次")].filter { $0.0.isEmpty }.map(\.1)
            guard missing.isEmpty else {
                statuses[index] = ResolveRecordStatus(recordIndex: index, status: "incomplete", fileName: fileName, missingFields: missing)
                warnings.append("第 \(index + 1) 条 \(fileName) 缺少\(missing.joined(separator: "、"))，Scene、Shot、Take 和 Comments 不会写入；有效的 Camera FPS 和 Shoot Day 仍会独立回填。")
                continue
            }
            let comment = ResolveCSVNormalization.comment(for: record.takeStatus, legacyGoodTake: record.goodTake, comments: comments)
            let status = record.takeStatus?.rawValue ?? (record.goodTake == true ? TakeStatus.passed.rawValue : record.goodTake == false ? TakeStatus.hold.rawValue : "")
            candidates.append(Candidate(recordIndex: index, key: key, fileName: fileName, scene: scene, shot: shot, take: take, comments: comment, signature: [scene, shot, take, status].joined(separator: "\0")))
        }

        let groups = Dictionary(grouping: candidates, by: \.key)
        var groupOrder: [String] = []
        var seenGroupKeys = Set<String>()
        for candidate in candidates where seenGroupKeys.insert(candidate.key).inserted { groupOrder.append(candidate.key) }
        var matchedRecordCount = 0
        for key in groupOrder {
            try Task.checkCancellation()
            guard let group = groups[key], let primary = group.first else { continue }
            guard Set(group.map(\.signature)).count == 1 else {
                for candidate in group { statuses[candidate.recordIndex] = ResolveRecordStatus(recordIndex: candidate.recordIndex, status: "conflict", fileName: candidate.fileName) }
                warnings.append("\(primary.fileName) 在识别结果中出现了互相冲突的场、镜、次或条次状态，这些场记字段已停止写入，请人工校对；有效的 Camera FPS 和 Shoot Day 仍会独立回填。")
                continue
            }
            for duplicate in group.dropFirst() { statuses[duplicate.recordIndex] = ResolveRecordStatus(recordIndex: duplicate.recordIndex, status: "duplicate", fileName: duplicate.fileName) }
            guard let matchedRows = rowIndex[key], !matchedRows.isEmpty else {
                statuses[primary.recordIndex] = ResolveRecordStatus(recordIndex: primary.recordIndex, status: "unmatched", fileName: primary.fileName)
                warnings.append("\(primary.fileName) 未在 Resolve CSV 的卷名或文件名中找到，不会新增虚构素材行。")
                continue
            }
            var fileNames: [String] = []
            for rowNumber in matchedRows {
                let changeStart = changes.count
                Self.write(primary.scene, field: "scene", column: columns.scene, row: rowNumber, headers: headers, rows: &rows, changes: &changes, updatedRows: &updatedRows)
                Self.write(primary.shot, field: "shot", column: columns.shot, row: rowNumber, headers: headers, rows: &rows, changes: &changes, updatedRows: &updatedRows)
                Self.write(primary.take, field: "take", column: columns.take, row: rowNumber, headers: headers, rows: &rows, changes: &changes, updatedRows: &updatedRows)
                Self.write(primary.comments, field: "comments", column: columns.comments, row: rowNumber, headers: headers, rows: &rows, changes: &changes, updatedRows: &updatedRows)
                let displayName = Self.rowDisplayName(rows[rowNumber], columns: columns)
                fileNames.append(displayName.isEmpty ? primary.fileName : displayName)
                let overwritten = changes[changeStart...].filter { !$0.previous.isEmpty }
                if !overwritten.isEmpty {
                    warnings.append("CSV 第 \(rowNumber + 2) 行 \(displayName.isEmpty ? primary.fileName : displayName) 已覆盖：\(overwritten.map { "\($0.header)“\($0.previous)”→“\($0.next)”" }.joined(separator: "，"))。")
                }
                updatedRows.insert(rowNumber)
            }
            matchedRecordCount += 1
            statuses[primary.recordIndex] = ResolveRecordStatus(recordIndex: primary.recordIndex, status: "matched", fileName: fileNames.first ?? primary.fileName, fileNames: fileNames, rowIndexes: matchedRows, matchedRows: matchedRows.count)
        }

        let orderedMissingFPS = missingFPSKeys.sorted(by: ResolveCSVNormalization.compareMaterialKeys)
        let orderedMissingDay = missingDayKeys.sorted(by: ResolveCSVNormalization.compareMaterialKeys)
        if !orderedMissingFPS.isEmpty {
            warnings.append("Sensor FPS 对账：\(orderedMissingFPS.count) 个已识别且匹配 CSV 的素材没有可用 slate.txt（\(ResolveCSVNormalization.compactMaterialRanges(orderedMissingFPS))），其 Camera FPS 保持原值。")
        }
        if !orderedMissingDay.isEmpty {
            warnings.append("Shoot Day 对账：\(orderedMissingDay.count) 个已识别且匹配 CSV 的素材没有可用 Shot Date（\(ResolveCSVNormalization.compactMaterialRanges(orderedMissingDay))），其 Shoot Day 保持原值。")
        }

        // Electron performs fixed-width fields across the whole table first,
        // then Comments in a second pass; preserve that changes/warning order.
        for rowNumber in rows.indices {
            if rowNumber.isMultiple(of: 512) { try Task.checkCancellation() }
            let targets = [
                ("scene", columns.scene, ResolveCSVNormalization.normalizeScene(rows[rowNumber][columns.scene], format: fieldFormats.scene)),
                ("shot", columns.shot, ResolveCSVNormalization.normalizeShot(rows[rowNumber][columns.shot], format: fieldFormats.shot)),
                ("take", columns.take, ResolveCSVNormalization.normalizeTake(rows[rowNumber][columns.take], format: fieldFormats.take)),
            ]
            for (field, column, value) in targets {
                let previous = ResolveCSVNormalization.clean(rows[rowNumber][column])
                Self.write(value, field: field, column: column, row: rowNumber, headers: headers, rows: &rows, changes: &changes, updatedRows: &updatedRows)
                if previous != value {
                    let fileName = Self.rowDisplayName(rows[rowNumber], columns: columns)
                    warnings.append("CSV 第 \(rowNumber + 2) 行 \(fileName.isEmpty ? "未知素材" : fileName) 的 \(headers[column])“\(previous)”已规范为“\(value)”。")
                }
            }
        }

        for rowNumber in rows.indices {
            if rowNumber.isMultiple(of: 512) { try Task.checkCancellation() }
            let previous = ResolveCSVNormalization.clean(rows[rowNumber][columns.comments])
            let value = ResolveCSVNormalization.canonicalComment(rows[rowNumber][columns.comments], comments: comments)
            Self.write(value, field: "comments", column: columns.comments, row: rowNumber, headers: headers, rows: &rows, changes: &changes, updatedRows: &updatedRows)
            if previous != value {
                let fileName = Self.rowDisplayName(rows[rowNumber], columns: columns)
                warnings.append("CSV 第 \(rowNumber + 2) 行 \(fileName.isEmpty ? "未知素材" : fileName) 的 Comments“\(previous)”已规范为“\(value)”。")
            }
        }

        // Preserve request order exactly; a Dictionary here would reintroduce
        // process-randomized audit ordering for multiple manual edits.
        for edit in edits {
            guard rows.indices.contains(edit.rowIndex), headers.indices.contains(edit.columnIndex) else { continue }
            Self.applySparseEdit(edit.value, column: edit.columnIndex, row: edit.rowIndex, headers: headers, rows: &rows, changes: &changes, updatedRows: &updatedRows)
        }

        return ResolveMergeResult(
            table: ResolveCSVTable(headers: headers, rows: rows, format: source.format),
            statuses: statuses,
            warnings: warnings,
            addedColumns: addedColumns,
            matchedRecordCount: matchedRecordCount,
            cameraFpsMatchedMaterialCount: fpsMaterials,
            cameraFpsMatchedRowCount: fpsRows.count,
            shootDayMatchedMaterialCount: dayMaterials,
            shootDayMatchedRowCount: dayRows.count,
            updatedRowCount: updatedRows.count,
            changes: changes,
            expectedMaterialCount: rowIndex.count,
            recognizedMaterialCount: rowIndex.count - unrecognizedKeys.count,
            unrecognizedMaterials: unrecognizedMaterials,
            unrecognizedRowIndexes: unrecognizedRows,
            rowKeys: rowKeys,
            missingCameraFPSKeys: orderedMissingFPS,
            missingShootDayKeys: orderedMissingDay,
            sequenceAnomalies: try sequenceAnomalies(records)
        )
    }

    public func standaloneTable(records: [ResolveSlateRecord], fieldFormats: ResolveFieldFormats = .init()) throws -> ResolveCSVTable {
        try fieldFormats.validate()
        var rows: [[String]] = []
        for (index, record) in records.enumerated() {
            if index.isMultiple(of: 512) { try Task.checkCancellation() }
            let scene = ResolveCSVNormalization.normalizeScene(record.scene, format: fieldFormats.scene)
            let shot = ResolveCSVNormalization.normalizeShot(record.shot, format: fieldFormats.shot)
            let take = ResolveCSVNormalization.normalizeTake(record.take, format: fieldFormats.take)
            guard !scene.isEmpty, !shot.isEmpty, !take.isEmpty else { continue }
            rows.append([scene, shot, take, record.comments ?? ""])
        }
        return ResolveCSVTable(
            headers: ["Scene", "Shot", "Take", "Comments"],
            rows: rows,
            format: ResolveCSVFormat(encoding: .utf16LittleEndian, bom: true, delimiter: ",", lineEnding: "\r\n", finalNewline: true)
        )
    }

    public func collectMaterialKeys(_ table: ResolveCSVTable) throws -> (keys: [String], warnings: [String]) {
        let columns = try ResolveHeaders.resolve(table.headers)
        var warnings: [String] = []
        let index = Self.buildRowIndex(table.rows.map { Self.normalizedRow($0, width: table.headers.count) }, columns: columns, warnings: &warnings)
        return (index.keys.sorted(by: ResolveCSVNormalization.compareMaterialKeys), warnings)
    }

    public func sequenceAnomalies(_ records: [ResolveSlateRecord]) throws -> [SlateSequenceAnomaly] {
        struct Entry { let record: ResolveSlateRecord; let index: Int; let clip: Int; let reel: String }
        let entries = records.enumerated().compactMap { index, record -> Entry? in
            guard let card = ResolveCSVNormalization.parseCardNumber(record.cardNumber),
                  let clip = Int(ResolveCSVNormalization.normalizeClipNumber(record.videoCode).dropFirst()) else { return nil }
            return Entry(record: record, index: index, clip: clip, reel: "\(card.camera)\(card.reel)")
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
                let key = ResolveCSVNormalization.canonicalMaterialKey(cardNumber: current.record.cardNumber, videoCode: current.record.videoCode)
                if current.clip > previous.clip + 1 {
                    let missingCount = current.clip - previous.clip - 1
                    var labels = (previous.clip + 1..<current.clip).prefix(5).map { "C\(String(format: "%03d", $0))" }
                    if missingCount > 5 { labels.append("等 \(missingCount) 条") }
                    result.append(SlateSequenceAnomaly(key: key, type: "clip-gap", message: "条号从 C\(String(format: "%03d", previous.clip)) 断档到 C\(String(format: "%03d", current.clip))，缺少 \(labels.joined(separator: "、"))，可能漏 \(missingCount) 条"))
                    continue
                }
                guard let previousScene = previous.record.scene, !previousScene.isEmpty,
                      let currentScene = current.record.scene, !currentScene.isEmpty, previousScene == currentScene,
                      let previousTake = Self.unsignedInteger(previous.record.take), let currentTake = Self.unsignedInteger(current.record.take),
                      let previousShot = Self.unsignedInteger(previous.record.shot), let currentShot = Self.unsignedInteger(current.record.shot),
                      Set(current.record.reviewRequiredFields).isDisjoint(with: ["scene", "shot", "take"]) else { continue }
                if previousShot == currentShot, currentTake == previousTake {
                    result.append(SlateSequenceAnomaly(key: key, type: "take-sequence", message: "与上一条同为 \(currentScene) \(current.record.shot ?? "") 镜 \(currentTake) 次，次序可能重复"))
                } else if previousShot == currentShot, currentTake > previousTake + 1 {
                    result.append(SlateSequenceAnomaly(key: key, type: "take-sequence", message: "\(currentScene) \(current.record.shot ?? "") 镜的次从 \(previousTake) 跳到 \(currentTake)，中间可能漏 \(currentTake - previousTake - 1) 条"))
                } else if previousShot == currentShot, currentTake < previousTake {
                    result.append(SlateSequenceAnomaly(key: key, type: "take-sequence", message: "\(currentScene) \(current.record.shot ?? "") 镜的次从 \(previousTake) 回落到 \(currentTake)"))
                } else if previousShot != currentShot, currentTake > 1 {
                    result.append(SlateSequenceAnomaly(key: key, type: "take-sequence", message: "进入 \(currentScene) \(current.record.shot ?? "") 镜的第一条次为 \(currentTake)，通常应从 1 开始"))
                }
            }
        }
        return result
    }

    private static func buildMetadataIndex(_ entries: [PersistedSlateMetadata], warnings: inout [String]) -> [String: MetadataValue] {
        var result: [String: MetadataValue] = [:]
        let valid = entries.filter { !$0.materialKey.isEmpty }
        let groups = Dictionary(grouping: valid, by: \.materialKey)
        var keyOrder: [String] = []
        var seenKeys = Set<String>()
        for entry in valid where seenKeys.insert(entry.materialKey).inserted { keyOrder.append(entry.materialKey) }
        for key in keyOrder {
            guard let group = groups[key] else { continue }
            let fps = Set(group.map { ResolveCSVNormalization.normalizeCameraFPS($0.sensorFps) }.filter { !$0.isEmpty })
            let days = Set(group.map { ResolveCSVNormalization.normalizeShootDay($0.shootDay) }.filter { !$0.isEmpty })
            if fps.count > 1 { warnings.append("\(ResolveCSVNormalization.canonicalKeyToMaterialPrefix(key)) 的 slate.txt 存在互相冲突或无效的 Sensor FPS，Camera FPS 不会写入。") }
            if days.count > 1 { warnings.append("\(ResolveCSVNormalization.canonicalKeyToMaterialPrefix(key)) 的 slate.txt 存在互相冲突的 Shot Date，Shoot Day 不会写入。") }
            let value = MetadataValue(sensorFPS: fps.count == 1 ? (fps.first ?? "") : "", shootDay: days.count == 1 ? (days.first ?? "") : "")
            if !value.sensorFPS.isEmpty || !value.shootDay.isEmpty { result[key] = value }
        }
        return result
    }

    private static func buildRowIndex(_ rows: [[String]], columns: ResolveColumnIndexes, warnings: inout [String]) -> [String: [Int]] {
        var result: [String: [Int]] = [:]
        for (index, row) in rows.enumerated() {
            let identity = identify(row, columns: columns)
            if identity.conflict { warnings.append("CSV 第 \(index + 2) 行的卷名与文件名指向不同素材，已跳过该行。") }
            else if !identity.key.isEmpty { result[identity.key, default: []].append(index) }
        }
        return result
    }

    private static func identify(_ row: [String], columns: ResolveColumnIndexes) -> (key: String, conflict: Bool) {
        let reelKeys = Set(columns.reelName.map { ResolveCSVNormalization.extractCombinedMaterialKey(row[$0]) }.filter { !$0.isEmpty })
        let fileKeys = Set((columns.fileName + columns.clipName + columns.clipDirectory).map { ResolveCSVNormalization.extractCombinedMaterialKey(row[$0]) }.filter { !$0.isEmpty })
        if reelKeys.count > 1 || fileKeys.count > 1 { return ("", true) }
        if let reel = reelKeys.first, let file = fileKeys.first, reel != file { return ("", true) }
        let cards = Set(columns.reelName.compactMap { ResolveCSVNormalization.parseCardNumber(row[$0]).map { "\($0.camera):\($0.reel)" } })
        let clips = Set((columns.clipName + columns.fileName).compactMap { ResolveCSVNormalization.extractLooseClipOrdinal(row[$0]) })
        if cards.count > 1 || clips.count > 1 { return ("", true) }
        let separate = cards.first.flatMap { card in clips.first.map { "\(card):\($0)" } } ?? ""
        let combined = reelKeys.first ?? fileKeys.first ?? ""
        if !separate.isEmpty, !combined.isEmpty, separate != combined { return ("", true) }
        return (combined.isEmpty ? separate : combined, false)
    }

    private static func write(_ value: String, field: String, column: Int, row: Int, headers: [String], rows: inout [[String]], changes: inout [ResolveCSVChange], updatedRows: inout Set<Int>) {
        guard column >= 0 else { return }
        let previous = ResolveCSVNormalization.clean(rows[row][column])
        guard previous != value else { return }
        rows[row][column] = value
        changes.append(ResolveCSVChange(rowIndex: row, field: field, header: headers[column], previous: previous, next: value))
        updatedRows.insert(row)
    }

    /// Sparse edits replace the original cell byte-for-byte. They deliberately
    /// do not trim before equality, matching the retained Worker snapshot path.
    private static func applySparseEdit(_ value: String, column: Int, row: Int, headers: [String], rows: inout [[String]], changes: inout [ResolveCSVChange], updatedRows: inout Set<Int>) {
        let previous = rows[row][column]
        guard previous != value else { return }
        rows[row][column] = value
        changes.append(ResolveCSVChange(rowIndex: row, field: "edit", header: headers[column], previous: previous, next: value))
        updatedRows.insert(row)
    }

    private static func normalizedRow(_ source: [String], width: Int) -> [String] {
        var row = Array(source.prefix(width))
        if row.count < width { row.append(contentsOf: repeatElement("", count: width - row.count)) }
        return row
    }

    private static func rowDisplayName(_ row: [String], columns: ResolveColumnIndexes) -> String {
        for index in columns.fileName where !ResolveCSVNormalization.clean(row[index]).isEmpty { return ResolveCSVNormalization.clean(row[index]) }
        for index in columns.reelName where !ResolveCSVNormalization.clean(row[index]).isEmpty { return ResolveCSVNormalization.clean(row[index]) }
        return ""
    }

    private static func unsignedInteger(_ value: String?) -> Int? {
        guard let value, !value.isEmpty, value.allSatisfy(\.isNumber) else { return nil }
        return Int(value)
    }
}

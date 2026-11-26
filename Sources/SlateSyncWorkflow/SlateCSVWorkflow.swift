import Foundation
import SlateSyncDomain

/// Decodes local production sheets with the same CSV grammar as Resolve.
public actor SlateCSVWorkflow {
    public init() {}

    public func decode(_ data: Data) throws -> [SlateCsvRecord] {
        let table = try ResolveCSVEngine.decodeTable(data, resolveTemplate: false)
        guard !table.rows.isEmpty else { throw SlateSyncError(code: "SLATE_CSV_EMPTY", message: "场记 CSV 为空或缺少数据行") }
        let aliases: [[String]] = [
            ["file name", "filename", "文件名"], ["scene", "场", "场次", "场景"],
            ["shot", "镜", "镜次"], ["take", "次", "镜头"], ["comments", "备注"],
            ["camera fps", "camerafps", "摄影机帧率"], ["shoot day", "shootday", "拍摄日期"]
        ]
        var columns: [Int: Int] = [:]
        for (index, header) in table.headers.enumerated() {
            if let field = aliases.firstIndex(where: { $0.contains(header.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()) }) { columns[field] = index }
        }
        guard columns[0] != nil else { throw SlateSyncError(code: "SLATE_CSV_COLUMNS", message: "场记 CSV 缺少 File Name 列") }
        return try table.rows.enumerated().compactMap { index, cells in
            try Task.checkCancellation()
            guard cells.contains(where: { !$0.isEmpty }) else { return nil }
            func value(_ field: Int) -> String? {
                guard let index = columns[field], cells.indices.contains(index), !cells[index].isEmpty else { return nil }
                return cells[index]
            }
            guard value(0) != nil || value(1) != nil || value(2) != nil || value(3) != nil else {
                throw SlateSyncError(code: "SLATE_CSV_ROW", message: "场记 CSV 第 \(index + 2) 行缺少素材和场镜次，请检查。")
            }
            let file = value(0)
            let matches = captures(#"([A-Z]\d+)_(C\d+)"#, in: file ?? "") ?? captures(#"([A-Z]\d+)(C\d+)"#, in: file ?? "")
            return SlateCsvRecord(fileName: file, materialKey: matches.map { ($0[0] + $0[1]).uppercased() },
                scene: value(1), shot: value(2), take: value(3), notes: status(value(4)) == nil ? value(4) : nil, comments: status(value(4)), cameraFps: value(5), shootDay: value(6))
        }
    }

    public func records(_ input: [SlateCsvRecord]) -> [PersistedRecognitionRecord] {
        input.enumerated().map { index, row in
            let parts = captures(#"^([A-Z]+\d+)(C\d+)$"#, in: row.materialKey ?? "")
            return PersistedRecognitionRecord(id: "slate-csv-\(index)", cardNumber: row.cardNumber ?? parts?.first,
                videoCode: row.videoCode ?? parts?.last, scene: row.scene, shot: row.shot, take: row.take,
                takeStatus: row.comments, comments: row.notes, sourceFileName: row.fileName, cameraFps: row.cameraFps, shootDay: row.shootDay, confidence: .high)
        }
    }

    private func status(_ raw: String?) -> TakeStatus? {
        let value = raw?.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() ?? ""
        switch value {
        case "OK", "_OK", "过", "过条", "好条": return .passed
        case "KP", "_KP", "保", "保条": return .hold
        case "NG", "_NG", "废条", "废": return .rejected
        default: return nil
        }
    }

    private func captures(_ pattern: String, in text: String) -> [String]? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return nil }
        return (1..<match.numberOfRanges).compactMap { Range(match.range(at: $0), in: text).map { String(text[$0]).uppercased() } }
    }
}

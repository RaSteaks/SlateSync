import Foundation
import SlateSyncDomain

/// Compatibility adapter for the retained slate-csv-parser.js and local Worker
/// record projection. Resolve merging still goes through SM05WorkflowServices;
/// this parser deliberately keeps the legacy comma/UTF-8/line-based contract.
public actor SlateCSVWorkflow {
    public init() {}

    public func decode(_ data: Data) throws -> [SlateCsvRecord] {
        // 与 Resolve CSV 共用统一预算：先拒病态大文件，再进入逐行解析
        // （行级取消检查见下方 compactMap）。
        guard data.count <= CSVInputBudget.maximumInputBytes else {
            throw SlateSyncError(code: "CSV_INPUT_SIZE", message: "场记 CSV 超过 \(CSVInputBudget.maximumInputBytes / 1024 / 1024) MB 上限")
        }
        guard var text = String(data: data, encoding: .utf8), !data.isEmpty else {
            throw SlateSyncError(code: "SLATE_CSV_ENCODING", message: "场记 CSV 需要非空 UTF-8 文件")
        }
        if text.first == "\u{FEFF}" { text.removeFirst() }
        let lines = text.components(separatedBy: "\n").map { $0.hasSuffix("\r") ? String($0.dropLast()) : $0 }
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard lines.count >= 2 else { throw SlateSyncError(code: "SLATE_CSV_EMPTY", message: "场记 CSV 为空或缺少数据行") }
        let aliases: [[String]] = [
            ["file name", "filename", "文件名"], ["scene", "场", "场次", "场景"],
            ["shot", "镜", "镜次"], ["take", "次", "镜头"], ["comments", "备注"],
            ["camera fps", "camerafps", "摄影机帧率"], ["shoot day", "shootday", "拍摄日期"]
        ]
        var columns: [Int: Int] = [:]
        for (index, header) in parseLine(lines[0]).enumerated() {
            if let field = aliases.firstIndex(where: { $0.contains(header.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()) }) { columns[field] = index }
        }
        guard columns[0] != nil else { throw SlateSyncError(code: "SLATE_CSV_COLUMNS", message: "场记 CSV 缺少 File Name 列") }
        return try lines.dropFirst().compactMap { line in
            try Task.checkCancellation()
            let cells = parseLine(line)
            func value(_ field: Int) -> String? {
                guard let index = columns[field], cells.indices.contains(index), !cells[index].isEmpty else { return nil }
                return cells[index]
            }
            guard value(1) != nil || value(2) != nil || value(3) != nil else { return nil }
            let file = value(0)
            let matches = captures(#"([A-Z]\d+)_(C\d+)"#, in: file ?? "") ?? captures(#"([A-Z]\d+)(C\d+)"#, in: file ?? "")
            return SlateCsvRecord(fileName: file, materialKey: matches.map { ($0[0] + $0[1]).uppercased() },
                scene: value(1), shot: value(2), take: value(3), comments: status(value(4)), cameraFps: value(5), shootDay: value(6))
        }
    }

    public func records(_ input: [SlateCsvRecord]) -> [PersistedRecognitionRecord] {
        input.enumerated().map { index, row in
            let parts = captures(#"^([A-Z]+\d+)(C\d+)$"#, in: row.materialKey ?? "")
            return PersistedRecognitionRecord(id: "slate-csv-\(index)", cardNumber: row.cardNumber ?? parts?.first,
                videoCode: row.videoCode ?? parts?.last, scene: row.scene, shot: row.shot, take: row.take,
                takeStatus: row.comments, confidence: .high)
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

    private func parseLine(_ line: String) -> [String] {
        let characters = Array(line)
        var cells: [String] = [], current = "", quoted = false, index = 0
        while index < characters.count {
            let character = characters[index]
            if quoted {
                if character == "\"" {
                    if index + 1 < characters.count, characters[index + 1] == "\"" { current.append(character); index += 1 }
                    else { quoted = false }
                } else { current.append(character) }
            } else if character == "\"" { quoted = true }
            else if character == "," { cells.append(current); current = "" }
            else { current.append(character) }
            index += 1
        }
        cells.append(current)
        return cells
    }
}

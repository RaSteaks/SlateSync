import Foundation
import SlateSyncDomain

public actor ResolveCSVEngine: CSVProcessing {
    public init() {}

    public func decode(_ data: Data) throws -> ResolveCSVTable {
        guard !data.isEmpty else {
            throw SlateSyncError(code: "CSV_EMPTY", message: "CSV 文件为空")
        }
        let detected = try Self.detect(data)
        let content = data.dropFirst(detected.prefixCount)
        guard let text = String(data: content, encoding: detected.stringEncoding) else {
            throw SlateSyncError(code: "CSV_ENCODING", message: "无法解码 CSV 文件")
        }
        let lineEnding = Self.detectLineEnding(text)
        // Inspect Unicode scalars because Swift represents CRLF as one Character.
        let finalScalar = text.unicodeScalars.last
        let finalNewline = finalScalar == "\n" || finalScalar == "\r"
        let delimiter = Self.detectDelimiter(text)
        let records = try Self.parse(text, delimiter: delimiter)
        guard let rawHeaders = records.first, rawHeaders.contains(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
            throw SlateSyncError(code: "CSV_EMPTY", message: "CSV 没有表头")
        }
        let headers = rawHeaders
        let columns = try ResolveHeaders.resolve(headers)
        guard ResolveHeaders.hasIdentifier(columns) else {
            throw SlateSyncError(code: "CSV_COLUMNS", message: "CSV 中未找到 File Name（文件名）、Reel Name（卷名）或 Clip Name（条名）列。")
        }
        let rows = records.dropFirst().map { record -> [String] in
            var row = Array(record.prefix(headers.count))
            if row.count < headers.count { row.append(contentsOf: repeatElement("", count: headers.count - row.count)) }
            return row
        }
        return ResolveCSVTable(
            headers: headers,
            rows: rows,
            format: .init(
                encoding: detected.encoding,
                bom: detected.prefixCount > 0,
                delimiter: delimiter,
                lineEnding: lineEnding,
                finalNewline: finalNewline
            )
        )
    }

    public func encode(_ table: ResolveCSVTable) throws -> Data {
        try encode(table, fieldFormats: .init(), comments: .init(), canonicalizeComments: false)
    }

    /// The explicit export variant performs the same field canonicalization as
    /// the Electron encoder while the protocol method remains a plain round trip.
    public func encode(
        _ table: ResolveCSVTable,
        fieldFormats: ResolveFieldFormats,
        comments: ResolveComments,
        canonicalizeComments: Bool
    ) throws -> Data {
        try table.format.validate()
        try fieldFormats.validate()
        try comments.validate()
        let delimiter = String(table.format.delimiter)
        let columns = try ResolveHeaders.resolve(table.headers)
        let rows = table.rows.map { source -> [String] in
            var row = Array(source.prefix(table.headers.count))
            if row.count < table.headers.count { row.append(contentsOf: repeatElement("", count: table.headers.count - row.count)) }
            if columns.scene >= 0 { row[columns.scene] = ResolveCSVNormalization.normalizeScene(row[columns.scene], format: fieldFormats.scene) }
            if columns.shot >= 0 { row[columns.shot] = ResolveCSVNormalization.normalizeShot(row[columns.shot], format: fieldFormats.shot) }
            if columns.take >= 0 { row[columns.take] = ResolveCSVNormalization.normalizeTake(row[columns.take], format: fieldFormats.take) }
            if canonicalizeComments, columns.comments >= 0 { row[columns.comments] = ResolveCSVNormalization.canonicalComment(row[columns.comments], comments: comments) }
            return row
        }
        let records = [table.headers] + rows
        var text = records.map { row in
            row.map { Self.quote($0, delimiter: delimiter) }.joined(separator: delimiter)
        }.joined(separator: table.format.lineEnding)
        if table.format.finalNewline { text += table.format.lineEnding }

        let encoded: Data
        switch table.format.encoding {
        case .utf8:
            encoded = Data(text.utf8)
        case .utf16LittleEndian:
            guard let data = text.data(using: .utf16LittleEndian) else {
                throw SlateSyncError(code: "CSV_ENCODING", message: "无法编码 UTF-16LE CSV")
            }
            encoded = data
        case .utf16BigEndian:
            guard let data = text.data(using: .utf16BigEndian) else {
                throw SlateSyncError(code: "CSV_ENCODING", message: "无法编码 UTF-16BE CSV")
            }
            encoded = data
        }
        guard table.format.bom else { return encoded }
        return Self.bom(for: table.format.encoding) + encoded
    }

    private struct Detection {
        let encoding: ResolveCSVEncoding
        let stringEncoding: String.Encoding
        let prefixCount: Int
    }

    private static func detect(_ data: Data) throws -> Detection {
        let bytes = [UInt8](data.prefix(3))
        if bytes.starts(with: [0xEF, 0xBB, 0xBF]) {
            return Detection(encoding: .utf8, stringEncoding: .utf8, prefixCount: 3)
        }
        if bytes.starts(with: [0xFF, 0xFE]) {
            return Detection(encoding: .utf16LittleEndian, stringEncoding: .utf16LittleEndian, prefixCount: 2)
        }
        if bytes.starts(with: [0xFE, 0xFF]) {
            return Detection(encoding: .utf16BigEndian, stringEncoding: .utf16BigEndian, prefixCount: 2)
        }
        let sample = [UInt8](data.prefix(2048))
        let evenZeros = sample.indices.filter { $0.isMultiple(of: 2) && sample[$0] == 0 }.count
        let oddZeros = sample.indices.filter { !$0.isMultiple(of: 2) && sample[$0] == 0 }.count
        if oddZeros > sample.count / 8, oddZeros > evenZeros * 4 {
            return Detection(encoding: .utf16LittleEndian, stringEncoding: .utf16LittleEndian, prefixCount: 0)
        }
        if evenZeros > sample.count / 8, evenZeros > oddZeros * 4 {
            return Detection(encoding: .utf16BigEndian, stringEncoding: .utf16BigEndian, prefixCount: 0)
        }
        guard String(data: data, encoding: .utf8) != nil else {
            throw SlateSyncError(code: "CSV_ENCODING", message: "仅支持 UTF-8 与 UTF-16 CSV")
        }
        return Detection(encoding: .utf8, stringEncoding: .utf8, prefixCount: 0)
    }

    private static func detectDelimiter(_ text: String) -> Character {
        var counts: [Character: Int] = [",": 0, "\t": 0, ";": 0]
        var quoted = false
        var index = text.startIndex
        while index < text.endIndex {
            let character = text[index]
            if character == "\"" {
                let next = text.index(after: index)
                if quoted, next < text.endIndex, text[next] == "\"" { index = next }
                else { quoted.toggle() }
            } else if !quoted, character == "\r" || character == "\n" || character == "\r\n" {
                break
            } else if !quoted, counts[character] != nil {
                counts[character, default: 0] += 1
            }
            index = text.index(after: index)
        }
        // JavaScript's stable sort keeps comma first when counts tie. Swift's
        // `max(by:)` does not promise that tie behavior, so preserve it here.
        var selected: Character = ","
        for candidate: Character in ["\t", ";"] where counts[candidate, default: 0] > counts[selected, default: 0] {
            selected = candidate
        }
        return selected
    }

    private static func detectLineEnding(_ text: String) -> String {
        var quoted = false
        var index = text.startIndex
        while index < text.endIndex {
            let character = text[index]
            if character == "\"" {
                let next = text.index(after: index)
                if quoted, next < text.endIndex, text[next] == "\"" { index = next }
                else { quoted.toggle() }
            } else if !quoted, character == "\r\n" {
                return "\r\n"
            } else if !quoted, character == "\r" {
                let next = text.index(after: index)
                return next < text.endIndex && text[next] == "\n" ? "\r\n" : "\r"
            } else if !quoted, character == "\n" {
                return "\n"
            }
            index = text.index(after: index)
        }
        return "\r\n"
    }

    private static func parse(_ text: String, delimiter: Character) throws -> [[String]] {
        var records: [[String]] = []
        var row: [String] = []
        var field = ""
        var quoted = false
        var index = text.startIndex
        while index < text.endIndex {
            let character = text[index]
            if quoted {
                if character == "\"" {
                    let next = text.index(after: index)
                    if next < text.endIndex, text[next] == "\"" {
                        field.append("\"")
                        index = next
                    } else {
                        quoted = false
                    }
                } else {
                    field.append(character)
                }
            } else if character == "\"" {
                // The Electron parser enters quoted mode wherever a quote is
                // encountered, including malformed-but-historically accepted
                // unquoted prefixes. Preserve that recovery behavior.
                quoted = true
            } else if character == delimiter {
                row.append(field)
                field = ""
            } else if character == "\r" || character == "\n" || character == "\r\n" {
                // Swift treats CRLF as one extended grapheme; only skip a following
                // LF when CR and LF were delivered as separate characters.
                if character == "\r" {
                    let next = text.index(after: index)
                    if next < text.endIndex, text[next] == "\n" { index = next }
                }
                row.append(field)
                records.append(row)
                row = []
                field = ""
            } else {
                field.append(character)
            }
            index = text.index(after: index)
        }
        guard !quoted else {
            throw SlateSyncError(code: "CSV_QUOTES", message: "CSV 引号结构不完整")
        }
        if !field.isEmpty || !row.isEmpty {
            row.append(field)
            records.append(row)
        }
        return records
    }

    private static func quote(_ value: String, delimiter: String) -> String {
        guard value.contains(delimiter) || value.contains("\"") || value.contains("\n") || value.contains("\r") else {
            return value
        }
        return "\"\(value.replacingOccurrences(of: "\"", with: "\"\""))\""
    }

    private static func bom(for encoding: ResolveCSVEncoding) -> Data {
        switch encoding {
        case .utf8: Data([0xEF, 0xBB, 0xBF])
        case .utf16LittleEndian: Data([0xFF, 0xFE])
        case .utf16BigEndian: Data([0xFE, 0xFF])
        }
    }
}

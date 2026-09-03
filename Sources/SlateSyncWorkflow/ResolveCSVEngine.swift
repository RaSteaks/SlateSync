import Foundation
import SlateSyncDomain

public actor ResolveCSVEngine: CSVProcessing {
    public init() {}

    public func decode(_ data: Data) throws -> ResolveCSVTable {
        let detected = try Self.detect(data)
        let content = data.dropFirst(detected.prefixCount)
        guard let text = String(data: content, encoding: detected.stringEncoding) else {
            throw SlateSyncError(code: "CSV_ENCODING", message: "无法解码 CSV 文件")
        }
        let lineEnding = text.contains("\r\n") ? "\r\n" : text.contains("\r") ? "\r" : "\n"
        // Inspect Unicode scalars because Swift represents CRLF as one Character.
        let finalScalar = text.unicodeScalars.last
        let finalNewline = finalScalar == "\n" || finalScalar == "\r"
        let delimiter = Self.detectDelimiter(text)
        let records = try Self.parse(text, delimiter: delimiter)
        guard let headers = records.first, !headers.isEmpty else {
            throw SlateSyncError(code: "CSV_EMPTY", message: "CSV 没有表头")
        }
        return ResolveCSVTable(
            headers: headers,
            rows: Array(records.dropFirst()),
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
        let delimiter = String(table.format.delimiter)
        let records = [table.headers] + table.rows
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
        guard String(data: data, encoding: .utf8) != nil else {
            throw SlateSyncError(code: "CSV_ENCODING", message: "仅支持 UTF-8 与 UTF-16 CSV")
        }
        return Detection(encoding: .utf8, stringEncoding: .utf8, prefixCount: 0)
    }

    private static func detectDelimiter(_ text: String) -> Character {
        let firstRecord = text.split(whereSeparator: \Character.isNewline).first ?? ""
        return firstRecord.filter { $0 == ";" }.count > firstRecord.filter { $0 == "," }.count ? ";" : ","
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
            } else if character == "\"", field.isEmpty {
                quoted = true
            } else if character == delimiter {
                row.append(field)
                field = ""
            } else if character.isNewline {
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

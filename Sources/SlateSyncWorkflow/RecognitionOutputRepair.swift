import Foundation
import SlateSyncDomain

/// An audit trail of syntax-only changes. No record field is inferred here.
public enum RepairAction: String, Codable, Hashable, Sendable {
    case removedBOM
    case removedMarkdownFence
    case extractedJSONObject
    case normalizedStructuralQuotes
    case removedTrailingCommas
}

public enum JSONTextRepair {
    public static func repair(_ source: String) -> (text: String, actions: [RepairAction]) {
        var text = source
        var actions: [RepairAction] = []
        if text.hasPrefix("\u{FEFF}") {
            text.removeFirst()
            actions.append(.removedBOM)
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("```"), trimmed.hasSuffix("```"),
           let newline = trimmed.firstIndex(of: "\n"),
           let closing = trimmed.range(of: "```", options: .backwards),
           newline < closing.lowerBound {
            let language = trimmed[trimmed.index(trimmed.startIndex, offsetBy: 3)..<newline]
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if language.isEmpty || language.lowercased() == "json" {
                text = String(trimmed[trimmed.index(after: newline)..<closing.lowerBound])
                actions.append(.removedMarkdownFence)
            }
        }
        if let object = balancedObject(text), object != text.trimmingCharacters(in: .whitespacesAndNewlines) {
            text = object
            actions.append(.extractedJSONObject)
        }
        let quoted = normalizeStructuralQuotes(text)
        if quoted != text {
            text = quoted
            actions.append(.normalizedStructuralQuotes)
        }
        let withoutCommas = removeTrailingCommas(text)
        if withoutCommas != text {
            text = withoutCommas
            actions.append(.removedTrailingCommas)
        }
        return (text, actions)
    }

    /// Only a single complete top-level object is eligible. Ambiguous extra
    /// objects and truncated bodies are returned unchanged for strict decode.
    private static func balancedObject(_ source: String) -> String? {
        let chars = Array(source)
        var start: Int?, end: Int?, depth = 0
        var quote: Character?, escaped = false
        for (index, char) in chars.enumerated() {
            if let delimiter = quote {
                if escaped { escaped = false; continue }
                if char == "\\" { escaped = true; continue }
                if char == (delimiter == "“" ? "”" : delimiter) { quote = nil }
                continue
            }
            if char == "\"" || char == "“" { quote = char; continue }
            if char == "{" {
                if depth == 0 {
                    guard start == nil else { return nil }
                    start = index
                }
                depth += 1
            } else if char == "}" {
                guard depth > 0 else { return nil }
                depth -= 1
                if depth == 0 { end = index }
            }
        }
        guard depth == 0, quote == nil, let start, let end else { return nil }
        return String(chars[start...end])
    }

    private static func normalizeStructuralQuotes(_ source: String) -> String {
        var result = "", quote: Character?, escaped = false
        for char in source {
            if let delimiter = quote {
                if escaped { result.append(char); escaped = false; continue }
                if char == "\\" { result.append(char); escaped = true; continue }
                if char == (delimiter == "“" ? "”" : delimiter) {
                    result.append("\""); quote = nil
                } else { result.append(char) }
            } else if char == "\"" || char == "“" {
                quote = char; result.append("\"")
            } else {
                result.append(char)
            }
        }
        return result
    }

    private static func removeTrailingCommas(_ source: String) -> String {
        let chars = Array(source)
        var result = "", quoted = false, escaped = false
        for (index, char) in chars.enumerated() {
            if quoted {
                result.append(char)
                if escaped { escaped = false }
                else if char == "\\" { escaped = true }
                else if char == "\"" { quoted = false }
                continue
            }
            if char == "\"" { quoted = true; result.append(char); continue }
            if char == "," {
                let next = chars.dropFirst(index + 1).first { !$0.isWhitespace }
                if next == "}" || next == "]" { continue }
            }
            result.append(char)
        }
        return result
    }
}

public enum TolerantStructuredJSON {
    public static func decode(_ source: String) throws -> (value: JSONValue, actions: [RepairAction]) {
        let decoder = JSONDecoder()
        if let data = source.data(using: .utf8),
           let value = try? decoder.decode(JSONValue.self, from: data) {
            return (value, [])
        }
        let repaired = JSONTextRepair.repair(source)
        if let data = repaired.text.data(using: .utf8),
           let value = try? decoder.decode(JSONValue.self, from: data) {
            return (value, repaired.actions)
        }
        throw RecognitionFailure.invalidStructuredJSON
    }
}

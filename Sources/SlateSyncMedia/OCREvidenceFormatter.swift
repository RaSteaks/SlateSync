import Foundation
import SlateSyncDomain

public enum OCREvidenceFormatter {
    public static func format(_ page: OCRPageEvidence, engine: String = "local", core: Bool = false, maxCharacters: Int = 18_000) -> String {
        guard !page.views.isEmpty else { return "" }
        let cleanEngine = engine.trimmingCharacters(in: .whitespacesAndNewlines)
        var lines = ["<ocr_evidence>","engine=\(cleanEngine.isEmpty ? "local" : cleanEngine) page=\(page.pageNumber) mode=\(core ? "core" : "full") bbox=normalized[left,top,right,bottom]","OCR is evidence, not ground truth. Verify every value against the attached images; preserve uncertain alternatives instead of guessing."]
        var count = lines.joined(separator: "\n").utf16.count, omitted = 0
        let budget = maxCharacters == 0 ? 18_000 : maxCharacters
        func append(_ line: String) { lines.append(line); count += line.utf16.count + 1 }
        for view in page.views {
            let selected = view.blocks.filter { !$0.text.isEmpty && ((!core && view.viewType == .full) || isCore($0.text)) }
            append("view=\(view.viewIndex) type=\(view.viewType.rawValue) size=\(view.width)x\(view.height) blocks=\(selected.count)")
            for block in selected {
                let box = block.bboxNormalized.map { fixed($0, digits: 4) }.joined(separator: ",")
                let encoder = JSONEncoder(); encoder.outputFormatting = [.withoutEscapingSlashes]
                let quoted = (try? encoder.encode(block.text)).flatMap { String(data: $0, encoding: .utf8) } ?? "\"\""
                let line = "#\(block.order) q=\(fixed(block.confidence, digits: 3)) box=[\(box)] text=\(quoted)"
                // JavaScript length is UTF-16, including emoji surrogate pairs.
                if count + line.utf16.count + 81 > budget { omitted += 1; continue }
                append(line)
            }
            if view.truncated { append("view_truncated=true") }
        }
        if omitted > 0 { lines.append("evidence_truncated=true omitted=\(omitted)") }
        lines.append("</ocr_evidence>")
        return lines.joined(separator: "\n")
    }
    private static func isCore(_ text: String) -> Bool {
        let compact = text.replacingOccurrences(of: #"\s+"#, with: "", options: .regularExpression)
        return compact.utf16.count <= 8 || compact.range(of: #"[0-9]"#, options: .regularExpression) != nil || compact.range(of: #"^(?:[A-D]\d{3}|C0?\d{1,3}|A机|B机|C机|D机|场次?|镜|次|视频(?:号|码)?|景别|√|✓|✔|X|×|△|▲)$"#, options: [.regularExpression,.caseInsensitive]) != nil
    }
    static func fixed(_ value: Double, digits: Int) -> String {
        guard value.isFinite else { return value.isNaN ? "NaN" : (value < 0 ? "-Infinity" : "Infinity") }
        let magnitude = abs(value)
        if magnitude >= 1e21 { return JavaScriptCompatibility.numberString(value) ?? "0" }
        // Exact binary rational -> decimal integer, ties upward as JS toFixed.
        // Multiplication in Double or printf's ties-to-even changes .0625.
        let bits = magnitude.bitPattern
        let exponent = Int((bits >> 52) & 0x7ff)
        let significand = (bits & ((1 << 52) - 1)) | (exponent == 0 ? 0 : 1 << 52)
        let power5: UInt64 = digits == 4 ? 625 : 125
        let product = significand * power5
        let shift = (exponent == 0 ? -1022 : exponent - 1023) - 52 + digits
        let rounded: UInt64
        if shift >= 0, shift < 64, product <= UInt64.max >> shift { rounded = product << shift }
        else if shift < 0 {
            let right = -shift
            if right > 64 { rounded = 0 }
            else if right == 64 { rounded = product >= (1 << 63) ? 1 : 0 }
            else { rounded = (product >> right) + ((product & ((1 << right) - 1)) >= (1 << (right - 1)) ? 1 : 0) }
        } else { return String(format: "%.*f", locale: Locale(identifier: "en_US_POSIX"), digits, value) }
        let scale: UInt64 = digits == 4 ? 10_000 : 1000
        let suffix = String(rounded % scale)
        return (value < 0 ? "-" : "") + String(rounded / scale) + "." + String(repeating: "0", count: digits - suffix.count) + suffix
    }
}

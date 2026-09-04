import Foundation
import SlateSyncDomain

/// Pure SM-05 compatibility primitives shared by CSV merge and metadata scan.
/// Field values use JavaScript's NFKC path; material identifiers deliberately
/// use its separate uppercase-then-ASCII-filter path without NFKC.
public enum ResolveCSVNormalization {
    public static let defaultFieldFormats = ResolveFieldFormats()
    public static let defaultComments = ResolveComments()

    public static func clean(_ value: String?) -> String {
        guard let value else { return "" }
        // Resolve exports are overwhelmingly ASCII. Avoid allocating an NFKC
        // copy for that hot path while retaining compatibility mapping for
        // full-width and other non-ASCII user input.
        let normalized = value.unicodeScalars.allSatisfy(\.isASCII)
            ? value
            : value.precomposedStringWithCompatibilityMapping
        return normalized.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "\u{FEFF}")))
    }

    public static func chineseNumeralsToArabic(_ value: String?) -> String {
        let source = value ?? ""
        var result = ""
        var run = ""
        let accepted = Set("零一二两三四五六七八九十百")
        func flush() -> String {
            defer { run = "" }
            guard !run.isEmpty, let number = parseChineseNumber(run) else { return run }
            return String(number)
        }
        for character in source {
            if accepted.contains(character) {
                run.append(character)
            } else {
                result += flush()
                result.append(character)
            }
        }
        result += flush()
        return result
    }

    public static func normalizeCameraFPS(_ value: String?) -> String {
        let normalized = clean(value).replacingOccurrences(of: ",", with: ".")
        guard let match = firstMatch(#"^(\d{1,4}(?:\.\d{1,6})?)\s*(?:fps)?$"#, in: normalized, caseInsensitive: true),
              let number = Double(match[1]), number.isFinite, number > 0, number <= 1_000 else { return "" }
        if number.rounded() == number { return String(Int(number)) }
        return String(number)
    }

    public static func normalizeShootDay(_ value: String?) -> String {
        let normalized = clean(value)
        let compact = firstMatch(#"^(\d{2}|\d{4})(\d{2})(\d{2})$"#, in: normalized)
        let separated = firstMatch(#"^(\d{2}|\d{4})\s*[-/.]\s*(\d{1,2})\s*[-/.]\s*(\d{1,2})(?:[T\s].*)?$"#, in: normalized)
        guard let match = compact ?? separated,
              let rawYear = Int(match[1]), let month = Int(match[2]), let day = Int(match[3]) else { return "" }
        let year = match[1].count == 2 ? 2_000 + rawYear : rawYear
        var calendar = Calendar(identifier: .gregorian)
        guard let utc = TimeZone(secondsFromGMT: 0) else { return "" }
        calendar.timeZone = utc
        guard let date = calendar.date(from: DateComponents(year: year, month: month, day: day)),
              calendar.component(.year, from: date) == year,
              calendar.component(.month, from: date) == month,
              calendar.component(.day, from: date) == day else { return "" }
        return String(format: "%02d-%02d-%02d", year % 100, month, day)
    }

    public static func extractCombinedMaterialKey(_ value: String?) -> String {
        let scalars = Array((value ?? "").uppercased().unicodeScalars)
        for start in scalars.indices where start == 0 || !isASCIIAlphaNumeric(scalars[start - 1]) {
            var cursor = start
            let cameraStart = cursor
            while cursor < scalars.count, isASCIIUppercase(scalars[cursor]) { cursor += 1 }
            guard cursor > cameraStart else { continue }
            let camera = String(String.UnicodeScalarView(scalars[cameraStart..<cursor]))
            skipMaterialSeparators(scalars, cursor: &cursor)
            let reelStart = cursor
            while cursor < scalars.count, isASCIIDigit(scalars[cursor]) { cursor += 1 }
            guard cursor > reelStart else { continue }
            let reelText = String(String.UnicodeScalarView(scalars[reelStart..<cursor]))
            skipMaterialSeparators(scalars, cursor: &cursor)
            guard cursor < scalars.count, scalars[cursor].value == 0x43 else { continue }
            cursor += 1
            skipMaterialSeparators(scalars, cursor: &cursor)
            let clipStart = cursor
            while cursor < scalars.count, isASCIIDigit(scalars[cursor]) { cursor += 1 }
            guard cursor > clipStart, cursor == scalars.count || !isASCIIDigit(scalars[cursor]) else { continue }
            let clipText = String(String.UnicodeScalarView(scalars[clipStart..<cursor]))
            guard let reel = Int(reelText), let clip = Int(clipText) else { continue }
            return "\(camera):\(reel):\(clip)"
        }
        return ""
    }

    public static func parseCanonicalMaterialKey(_ key: String) -> (camera: String, reel: Int, clip: Int)? {
        let parts = key.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 3, !parts[0].isEmpty,
              parts[1].allSatisfy(\.isNumber), parts[2].allSatisfy(\.isNumber),
              let reel = Int(parts[1]), let clip = Int(parts[2]) else { return nil }
        return (String(parts[0]), reel, clip)
    }

    public static func canonicalKeyToMaterialPrefix(_ key: String) -> String {
        guard let parsed = parseCanonicalMaterialKey(key) else { return key }
        return "\(parsed.camera)\(String(format: "%03d", parsed.reel))C\(String(format: "%03d", parsed.clip))"
    }

    /// Formats adjacent material keys exactly like the Electron audit text,
    /// grouping each camera/reel and compacting consecutive clip numbers.
    public static func compactMaterialRanges(_ keys: [String]) -> String {
        var grouped: [String: [Int]] = [:]
        var reelOrder: [String] = []
        for key in keys {
            guard let parsed = parseCanonicalMaterialKey(key) else { continue }
            let reelKey = "\(parsed.camera):\(parsed.reel)"
            if grouped[reelKey] == nil { reelOrder.append(reelKey) }
            grouped[reelKey, default: []].append(parsed.clip)
        }
        var ranges: [String] = []
        for reelKey in reelOrder {
            let parts = reelKey.split(separator: ":", maxSplits: 1)
            guard parts.count == 2, let reel = Int(parts[1]), var clips = grouped[reelKey], !clips.isEmpty else { continue }
            clips.sort()
            var start = clips[0]
            var end = start
            func label(_ clip: Int) -> String { "C\(String(format: "%03d", clip))" }
            func appendRange() {
                let reelLabel = "\(parts[0])\(String(format: "%03d", reel))"
                ranges.append("\(reelLabel) \(start == end ? label(start) : "\(label(start))–\(label(end))")")
            }
            for clip in clips.dropFirst() {
                if clip == end + 1 { end = clip }
                else { appendRange(); start = clip; end = clip }
            }
            appendRange()
        }
        return ranges.joined(separator: "、")
    }

    public static func normalizeClipNumber(_ value: String?) -> String {
        var token = asciiToken(value)
        if let c = token.lastIndex(of: "C"), c != token.startIndex {
            let prefix = token[..<c]
            let suffix = token[token.index(after: c)...]
            let letterEnd = prefix.firstIndex(where: \.isNumber) ?? prefix.endIndex
            let letters = prefix[..<letterEnd]
            let reel = prefix[letterEnd...]
            if !letters.isEmpty, letters.allSatisfy(\.isLetter), !reel.isEmpty,
               reel.allSatisfy(\.isNumber), !suffix.isEmpty, suffix.allSatisfy(\.isNumber) {
                token = String(suffix)
            }
        } else if token.first == "C" {
            token.removeFirst()
        }
        guard !token.isEmpty, token.allSatisfy(\.isNumber) else { return "" }
        var digits = token
        while digits.count > 3, digits.first == "0" { digits.removeFirst() }
        guard digits.count <= 3 else { return "" }
        digits = String(repeating: "0", count: 3 - digits.count) + digits
        guard digits.first == "0" else { return "" }
        return "C\(digits)"
    }

    public static func canonicalMaterialKey(cardNumber: String?, videoCode: String?) -> String {
        guard let card = parseCardNumber(cardNumber) else { return "" }
        let video = normalizeClipNumber(videoCode)
        guard !video.isEmpty, let clip = Int(video.dropFirst()) else { return "" }
        return "\(card.camera):\(card.reel):\(clip)"
    }

    public static func materialPrefix(cardNumber: String?, videoCode: String?) -> String? {
        let card = asciiToken(cardNumber)
        let video = normalizeClipNumber(videoCode)
        guard parseCardNumber(card) != nil, !video.isEmpty else { return nil }
        return card + video
    }

    public static func normalizeScene(_ value: String?, format: String = "XXX") -> String {
        let source = clean(chineseNumeralsToArabic(value)).uppercased()
        guard !source.isEmpty else { return "" }
        let scalars = Array(source.unicodeScalars)
        var parts: [String] = []
        var cursor = 0
        while cursor < scalars.count {
            while cursor < scalars.count, !isASCIIDigit(scalars[cursor]) { cursor += 1 }
            let digitStart = cursor
            while cursor < scalars.count, isASCIIDigit(scalars[cursor]) { cursor += 1 }
            guard cursor > digitStart else { break }
            let digits = String(String.UnicodeScalarView(scalars[digitStart..<cursor]))
            guard let number = Int(digits), number >= 0, number < 1_000_000 else { return "" }
            while cursor < scalars.count, CharacterSet.whitespacesAndNewlines.contains(scalars[cursor]) { cursor += 1 }
            let suffixStart = cursor
            while cursor < scalars.count, isASCIIUppercase(scalars[cursor]) { cursor += 1 }
            let suffix = String(String.UnicodeScalarView(scalars[suffixStart..<cursor]))
            parts.append(suffix.isEmpty ? String(number) : "\(number)\(suffix)")
        }
        guard !parts.isEmpty else { return "" }
        if parts.count > 1 || parts[0].contains(where: \Character.isLetter) { return parts.joined(separator: " / ") }
        let width = fieldWidth(format, fallback: 3)
        return String(repeating: "0", count: max(0, width - parts[0].count)) + parts[0]
    }

    public static func normalizeShot(_ value: String?, format: String = "XX") -> String {
        normalizeNumber(value, format: format, fallback: 2)
    }

    public static func normalizeTake(_ value: String?, format: String = "XX") -> String {
        normalizeNumber(value, format: format, fallback: 2)
    }

    public static func canonicalComment(_ value: String?, comments: ResolveComments = .init()) -> String {
        let normalized = clean(value).uppercased()
        if normalized == clean(comments.goodTake).uppercased() { return comments.goodTake }
        if normalized == clean(comments.holdTake).uppercased() { return comments.holdTake }
        if normalized == "OK" || normalized == "_OK" { return comments.goodTake }
        if normalized == "KP" || normalized == "_KP" { return comments.holdTake }
        return ""
    }

    public static func comment(for status: TakeStatus?, legacyGoodTake: Bool?, comments: ResolveComments) -> String {
        let resolved: TakeStatus?
        if let status { resolved = status }
        else if legacyGoodTake == true { resolved = .passed }
        else if legacyGoodTake == false { resolved = .hold }
        else { resolved = nil }
        return switch resolved {
        case .passed: comments.goodTake
        case .hold: comments.holdTake
        default: ""
        }
    }

    public static func compareMaterialKeys(_ left: String, _ right: String) -> Bool {
        guard let a = parseCanonicalMaterialKey(left), let b = parseCanonicalMaterialKey(right) else { return left < right }
        if a.camera != b.camera { return a.camera < b.camera }
        if a.reel != b.reel { return a.reel < b.reel }
        return a.clip < b.clip
    }

    static func parseCardNumber(_ value: String?) -> (camera: String, reel: Int)? {
        let token = asciiToken(value)
        let split = token.firstIndex(where: \.isNumber) ?? token.endIndex
        let camera = token[..<split]
        let reelText = token[split...]
        guard !camera.isEmpty, camera.allSatisfy(\.isLetter), !reelText.isEmpty,
              reelText.allSatisfy(\.isNumber), let reel = Int(reelText) else { return nil }
        return (String(camera), reel)
    }

    static func extractLooseClipOrdinal(_ value: String?) -> Int? {
        let scalars = Array((value ?? "").uppercased().unicodeScalars)
        for index in scalars.indices where scalars[index].value == 0x43 && (index == 0 || !isASCIIAlphaNumeric(scalars[index - 1])) {
            var cursor = index + 1
            skipMaterialSeparators(scalars, cursor: &cursor)
            let start = cursor
            while cursor < scalars.count, isASCIIDigit(scalars[cursor]) { cursor += 1 }
            guard cursor > start, cursor == scalars.count || !isASCIIDigit(scalars[cursor]) else { continue }
            return Int(String(String.UnicodeScalarView(scalars[start..<cursor])))
        }
        return nil
    }

    static func normalizeHeader(_ value: String) -> String {
        clean(value).lowercased().replacingOccurrences(of: #"[\s_-]+"#, with: "", options: .regularExpression)
    }

    static func firstMatch(_ pattern: String, in value: String, caseInsensitive: Bool = false) -> [String]? {
        let options: NSRegularExpression.Options = caseInsensitive ? [.caseInsensitive] : []
        guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else { return nil }
        let ns = value as NSString
        guard let result = regex.firstMatch(in: value, range: NSRange(location: 0, length: ns.length)) else { return nil }
        return (0..<result.numberOfRanges).map { index in
            let range = result.range(at: index)
            return range.location == NSNotFound ? "" : ns.substring(with: range)
        }
    }

    private static func parseChineseNumber(_ text: String) -> Int? {
        let digits: [Character: Int] = ["零": 0, "一": 1, "二": 2, "两": 2, "三": 3, "四": 4, "五": 5, "六": 6, "七": 7, "八": 8, "九": 9]
        let units: [Character: Int] = ["十": 10, "百": 100]
        var section = 0
        var digit = -1
        var matched = false
        for character in text {
            if let value = digits[character] { digit = value; matched = true }
            else if let unit = units[character] { section += (digit < 0 ? 1 : digit) * unit; digit = -1; matched = true }
            else { return nil }
        }
        let total = section + max(digit, 0)
        return matched && total < 1_000 ? total : nil
    }

    private static func normalizeNumber(_ value: String?, format: String, fallback: Int) -> String {
        let source = clean(chineseNumeralsToArabic(value))
        guard !source.isEmpty else { return "" }
        let scalars = Array(source.unicodeScalars)
        guard let start = scalars.firstIndex(where: isASCIIDigit) else { return "" }
        var end = start
        while end < scalars.count, isASCIIDigit(scalars[end]) { end += 1 }
        let digits = String(String.UnicodeScalarView(scalars[start..<end]))
        guard let number = Int(digits), number < 1_000_000 else { return "" }
        let raw = String(number)
        let width = fieldWidth(format, fallback: fallback)
        return String(repeating: "0", count: max(0, width - raw.count)) + raw
    }

    private static func fieldWidth(_ value: String, fallback: Int) -> Int {
        let format = value.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        return (1...6).contains(format.count) && format.allSatisfy { $0 == "X" } ? format.count : fallback
    }

    private static func asciiToken(_ value: String?) -> String {
        // Unlike cleanValue(), Electron's card/video normalizeToken does not
        // apply NFKC. Preserve that distinction so full-width identifiers stay
        // unmatched instead of silently addressing a different material row.
        let trimSet = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "\u{FEFF}"))
        return (value ?? "").trimmingCharacters(in: trimSet).uppercased()
            .filter { $0.isASCII && ($0.isLetter || $0.isNumber) }
    }

    private static func isASCIIUppercase(_ scalar: UnicodeScalar) -> Bool { (0x41...0x5A).contains(scalar.value) }
    private static func isASCIIDigit(_ scalar: UnicodeScalar) -> Bool { (0x30...0x39).contains(scalar.value) }
    private static func isASCIIAlphaNumeric(_ scalar: UnicodeScalar) -> Bool { isASCIIUppercase(scalar) || isASCIIDigit(scalar) }
    private static func skipMaterialSeparators(_ scalars: [UnicodeScalar], cursor: inout Int) {
        while cursor < scalars.count {
            let value = scalars[cursor].value
            guard value == 0x20 || value == 0x09 || value == 0x0A || value == 0x0D || value == 0x5F || value == 0x2D else { return }
            cursor += 1
        }
    }
}

struct ResolveColumnIndexes: Sendable {
    var fileName: [Int] = []
    var clipDirectory: [Int] = []
    var reelName: [Int] = []
    var clipName: [Int] = []
    var shot = -1
    var scene = -1
    var take = -1
    var comments = -1
    var cameraFPS = -1
    var shootDay = -1
}

enum ResolveHeaders {
    private static let aliases: [(String, [String])] = [
        ("fileName", ["File Name", "Filename", "文件名"]),
        ("clipDirectory", ["Clip Directory", "片段目录", "素材目录"]),
        ("reelName", ["Reel Name", "Reel", "卷名"]),
        ("clipName", ["Clip Name", "条名", "片段名", "片段名称"]),
        ("shot", ["Shot", "镜次", "鏡次"]),
        ("scene", ["Scene", "场景", "場景"]),
        ("take", ["Take", "镜头", "鏡頭"]),
        ("comments", ["Comments", "Comment", "备注", "備註", "注释", "註釋"]),
        ("cameraFPS", ["Camera FPS", "CameraFPS", "摄影机帧率", "攝影機幀率"]),
        ("shootDay", ["Shoot Day", "ShootDay", "拍摄日期", "拍攝日期"]),
    ]

    static func resolve(_ headers: [String]) throws -> ResolveColumnIndexes {
        var result = ResolveColumnIndexes()
        for (field, names) in aliases {
            let accepted = Set(names.map(ResolveCSVNormalization.normalizeHeader))
            let matches = headers.indices.filter { accepted.contains(ResolveCSVNormalization.normalizeHeader(headers[$0])) }
            let writable = !["fileName", "clipDirectory", "reelName", "clipName"].contains(field)
            if writable, matches.count > 1 {
                throw SlateSyncError(code: "CSV_COLUMNS", message: "CSV 中存在多个 \(names[0]) 对应列，无法确定应写入哪一列。")
            }
            switch field {
            case "fileName": result.fileName = matches
            case "clipDirectory": result.clipDirectory = matches
            case "reelName": result.reelName = matches
            case "clipName": result.clipName = matches
            case "shot": result.shot = matches.first ?? -1
            case "scene": result.scene = matches.first ?? -1
            case "take": result.take = matches.first ?? -1
            case "comments": result.comments = matches.first ?? -1
            case "cameraFPS": result.cameraFPS = matches.first ?? -1
            case "shootDay": result.shootDay = matches.first ?? -1
            default: break
            }
        }
        return result
    }

    static func hasIdentifier(_ columns: ResolveColumnIndexes) -> Bool {
        !columns.fileName.isEmpty || !columns.reelName.isEmpty || !columns.clipName.isEmpty
    }
}

import Foundation

/// Small, dependency-free compatibility helpers for values whose canonical
/// form is defined by JavaScript's String/Number behavior rather than by
/// Swift's native text and numeric formatting rules.
public enum JavaScriptCompatibility {
    /// JavaScript's String.length counts UTF-16 code units, not grapheme
    /// clusters. Use this only for fields whose Electron validator uses
    /// .length; human-facing names intentionally use scalar/code-point
    /// counting in their own validator.
    public static func utf16Length(_ value: String) -> Int {
        value.utf16.count
    }

    /// Parses the string forms accepted by JavaScript's Number(value) for
    /// the finite values used by settings. Empty input still maps to zero as
    /// JavaScript does; callers that treat empty as an unset value handle it
    /// before invoking this helper.
    public static func number(_ value: String) -> Double? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return 0 }

        // JavaScript accepts non-decimal integer prefixes only without an
        // explicit sign. Accumulate into Double instead of UInt64 so large
        // but still finite JavaScript numbers do not become a Swift-only
        // parse failure before the caller applies its range check.
        for (prefix, radix) in [("0x", 16), ("0b", 2), ("0o", 8)] {
            if trimmed.hasPrefix(prefix) || trimmed.hasPrefix(prefix.uppercased()) {
                let digits = String(trimmed.dropFirst(2))
                guard !digits.isEmpty else {
                    return nil
                }
                var result = 0.0
                for scalar in digits.unicodeScalars {
                    let digit: Double?
                    switch scalar.value {
                    case 48...57: digit = Double(scalar.value - 48)
                    case 65...70: digit = Double(scalar.value - 55)
                    case 97...102: digit = Double(scalar.value - 87)
                    default: digit = nil
                    }
                    guard let digit, digit < Double(radix) else { return nil }
                    result = result * Double(radix) + digit
                    guard result.isFinite else { return nil }
                }
                return result
            }
        }

        // Keep the accepted decimal grammar explicit. This avoids Foundation
        // accepting a prefix while JavaScript would reject the full string.
        let decimalPattern = #"^[+-]?(?:[0-9]+(?:\.[0-9]*)?|\.[0-9]+)(?:[eE][+-]?[0-9]+)?$"#
        guard trimmed.range(of: decimalPattern, options: .regularExpression) != nil,
              let parsed = Double(trimmed) else {
            return nil
        }
        return parsed
    }

    /// Applies the JSON-value subset of JavaScript's `Number(value)` coercion.
    /// This is used by hand-edited configuration fields whose Electron
    /// validators accept numeric strings such as `1e2` or `0x10`.
    public static func number(_ value: JSONValue?) -> Double? {
        guard let value else { return nil }
        switch value {
        case .null:
            return 0
        case .boolean(let value):
            return value ? 1 : 0
        case .number(let value):
            return value
        case .string(let value):
            return number(value)
        case .array(let values):
            // Number([]) is 0, Number([x]) uses String(x), while a multi-item
            // array becomes a comma-separated string and normally yields NaN.
            return number(values.map(arrayElementString).joined(separator: ","))
        case .object:
            return nil
        }
    }

    private static func arrayElementString(_ value: JSONValue) -> String {
        switch value {
        case .null:
            return ""
        case .boolean(let value):
            return value ? "true" : "false"
        case .number(let value):
            return numberString(value) ?? "NaN"
        case .string(let value):
            return value
        case .array(let values):
            return values.map(arrayElementString).joined(separator: ",")
        case .object:
            return "[object Object]"
        }
    }

    /// Returns the shortest stable decimal spelling with the notation rules
    /// used by ECMAScript Number#toString: fixed notation for [1e-6, 1e21),
    /// scientific notation outside that interval, and no -0 or exponent
    /// padding. Swift's Double description supplies the shortest round-trip
    /// digits; this method only converts its notation and removes Foundation's
    /// trailing .0 decoration.
    public static func numberString(_ number: Double) -> String? {
        guard number.isFinite else { return nil }
        if number == 0 { return "0" }

        let negative = number < 0
        let magnitude = abs(number)
        let representation = String(magnitude)
        let lowercased = representation.lowercased()
        if lowercased.contains("nan") || lowercased.contains("inf") {
            return nil
        }

        var digits = representation
        var exponent = 0
        if let exponentMarker = digits.firstIndex(where: { $0 == "e" || $0 == "E" }) {
            let exponentText = String(digits[digits.index(after: exponentMarker)...])
            exponent = Int(exponentText) ?? 0
            digits = String(digits[..<exponentMarker])
        }

        let parts = digits.split(separator: ".", omittingEmptySubsequences: false)
        let integerPart = parts.first.map(String.init) ?? digits
        // Drop only insignificant fractional zeroes. Leading zeroes must be
        // counted before calculating the decimal position, otherwise values
        // such as 0.0012 would lose their exponent-free zero padding.
        let fractionPart = String(parts.dropFirst().first.map(String.init) ?? "")
            .replacingOccurrences(of: #"0+$"#, with: "", options: .regularExpression)
        let allDigits = integerPart + fractionPart
        let leadingZeroCount = allDigits.prefix { $0 == "0" }.count
        let significantDigits = String(allDigits.dropFirst(leadingZeroCount))
        guard !significantDigits.isEmpty else { return "0" }

        let decimalPosition = integerPart.count + exponent - leadingZeroCount
        let adjustedExponent = decimalPosition - 1
        let body: String
        if (-6...20).contains(adjustedExponent) {
            if decimalPosition <= 0 {
                body = "0." + String(repeating: "0", count: -decimalPosition) + significantDigits
            } else if decimalPosition >= significantDigits.count {
                body = significantDigits + String(repeating: "0", count: decimalPosition - significantDigits.count)
            } else {
                let split = significantDigits.index(significantDigits.startIndex, offsetBy: decimalPosition)
                body = String(significantDigits[..<split]) + "." + String(significantDigits[split...])
            }
        } else {
            let first = significantDigits.prefix(1)
            let rest = significantDigits.dropFirst()
            body = String(first) + (rest.isEmpty ? "" : ".\(rest)") + "e" + (adjustedExponent >= 0 ? "+" : "") + String(adjustedExponent)
        }

        return negative ? "-\(body)" : body
    }

    /// Parses and canonicalizes a JavaScript integer while preserving the
    /// finite/integer checks performed by Number.isInteger in Electron.
    public static func integerString(_ value: String) -> String? {
        guard let parsed = number(value), parsed.isFinite, parsed.rounded() == parsed else {
            return nil
        }
        return numberString(parsed)
    }
}

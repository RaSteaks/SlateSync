import Foundation
import Darwin

/// Canonicalizes the safe HTTP(S) URL subset shared by global settings and
/// custom providers. The explicit authority/path construction mirrors the
/// WHATWG `new URL(...).toString()` behaviors that matter to endpoint identity:
/// lowercase scheme/host, default-port removal, dot-segment removal, and
/// deterministic trailing-slash handling.
enum HTTPURLNormalizer {
    enum TrailingSlashPolicy {
        case removeOne
        case removeAll
    }

    static func normalize(
        _ value: String,
        trailingSlashPolicy: TrailingSlashPolicy
    ) -> String? {
        let raw = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty,
              !raw.contains("?"),
              !raw.contains("#"),
              let url = URL(string: prepareSpecialHTTPURL(raw)),
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let rawScheme = components.scheme,
              let rawHost = components.host,
              !rawHost.isEmpty,
              // WHATWG strips empty userinfo but rejects non-empty
              // credentials. Foundation represents an empty component as an
              // empty string, so only non-empty values are unsafe.
              components.user?.isEmpty != false,
              components.password?.isEmpty != false,
              components.query == nil,
              components.fragment == nil else {
            return nil
        }

        let scheme = rawScheme.lowercased()
        guard scheme == "http" || scheme == "https" else { return nil }

        guard let authority = URLAuthority(url: url),
              authority.port == components.port || !authority.hasExplicitPort,
              let authorityHost = normalizeHost(rawHost, scheme: scheme) else {
            return nil
        }
        var result = "\(scheme)://\(authorityHost)"
        if let port = authority.port,
           !((scheme == "http" && port == 80) || (scheme == "https" && port == 443)) {
            result += ":\(port)"
        }

        let path = normalizePath(components.percentEncodedPath)
        result += path
        switch trailingSlashPolicy {
        case .removeOne:
            if result.hasSuffix("/") { result.removeLast() }
        case .removeAll:
            while result.hasSuffix("/") { result.removeLast() }
        }
        return result
    }

    private static func prepareSpecialHTTPURL(_ raw: String) -> String {
        // WHATWG treats backslashes as slashes for special schemes and accepts
        // one or more slashes between the scheme and authority. Foundation's
        // URL parser follows RFC syntax instead, so normalize only this prefix
        // before parsing while leaving encoded path bytes untouched.
        let slashNormalized = raw.replacingOccurrences(of: "\\", with: "/")
        guard let colon = slashNormalized.firstIndex(of: ":") else { return raw }
        let scheme = slashNormalized[..<colon]
        guard scheme.caseInsensitiveCompare("http") == .orderedSame
                || scheme.caseInsensitiveCompare("https") == .orderedSame else {
            return raw
        }
        let remainder = slashNormalized[slashNormalized.index(after: colon)...]
        let authority = remainder.drop(while: { $0 == "/" })
        return "\(scheme)://\(authority)"
    }

    private static func normalizeHost(_ host: String, scheme: String) -> String? {
        guard !host.isEmpty,
              !host.unicodeScalars.contains(where: isUnsafeHostScalar) else {
            return nil
        }

        let asciiHost: String
        if host.hasPrefix("[") {
            // IPv6 zone identifiers are OS-specific routing metadata, not a
            // WHATWG host grammar, and must never enter an endpoint identity.
            guard host.hasSuffix("]"), host.contains(":"), !host.contains("%") else {
                return nil
            }
            guard let ipv6 = normalizeIPv6(String(host.dropFirst().dropLast())) else {
                return nil
            }
            asciiHost = "[\(ipv6)]"
        } else {
            guard !host.contains(":"),
                  !host.contains("@"),
                  !host.contains("%"),
                  let hostURL = URL(string: "\(scheme)://\(host)"),
                  let hostComponents = URLComponents(url: hostURL, resolvingAgainstBaseURL: false),
                  hostComponents.host != nil,
                  let separator = hostURL.absoluteString.range(of: "://") else {
                return nil
            }
            let authorityStart = separator.upperBound
            let authorityEnd = hostURL.absoluteString[authorityStart...].firstIndex(of: "/")
                ?? hostURL.absoluteString.endIndex
            asciiHost = String(hostURL.absoluteString[authorityStart..<authorityEnd])
        }

        let lowercased = asciiHost.lowercased()
        switch normalizeIPv4Host(lowercased) {
        case .valid(let address): return address
        case .invalid: return nil
        case .notAnIPv4Candidate: return lowercased
        }
    }

    private static func normalizeIPv6(_ value: String) -> String? {
        var address = in6_addr()
        guard value.withCString({ inet_pton(AF_INET6, $0, &address) }) == 1 else {
            return nil
        }
        let bytes = withUnsafeBytes(of: &address) { Array($0) }.map { UInt8($0) }
        guard bytes.count == 16 else { return nil }
        var groups: [UInt16] = []
        for index in stride(from: 0, to: 16, by: 2) {
            groups.append(UInt16(bytes[index]) << 8 | UInt16(bytes[index + 1]))
        }

        // WHATWG serializes IPv6 with the first longest zero run compressed;
        // serializing the bytes as eight hex groups also converts embedded
        // IPv4 notation to the same hexadecimal tail used by new URL().
        var bestStart = -1
        var bestLength = 1
        var currentStart = 0
        var currentLength = 0
        for index in 0...groups.count {
            if index < groups.count, groups[index] == 0 {
                if currentLength == 0 { currentStart = index }
                currentLength += 1
            } else {
                if currentLength > bestLength {
                    bestStart = currentStart
                    bestLength = currentLength
                }
                currentLength = 0
            }
        }

        if bestStart >= 0 {
            let before = groups[..<bestStart].map { String($0, radix: 16) }
            let afterStart = bestStart + bestLength
            let after = groups[afterStart...].map { String($0, radix: 16) }
            if before.isEmpty && after.isEmpty { return "::" }
            if before.isEmpty { return "::" + after.joined(separator: ":") }
            if after.isEmpty { return before.joined(separator: ":") + "::" }
            return before.joined(separator: ":") + "::" + after.joined(separator: ":")
        }
        return groups.map { String($0, radix: 16) }.joined(separator: ":")
    }

    private static func isUnsafeHostScalar(_ scalar: UnicodeScalar) -> Bool {
        scalar.value <= 0x20
            || scalar.value == 0x7F
            || scalar.value == 0x2F
            || scalar.value == 0x5C
    }

    private enum IPv4Normalization {
        case valid(String)
        case invalid
        case notAnIPv4Candidate
    }

    private static func normalizeIPv4Host(_ host: String) -> IPv4Normalization {
        var parts = host.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        // WHATWG permits one terminal dot while parsing an IPv4 candidate,
        // then emits the four-octet form without that dot. Empty interior
        // segments remain invalid; they must not silently become zero.
        if parts.last == "" {
            parts.removeLast()
        }
        guard let last = parts.last else { return .notAnIPv4Candidate }
        let lastIsDecimal = !last.isEmpty && last.unicodeScalars.allSatisfy(isASCIIDigit)
        let lastIsHex = last.count >= 2
            && (last.hasPrefix("0x") || last.hasPrefix("0X"))
            && last.dropFirst(2).unicodeScalars.allSatisfy(isASCIIHexDigit)
        guard lastIsDecimal || lastIsHex else { return .notAnIPv4Candidate }
        guard (1...4).contains(parts.count) else { return .invalid }

        var values: [UInt64] = []
        for (index, part) in parts.enumerated() {
            guard !part.isEmpty else { return .invalid }
            let isLast = index == parts.count - 1
            let (digits, radix): (String, Int)
            if part.hasPrefix("0x") || part.hasPrefix("0X") {
                digits = String(part.dropFirst(2))
                radix = 16
            } else if part.count > 1 && part.hasPrefix("0") {
                digits = String(part.dropFirst())
                radix = 8
            } else {
                digits = part
                radix = 10
            }

            let value: UInt64
            if digits.isEmpty {
                value = 0
            } else if let parsed = UInt64(digits, radix: radix) {
                value = parsed
            } else {
                return .invalid
            }
            let maximum = isLast ? (UInt64(1) << (8 * (5 - parts.count))) - 1 : 255
            guard value <= maximum else { return .invalid }
            values.append(value)
        }

        var octets = Array(repeating: UInt64(0), count: 4)
        for index in 0..<(parts.count - 1) {
            octets[index] = values[index]
        }
        let lastValue = values[values.count - 1]
        let remainingOctets = 5 - parts.count
        for index in 0..<remainingOctets {
            let shift = 8 * (remainingOctets - index - 1)
            octets[parts.count - 1 + index] = (lastValue >> shift) & 255
        }
        return .valid(octets.map(String.init).joined(separator: "."))
    }

    private static func isASCIIDigit(_ scalar: UnicodeScalar) -> Bool {
        (0x30...0x39).contains(scalar.value)
    }

    private static func isASCIIHexDigit(_ scalar: UnicodeScalar) -> Bool {
        isASCIIDigit(scalar)
            || (0x61...0x66).contains(scalar.value)
            || (0x41...0x46).contains(scalar.value)
    }

    private static func normalizePath(_ path: String) -> String {
        guard !path.isEmpty else { return "" }

        // Keep repeated separators and percent-encoded bytes intact while
        // applying the URL standard's literal and percent-encoded dot segments.
        var segments: [String] = []
        for segment in path.split(separator: "/", omittingEmptySubsequences: false).map(String.init) {
            // WHATWG treats these case-insensitive spellings as dot segments;
            // decoding the whole path would incorrectly turn `%2f` into `/`.
            switch segment.lowercased() {
            case ".", "%2e":
                continue
            case "..", ".%2e", "%2e.", "%2e%2e":
                if segments.count > 1 {
                    segments.removeLast()
                }
            default:
                segments.append(segment)
            }
        }
        guard !segments.isEmpty else { return "" }
        var normalized = segments.joined(separator: "/")
        if !normalized.hasPrefix("/") { normalized = "/" + normalized }
        return normalized
    }
}

private struct URLAuthority {
    let hasExplicitPort: Bool
    let port: Int?

    init?(url: URL) {
        let absolute = url.absoluteString
        guard let schemeSeparator = absolute.range(of: "://") else { return nil }
        let authorityStart = schemeSeparator.upperBound
        let authorityEnd = absolute[authorityStart...].firstIndex(of: "/") ?? absolute.endIndex
        let authority = String(absolute[authorityStart..<authorityEnd])
        guard !authority.isEmpty else { return nil }

        if authority.first == "[" {
            guard let closingBracket = authority.firstIndex(of: "]") else { return nil }
            let suffix = authority[authority.index(after: closingBracket)...]
            guard !suffix.contains(where: { $0 != ":" && !$0.isNumber }) else { return nil }
            if suffix.isEmpty {
                self.hasExplicitPort = false
                self.port = nil
            } else {
                guard suffix.first == ":" else { return nil }
                self.hasExplicitPort = true
                self.port = Self.parsePort(String(suffix.dropFirst()))
                guard suffix.dropFirst().isEmpty || self.port != nil else { return nil }
            }
            return
        }

        if let separator = authority.lastIndex(of: ":") {
            // Foundation exposes the numeric port but preserves leading zeroes
            // in URL.absoluteString; split at the final colon so the rebuilt
            // authority uses the same canonical numeric port as WHATWG.
            self.hasExplicitPort = true
            self.port = Self.parsePort(String(authority[authority.index(after: separator)...]))
            guard authority[authority.index(after: separator)...].isEmpty || self.port != nil else {
                return nil
            }
        } else {
            self.hasExplicitPort = false
            self.port = nil
        }
    }

    private static func parsePort(_ value: String) -> Int? {
        guard !value.isEmpty,
              value.unicodeScalars.allSatisfy({ (0x30...0x39).contains($0.value) }),
              let number = UInt64(value, radix: 10),
              number <= 65_535 else {
            return nil
        }
        return Int(number)
    }
}

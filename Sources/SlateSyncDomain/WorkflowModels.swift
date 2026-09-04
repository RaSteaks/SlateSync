import Foundation

public enum ResolveCSVEncoding: String, Codable, Hashable, Sendable {
    case utf8 = "utf-8"
    case utf16LittleEndian = "utf-16le"
    case utf16BigEndian = "utf-16be"
}

public struct ResolveCSVFormat: Codable, Hashable, Sendable {
    public var encoding: ResolveCSVEncoding
    public var bom: Bool
    public var delimiter: Character
    public var lineEnding: String
    public var finalNewline: Bool

    public init(
        encoding: ResolveCSVEncoding = .utf8,
        bom: Bool = false,
        delimiter: Character = ",",
        lineEnding: String = "\r\n",
        finalNewline: Bool = true
    ) {
        self.encoding = encoding
        self.bom = bom
        self.delimiter = delimiter
        self.lineEnding = lineEnding
        self.finalNewline = finalNewline
    }

    private enum CodingKeys: String, CodingKey {
        case encoding
        case bom
        case delimiter
        case lineEnding
        case newline
        case finalNewline
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        encoding = try values.decodeIfPresent(ResolveCSVEncoding.self, forKey: .encoding) ?? .utf8
        bom = try values.decodeIfPresent(Bool.self, forKey: .bom) ?? false
        let delimiterValue = try values.decodeIfPresent(String.self, forKey: .delimiter) ?? ","
        guard delimiterValue.count == 1, let delimiter = delimiterValue.first else {
            throw DecodingError.dataCorruptedError(
                forKey: .delimiter,
                in: values,
                debugDescription: "CSV delimiter must contain exactly one character."
            )
        }
        self.delimiter = delimiter
        // `newline` was the field name in early snapshots; prefer the
        // canonical key while retaining those snapshots on decode.
        if let canonicalLineEnding = try values.decodeIfPresent(String.self, forKey: .lineEnding) {
            lineEnding = canonicalLineEnding
        } else if let legacyLineEnding = try values.decodeIfPresent(String.self, forKey: .newline) {
            lineEnding = legacyLineEnding
        } else {
            lineEnding = "\r\n"
        }
        finalNewline = try values.decodeIfPresent(Bool.self, forKey: .finalNewline) ?? true
        try validate()
    }

    public func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(encoding, forKey: .encoding)
        try values.encode(bom, forKey: .bom)
        // Persisting as a one-character string preserves the existing JSON contract.
        try values.encode(String(delimiter), forKey: .delimiter)
        try values.encode(lineEnding, forKey: .lineEnding)
        try values.encode(finalNewline, forKey: .finalNewline)
    }

    /// Resolve detection emits comma, semicolon or tab plus the three legacy
    /// line endings. Reject structural characters before they can corrupt rows.
    public func validate() throws {
        guard [",", ";", "\t"].contains(delimiter) else {
            throw SlateSyncError(code: "CSV_FORMAT_INVALID", message: "CSV 分隔符无效")
        }
        guard ["\r\n", "\n", "\r"].contains(lineEnding) else {
            throw SlateSyncError(code: "CSV_FORMAT_INVALID", message: "CSV 换行符无效")
        }
    }
}

public struct ResolveCSVTable: Codable, Hashable, Sendable {
    public var headers: [String]
    public var rows: [[String]]
    public var format: ResolveCSVFormat

    public init(headers: [String], rows: [[String]], format: ResolveCSVFormat) {
        self.headers = headers
        self.rows = rows
        self.format = format
    }
}

public struct OCRBlock: Codable, Hashable, Sendable {
    public var text: String
    public var confidence: Double
    public var boundingBox: CGRectValue

    public init(text: String, confidence: Double, boundingBox: CGRectValue) {
        self.text = text
        self.confidence = confidence
        self.boundingBox = boundingBox
    }
}

/// Codable rectangle avoids leaking CoreGraphics into persisted domain models.
public struct CGRectValue: Codable, Hashable, Sendable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }
}

public struct OCRPageResult: Codable, Hashable, Sendable {
    public var page: Int
    public var blocks: [OCRBlock]

    public init(page: Int, blocks: [OCRBlock]) {
        self.page = page
        self.blocks = blocks
    }
}

public struct RecognitionProgress: Codable, Hashable, Sendable {
    public var phase: String
    public var completed: Int
    public var total: Int
    public var message: String

    public init(phase: String, completed: Int, total: Int, message: String) {
        self.phase = phase
        self.completed = completed
        self.total = total
        self.message = message
    }
}

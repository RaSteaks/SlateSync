import Foundation

/// A bounded, typed representation for untrusted JSON at compatibility
/// boundaries. Known application contracts use concrete structs; this value is
/// reserved for unknown fields and diagnostic metadata that must be inspected
/// without falling back to `[String: Any]`.
public indirect enum JSONValue: Codable, Hashable, Sendable {
    case null
    case boolean(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public init(from decoder: any Decoder) throws {
        let values = try decoder.singleValueContainer()
        if values.decodeNil() {
            self = .null
        } else if let value = try? values.decode(Bool.self) {
            self = .boolean(value)
        } else if let value = try? values.decode(Double.self) {
            self = .number(value)
        } else if let value = try? values.decode(String.self) {
            self = .string(value)
        } else if let value = try? values.decode([JSONValue].self) {
            self = .array(value)
        } else if let value = try? values.decode([String: JSONValue].self) {
            self = .object(value)
        } else {
            throw DecodingError.dataCorruptedError(
                in: values,
                debugDescription: "无法解析 JSON 值"
            )
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var values = encoder.singleValueContainer()
        switch self {
        case .null:
            try values.encodeNil()
        case .boolean(let value):
            try values.encode(value)
        case .number(let value):
            try values.encode(value)
        case .string(let value):
            try values.encode(value)
        case .array(let value):
            try values.encode(value)
        case .object(let value):
            try values.encode(value)
        }
    }
}

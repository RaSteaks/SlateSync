import Foundation
import MCP
import SlateSyncDomain

/// The SDK dispatches JSON-RPC but does not enforce tool input schemas.
/// Validate the catalog's supported schema subset before any filesystem/API work.
enum MCPArguments {
    static func validate(_ value: Value, schema: Value, path: String = "arguments") throws {
        guard case .object(let rules) = schema else { return }
        if case .array(let values)? = rules["enum"], !values.contains(value) { throw invalid(path) }
        let types: [String]
        switch rules["type"] {
        case .string(let type): types = [type]
        case .array(let array): types = array.compactMap(\.stringValue)
        default: types = []
        }
        if !types.isEmpty {
            let actual: String
            switch value {
            case .object: actual = "object"
            case .array: actual = "array"
            case .string: actual = "string"
            case .int: actual = "integer"
            case .double: actual = "number"
            case .bool: actual = "boolean"
            case .null: actual = "null"
            case .data: actual = "data"
            }
            guard types.contains(actual) else { throw invalid(path) }
        }
        if case .object(let fields) = value {
            let properties = rules["properties"]?.objectValue ?? [:]
            for name in rules["required"]?.arrayValue?.compactMap(\.stringValue) ?? [] where fields[name] == nil {
                throw invalid(path + "." + name)
            }
            for (name, child) in fields {
                guard let childSchema = properties[name] else {
                    if rules["additionalProperties"] == false { throw invalid(path + "." + name) }
                    continue
                }
                try validate(child, schema: childSchema, path: path + "." + name)
            }
        }
        if case .array(let items) = value {
            if let maximum = rules["maxItems"]?.intValue, items.count > maximum { throw invalid(path) }
            if let itemSchema = rules["items"] { for item in items { try validate(item, schema: itemSchema, path: path + "[]") } }
        }
        if case .int(let number) = value {
            if let minimum = rules["minimum"]?.intValue, number < minimum { throw invalid(path) }
            if let maximum = rules["maximum"]?.intValue, number > maximum { throw invalid(path) }
        }
    }

    static func decode<T: Decodable>(_ type: T.Type, from value: Value) throws -> T {
        do { return try JSONDecoder().decode(type, from: JSONEncoder().encode(value)) }
        catch { throw invalid("arguments") }
    }

    static func invalid(_ path: String) -> MCPError { .invalidParams("Invalid or missing \(path). See tools/list for the input schema.") }
}

/// Optional markers default to empty at the protocol boundary without
/// weakening the app's persisted domain contract or accepting arbitrary fields.
struct MCPRecord: Decodable, Sendable {
    let cardNumber: String?
    let videoCode: String?
    let scene: String?
    let shot: String?
    let take: String?
    let takeStatus: TakeStatus?
    let goodTake: Bool?
    let comments: String?
    let reviewRequiredFields: [String]?
    var record: ResolveSlateRecord {
        .init(cardNumber: cardNumber, videoCode: videoCode, scene: scene, shot: shot, take: take,
              takeStatus: takeStatus, goodTake: goodTake, comments: comments, reviewRequiredFields: reviewRequiredFields ?? [])
    }
}

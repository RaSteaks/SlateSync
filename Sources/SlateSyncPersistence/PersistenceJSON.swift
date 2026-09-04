import CryptoKit
import Foundation
import SlateSyncDomain

enum PersistenceJSON {
    static func object(from data: Data, errorCode: String) throws -> [String: Any] {
        let value: Any
        do {
            value = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw SlateSyncError(code: errorCode, message: "持久化 JSON 无效")
        }
        guard let object = value as? [String: Any] else {
            throw SlateSyncError(code: errorCode, message: "持久化 JSON 必须是对象")
        }
        return object
    }

    static func data(from object: [String: Any], errorCode: String) throws -> Data {
        do {
            // Sorted keys make native snapshots deterministic; compatibility is
            // semantic because Electron's JSON.stringify order was never a byte
            // contract for task or diagnostic snapshots.
            return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        } catch {
            throw SlateSyncError(code: errorCode, message: "无法编码持久化 JSON")
        }
    }

    static func data(from string: String, errorCode: String) throws -> Data {
        guard let data = string.data(using: .utf8) else {
            throw SlateSyncError(code: errorCode, message: "持久化 JSON 不是 UTF-8")
        }
        return data
    }

    static func string(from data: Data, errorCode: String) throws -> String {
        guard let value = String(data: data, encoding: .utf8) else {
            throw SlateSyncError(code: errorCode, message: "持久化 JSON 不是 UTF-8")
        }
        return value
    }

    static func string(_ value: Any?) -> String? {
        value as? String
    }

    static func int(_ value: Any?) -> Int? {
        if let value = value as? Int { return value }
        if let value = value as? NSNumber { return value.intValue }
        return nil
    }

    static func sha256Prefix(_ value: String, count: Int) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }
            .joined()
            .prefix(count)
            .description
    }

    static func timestamp(_ date: Date = Date()) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }
}

enum PersistenceIdentifiers {
    static func task(_ value: String) throws -> String {
        guard value.range(of: #"^[a-zA-Z0-9_-]+$"#, options: .regularExpression) != nil else {
            throw SlateSyncError(code: "TASK_ID_INVALID", message: "无效任务 ID")
        }
        return value
    }

    static func diagnostic(_ value: String) throws -> String {
        guard value.range(of: #"^[a-zA-Z0-9_-]+$"#, options: .regularExpression) != nil else {
            throw SlateSyncError(code: "DIAGNOSTIC_ID_INVALID", message: "无效诊断会话 ID")
        }
        return value
    }

    static func project(_ value: String) throws -> String {
        guard value.range(of: #"^project-[a-zA-Z0-9_-]+$"#, options: .regularExpression) != nil else {
            throw SlateSyncError(code: "PROJECT_ID_INVALID", message: "无效项目 ID")
        }
        return value
    }

    static func scenario(_ value: String) throws -> String {
        guard value.range(of: #"^scenario-[a-f0-9]{16}$"#, options: .regularExpression) != nil else {
            throw SlateSyncError(code: "SCENARIO_ID_INVALID", message: "无效场记结构 ID")
        }
        return value
    }
}

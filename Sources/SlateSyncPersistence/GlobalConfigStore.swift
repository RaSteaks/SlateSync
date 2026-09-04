import Foundation
import SlateSyncDomain

public struct GlobalConfigSnapshot: Codable, Hashable, Sendable {
    public let version: Int
    public let values: GlobalSettingValues
    public let customProviders: [CustomProviderConfiguration]

    public init(
        version: Int = 2,
        values: GlobalSettingValues = .init(),
        customProviders: [CustomProviderConfiguration] = []
    ) {
        self.version = version
        self.values = values
        self.customProviders = customProviders
    }
}

/// Atomic, versioned machine-level storage for non-secret global overrides.
/// The custom-provider array is retained as typed non-secret data so a native
/// settings write cannot erase records owned by a later migration phase.
public actor GlobalConfigStore {
    public static let currentVersion = 2

    public nonisolated let fileURL: URL

    private let writer: any AtomicFileWriting
    private var cached: GlobalConfigSnapshot?

    public init(
        applicationSupportRoot: URL,
        writer: any AtomicFileWriting = FileManagerAtomicFileWriter()
    ) {
        fileURL = applicationSupportRoot.appending(path: "global-config.json")
        self.writer = writer
    }

    public init(
        locator: ApplicationSupportLocator,
        writer: any AtomicFileWriting = FileManagerAtomicFileWriter()
    ) {
        self.init(applicationSupportRoot: locator.url, writer: writer)
    }

    public func load() throws -> GlobalConfigSnapshot {
        let snapshot = try readSnapshot()
        cached = snapshot
        return snapshot
    }

    @discardableResult
    public func save(_ patch: GlobalSettingsPatch) throws -> GlobalConfigSnapshot {
        let current: GlobalConfigSnapshot
        if let cached {
            current = cached
        } else {
            current = try readSnapshot()
        }
        let routedPatch = GlobalSettingsValidator.normalizeOcrRoutingPatch(patch)
        var rawValues = current.values.rawValues
        for (key, value) in routedPatch.rawValues {
            if let value, !value.isEmpty {
                rawValues[key] = value
            } else {
                rawValues.removeValue(forKey: key)
            }
        }
        return try publish(
            values: GlobalSettingsValidator.sanitize(rawValues),
            customProviders: current.customProviders
        )
    }

    /// Convenience for an IPC-shaped raw patch, including explicit nulls.
    @discardableResult
    public func save(rawValues: [String: String?]) throws -> GlobalConfigSnapshot {
        try save(GlobalSettingsPatch(rawValues: rawValues))
    }

    /// Values-only writes preserve custom-provider records, matching the v2
    /// Electron store's backwards-compatible save(values) behavior.
    @discardableResult
    public func save(values: [GlobalSettingKey: String]) throws -> GlobalConfigSnapshot {
        let current: GlobalConfigSnapshot
        if let cached {
            current = cached
        } else {
            current = try readSnapshot()
        }
        return try publish(
            values: GlobalSettingsValidator.sanitize(
                Dictionary(uniqueKeysWithValues: values.map { ($0.rawValue, $1) })
            ),
            customProviders: current.customProviders
        )
    }

    @discardableResult
    public func save(
        values: [GlobalSettingKey: String],
        customProviders: [CustomProviderConfiguration]
    ) throws -> GlobalConfigSnapshot {
        let normalizedProviders = try Self.validateProviders(customProviders)
        return try publish(
            values: GlobalSettingsValidator.sanitize(
                Dictionary(uniqueKeysWithValues: values.map { ($0.rawValue, $1) })
            ),
            customProviders: normalizedProviders
        )
    }

    @discardableResult
    public func reset() throws -> GlobalConfigSnapshot {
        let current: GlobalConfigSnapshot
        if let cached {
            current = cached
        } else {
            current = try readSnapshot()
        }
        return try publish(values: .init(), customProviders: current.customProviders)
    }

    private func publish(
        values: GlobalSettingValues,
        customProviders: [CustomProviderConfiguration]
    ) throws -> GlobalConfigSnapshot {
        let snapshot = GlobalConfigSnapshot(
            version: Self.currentVersion,
            values: values,
            customProviders: customProviders
        )
        let data = try JSONEncoder().encode(snapshot)
        try writer.writeAtomically(data, to: fileURL, permissions: 0o600)
        cached = snapshot
        return snapshot
    }

    private func readSnapshot() throws -> GlobalConfigSnapshot {
        do {
            try SecureFilePermissions.repairDirectory(at: fileURL.deletingLastPathComponent())
            try SecureFilePermissions.repairFile(at: fileURL)
            let data = try Data(contentsOf: fileURL)
            let root = try JSONDecoder().decode(JSONValue.self, from: data)
            guard case .object(let object) = root else { return GlobalConfigSnapshot() }

            // v1 files were either `{ values: ... }` or a direct values object.
            let valuesObject: [String: JSONValue]
            if case .object(let nested)? = object["values"] {
                valuesObject = nested
            } else {
                valuesObject = object
            }
            let rawValues: [String: String] = Dictionary(uniqueKeysWithValues: valuesObject.compactMap { key, value in
                guard case .string(let string) = value else { return nil }
                return (key, string)
            })
            let customProviders = decodeProviders(object["customProviders"])
            return GlobalConfigSnapshot(
                version: Self.currentVersion,
                values: GlobalSettingsValidator.sanitize(rawValues),
                customProviders: customProviders
            )
        } catch let error as SlateSyncError where error.code == "PERSISTENCE_PERMISSIONS" {
            // Global config contains no credential material. A permissions
            // repair failure therefore falls back to defaults instead of
            // blocking startup; secret-bearing legacy files remain fail-closed.
            return GlobalConfigSnapshot()
        } catch {
            // Corrupt global config must never prevent startup and must not be
            // re-published until a valid replacement is explicitly saved.
            return GlobalConfigSnapshot()
        }
    }

    private func decodeProviders(_ value: JSONValue?) -> [CustomProviderConfiguration] {
        guard case .array(let values) = value else { return [] }
        let decoder = JSONDecoder()
        var result: [CustomProviderConfiguration] = []
        var ids = Set<String>()
        var names = Set<String>()
        for value in values {
            guard let data = try? JSONEncoder().encode(value),
                  let provider = try? decoder.decode(CustomProviderConfiguration.self, from: data) else {
                continue
            }
            let nameKey = provider.name.lowercased()
            guard ids.insert(provider.id).inserted, names.insert(nameKey).inserted else { continue }
            result.append(provider)
        }
        return result
    }

    private static func validateProviders(
        _ providers: [CustomProviderConfiguration]
    ) throws -> [CustomProviderConfiguration] {
        var ids = Set<String>()
        var names = Set<String>()
        var normalizedProviders: [CustomProviderConfiguration] = []
        for provider in providers {
            let normalized = try CustomProviderValidator.normalize(provider)
            let nameKey = normalized.name.lowercased()
            guard ids.insert(normalized.id).inserted,
                  names.insert(nameKey).inserted else {
                throw SlateSyncError(code: "CUSTOM_PROVIDER_INVALID", message: "接口 ID 或名称重复")
            }
            normalizedProviders.append(normalized)
        }
        return normalizedProviders
    }
}

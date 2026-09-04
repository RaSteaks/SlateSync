import Foundation
import SlateSyncDomain

public typealias ConfigurationValueSource = GlobalSettingValueSource

public struct ConfigurationValue: Codable, Hashable, Sendable {
    public let value: String
    public let source: ConfigurationValueSource

    public init(value: String, source: ConfigurationValueSource) {
        self.value = value
        self.source = source
    }
}

public struct ResolvedConfiguration: Codable, Hashable, Sendable {
    public let values: GlobalSettingValues
    public let sources: [GlobalSettingKey: ConfigurationValueSource]

    public init(values: GlobalSettingValues, sources: [GlobalSettingKey: ConfigurationValueSource]) {
        self.values = values
        self.sources = sources
    }
}

/// Resolves the same machine-level precedence as the existing Main process.
/// The process map is intentionally passed in, which keeps tests away from
/// `ProcessInfo` and makes explicit call-site overrides observable.
public enum ConfigurationResolver {
    public static func resolve(
        key: GlobalSettingKey,
        explicit: GlobalSettingValues = .init(),
        globalSettings: GlobalSettingValues = .init(),
        processEnvironment: [String: String] = [:],
        envFile: [String: String] = [:],
        legacySettings: MachineSettings? = nil,
        applicationSupportRoot: URL? = nil
    ) -> ConfigurationValue {
        let resolved = GlobalSettingsResolution.resolve(
            key: key,
            processEnvironment: processEnvironment,
            envFile: envFile,
            globalOverrides: globalSettings,
            explicit: explicit,
            legacyPaddlePythonPath: legacySettings?.ocrPythonPath,
            applicationSupportRoot: applicationSupportRoot
        )
        return ConfigurationValue(value: resolved.value, source: resolved.source)
    }

    public static func resolveAll(
        explicit: GlobalSettingValues = .init(),
        globalSettings: GlobalSettingValues = .init(),
        processEnvironment: [String: String] = [:],
        envFile: [String: String] = [:],
        legacySettings: MachineSettings? = nil,
        applicationSupportRoot: URL? = nil
    ) -> ResolvedConfiguration {
        // Resolve the complete map through the domain implementation in one
        // pass. Persistence owns the adapter type, while precedence,
        // normalization, empty-value masking, and dynamic defaults have one
        // executable source of truth.
        let resolved = GlobalSettingsResolution.resolveAll(
            processEnvironment: processEnvironment,
            envFile: envFile,
            globalOverrides: globalSettings,
            explicit: explicit,
            legacyPaddlePythonPath: legacySettings?.ocrPythonPath,
            applicationSupportRoot: applicationSupportRoot
        )
        let values = resolved.reduce(into: [GlobalSettingKey: String]()) { result, entry in
            result[entry.key] = entry.value.value
        }
        let sources = resolved.reduce(into: [GlobalSettingKey: ConfigurationValueSource]()) { result, entry in
            result[entry.key] = entry.value.source
        }
        return ResolvedConfiguration(values: .init(values), sources: sources)
    }

    public static func settingsData(
        globalSettings: GlobalSettingValues,
        processEnvironment: [String: String] = [:],
        envFile: [String: String] = [:],
        legacySettings: MachineSettings? = nil,
        keyConfigured: [String: Bool] = [:],
        restartRequired: Bool = false,
        customProviders: [CustomProviderSummary]? = nil,
        applicationSupportRoot: URL? = nil
    ) -> GlobalSettingsData {
        let resolved = resolveAll(
            globalSettings: globalSettings,
            processEnvironment: processEnvironment,
            envFile: envFile,
            legacySettings: legacySettings,
            applicationSupportRoot: applicationSupportRoot
        )
        return GlobalSettingsData(
            values: resolved.values,
            overrides: GlobalSettingsValidator.overrides(in: globalSettings),
            keyConfigured: keyConfigured,
            restartRequired: restartRequired,
            customProviders: customProviders
        )
    }

}

public enum EnvironmentFileLoader {
    public static func parse(_ contents: String) -> [String: String] {
        var values: [String: String] = [:]
        // JavaScript splits on LF with an optional CR at the end of each
        // record. Foundation's .newlines also splits lone CR, which changes a
        // value containing that character into multiple assignments.
        // `Character` treats CRLF as one grapheme, so String.split(separator:
        // "\n") would not split a Windows line ending on current Swift.
        for rawLine in contents.components(separatedBy: "\n") {
            let lineWithOptionalCR = rawLine.last == "\r"
                ? String(rawLine.dropLast())
                : rawLine
            let line = lineWithOptionalCR.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty, !line.hasPrefix("#"), let separator = line.firstIndex(of: "=") else {
                continue
            }
            let key = String(line[..<separator]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty else { continue }
            var value = String(line[line.index(after: separator)...]).trimmingCharacters(in: .whitespacesAndNewlines)
            if value.count >= 2,
               (value.first == "\"" && value.last == "\"") || (value.first == "'" && value.last == "'") {
                value.removeFirst()
                value.removeLast()
            }
            // Electron's loadLocalEnv keeps the first occurrence and never
            // lets a later duplicate silently replace the startup value.
            if values[key] == nil {
                values[key] = value
            }
        }
        return values
    }

    public static func load(from url: URL) throws -> [String: String] {
        do {
            let data = try Data(contentsOf: url)
            guard let contents = String(data: data, encoding: .utf8) else {
                throw SlateSyncError(code: "ENV_INVALID", message: "无法读取环境配置文件")
            }
            return parse(contents)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile {
            // Data(contentsOf:) reports a missing path as fileReadNoSuchFile
            // (260) on macOS; Electron's ENOENT path resolves to an empty
            // environment map, so a first-run install must do the same.
            return [:]
        }
    }
}

public enum WorkflowConfigLoader {
    public static func load(from url: URL) throws -> WorkflowConfig {
        let data = try Data(contentsOf: url)
        let withoutBOM = data.starts(with: [0xEF, 0xBB, 0xBF]) ? data.dropFirst(3) : data[...]
        do {
            let config = try JSONDecoder().decode(WorkflowConfig.self, from: Data(withoutBOM))
            try config.validate()
            return config
        } catch let error as SlateSyncError {
            throw error
        } catch {
            throw SlateSyncError(code: "CONFIG_INVALID", message: "无法读取 SlateSync 配置文件")
        }
    }
}

/// The provider mirrors the hot-reload behavior used by Electron: an invalid
/// edit keeps the last valid snapshot, while an invalid first read is exposed.
public actor WorkflowConfigProvider {
    private let url: URL
    private var signature: String?
    private var cached: WorkflowConfig?

    public init(url: URL) {
        self.url = url
    }

    public func current() throws -> WorkflowConfig {
        let nextSignature: String
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            let modified = (attributes[.modificationDate] as? Date)?.timeIntervalSinceReferenceDate ?? 0
            let size = (attributes[.size] as? NSNumber)?.int64Value ?? 0
            nextSignature = "\(modified):\(size)"
        } catch {
            if let cached { return cached }
            throw SlateSyncError(code: "CONFIG_MISSING", message: "找不到 SlateSync 配置文件")
        }

        if signature == nextSignature, let cached { return cached }
        do {
            let config = try WorkflowConfigLoader.load(from: url)
            signature = nextSignature
            cached = config
            return config
        } catch {
            if let cached { return cached }
            throw error
        }
    }
}

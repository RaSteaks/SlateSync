import Foundation
import SlateSyncDomain

/// Legacy machine-local settings retained for compatibility with the Electron
/// first-run OCR flow. Project content and provider keys never belong here.
public struct MachineSettings: Codable, Hashable, Sendable {
    public var libraryPath: String
    public var ocrPythonPath: String
    public var ocrSetupCompleted: Bool
    public var ocrSetupSkipped: Bool

    public init(
        libraryPath: String = "",
        ocrPythonPath: String = "",
        ocrSetupCompleted: Bool = false,
        ocrSetupSkipped: Bool = false
    ) {
        self.libraryPath = libraryPath
        self.ocrPythonPath = ocrPythonPath
        self.ocrSetupCompleted = ocrSetupCompleted
        self.ocrSetupSkipped = ocrSetupSkipped
    }
}

public actor MachineSettingsStore {
    public nonisolated let fileURL: URL

    private let writer: any AtomicFileWriting

    public init(
        applicationSupportRoot: URL,
        writer: any AtomicFileWriting = FileManagerAtomicFileWriter()
    ) {
        fileURL = applicationSupportRoot.appending(path: "settings.json")
        self.writer = writer
    }

    public init(
        locator: ApplicationSupportLocator,
        writer: any AtomicFileWriting = FileManagerAtomicFileWriter()
    ) {
        self.init(applicationSupportRoot: locator.url, writer: writer)
    }

    public func load() throws -> MachineSettings {
        do {
            try SecureFilePermissions.repairDirectory(at: fileURL.deletingLastPathComponent())
            try SecureFilePermissions.repairFile(at: fileURL)
            let data = try Data(contentsOf: fileURL)
            let value = try JSONDecoder().decode(JSONValue.self, from: data)
            return Self.decodeTolerant(value)
        } catch let error as SlateSyncError where error.code == "PERSISTENCE_PERMISSIONS" {
            // Machine settings are non-secret. If an old installation cannot
            // be repaired, ignore it and use safe defaults; startup remains
            // available while the next explicit save can retry protection.
            return MachineSettings()
        } catch {
            // Existing Electron behavior falls back to defaults for missing,
            // malformed, or partially incompatible settings files.
            return MachineSettings()
        }
    }

    @discardableResult
    public func save(_ settings: MachineSettings) throws -> MachineSettings {
        let data = try JSONEncoder().encode(settings)
        try writer.writeAtomically(data, to: fileURL, permissions: 0o600)
        return settings
    }

    private static func decodeTolerant(_ value: JSONValue) -> MachineSettings {
        guard case .object(let object) = value else { return MachineSettings() }
        return MachineSettings(
            libraryPath: string(object["libraryPath"]) ?? "",
            ocrPythonPath: string(object["ocrPythonPath"]) ?? "",
            ocrSetupCompleted: boolean(object["ocrSetupCompleted"]) ?? false,
            ocrSetupSkipped: boolean(object["ocrSetupSkipped"]) ?? false
        )
    }

    private static func string(_ value: JSONValue?) -> String? {
        guard case .string(let value) = value else { return nil }
        return value
    }

    private static func boolean(_ value: JSONValue?) -> Bool? {
        guard case .boolean(let value) = value else { return nil }
        return value
    }
}

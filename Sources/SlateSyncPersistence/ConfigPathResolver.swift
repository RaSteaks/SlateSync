import Foundation
import SlateSyncDomain

/// Platform anchors for the workflow-config resolution rules. Production
/// mirrors the old packaged branch (`process.resourcesPath/app` becomes the
/// native bundle resource root), while development anchors at the launch
/// working directory — the native analogue of the old Electron dev project
/// root. Tests inject explicit values instead of depending on either anchor.
public struct WorkflowConfigPathEnvironment: Sendable {
    public let isPackaged: Bool
    public let developmentRoot: URL
    public let bundledResourceURL: URL?

    public init(isPackaged: Bool, developmentRoot: URL, bundledResourceURL: URL?) {
        self.isPackaged = isPackaged
        self.developmentRoot = developmentRoot
        self.bundledResourceURL = bundledResourceURL
    }

    public static func live(bundle: Bundle = .main) -> Self {
        Self(
            isPackaged: bundle.bundleURL.pathExtension == "app",
            developmentRoot: URL(
                fileURLWithPath: FileManager.default.currentDirectoryPath,
                isDirectory: true
            ),
            bundledResourceURL: bundle.resourceURL
        )
    }
}

/// Single home for every config-path policy shared by `GlobalConfigStore` and
/// `SlateSyncRuntime`. The workflow rules freeze the retained Electron
/// startup (old `electron/main.mjs`): a packaged app reads the bundled
/// `slatesync.config.json` and ignores the setting, while development
/// resolves the effective `SLATESYNC_CONFIG_PATH` against the project root
/// with `path.resolve` semantics — absolute values win, relative values
/// normalize (including `..`), and an empty value falls back to the default
/// file name.
public enum ConfigPathResolver {
    /// Machine-level non-secret overrides stay beside settings.json under
    /// Application Support, never inside a Project Library or the repository.
    public static func globalConfigFileURL(applicationSupportRoot: URL) -> URL {
        applicationSupportRoot.appending(path: "global-config.json")
    }

    public static func workflowConfigURL(
        configured: String?,
        environment: WorkflowConfigPathEnvironment
    ) -> URL {
        // Packaged rule: the bundled copy is authoritative; a launch-time or
        // persisted setting can never point production at an arbitrary path.
        if environment.isPackaged, let bundled = environment.bundledResourceURL {
            return bundled.appending(path: "slatesync.config.json")
        }
        let value = (configured ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let name = value.isEmpty ? "slatesync.config.json" : value
        if name.hasPrefix("/") {
            return URL(fileURLWithPath: name)
        }
        // Old dev rule: resolve(projectRoot, name) — dot segments normalize
        // lexically against the development root.
        return URL(fileURLWithPath: name, isDirectory: false, relativeTo: environment.developmentRoot)
            .standardizedFileURL
    }
}

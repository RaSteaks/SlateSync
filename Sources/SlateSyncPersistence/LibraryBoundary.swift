import Foundation
import SlateSyncDomain

/// Library filesystem boundary enforcement. The Library root itself is
/// canonicalized — users may legitimately reach it through a symlinked
/// ancestor such as `/tmp` → `/private/tmp` — but every interior path (the
/// Projects root, a project directory, a project database file) must resolve,
/// through any symlinks, back inside that canonical root. Any interior link
/// pointing outside the Library fails closed.
public enum LibraryBoundary {
    /// Resolves every existing component through its symlinks; components
    /// that do not exist yet (a project directory about to be created) keep
    /// the already-resolved ancestor chain and are checked the same way, which
    /// is exactly the "check all parents" requirement for new paths.
    public static func canonicalized(_ url: URL) -> URL {
        url.standardizedFileURL.resolvingSymlinksInPath()
    }

    /// Validates the Library root itself and returns its canonical form for
    /// the interior checks of this open.
    public static func validateRoot(_ root: URL) throws -> URL {
        let canonical = canonicalized(root)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: canonical.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw SlateSyncError(code: "LIBRARY_PATH_INVALID", message: "项目库路径不可用")
        }
        return canonical
    }

    /// Fails closed when `url` — after full symlink resolution — is not
    /// strictly inside the canonical Library root.
    public static func validateInterior(
        _ url: URL,
        canonicalRoot: URL,
        code: String = "PROJECT_PATH_INVALID",
        message: String = "项目路径不在当前 Project Library 中"
    ) throws {
        let boundary = canonicalRoot.standardizedFileURL.path + "/"
        guard canonicalized(url).path.hasPrefix(boundary) else {
            throw SlateSyncError(code: code, message: message)
        }
    }
}

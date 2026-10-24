import Darwin
import Foundation
import SlateSyncDomain

/// Local stdio clients receive only the directories explicitly granted at
/// launch. Descriptor-relative I/O rejects symlink substitutions and exports
/// publish a complete new file without overwriting an existing destination.
public struct MCPFileAccess: Sendable {
    public let roots: [URL]

    public init(roots: [URL]) throws {
        // Service discovery does not require grants. Empty roots deny every
        // file operation while allowing initialize, tools/list and model listing.
        self.roots = try roots.map { root in
            let url = try Self.canonicalURL(root.path)
            guard url.isFileURL, url.path != "/" else { throw Self.failure("MCP_PATH", "Grant a specific directory, not the filesystem root.") }
            let fd = try Self.openDirectory(url)
            close(fd)
            return url
        }
    }

    public func permittedURL(_ path: String) throws -> URL {
        guard path.hasPrefix("/"), !path.utf8.contains(0) else { throw Self.failure("MCP_PATH", "Use an absolute local path.") }
        let url = try Self.canonicalURL(path)
        guard roots.contains(where: { url.path == $0.path || url.path.hasPrefix($0.path + "/") }) else {
            throw Self.failure("MCP_PATH_DENIED", "The path is outside the directories granted at launch.")
        }
        return url
    }

    public func directory(_ path: String) throws -> URL {
        let url = try permittedURL(path)
        let fd = try Self.openDirectory(url)
        close(fd)
        return url
    }

    public func read(_ path: String, maximumBytes: Int) throws -> Data {
        let url = try permittedURL(path)
        let parent = try Self.openDirectory(url.deletingLastPathComponent())
        defer { close(parent) }
        let fd = openat(parent, url.lastPathComponent, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw Self.failure("MCP_READ", "Cannot open the input file.") }
        defer { close(fd) }
        var before = stat()
        guard fstat(fd, &before) == 0, before.st_mode & S_IFMT == S_IFREG else {
            throw Self.failure("MCP_FILE_TYPE", "Input must be a regular file.")
        }
        guard before.st_size <= maximumBytes else { throw Self.failure("MCP_FILE_SIZE", "Input exceeds the operation's file-size limit.") }
        var data = Data(), buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            try Task.checkCancellation()
            let count = Darwin.read(fd, &buffer, min(buffer.count, maximumBytes + 1 - data.count))
            if count < 0, errno == EINTR { continue }
            guard count >= 0 else { throw Self.failure("MCP_READ", "Cannot read the input file.") }
            if count == 0 { break }
            data.append(contentsOf: buffer.prefix(count))
            guard data.count <= maximumBytes else { throw Self.failure("MCP_FILE_SIZE", "Input exceeds the operation's file-size limit.") }
        }
        var after = stat()
        guard fstat(fd, &after) == 0, before.st_size == after.st_size, data.count == after.st_size,
              before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
              before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
              before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec,
              before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec else {
            throw Self.failure("MCP_FILE_CHANGED", "Input changed during reading. Retry with a stable file.")
        }
        return data
    }

    public func writeNew(_ data: Data, path: String) throws -> URL {
        let url = try permittedURL(path)
        let parent = try Self.openDirectory(url.deletingLastPathComponent())
        defer { close(parent) }
        let temporary = ".slatesync-\(UUID().uuidString).tmp"
        let fd = openat(parent, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw Self.failure("MCP_WRITE", "Cannot create an export in the selected directory.") }
        defer { close(fd); unlinkat(parent, temporary, 0) }
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                try Task.checkCancellation()
                let count = Darwin.write(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { throw Self.failure("MCP_WRITE", "Cannot write the export.") }
                offset += count
            }
        }
        guard fsync(fd) == 0 else { throw Self.failure("MCP_WRITE", "Cannot flush the export.") }
        try Task.checkCancellation()
        // linkat publishes atomically and fails if any destination already
        // exists, including symlinks; no check-then-overwrite race is possible.
        guard linkat(parent, temporary, parent, url.lastPathComponent, 0) == 0 else {
            throw Self.failure("MCP_OUTPUT_EXISTS", "Export was not published. Choose a new filename in a writable directory.")
        }
        return url
    }

    private static func openDirectory(_ url: URL) throws -> Int32 {
        var fd = open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard fd >= 0 else { throw failure("MCP_PATH", "Cannot open the directory.") }
        for component in url.pathComponents.dropFirst() {
            let next = openat(fd, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            close(fd)
            guard next >= 0 else { throw failure("MCP_PATH", "Directory is missing, inaccessible, or contains a symbolic link.") }
            fd = next
        }
        return fd
    }

    private static func canonicalURL(_ path: String) throws -> URL {
        // Foundation rewrites macOS /private/var and /private/tmp back to their
        // symlink aliases. POSIX realpath preserves a physical path suitable
        // for the descriptor walk's O_NOFOLLOW checks.
        if let resolved = realpath(path, nil) {
            defer { free(resolved) }
            return URL(fileURLWithPath: String(cString: resolved))
        }
        let target = URL(fileURLWithPath: path).standardizedFileURL
        guard let parent = realpath(target.deletingLastPathComponent().path, nil) else {
            throw failure("MCP_PATH", "The parent directory is missing or inaccessible.")
        }
        defer { free(parent) }
        return URL(fileURLWithPath: String(cString: parent)).appending(path: target.lastPathComponent)
    }

    private static func failure(_ code: String, _ message: String) -> SlateSyncError {
        .init(code: code, message: message)
    }
}

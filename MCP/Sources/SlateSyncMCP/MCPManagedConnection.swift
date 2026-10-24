import Darwin
import Dispatch
import Foundation

/// A private Unix socket joins client stdio to app-owned sessions. The broker
/// never parses MCP, listens on TCP, or lets clients replace its launch grants.
public enum MCPManagedConnection {
    public static func serve(path: String, arguments: [String]) throws {
        let options = try MCPServerOptions(arguments: arguments)
        _ = try MCPFileAccess(roots: options.directories)
        let directory = URL(fileURLWithPath: path).deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var attributes = stat()
        guard lstat(directory.path, &attributes) == 0, attributes.st_uid == getuid(),
              attributes.st_mode & S_IFMT == S_IFDIR, attributes.st_mode & 0o077 == 0 else {
            throw problem("Managed socket directory must be private and owned by the current user.")
        }
        // A separate lock makes stale-socket recovery safe across two app
        // instances. Never unlink a live broker or a non-socket filesystem item.
        let lock = open(directory.appending(path: "service.lock").path, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard lock >= 0 else { throw problem("Cannot open managed service lock.") }
        defer { close(lock) }
        guard flock(lock, LOCK_EX | LOCK_NB) == 0 else { throw problem("A managed MCP service is already running.") }
        if lstat(path, &attributes) == 0 {
            guard attributes.st_uid == getuid(), attributes.st_mode & S_IFMT == S_IFSOCK else {
                throw problem("Refusing to replace an existing non-socket path.")
            }
            let probe = try makeSocket()
            let connected = try withAddress(path) { connect(probe, $0, $1) }
            let connectionError = errno
            close(probe)
            guard connected != 0, connectionError == ECONNREFUSED else { throw problem("Managed socket is already in use.") }
            guard unlink(path) == 0 else { throw problem("Cannot remove stale managed socket.") }
        } else if errno != ENOENT { throw problem("Cannot inspect managed socket.") }

        let listener = try makeSocket()
        defer { close(listener) }
        guard try withAddress(path, { bind(listener, $0, $1) }) == 0 else { throw problem("Cannot bind managed socket.") }
        defer { unlink(path) }
        guard chmod(path, 0o600) == 0, listen(listener, 8) == 0 else { throw problem("Cannot listen on managed socket.") }
        // A dedicated group supports bounded cleanup of this broker's own
        // descendants. Closing the app's control pipe is the normal shutdown.
        if getpgrp() != getpid(), setpgid(0, 0) != 0 { throw problem("Cannot isolate managed process group.") }
        let wake = Pipe()
        let signals = [SIGINT, SIGTERM].map { number -> any DispatchSourceSignal in
            Darwin.signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: .global())
            source.setEventHandler { try? wake.fileHandleForWriting.write(contentsOf: Data([1])) }
            source.resume()
            return source
        }
        defer { signals.forEach { $0.cancel() } }
        var sessions: [Process] = []
        defer {
            // SIGTERM enters MCPServerRunner's cancellation/drain path. Keep
            // accepting disabled until all sessions close, then remove the socket.
            sessions.filter(\.isRunning).forEach { $0.terminate() }
            let deadline = ContinuousClock.now.advanced(by: .seconds(8))
            while sessions.contains(where: \.isRunning), ContinuousClock.now < deadline { usleep(20_000) }
            for session in sessions where session.isRunning { kill(session.processIdentifier, SIGKILL) }
            sessions.forEach { $0.waitUntilExit() }
        }
        try FileHandle.standardOutput.write(contentsOf: Data("SLATESYNC_MCP_READY\n".utf8))
        while true {
            sessions.removeAll { !$0.isRunning }
            var descriptors = [pollfd(fd: STDIN_FILENO, events: Int16(POLLIN), revents: 0),
                               pollfd(fd: listener, events: Int16(POLLIN), revents: 0),
                               pollfd(fd: wake.fileHandleForReading.fileDescriptor, events: Int16(POLLIN), revents: 0)]
            let result = poll(&descriptors, nfds_t(descriptors.count), 250)
            if result < 0, errno == EINTR { continue }
            guard result >= 0 else { throw problem("Managed service polling failed.") }
            if descriptors[0].revents != 0 || descriptors[2].revents != 0 { return }
            guard descriptors[1].revents & Int16(POLLIN) != 0 else { continue }
            let connection = accept(listener, nil, nil)
            guard connection >= 0 else { continue }
            let stream = FileHandle(fileDescriptor: connection, closeOnDealloc: true)
            defer { try? stream.close() }
            var user: uid_t = 0, group: gid_t = 0
            guard getpeereid(connection, &user, &group) == 0, user == getuid(), sessions.count < 8 else { continue }
            _ = fcntl(connection, F_SETFD, FD_CLOEXEC)
            let session = Process()
            session.executableURL = Bundle.main.executableURL
            session.arguments = arguments
            session.environment = ProcessInfo.processInfo.environment
            session.standardInput = stream
            session.standardOutput = stream
            session.standardError = FileHandle.standardError
            do { try session.run(); sessions.append(session) }
            catch { try? FileHandle.standardError.write(contentsOf: Data("Cannot launch managed MCP session.\n".utf8)) }
        }
    }

    public static func connectStdio(path: String) throws {
        let connection = try connectAuthenticated(path: path)
        defer { close(connection) }
        // Preserve half-close: EOF on client stdin drains the server's final
        // replies before the bridge exits. A disconnected client cannot SIGPIPE
        // the app-owned broker or another client's independent session.
        var ignoresPipe: Int32 = 1
        _ = setsockopt(connection, SOL_SOCKET, SO_NOSIGPIPE, &ignoresPipe, socklen_t(MemoryLayout<Int32>.size))
        Darwin.signal(SIGPIPE, SIG_IGN)
        var inputOpen = true
        var bytes = [UInt8](repeating: 0, count: 65_536)
        while true {
            var descriptors = [pollfd(fd: inputOpen ? STDIN_FILENO : -1, events: Int16(POLLIN), revents: 0),
                               pollfd(fd: connection, events: Int16(POLLIN), revents: 0)]
            let result = poll(&descriptors, 2, -1)
            if result < 0, errno == EINTR { continue }
            guard result >= 0 else { throw problem("MCP bridge polling failed.") }
            if descriptors[0].revents != 0 {
                let count = read(STDIN_FILENO, &bytes, bytes.count)
                if count == 0 { inputOpen = false; shutdown(connection, SHUT_WR) }
                else if count > 0 { try writeAll(connection, bytes: bytes, count: count) }
                else if errno != EINTR { throw problem("Cannot read client stdin.") }
            }
            if descriptors[1].revents != 0 {
                let count = read(connection, &bytes, bytes.count)
                if count == 0 { return }
                if count > 0 { try writeAll(STDOUT_FILENO, bytes: bytes, count: count) }
                else if errno != EINTR { throw problem("Managed MCP connection was interrupted.") }
            }
        }
    }

    /// Authenticate the connected socket, not its replaceable pathname. After
    /// /tmp cleanup another user could reserve the predictable endpoint before
    /// the broker starts. No client bytes may reach that process.
    static func connectAuthenticated(path: String, expectedUID: uid_t = getuid()) throws -> Int32 {
        let connection = try makeSocket()
        do {
            guard try withAddress(path, { connect(connection, $0, $1) }) == 0 else {
                throw problem("MCP service is stopped. Start it in SlateSync Settings > MCP.")
            }
            var user: uid_t = 0, group: gid_t = 0
            guard getpeereid(connection, &user, &group) == 0, user == expectedUID else {
                throw problem("Managed MCP service is not owned by the current user.")
            }
            return connection
        } catch {
            close(connection)
            throw error
        }
    }

    private static func makeSocket() throws -> Int32 {
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw problem("Cannot create local socket.") }
        _ = fcntl(descriptor, F_SETFD, FD_CLOEXEC)
        return descriptor
    }

    private static func withAddress<T>(_ path: String, _ action: (UnsafePointer<sockaddr>, socklen_t) -> T) throws -> T {
        var address = sockaddr_un()
        let bytes = Array(path.utf8) + [0]
        guard path.hasPrefix("/"), !path.utf8.contains(0), bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else {
            throw problem("Managed socket requires a short absolute path.")
        }
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes) }
        return withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { action($0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
    }

    private static func writeAll(_ descriptor: Int32, bytes: [UInt8], count: Int) throws {
        try bytes.withUnsafeBytes { buffer in
            var offset = 0
            while offset < count {
                let written = write(descriptor, buffer.baseAddress!.advanced(by: offset), count - offset)
                if written < 0, errno == EINTR { continue }
                guard written > 0 else { throw problem("MCP connection closed while forwarding data.") }
                offset += written
            }
        }
    }

    private static func problem(_ message: String) -> NSError { NSError(domain: "SlateSync.MCP.Managed", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
}

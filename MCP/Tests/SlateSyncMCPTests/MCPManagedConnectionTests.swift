import Darwin
import Foundation
import XCTest
@testable import SlateSyncMCP

/// Kernel peer credentials are checked on a real disposable Unix socket.
/// A different expected UID exercises rejection without switching OS users.
final class MCPManagedConnectionTests: XCTestCase {
    func testAuthenticatedConnectionAcceptsCurrentUser() throws {
        let listener = try Listener()
        defer { listener.close() }
        let client = try MCPManagedConnection.connectAuthenticated(path: listener.path)
        defer { Darwin.close(client) }
        let peer = accept(listener.descriptor, nil, nil)
        XCTAssertGreaterThanOrEqual(peer, 0)
        if peer >= 0 { Darwin.close(peer) }
    }

    func testWrongPeerUserIsRejectedAndClosedBeforeForwarding() throws {
        let listener = try Listener()
        defer { listener.close() }
        XCTAssertThrowsError(try MCPManagedConnection.connectAuthenticated(path: listener.path, expectedUID: getuid() ^ 1)) {
            XCTAssertTrue($0.localizedDescription.contains("not owned by the current user"))
        }
        let peer = accept(listener.descriptor, nil, nil)
        XCTAssertGreaterThanOrEqual(peer, 0)
        guard peer >= 0 else { return }
        defer { Darwin.close(peer) }
        var status = pollfd(fd: peer, events: Int16(POLLIN), revents: 0)
        XCTAssertEqual(poll(&status, 1, 1_000), 1, "Rejected connection must close promptly")
        _ = fcntl(peer, F_SETFL, O_NONBLOCK)
        var byte: UInt8 = 0
        XCTAssertEqual(read(peer, &byte, 1), 0, "No client bytes may reach an untrusted peer")
    }
}

private final class Listener {
    let path = "/tmp/mcp-peer-\(UUID().uuidString).sock"
    let descriptor: Int32
    init() throws {
        descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw POSIXError(.ENFILE) }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: Array(path.utf8) + [0]) }
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard bound == 0, listen(descriptor, 1) == 0 else {
            close()
            throw POSIXError(.EADDRINUSE)
        }
    }
    func close() { Darwin.close(descriptor); unlink(path) }
}

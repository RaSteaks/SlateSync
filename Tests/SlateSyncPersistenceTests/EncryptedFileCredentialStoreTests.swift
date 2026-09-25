import Foundation
import Darwin
import XCTest
@testable import SlateSyncDomain
@testable import SlateSyncPersistence

final class EncryptedFileCredentialStoreTests: XCTestCase {
    func testBatchUsesOneSnapshotAndPreservesMissingProviders() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = EncryptedFileCredentialStore(locator: .init(root: root))
        try await store.setValue("secret", providerID: "openai")
        let states = try await store.statuses(for: ["openai", "missing", "openai"])
        XCTAssertEqual(states, ["openai": .configured, "missing": .missing])
        let empty = try await store.statuses(for: [])
        XCTAssertTrue(empty.isEmpty)
    }

    func testLockTimeoutIsTransientAndBatchWaitsOnlyOnce() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = EncryptedFileCredentialStore(locator: .init(root: root), lockTimeout: 0.05)
        try await store.setValue("original", providerID: "openai")
        let lock = try holdLock(root)
        defer { _ = flock(lock, LOCK_UN); close(lock) }
        let started = ContinuousClock.now
        let states = try await store.statuses(for: (0..<15).map { "provider-\($0)" })
        XCTAssertEqual(Set(states.values), [.temporarilyUnavailable])
        XCTAssertLessThan(started.duration(to: .now), .milliseconds(600), "15 statuses must share one timeout")
        do { _ = try await store.value(providerID: "openai"); XCTFail("Expected contention") }
        catch let error as SlateSyncError { XCTAssertEqual(error.code, "FILE_LOCK_TIMEOUT") }
        _ = flock(lock, LOCK_UN)
        let recovered = try await store.value(providerID: "openai")
        XCTAssertEqual(recovered, "original")
    }

    func testAnotherProcessHoldingLockCanRecoverWithoutReset() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = EncryptedFileCredentialStore(locator: .init(root: root), lockTimeout: 0.05)
        try await store.setValue("original", providerID: "openai")
        let process = Process()
        let input = Pipe()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = ["-c", "import fcntl,sys; f=open(sys.argv[1],'r+'); fcntl.flock(f,fcntl.LOCK_EX); print('R',flush=True); sys.stdin.read(1)",
                             root.appending(path: "Credentials/.credentials.lock").path]
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        let ready = expectation(description: "Separate process acquired credential lock")
        let exited = expectation(description: "Separate process released credential lock")
        process.terminationHandler = { _ in exited.fulfill() }
        try process.run()
        defer {
            try? input.fileHandleForWriting.close()
            if process.isRunning { process.terminate() }
        }
        DispatchQueue.global().async {
            if (try? output.fileHandleForReading.read(upToCount: 1)) == Data("R".utf8) { ready.fulfill() }
        }
        await fulfillment(of: [ready], timeout: 5)
        let states = try await store.statuses(for: ["openai", "other"])
        XCTAssertEqual(states, ["openai": .temporarilyUnavailable, "other": .temporarilyUnavailable])
        try input.fileHandleForWriting.write(contentsOf: Data("X".utf8))
        await fulfillment(of: [exited], timeout: 5)
        let recovered = try await store.value(providerID: "openai")
        XCTAssertEqual(recovered, "original")
    }

    func testCancellationWhileWaitingForLockPreservesVault() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = EncryptedFileCredentialStore(locator: .init(root: root))
        try await store.setValue("original", providerID: "openai")
        let lock = try holdLock(root)
        defer { _ = flock(lock, LOCK_UN); close(lock) }
        let finished = expectation(description: "Canceled lock waiter completes promptly")
        let pending = Task {
            defer { finished.fulfill() }
            do { try await store.setValue("replacement", providerID: "openai"); XCTFail("Expected cancellation") }
            catch is CancellationError { }
            catch { XCTFail("Wrong cancellation error: \(error)") }
        }
        try await Task.sleep(for: .milliseconds(50))
        pending.cancel()
        await fulfillment(of: [finished], timeout: 1)
        _ = flock(lock, LOCK_UN)
        await pending.value
        let retained = try await store.value(providerID: "openai")
        XCTAssertEqual(retained, "original")
    }

    func testQueuedCancellationAndCancellationAfterCommitBoundary() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let entered = expectation(description: "Write entered commit")
        let writer = BlockingCredentialWriter(entered: entered)
        defer { writer.release.signal() }
        let store = EncryptedFileCredentialStore(locator: .init(root: root), writer: writer)
        let committing = Task { try await store.setValue("committed", providerID: "openai") }
        await fulfillment(of: [entered], timeout: 2)
        let canceled = expectation(description: "Queued cancellation completes before active write")
        let queued = Task {
            defer { canceled.fulfill() }
            do { try await store.reset(); XCTFail("Canceled reset must not delete credentials") }
            catch is CancellationError { }
            catch { XCTFail("Unexpected error: \(error)") }
        }
        try await Task.sleep(for: .milliseconds(30))
        queued.cancel()
        await fulfillment(of: [canceled], timeout: 1)
        committing.cancel()
        writer.release.signal()
        // The already-admitted transaction returns its real successful result.
        try await committing.value
        await queued.value
        let value = try await store.value(providerID: "openai")
        XCTAssertEqual(value, "committed")
    }

    func testMissingMasterKeyAndAccessFailuresRemainDistinct() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = EncryptedFileCredentialStore(locator: .init(root: root))
        try await store.setValue("secret", providerID: "openai")
        try FileManager.default.removeItem(at: root.appending(path: "Credentials/master.key"))
        do { _ = try await store.value(providerID: "openai"); XCTFail("Expected missing key") }
        catch let error as SlateSyncError { XCTAssertEqual(error.code, "CREDENTIAL_KEY_MISSING") }
        let unreadable = try await store.status(providerID: "openai")
        XCTAssertEqual(unreadable, .unreadable)
        let failingRoot = try self.root()
        defer { try? FileManager.default.removeItem(at: failingRoot) }
        let failing = EncryptedFileCredentialStore(locator: .init(root: failingRoot), writer: PermissionCredentialWriter())
        do { try await failing.setValue("secret", providerID: "openai"); XCTFail("Expected permission error") }
        catch let error as SlateSyncError { XCTAssertEqual(error.code, "PERSISTENCE_PERMISSIONS") }
    }

    /// Independent descriptors exercise the same advisory lock used by other processes.
    private func holdLock(_ root: URL) throws -> Int32 {
        let descriptor = open(root.appending(path: "Credentials/.credentials.lock").path, O_RDWR)
        guard descriptor >= 0, flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            if descriptor >= 0 { close(descriptor) }
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        return descriptor
    }

    private func root() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "CredentialTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func testRoundTripRestartNoncePermissionsAndDeletion() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let locator = ApplicationSupportLocator(root: root)
        let store = EncryptedFileCredentialStore(locator: locator)
        try await store.setValue("test-secret-one", providerID: "openai")
        let payload = root.appending(path: "Credentials/provider-keys.enc")
        let first = try Data(contentsOf: payload)
        XCTAssertFalse(String(decoding: first, as: UTF8.self).contains("test-secret-one"))
        try await store.setValue("test-secret-one", providerID: "openai")
        XCTAssertNotEqual(first, try Data(contentsOf: payload))
        let restarted = EncryptedFileCredentialStore(locator: locator)
        let value = try await restarted.value(providerID: "openai")
        XCTAssertEqual(value, "test-secret-one")
        for name in ["master.key", "provider-keys.enc"] {
            let attrs = try FileManager.default.attributesOfItem(atPath: root.appending(path: "Credentials/\(name)").path)
            XCTAssertEqual((attrs[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        }
        let attrs = try FileManager.default.attributesOfItem(atPath: root.appending(path: "Credentials").path)
        XCTAssertEqual((attrs[.posixPermissions] as? NSNumber)?.intValue, 0o700)
        try await restarted.setValue(nil, providerID: "openai")
        let state = try await store.status(providerID: "openai")
        XCTAssertEqual(state, .missing)
    }

    func testTamperingAndMissingKeyNeverOverwriteVault() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = EncryptedFileCredentialStore(locator: .init(root: root))
        try await store.setValue("secret", providerID: "openai")
        let payload = root.appending(path: "Credentials/provider-keys.enc")
        var corrupted = try Data(contentsOf: payload)
        corrupted[corrupted.count - 1] ^= 1
        try corrupted.write(to: payload)
        let state = try await store.status(providerID: "openai")
        XCTAssertEqual(state, .unreadable)
        do { try await store.setValue("new", providerID: "openai"); XCTFail("corruption must fail closed") } catch {}
        XCTAssertEqual(try Data(contentsOf: payload), corrupted)
        try FileManager.default.removeItem(at: root.appending(path: "Credentials/master.key"))
        do { try await store.setValue("new", providerID: "openai"); XCTFail("missing master must not regenerate") } catch {}
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appending(path: "Credentials/master.key").path))
        try await store.reset()
        try await store.setValue("recovered", providerID: "openai")
        let recovered = try await store.value(providerID: "openai")
        XCTAssertEqual(recovered, "recovered")
    }

    func testIndependentStoresSerializeReadModifyWrite() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let locator = ApplicationSupportLocator(root: root)
        try await withThrowingTaskGroup(of: Void.self) { group in
            for index in 0..<12 {
                group.addTask { try await EncryptedFileCredentialStore(locator: locator).setValue("key-\(index)", providerID: "provider-\(index)") }
            }
            try await group.waitForAll()
        }
        let store = EncryptedFileCredentialStore(locator: locator)
        for index in 0..<12 {
            let value = try await store.value(providerID: "provider-\(index)")
            XCTAssertEqual(value, "key-\(index)")
        }
    }

    func testSymlinkAndUnsafeFileRejection() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appending(path: "Credentials")
        let outside = root.appending(path: "outside")
        try Data("untouched".utf8).write(to: outside)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: directory.appending(path: "master.key"), withDestinationURL: outside)
        let store = EncryptedFileCredentialStore(locator: .init(root: root))
        do { try await store.setValue("secret", providerID: "openai"); XCTFail("must reject link") } catch {}
        XCTAssertEqual(try String(contentsOf: outside, encoding: .utf8), "untouched")
        try FileManager.default.removeItem(at: directory.appending(path: "master.key"))
        try FileManager.default.createDirectory(at: directory.appending(path: "provider-keys.enc"), withIntermediateDirectories: true)
        let state = try await store.status(providerID: "openai")
        XCTAssertEqual(state, .unavailable)
    }

    func testFailedPayloadWritePreservesPreviousCredentials() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let locator = ApplicationSupportLocator(root: root)
        let store = EncryptedFileCredentialStore(locator: locator)
        try await store.setValue("before", providerID: "openai")
        let failed = EncryptedFileCredentialStore(locator: locator, writer: RejectPayloadWriter())
        do { try await failed.setValue("after", providerID: "openai"); XCTFail("write should fail") } catch {}
        let value = try await store.value(providerID: "openai")
        XCTAssertEqual(value, "before")
    }
}

private struct RejectPayloadWriter: AtomicFileWriting {
    func writeAtomically(_ data: Data, to url: URL, permissions: Int) throws {
        throw SlateSyncError(code: "TEST_WRITE", message: "write rejected")
    }
}

/// The barrier is on the dedicated I/O queue, not a cooperative executor.
private final class BlockingCredentialWriter: AtomicFileWriting, @unchecked Sendable {
    let entered: XCTestExpectation
    let release = DispatchSemaphore(value: 0)
    init(entered: XCTestExpectation) { self.entered = entered }
    func writeAtomically(_ data: Data, to url: URL, permissions: Int) throws {
        if url.lastPathComponent == "provider-keys.enc" {
            entered.fulfill()
            guard release.wait(timeout: .now() + 5) == .success else { throw CancellationError() }
        }
        try FileManagerAtomicFileWriter().writeAtomically(data, to: url, permissions: permissions)
    }
}

private struct PermissionCredentialWriter: AtomicFileWriting {
    func writeAtomically(_ data: Data, to url: URL, permissions: Int) throws {
        throw SlateSyncError(code: "PERSISTENCE_PERMISSIONS", message: "无法保护配置文件")
    }
}

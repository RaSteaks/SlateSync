import Foundation
import SlateSyncDomain
import XCTest
@testable import SlateSyncPersistence

final class LocalProjectEncryptionTests: XCTestCase {
    func testOpeningEncryptedDatabaseDoesNotRewriteSnapshot() async throws {
        let root = try PersistenceTestSupport.temporaryRoot("encrypted-open-read-only")
        defer { try? FileManager.default.removeItem(at: root) }
        try await LocalProjectEncryption.prepare(at: root, backend: InMemoryKeychainBackend())
        let url = root.appending(path: "project.sqlite")
        let original = try SQLiteDatabase(url: url)
        try await original.executeScript("CREATE TABLE sample(value TEXT); INSERT INTO sample VALUES ('kept');")
        try await original.close()
        let snapshot = try Data(contentsOf: url)
        // Independent writable connections may read the same encrypted library
        // without resealing it or changing the snapshot's file identity.
        let reopened = try SQLiteDatabase(url: url)
        let value = try await reopened.scalar("SELECT value FROM sample;")
        XCTAssertEqual(value, "kept")
        try await reopened.close()
        XCTAssertEqual(try Data(contentsOf: url), snapshot)
    }

    func testExistingEncryptedDatabaseRemovesStaleSQLiteSidecars() async throws {
        let root = try PersistenceTestSupport.temporaryRoot("encrypted-stale-sidecars")
        defer { try? FileManager.default.removeItem(at: root) }
        let backend = InMemoryKeychainBackend()
        try await LocalProjectEncryption.prepare(at: root, backend: backend)
        let url = root.appending(path: "project.sqlite")
        let database = try SQLiteDatabase(url: url)
        try await database.executeScript("CREATE TABLE sample(value TEXT); INSERT INTO sample VALUES ('kept');")
        try await database.close()

        // Simulate the crash window after the encrypted main snapshot was
        // replaced but before legacy SQLite sidecars were removed.
        for suffix in ["-wal", "-shm", "-journal"] {
            try Data("plaintext-sidecar".utf8).write(to: URL(fileURLWithPath: url.path + suffix))
        }
        try await LocalProjectEncryption.prepare(at: root, backend: backend)
        for suffix in ["-wal", "-shm", "-journal"] {
            XCTAssertFalse(FileManager.default.fileExists(atPath: url.path + suffix))
        }

        // Direct database opens must apply the same cleanup if migration was
        // not the code path that observed the interrupted replacement.
        for suffix in ["-wal", "-shm", "-journal"] {
            try Data("plaintext-sidecar".utf8).write(to: URL(fileURLWithPath: url.path + suffix))
        }
        let reopened = try SQLiteDatabase(url: url)
        let value = try await reopened.scalar("SELECT value FROM sample;")
        XCTAssertEqual(value, "kept")
        try await reopened.close()
        for suffix in ["-wal", "-shm", "-journal"] {
            XCTAssertFalse(FileManager.default.fileExists(atPath: url.path + suffix))
        }
    }

    func testValidationUnlocksPreviousLibraryAfterRestartWithoutRewritingIt() async throws {
        let root = try PersistenceTestSupport.temporaryRoot("encrypted-library-switch")
        defer { try? FileManager.default.removeItem(at: root) }
        let backend = InMemoryKeychainBackend()
        let firstURL = root.appending(path: "First.slatesync-library")
        let secondURL = root.appending(path: "Second.slatesync-library")
        for url in [firstURL, secondURL] {
            try await LocalProjectEncryption.prepare(at: url, backend: backend)
            let library = try ProjectLibraryStore(libraryRoot: url)
            _ = try await library.libraryInfo()
            try await library.close()
        }
        let manifestURL = firstURL.appending(path: "library.json")
        let databaseURL = firstURL.appending(path: "library.sqlite")
        let manifest = try Data(contentsOf: manifestURL)
        let database = try Data(contentsOf: databaseURL)
        // Restart with B active: A's key is durable but absent from memory.
        await LocalProjectEncryption.resetUnlockCacheForTesting()
        try await LocalProjectEncryption.prepare(at: secondURL, backend: backend)
        let validated = try await ProjectLibraryTransfer.validateLibrary(at: firstURL, keychainBackend: backend)
        XCTAssertEqual(validated.path, firstURL.path)
        XCTAssertEqual(try Data(contentsOf: manifestURL), manifest)
        XCTAssertEqual(try Data(contentsOf: databaseURL), database)
    }

    func testValidationPreservesUnlockFailureAndAllowsExplicitRetry() async throws {
        let root = try PersistenceTestSupport.temporaryRoot("encrypted-library-retry")
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appending(path: "Library.slatesync-library")
        let backend = InMemoryKeychainBackend()
        try await LocalProjectEncryption.prepare(at: url, backend: backend)
        let library = try ProjectLibraryStore(libraryRoot: url)
        _ = try await library.libraryInfo()
        try await library.close()
        let marker = try Data(contentsOf: url.appending(path: LocalProjectEncryption.markerName))
        await LocalProjectEncryption.resetUnlockCacheForTesting()
        // Missing authorization/key must remain recoverable, not INVALID_PROJECT_LIBRARY.
        do {
            _ = try await ProjectLibraryTransfer.validateLibrary(at: url, keychainBackend: InMemoryKeychainBackend())
            XCTFail("Validation must not replace a missing key")
        } catch let error as SlateSyncError {
            XCTAssertEqual(error.code, "PROJECT_UNLOCK_REQUIRED")
            XCTAssertTrue(error.retryable)
        }
        await LocalProjectEncryption.allowUnlockRetry()
        _ = try await ProjectLibraryTransfer.validateLibrary(at: url, keychainBackend: backend)
        XCTAssertEqual(try Data(contentsOf: url.appending(path: LocalProjectEncryption.markerName)), marker)
    }

    func testValidationLeavesPortableLibraryUnencrypted() async throws {
        let root = try PersistenceTestSupport.temporaryRoot("portable-library-validation")
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appending(path: "Portable.slatesync-library")
        let library = try ProjectLibraryStore(libraryRoot: url)
        _ = try await library.libraryInfo()
        try await library.close()
        _ = try await ProjectLibraryTransfer.validateLibrary(at: url, keychainBackend: InMemoryKeychainBackend())
        // Validation cannot adopt/encrypt an external package as a side effect.
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.appending(path: LocalProjectEncryption.markerName).path))
        XCTAssertTrue(try Data(contentsOf: url.appending(path: "library.sqlite")).starts(with: Data("SQLite format 3".utf8)))
    }

    func testMigrationEncryptsLibraryAndSnapshotsAndExportsPortableData() async throws {
        let root = try PersistenceTestSupport.temporaryRoot("encryption-migration")
        defer { try? FileManager.default.removeItem(at: root) }
        let internalURL = root.appending(path: "Internal.slatesync-library")
        let original = try ProjectLibraryStore(libraryRoot: internalURL)
        let project = try await original.createProject(name: "Secret Project Name", description: "private-description")
        let projectURL = internalURL.appending(path: "Projects/\(project.id)")
        let tasks = try ProjectTaskStore(projectDirectory: projectURL)
        let payload = Data(#"{"id":"private-task","text":"confidential-dialogue"}"#.utf8)
        _ = try await tasks.saveTask(payload)
        try await tasks.close()
        try await original.close()

        let backend = InMemoryKeychainBackend()
        try await LocalProjectEncryption.prepare(at: internalURL, backend: backend)
        // Scan every internal regular data file, including SQLite sidecars.
        let files = try FileManager.default.subpathsOfDirectory(atPath: internalURL.path)
        for name in files where name.hasSuffix(".json") || name.hasSuffix(".sqlite") {
            let bytes = try Data(contentsOf: internalURL.appending(path: name))
            XCTAssertTrue(LocalProjectEncryption.isEncrypted(bytes), name)
            XCTAssertNil(bytes.range(of: Data("confidential-dialogue".utf8)), name)
            XCTAssertNil(bytes.range(of: Data("Secret Project Name".utf8)), name)
        }
        let encrypted = try ProjectLibraryStore(libraryRoot: internalURL)
        let recovered = try await encrypted.getProject(project.id)
        XCTAssertEqual(recovered.name, "Secret Project Name")
        let reader = try ProjectTaskStore(projectDirectory: projectURL)
        let recoveredTask = try await reader.loadTask("private-task")
        XCTAssertNotNil(recoveredTask.range(of: Data("confidential-dialogue".utf8)))
        try await reader.close()
        let exportURL = root.appending(path: "Portable.slatesync-library")
        _ = try await ProjectLibraryTransfer.exportLibrary(from: internalURL, to: exportURL)
        XCTAssertFalse(FileManager.default.fileExists(atPath: exportURL.appending(path: LocalProjectEncryption.markerName).path))
        let exportedDatabase = try Data(contentsOf: exportURL.appending(path: "library.sqlite"))
        XCTAssertTrue(exportedDatabase.starts(with: Data("SQLite format 3".utf8)))
        _ = try JSONSerialization.jsonObject(with: Data(contentsOf: exportURL.appending(path: "library.json")))
        let projectExport = root.appending(path: "Portable.slatesync-project")
        _ = try await encrypted.exportProject(project.id, to: projectExport)
        let imported = try await encrypted.importProject(from: projectExport)
        let importedID = try XCTUnwrap(imported.project?.id)
        let importedBytes = try Data(contentsOf: internalURL.appending(path: "Projects/\(importedID)/project.sqlite"))
        XCTAssertTrue(LocalProjectEncryption.isEncrypted(importedBytes))
        // A second migration must authenticate existing envelopes and preserve data.
        try await encrypted.close()
        try await LocalProjectEncryption.prepare(at: internalURL, backend: backend)
    }

    func testIndependentConnectionsPreserveUpdatesAndTamperingFailsClosed() async throws {
        let root = try PersistenceTestSupport.temporaryRoot("encryption-concurrent")
        defer { try? FileManager.default.removeItem(at: root) }
        try await LocalProjectEncryption.prepare(at: root, backend: InMemoryKeychainBackend())
        let url = root.appending(path: "project.sqlite")
        let first = try SQLiteDatabase(url: url)
        try await first.executeScript("CREATE TABLE messages (id TEXT PRIMARY KEY, text TEXT);")
        let second = try SQLiteDatabase(url: url)
        async let a = first.execute("INSERT INTO messages VALUES (?, ?);", bindings: ["a", "secret-a"])
        async let b = second.execute("INSERT INTO messages VALUES (?, ?);", bindings: ["b", "secret-b"])
        _ = try await (a, b)
        let count = try await first.scalar("SELECT COUNT(*) FROM messages;")
        XCTAssertEqual(count, "2")
        try await first.close()
        try await second.close()
        var bytes = try Data(contentsOf: url)
        bytes[bytes.count - 1] ^= 1
        try bytes.write(to: url)
        XCTAssertThrowsError(try SQLiteDatabase(url: url))
        XCTAssertEqual(try Data(contentsOf: url), bytes)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path + "-wal"))
    }

    func testMigrationIncludesUncheckpointedWALAndReadonlyRejectsWrites() async throws {
        let root = try PersistenceTestSupport.temporaryRoot("encryption-wal")
        defer { try? FileManager.default.removeItem(at: root) }
        let legacyURL = root.appending(path: "legacy.sqlite")
        let legacy = try SQLiteDatabase(url: legacyURL)
        try await legacy.executeScript("CREATE TABLE records (value TEXT); INSERT INTO records VALUES ('wal-secret');")
        let target = root.appending(path: "Encrypted")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        let targetDB = target.appending(path: "project.sqlite")
        // Copy main + WAL while the source is still open; only the WAL has the
        // latest row. Migration must use SQLite backup instead of raw main bytes.
        for suffix in ["", "-wal"] {
            try FileManager.default.copyItem(at: URL(fileURLWithPath: legacyURL.path + suffix), to: URL(fileURLWithPath: targetDB.path + suffix))
        }
        try await legacy.close()
        try await LocalProjectEncryption.prepare(at: target, backend: InMemoryKeychainBackend())
        let readonly = try SQLiteDatabase(url: targetDB, mode: .readOnly)
        let value = try await readonly.scalar("SELECT value FROM records;")
        XCTAssertEqual(value, "wal-secret")
        do {
            try await readonly.execute("DELETE FROM records;")
            XCTFail("Readonly encrypted databases must reject mutations")
        } catch {}
        try await readonly.close()
        XCTAssertFalse(FileManager.default.fileExists(atPath: targetDB.path + "-wal"))
    }

    func testMissingKeyDoesNotReplaceEncryptedData() async throws {
        let root = try PersistenceTestSupport.temporaryRoot("encryption-missing-key")
        defer { try? FileManager.default.removeItem(at: root) }
        try await LocalProjectEncryption.prepare(at: root, backend: InMemoryKeychainBackend())
        let url = root.appending(path: "project.json")
        try FileManagerAtomicFileWriter().writeAtomically(Data("private".utf8), to: url)
        let original = try Data(contentsOf: url)
        // A fresh process must still fail when the keychain item was lost.
        await LocalProjectEncryption.resetUnlockCacheForTesting()
        do {
            try await LocalProjectEncryption.prepare(at: root, backend: InMemoryKeychainBackend())
            XCTFail("A missing key must never be replaced")
        } catch {}
        XCTAssertEqual(try Data(contentsOf: url), original)
    }
}

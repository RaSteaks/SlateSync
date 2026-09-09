import Foundation
import SlateSyncDomain
import XCTest
@testable import SlateSyncPersistence

/// Freeze for the Library symlink boundary: every open of an active Library
/// re-runs the checks, project paths are validated against the canonicalized
/// root and Projects root, and any interior link resolving outside the
/// Library fails closed. Interior links that stay inside remain allowed.
final class LibraryBoundaryTests: XCTestCase {
    private func exists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    private func makeLibrary(in root: URL) async throws -> (root: URL, store: ProjectLibraryStore) {
        let libraryRoot = root.appending(path: "L.slatesync-library", directoryHint: .isDirectory)
        let store = try ProjectLibraryStore(libraryRoot: libraryRoot)
        try await store.bootstrap()
        return (libraryRoot, store)
    }

    /// Swaps an existing library-interior path for a symlink to an outside
    /// directory, then returns a freshly opened store: each open must re-run
    /// the boundary checks on what is now on disk.
    private func reopenAfterSwap(from source: URL, to outside: URL, in libraryRoot: URL) throws -> ProjectLibraryStore {
        try FileManager.default.removeItem(at: source)
        try FileManager.default.createSymbolicLink(at: source, withDestinationURL: outside)
        return try ProjectLibraryStore(libraryRoot: libraryRoot)
    }

    func testNormalLibraryPathWithInteriorLinkKeepsWorking() async throws {
        let root = try PersistenceTestSupport.temporaryRoot("boundary-normal")
        defer { try? FileManager.default.removeItem(at: root) }
        let (libraryRoot, store) = try await makeLibrary(in: root)
        let project = try await store.createProject(name: "常规", description: "")

        // An interior symlink that stays inside the Library is legitimate.
        try FileManager.default.createSymbolicLink(
            at: libraryRoot.appending(path: "Projects/latest"),
            withDestinationURL: libraryRoot.appending(path: "Projects", directoryHint: .isDirectory).appending(path: project.id)
        )
        let summaries = try await store.listProjects()
        XCTAssertEqual(summaries.count, 2)
        _ = try await store.getProject(project.id)
    }

    func testSymlinkedProjectDirectoryEscapingLibraryFailsClosed() async throws {
        let root = try PersistenceTestSupport.temporaryRoot("boundary-project-dir")
        defer { try? FileManager.default.removeItem(at: root) }
        let (libraryRoot, store) = try await makeLibrary(in: root)
        let projectDirectory = libraryRoot.appending(path: "Projects/project-default", directoryHint: .isDirectory)

        let outside = root.appending(path: "outside/project", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let reopened = try reopenAfterSwap(from: projectDirectory, to: outside, in: libraryRoot)

        await expectPathFailure { _ = try await reopened.listProjects() }
        await expectPathFailure { _ = try await reopened.getProject(ProjectLibraryStore.defaultProjectID) }
    }

    func testSymlinkedProjectDatabaseEscapingLibraryFailsClosed() async throws {
        let root = try PersistenceTestSupport.temporaryRoot("boundary-project-db")
        defer { try? FileManager.default.removeItem(at: root) }
        let (libraryRoot, store) = try await makeLibrary(in: root)
        let databaseURL = libraryRoot
            .appending(path: "Projects/project-default")
            .appending(path: SQLiteV1.projectDatabaseFilename)

        // The outside copy is a valid database: without the boundary check
        // every read would silently succeed through the link.
        let outsideDirectory = root.appending(path: "outside", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: outsideDirectory, withIntermediateDirectories: true)
        let outsideDatabase = outsideDirectory.appending(path: "project.sqlite")
        try FileManager.default.copyItem(at: databaseURL, to: outsideDatabase)
        try FileManager.default.removeItem(at: databaseURL)
        try FileManager.default.createSymbolicLink(at: databaseURL, withDestinationURL: outsideDatabase)

        let reopened = try ProjectLibraryStore(libraryRoot: libraryRoot)
        await expectPathFailure { _ = try await reopened.getProject(ProjectLibraryStore.defaultProjectID) }
        await expectPathFailure { _ = try await reopened.listProjects() }
    }

    func testSymlinkedProjectsRootEscapingLibraryFailsClosed() async throws {
        let root = try PersistenceTestSupport.temporaryRoot("boundary-projects-root")
        defer { try? FileManager.default.removeItem(at: root) }
        let (libraryRoot, _) = try await makeLibrary(in: root)
        let projectsRoot = libraryRoot.appending(path: "Projects", directoryHint: .isDirectory)

        let outside = root.appending(path: "outside/projects", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let reopened = try reopenAfterSwap(from: projectsRoot, to: outside, in: libraryRoot)

        await expectPathFailure { _ = try await reopened.libraryInfo() }
        await expectPathFailure { _ = try await reopened.listProjects() }
    }

    private func expectPathFailure(_ operation: () async throws -> Void) async {
        do {
            try await operation()
            XCTFail("指向 Library 外部的链接必须 fail closed")
        } catch { /* 预期的边界失败 */ }
    }
}

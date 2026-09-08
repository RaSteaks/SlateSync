import CryptoKit
import Foundation
import SlateSyncDomain
import XCTest
@testable import SlateSyncPersistence

final class SM09LegacyPackageTests: XCTestCase {
    private struct FrozenExport: Decodable {
        struct File: Decodable {
            let path: String
            let bytes: Int
            let sha256: String
            let base64: String
        }
        let projectID: String
        let packages: [String: [File]]
    }

    // These bytes were exported by the retained v1 implementation before
    // cutover. Materialization only writes beneath this test's temporary root.
    private func materialize(_ files: [FrozenExport.File], at root: URL) throws {
        for file in files {
            XCTAssertFalse(file.path.hasPrefix("/"))
            XCTAssertFalse(file.path.components(separatedBy: "/").contains(".."))
            let data = try XCTUnwrap(Data(base64Encoded: file.base64))
            XCTAssertEqual(data.count, file.bytes)
            XCTAssertEqual(SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(), file.sha256)
            let destination = root.appending(path: file.path)
            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: destination)
        }
    }

    func testFrozenLegacyPackagesImportEditReopenAndExportWithoutSourceMutation() async throws {
        let fixture = try XCTUnwrap(Bundle.module.url(forResource: "sm09-legacy-export", withExtension: "json"))
        let frozen = try JSONDecoder().decode(FrozenExport.self, from: Data(contentsOf: fixture))
        let root = try PersistenceTestSupport.temporaryRoot("sm09-legacy-package")
        defer { try? FileManager.default.removeItem(at: root) }
        let sourcePackage = root.appending(path: "Legacy.slatesync-project")
        let sourceLibrary = root.appending(path: "Legacy.slatesync-library")
        let projectFiles = try XCTUnwrap(frozen.packages["project"])
        try materialize(projectFiles, at: sourcePackage)
        try materialize(try XCTUnwrap(frozen.packages["library"]), at: sourceLibrary)
        let validated = try await ProjectLibraryTransfer.validateProjectPackage(at: sourcePackage)
        XCTAssertEqual(validated.taskCount, 1)
        XCTAssertEqual(validated.diagnosticCount, 1)
        _ = try await ProjectLibraryTransfer.validateLibrary(at: sourceLibrary)

        // Open the copied library in place, exercising SQLite v1 upgrade/read
        // behavior separately from the project importer and ownership rebind.
        let oldLibrary = try ProjectLibraryStore(libraryRoot: sourceLibrary)
        let oldRuntime = ProjectRuntime(library: oldLibrary)
        let oldTask = try PersistenceTestSupport.jsonObject(await oldRuntime.loadTask(projectID: frozen.projectID, taskID: "sm09-task"))
        XCTAssertEqual((oldTask["unknownV1"] as? [String: Bool])?["retained"], true)
        try await oldRuntime.close()
        try await oldLibrary.close()

        let target = root.appending(path: "Native.slatesync-library")
        let library = try ProjectLibraryStore(libraryRoot: target)
        let runtime = ProjectRuntime(library: library)
        let result = try await library.importProject(from: sourcePackage)
        let project = try XCTUnwrap(result.project)
        XCTAssertNotEqual(project.id, frozen.projectID)
        var task = try PersistenceTestSupport.jsonObject(await runtime.loadTask(projectID: project.id, taskID: "sm09-task"))
        XCTAssertEqual((task["unknownV1"] as? [String: Bool])?["retained"], true)
        task["filename"] = "edited.png"
        _ = try await runtime.saveTask(projectID: project.id, taskID: "sm09-task", payload: JSONSerialization.data(withJSONObject: task))
        try await runtime.close()
        try await library.close()

        let reopened = try ProjectLibraryStore(libraryRoot: target)
        let reopenedRuntime = ProjectRuntime(library: reopened)
        let saved = try PersistenceTestSupport.jsonObject(await reopenedRuntime.loadTask(projectID: project.id, taskID: "sm09-task"))
        XCTAssertEqual(saved["filename"] as? String, "edited.png")
        XCTAssertEqual((saved["unknownV1"] as? [String: Bool])?["retained"], true)
        let output = root.appending(path: "Native.slatesync-project")
        _ = try await reopened.exportProject(project.id, to: output)
        let importedAgain = try await reopened.importProject(from: output)
        XCTAssertNotEqual(importedAgain.project?.id, project.id)
        _ = try await reopened.exportLibrary(to: root.appending(path: "NativeCopy.slatesync-library"))
        _ = try await ProjectLibraryTransfer.validateLibrary(at: root.appending(path: "NativeCopy.slatesync-library"))
        try await reopenedRuntime.close()
        try await reopened.close()

        // The import source stays byte-for-byte unchanged, including its
        // original ownership and database. No real user Library is involved.
        for file in projectFiles {
            XCTAssertEqual(try Data(contentsOf: sourcePackage.appending(path: file.path)), Data(base64Encoded: file.base64))
        }
    }
}

import Foundation
import SlateSyncDomain
import SlateSyncPersistence
import SlateSyncUI
import SlateSyncWorkflow
import XCTest

@MainActor
final class LibraryRenameRecoveryTests: XCTestCase {
    /// Test the complete persistence → facade → UI failure projection, including
    /// reopening at the old location after the settings commit is rejected.
    func testFailedRenameRestoresDataAndFreezesEveryWindowUntilRestart() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "rename-recovery-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let runtime = SlateSyncRuntime(
            locator: .init(root: root.appending(path: "machine")), environment: [:], writer: RejectMachineWriter())
        let library = ProjectLibraryStartupService(
            machineSettings: runtime.machineSettingsStore, defaultLibraryParent: root, legacyDefaultRoots: [])
        let facade = SlateSyncWorkflowFacade(
            library: library, runtime: runtime,
            logs: LocalLogStore(directory: root.appending(path: "logs")),
            paddleInstaller: PaddleOCRInstallerService(
                userDataRoot: root, requirementsURL: root.appending(path: "unused.txt")),
            allowsExternalOperations: false)
        let created = try await facade.createProject(name: "Retain me", description: "")
        let before = try await facade.projectLibrary()
        let termination = TerminationCoordinator(lifecycle: facade)
        let model = ProjectLibraryModel(service: facade)
        model.didRequireRestart = termination.requireRestart
        model.mutationCoordinator = termination.performLibraryMutation
        await model.load()
        model.libraryNameDraft = "New Name"
        await model.renameLibrary()
        XCTAssertEqual(model.error?.code, "TEST_MACHINE_WRITE")
        XCTAssertEqual(model.error?.requiresRestart, true)
        XCTAssertTrue(model.libraryRestartRequired)
        XCTAssertTrue(termination.restartRequired)
        XCTAssertFalse(WindowAdmission.shared(termination)())
        XCTAssertTrue(FileManager.default.fileExists(atPath: before.library.path))
        try await facade.drain()
        let restarted = ProjectLibraryStartupService(
            machineSettings: runtime.machineSettingsStore, defaultLibraryParent: root, legacyDefaultRoots: [])
        let reopened = try await restarted.projectLibrary()
        XCTAssertEqual(reopened.library.path, before.library.path)
        XCTAssertTrue(reopened.active.contains { $0.id == created.id })
        try await restarted.close()
    }
}
private struct RejectMachineWriter: AtomicFileWriting {
    func writeAtomically(_ data: Data, to url: URL, permissions: Int) throws {
        throw SlateSyncError(code: "TEST_MACHINE_WRITE", message: "Injected machine settings failure")
    }
}

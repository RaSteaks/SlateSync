import Foundation
import XCTest
@testable import SlateSyncPersistence

final class ProjectLibraryStartupServiceTests: XCTestCase {
    func testStartupWithoutSelectionMigratesKnownLegacyDefault() async throws {
        let container = try PersistenceTestSupport.temporaryRoot("library-startup-default")
        defer { try? FileManager.default.removeItem(at: container) }
        let machineRoot = container.appending(path: "Machine", directoryHint: .isDirectory)
        let defaultParent = container.appending(path: "Application Support", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: defaultParent, withIntermediateDirectories: true)
        let legacyRoot = machineRoot
            .appending(path: "Libraries", directoryHint: .isDirectory)
            .appending(
                path: ProjectLibraryStore.legacyDefaultLibraryName,
                directoryHint: .isDirectory
            )
        let legacy = try ProjectLibraryStore(libraryRoot: legacyRoot)
        let expected = try await legacy.libraryInfo()
        try await legacy.close()
        let settings = MachineSettingsStore(applicationSupportRoot: machineRoot)
        let service = ProjectLibraryStartupService(
            machineSettings: settings,
            defaultLibraryParent: defaultParent,
            legacyDefaultRoots: [legacyRoot]
        )

        let reopened = try await service.libraryInfo()
        let preferred = defaultParent.appending(path: ProjectLibraryStore.defaultLibraryName)
        let saved = try await settings.load()

        XCTAssertEqual(reopened.id, expected.id)
        XCTAssertEqual(reopened.path, preferred.path)
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacyRoot.path))
        XCTAssertEqual(saved.libraryPath, "")
    }

    func testTestRootInitializerKeepsDefaultLibraryInsideExplicitIsolation() async throws {
        let root = try PersistenceTestSupport.temporaryRoot("library-startup-isolation")
        defer { try? FileManager.default.removeItem(at: root) }
        let locator = ApplicationSupportLocator(root: root)
        let settings = MachineSettingsStore(locator: locator)
        let service = ProjectLibraryStartupService(
            locator: locator,
            machineSettings: settings,
            environment: ["SLATESYNC_TEST_ROOT": root.path]
        )

        let resolved = try await service.activeLibraryRoot()

        XCTAssertEqual(
            resolved,
            root.appending(path: ProjectLibraryStore.defaultLibraryName).standardizedFileURL
        )
    }

    func testStartupReopensConfiguredPortableLibraryAfterActivation() async throws {
        let container = try PersistenceTestSupport.temporaryRoot("library-startup-configured")
        defer { try? FileManager.default.removeItem(at: container) }
        let machineRoot = container.appending(path: "Machine", directoryHint: .isDirectory)
        let defaultParent = container.appending(path: "Application Support", directoryHint: .isDirectory)
        let configuredRoot = container.appending(path: "Selected.slatesync-library", directoryHint: .isDirectory)
        let configured = try ProjectLibraryStore(libraryRoot: configuredRoot)
        let expected = try await configured.libraryInfo()
        try await configured.close()
        let settings = MachineSettingsStore(applicationSupportRoot: machineRoot)
        _ = try await settings.save(MachineSettings(libraryPath: configuredRoot.path))
        let service = ProjectLibraryStartupService(
            machineSettings: settings,
            defaultLibraryParent: defaultParent,
            legacyDefaultRoots: []
        )

        let reopened = try await service.libraryInfo()

        XCTAssertEqual(reopened.id, expected.id)
        XCTAssertEqual(reopened.path, configuredRoot.path)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: defaultParent.appending(path: ProjectLibraryStore.defaultLibraryName).path
        ))
    }

    func testStartupMigratesKnownConfiguredDefaultAndPersistsNewPath() async throws {
        let container = try PersistenceTestSupport.temporaryRoot("library-startup-migration")
        defer { try? FileManager.default.removeItem(at: container) }
        let machineRoot = container.appending(path: "Machine", directoryHint: .isDirectory)
        let defaultParent = container.appending(path: "Application Support", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: defaultParent, withIntermediateDirectories: true)
        let legacyRoot = defaultParent.appending(
            path: ProjectLibraryStore.legacyDefaultLibraryName,
            directoryHint: .isDirectory
        )
        let legacy = try ProjectLibraryStore(libraryRoot: legacyRoot)
        let expected = try await legacy.libraryInfo()
        try await legacy.close()
        let settings = MachineSettingsStore(applicationSupportRoot: machineRoot)
        _ = try await settings.save(MachineSettings(libraryPath: legacyRoot.path))
        let service = ProjectLibraryStartupService(
            machineSettings: settings,
            defaultLibraryParent: defaultParent,
            legacyDefaultRoots: [legacyRoot]
        )

        let reopened = try await service.libraryInfo()
        let preferred = defaultParent.appending(path: ProjectLibraryStore.defaultLibraryName)
        let saved = try await settings.load()

        XCTAssertEqual(reopened.id, expected.id)
        XCTAssertEqual(reopened.path, preferred.path)
        XCTAssertEqual(saved.libraryPath, preferred.path)
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacyRoot.path))
    }

    func testStartupKeepsConfiguredLegacyDefaultWhenPreferredPathConflicts() async throws {
        let container = try PersistenceTestSupport.temporaryRoot("library-startup-conflict")
        defer { try? FileManager.default.removeItem(at: container) }
        let machineRoot = container.appending(path: "Machine", directoryHint: .isDirectory)
        let defaultParent = container.appending(path: "Application Support", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: defaultParent, withIntermediateDirectories: true)
        let preferredRoot = defaultParent.appending(path: ProjectLibraryStore.defaultLibraryName)
        let preferred = try ProjectLibraryStore(libraryRoot: preferredRoot)
        let preferredInfo = try await preferred.libraryInfo()
        try await preferred.close()
        let legacyRoot = defaultParent.appending(
            path: ProjectLibraryStore.legacyDefaultLibraryName,
            directoryHint: .isDirectory
        )
        let legacy = try ProjectLibraryStore(libraryRoot: legacyRoot)
        let expected = try await legacy.libraryInfo()
        try await legacy.close()
        let settings = MachineSettingsStore(applicationSupportRoot: machineRoot)
        _ = try await settings.save(MachineSettings(libraryPath: legacyRoot.path))
        let service = ProjectLibraryStartupService(
            machineSettings: settings,
            defaultLibraryParent: defaultParent,
            legacyDefaultRoots: [legacyRoot]
        )

        let reopened = try await service.libraryInfo()
        let saved = try await settings.load()

        XCTAssertNotEqual(expected.id, preferredInfo.id)
        XCTAssertEqual(reopened.id, expected.id)
        XCTAssertEqual(reopened.path, legacyRoot.path)
        XCTAssertEqual(saved.libraryPath, legacyRoot.path)
    }
}

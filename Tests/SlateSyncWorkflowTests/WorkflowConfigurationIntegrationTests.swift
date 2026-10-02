import Foundation
import SlateSyncDomain
import SlateSyncPersistence
import XCTest

@testable import SlateSyncWorkflow

@MainActor
final class WorkflowConfigurationIntegrationTests: XCTestCase {
    func testConfiguredDepthAndProjectDefaultsReachRealConsumers() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "workflow-config-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let configURL = root.appending(path: "workflow.json")
        var config = WorkflowConfig(
            slate: .init(maxDirectoryDepth: 1),
            resolve: .init(fieldFormats: .init(scene: "X", shot: "XXX", take: "XXXX")))
        try JSONEncoder().encode(config).write(to: configURL)
        let runtime = SlateSyncRuntime(
            locator: .init(root: root.appending(path: "machine")),
            environment: ["SLATESYNC_CONFIG_PATH": configURL.path],
            workflowConfigEnvironment: .init(isPackaged: false, developmentRoot: root, bundledResourceURL: nil))
        let library = ProjectLibraryStartupService(
            machineSettings: runtime.machineSettingsStore, defaultLibraryParent: root, legacyDefaultRoots: [])
        let facade = SlateSyncWorkflowFacade(
            library: library, runtime: runtime, logs: .init(directory: root.appending(path: "logs")),
            paddleInstaller: .init(userDataRoot: root, requirementsURL: root.appending(path: "unused.txt")),
            allowsExternalOperations: false)
        let project = try await facade.createProject(name: "Configured", description: "")
        XCTAssertEqual(project.settings.resolve, config.resolve)
        let scanRoot = root.appending(path: "scan")
        try FileManager.default.createDirectory(
            at: scanRoot.appending(path: "one/two/three/four"), withIntermediateDirectories: true)
        let shallow = try await facade.scanMetadata(directory: scanRoot, options: .init(expectedKeys: ["A001:C001"]))
        XCTAssertEqual(shallow.stats.visitedDirectories, 2)
        config.slate.maxDirectoryDepth = 4
        try JSONEncoder().encode(config).write(to: configURL)
        let deeper = try await facade.scanMetadata(directory: scanRoot, options: .init(expectedKeys: ["A001:C001"]))
        XCTAssertEqual(deeper.stats.visitedDirectories, 5)
        // A malformed later edit retains the last validated configuration.
        try Data("invalid".utf8).write(to: configURL)
        let retained = try await facade.scanMetadata(directory: scanRoot, options: .init(expectedKeys: ["A001:C001"]))
        XCTAssertEqual(retained.stats.visitedDirectories, 5)
        try await facade.drain()
    }
}

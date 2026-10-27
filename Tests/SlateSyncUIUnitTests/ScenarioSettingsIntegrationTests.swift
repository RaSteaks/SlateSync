import AppKit
import Foundation
import SlateSyncDomain
import SlateSyncPersistence
import SlateSyncWorkflow
import SwiftUI
import XCTest
@testable import SlateSyncUI

@MainActor
final class ScenarioSettingsIntegrationTests: XCTestCase {
    func testConfirmAndRefreshPreserveDraftsAndRecoverFromValidationFailure() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "scenario-settings-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let runtime = SlateSyncRuntime(locator: ApplicationSupportLocator(root: root), environment: [:])
        let library = ProjectLibraryStartupService(locator: runtime.locator, machineSettings: runtime.machineSettingsStore,
            environment: [:], forceIsolatedRoot: true)
        let service = SlateSyncWorkflowFacade(library: library, runtime: runtime,
            logs: LocalLogStore(directory: root.appending(path: "logs")),
            paddleInstaller: PaddleOCRInstallerService(userDataRoot: root, requirementsURL: root.appending(path: "unused.txt")),
            allowsExternalOperations: false)
        let projection = try await service.projectLibrary()
        let projectID = try XCTUnwrap(projection.active.first?.id)
        let storage = try await library.projectRuntime()
        let view = ScenarioOCRView(width: 1200, height: 1800, blocks: [
            .init(text: "场次", confidence: 1, bboxNormalized: [0.05, 0.1, 0.15, 0.15]),
            .init(text: "镜", confidence: 1, bboxNormalized: [0.25, 0.1, 0.35, 0.15]),
            .init(text: "次", confidence: 1, bboxNormalized: [0.45, 0.1, 0.55, 0.15]),
        ])
        let decision = try XCTUnwrap(ScenarioStructureMatcher.evaluate(.init(filename: "剧组场记单", pages: [.init(pageNumber: 1, views: [view])]), profiles: []).first)
        try await storage.saveScenarioObservation(projectID: projectID, observation: .init(sourceDigest: "sample", decision: decision))
        let model = ProjectSettingsModel(service: service)
        await model.load(projectID: projectID)
        let candidate = try XCTUnwrap(model.scenarioCandidates.first)
        model.name = "未保存的项目名称"
        model.settings.customPrompt = "未保存的识别说明"
        await model.refreshScenarios()
        XCTAssertEqual(model.name, "未保存的项目名称")
        XCTAssertEqual(model.scenarioCandidates.count, 1)
        // Optional proof images are offscreen only: no window is ordered front.
        if let output = ProcessInfo.processInfo.environment["SLATESYNC_SCENARIO_SNAPSHOT_DIR"] {
            let directory = URL(fileURLWithPath: output)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            for scheme in [ColorScheme.light, .dark] {
                let host = NSHostingView(rootView: Form { ScenarioCandidatesSection(model: model) }
                    .formStyle(.grouped).environment(\.colorScheme, scheme).frame(width: 700, height: 540))
                host.frame = NSRect(x: 0, y: 0, width: 700, height: 540)
                host.layoutSubtreeIfNeeded()
                let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: bitmap)
                try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                    .write(to: directory.appending(path: "scenario-\(scheme == .light ? "light" : "dark").png"))
            }
        }

        await model.confirmCandidate(candidate, label: "", existingProfileID: nil)
        guard case .failed = model.scenarioOperation else { return XCTFail("Invalid names must remain recoverable") }
        XCTAssertEqual(model.scenarioCandidates.count, 1)
        await model.confirmCandidate(candidate, label: "标准场记单", existingProfileID: nil)
        guard case .succeeded = model.scenarioOperation else { return XCTFail("Valid retry must commit") }
        XCTAssertTrue(model.scenarioCandidates.isEmpty)
        XCTAssertEqual(model.scenarios.first?.label, "标准场记单")
        XCTAssertEqual(model.name, "未保存的项目名称")
        XCTAssertEqual(model.settings.customPrompt, "未保存的识别说明")
        let persistedProject = try await service.project(id: projectID)
        XCTAssertNotEqual(persistedProject.name, model.name)
        await model.load(projectID: projectID)
        XCTAssertEqual(model.name, "未保存的项目名称")
        XCTAssertEqual(model.scenarios.count, 1)
        let legacy = try await ScenarioProfileEngine().profile(from: .init(filename: "旧版式", pages: [.init(pageNumber: 1, views: [view])]), resolve: .init())
        let oldProfile = try await storage.importScenario(projectID: projectID, profile: legacy)
        await model.refreshScenarios()
        let targetID = try XCTUnwrap(model.scenarios.first { $0.id != oldProfile.id }?.id)
        model.settings.scenarioId = oldProfile.id
        await model.previewScenarioMerge(sourceID: oldProfile.id, targetID: targetID)
        XCTAssertNotNil(model.scenarioMergePreview)
        await model.commitScenarioMerge()
        XCTAssertEqual(model.scenarios.count, 1)
        XCTAssertEqual(model.settings.scenarioId, targetID)
        XCTAssertNotNil(model.lastScenarioMerge)
        await model.undoScenarioMerge()
        XCTAssertEqual(model.scenarios.count, 2)
        XCTAssertEqual(model.settings.scenarioId, oldProfile.id)
        XCTAssertEqual(model.name, "未保存的项目名称")
        XCTAssertEqual(model.settings.customPrompt, "未保存的识别说明")
        try await service.drain()
    }
}

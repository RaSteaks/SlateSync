import Foundation
import SlateSyncDomain
import XCTest

// Only test doubles get defaults. Production model constructors require the
// full capability set, so an omitted runtime service is a compile-time error.
extension ProjectContextWorkflowServing {
    func project(id: String) async throws -> ProjectData {
        let summary = ProjectSummary(
            id: id, name: "Fixture", description: "", relativePath: "Projects/\(id)", createdAt: "", updatedAt: "")
        return ProjectData(summary: summary, settings: .init(), lastRecognitionDefaults: nil)
    }
}
extension LocalSlateWorkflowServing {
    func decodeSlateCSV(_ data: Data) async throws -> [SlateCsvRecord] { throw missingFixtureCapability }
    func localSlateRecords(_ records: [SlateCsvRecord]) async -> [PersistedRecognitionRecord] {
        XCTFail("Configure local record generation for this fixture")
        return []
    }
}
extension ResolveExportWorkflowServing {
    // Unrelated fixtures fail explicitly if a new preview capability is used.
    func previewResolve(source: Data, records: [ResolveSlateRecord], metadata: [PersistedSlateMetadata],
        settings: ProjectSettings.ResolveSettings, edits: [ResolveSparseEdit]
    ) async throws -> ResolveMergeResult { throw missingFixtureCapability }
    func mergeResolve(
        source: Data, records: [ResolveSlateRecord], metadata: [PersistedSlateMetadata],
        settings: ProjectSettings.ResolveSettings, edits: [ResolveSparseEdit]
    ) async throws -> ResolveExportArtifact { throw missingFixtureCapability }
    func exportStandalone(records: [ResolveSlateRecord], settings: ProjectSettings.ResolveSettings) async throws -> Data
    { throw missingFixtureCapability }
}
private var missingFixtureCapability: SlateSyncError {
    .init(code: "FIXTURE_CAPABILITY", message: "Configure the fixture capability required by this test")
}

extension ScenarioListWorkflowServing {
    func listScenarios(projectID: String) async throws -> [ScenarioSummary] { [] }
    func listScenarioCandidates(projectID: String) async throws -> [ScenarioCandidate] { [] }
    func confirmScenarioCandidate(projectID: String, candidateID: String, label: String, existingProfileID: String?) async throws -> ScenarioData {
        throw missingFixtureCapability
    }
    func previewScenarioMerge(projectID: String, sourceID: String, targetID: String) async throws -> ScenarioMergePreview { throw missingFixtureCapability }
    func mergeScenarioProfiles(projectID: String, preview: ScenarioMergePreview) async throws -> ScenarioMergeReceipt { throw missingFixtureCapability }
    func latestScenarioMerge(projectID: String) async throws -> ScenarioMergeReceipt? { nil }
    func undoScenarioMerge(projectID: String, receiptID: String) async throws { throw missingFixtureCapability }
}

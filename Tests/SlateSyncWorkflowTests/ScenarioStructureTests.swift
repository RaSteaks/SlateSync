import Foundation
import SlateSyncDomain
import SlateSyncPersistence
@testable import SlateSyncWorkflow
import XCTest

final class ScenarioStructureTests: XCTestCase {
    func testMergePreservesOldTaskReferencesRejectsStalePreviewAndSurvivesUndoAfterReopen() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "scenario-merge-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let libraryURL = root.appending(path: "Library.slatesync-library")
        let library = try ProjectLibraryStore(libraryRoot: libraryURL)
        let runtime = ProjectRuntime(library: library)
        let projectID = ProjectLibraryStore.defaultProjectID
        var sourceFormats = ProjectSettings.ResolveSettings()
        sourceFormats.fieldFormats.scene = "XXXX"
        let legacy = try await ScenarioProfileEngine().profile(from: input(), resolve: sourceFormats)
        let modern = try XCTUnwrap(ScenarioStructureMatcher.evaluate(input(), profiles: []).first?.candidate)
        let source = try await runtime.importScenario(projectID: projectID, profile: legacy)
        let target = try await runtime.importScenario(projectID: projectID, profile: modern)
        let project = try await library.getProject(projectID)
        let info = try await library.libraryInfo()
        let databaseURL = URL(fileURLWithPath: info.path).appending(path: project.relativePath).appending(path: SQLiteV1.projectDatabaseFilename)
        let database = try SQLiteDatabase(url: databaseURL)
        let originalValue = try await database.scalar("SELECT profile_json FROM scenario_profiles WHERE id = ?;", bindings: [source.id])
        let originalJSON = try XCTUnwrap(originalValue)
        var extra = try JSONDecoder().decode([String: JSONValue].self, from: Data(originalJSON.utf8))
        extra["futureMetadata"] = .object(["preserve": .string("unknown fields")])
        let preservedJSON = String(decoding: try JSONEncoder().encode(extra), as: UTF8.self)
        try await database.execute("UPDATE scenario_profiles SET profile_json = ? WHERE id = ?;", bindings: [preservedJSON, source.id])
        let taskID = try await runtime.saveTask(projectID: projectID, taskID: nil, payload: JSONEncoder().encode(TaskData(scenarioId: source.id)))
        let taskBefore = try await runtime.loadTask(projectID: projectID, taskID: taskID)
        let preview = try await runtime.previewScenarioMerge(projectID: projectID, sourceID: source.id, targetID: target.id)
        XCTAssertTrue(preview.warnings.contains { $0.contains("当前项目设置不变") })
        let opposite = try await runtime.previewScenarioMerge(projectID: projectID, sourceID: target.id, targetID: source.id)
        let receipt = try await runtime.mergeScenarioProfiles(projectID: projectID, preview: preview)
        let summaries = try await runtime.listScenarios(projectID: projectID)
        XCTAssertEqual(summaries.map(\.id), [target.id])
        XCTAssertEqual(summaries.first?.aliases, [source.id])
        let resolved = try await runtime.loadScenario(projectID: projectID, scenarioID: source.id)
        XCTAssertEqual(resolved.id, target.id)
        let taskAfter = try await runtime.loadTask(projectID: projectID, taskID: taskID)
        XCTAssertEqual(taskBefore, taskAfter)
        let aliasValue = try await database.scalar("SELECT profile_json FROM scenario_profiles WHERE id = ?;", bindings: [source.id])
        let aliasJSON = try XCTUnwrap(aliasValue)
        XCTAssertEqual(try JSONDecoder().decode([String: JSONValue].self, from: Data(aliasJSON.utf8))["futureMetadata"], extra["futureMetadata"])
        do {
            _ = try await runtime.mergeScenarioProfiles(projectID: projectID, preview: opposite)
            XCTFail("A stale preview must not create an alias cycle")
        } catch { XCTAssertEqual((error as? SlateSyncError)?.code, "SCENARIO_CONFLICT") }
        try await database.close(); try await runtime.close(); try await library.close()

        let reopenedLibrary = try ProjectLibraryStore(libraryRoot: libraryURL)
        let reopened = ProjectRuntime(library: reopenedLibrary)
        let latest = try await reopened.latestScenarioMerge(projectID: projectID)
        XCTAssertEqual(latest, receipt)
        try await reopened.undoScenarioMerge(projectID: projectID, receiptID: receipt.id)
        let restored = try await reopened.loadScenario(projectID: projectID, scenarioID: source.id)
        XCTAssertEqual(restored.profile, legacy)
        let profiles = try await reopened.listScenarios(projectID: projectID)
        XCTAssertEqual(profiles.count, 2)
        let undo = try await reopened.latestScenarioMerge(projectID: projectID)
        XCTAssertNil(undo)
        let unchangedTask = try await reopened.loadTask(projectID: projectID, taskID: taskID)
        XCTAssertEqual(unchangedTask, taskBefore)
        let reopenedDatabase = try SQLiteDatabase(url: databaseURL)
        let restoredJSON = try await reopenedDatabase.scalar("SELECT profile_json FROM scenario_profiles WHERE id = ?;", bindings: [source.id])
        XCTAssertEqual(restoredJSON, preservedJSON)
        try await reopenedDatabase.close()
        try await reopened.close(); try await reopenedLibrary.close()
    }
    func testHeaderBandCanMoveBelowPageMidpointWithoutChangingFamily() throws {
        let original = input()
        let profile = try XCTUnwrap(ScenarioStructureMatcher.evaluate(original, profiles: []).first?.candidate)
        let shifted = original.pages[0].views[0].blocks.map { block in
            ScenarioOCRBlock(text: block.text, confidence: block.confidence,
                bboxNormalized: [block.bboxNormalized[0], block.bboxNormalized[1] + 0.35,
                                 block.bboxNormalized[2], block.bboxNormalized[3] + 0.35])
        }
        let scan = ScenarioObservationInput(filename: "large-top-margin", pages: [.init(pageNumber: 1,
            views: [.init(width: 1200, height: 2400, blocks: shifted)])])
        XCTAssertEqual(try ScenarioStructureMatcher.evaluate(scan, profiles: [data(profile)]).first?.status, .reused)
    }
    func testEvaluationSeparatesCoveragePrecisionAndUnknownAcceptance() throws {
        XCTAssertThrowsError(try JSONDecoder().decode(ScenarioEvaluation.ExpectedPage.self, from: Data(#"{"pageNumber":1}"#.utf8)))
        let unknownLabel = ScenarioEvaluation.ExpectedPage(pageNumber: 1, templateID: nil)
        let decodedLabel = try JSONDecoder().decode(ScenarioEvaluation.ExpectedPage.self, from: JSONEncoder().encode(unknownLabel))
        XCTAssertNil(decodedLabel.templateID)
        let profile = try XCTUnwrap(ScenarioStructureMatcher.evaluate(input(), profiles: []).first?.candidate)
        let report = try ScenarioEvaluation.run([
            .init(id: "known", sourceGroupID: "one", observation: input(), expected: [.init(pageNumber: 1, templateID: "known")]),
            .init(id: "unknown", sourceGroupID: "two", observation: input(swapped: true), expected: [.init(pageNumber: 1, templateID: nil)]),
        ], templates: [data(profile)])
        XCTAssertEqual(report.knownCoverage, 1)
        XCTAssertEqual(report.knownPrecision, 1)
        XCTAssertEqual(report.unknownAcceptance, 0)
        let noAssignments = try ScenarioEvaluation.run([
            .init(id: "known", sourceGroupID: "one", observation: input(swapped: true), expected: [.init(pageNumber: 1, templateID: "known")]),
        ], templates: [data(profile)])
        XCTAssertEqual(noAssignments.knownCoverage, 0)
        XCTAssertNil(noAssignments.knownPrecision, "Abstaining on everything is not perfect precision")
        XCTAssertThrowsError(try ScenarioEvaluation.run([
            .init(id: "missing-label", sourceGroupID: "one", observation: input(), expected: []),
        ], templates: [data(profile)]))
        XCTAssertThrowsError(try ScenarioEvaluation.run([
            .init(id: "empty", sourceGroupID: "one", observation: .init(filename: "empty", pages: []), expected: []),
        ], templates: []))
    }
    func testPrintedLayoutIgnoresContentResolutionFilenameAndDetailViews() throws {
        let first = try XCTUnwrap(ScenarioStructureMatcher.evaluate(input(), profiles: []).first?.candidate)
        let known = data(first)
        let variants = [input(content: "2026-10-27 B098 99A 18 7"), input(width: 600), input(detail: true), input(shift: 0.015)]
        for sample in variants {
            let decision = try XCTUnwrap(ScenarioStructureMatcher.evaluate(sample, profiles: [known]).first)
            XCTAssertEqual(decision.status, .reused)
            XCTAssertEqual(decision.profile?.id, "known")
            XCTAssertFalse(decision.candidate?.recognition.headerTokens.contains("2026-10-27") ?? true)
        }
        XCTAssertEqual(first.fields.take.region, [0.36, 0.12, 0.41, 0.16], "次 must not include 场次's region")
        XCTAssertEqual(first.structure?.anchors.last?.field, "camera:A")
    }

    func testMissingHeadersAndChangedColumnOrderDoNotReuse() throws {
        let profile = try XCTUnwrap(ScenarioStructureMatcher.evaluate(input(), profiles: []).first?.candidate)
        let swapped = try XCTUnwrap(ScenarioStructureMatcher.evaluate(input(swapped: true), profiles: [data(profile)]).first)
        XCTAssertEqual(swapped.status, .candidate)
        XCTAssertEqual(swapped.diagnostics.first?.orderMatches, false)
        let empty = ScenarioObservationInput(filename: "empty", pages: [.init(pageNumber: 1, views: [.init(width: 100, height: 100, blocks: [])])])
        XCTAssertEqual(try ScenarioStructureMatcher.evaluate(empty, profiles: [data(profile)]).first?.status, .insufficient)
        let future = ScenarioProfile(schemaVersion: 2, fingerprintVersion: 2, fingerprint: profile.fingerprint,
            label: profile.label, layout: profile.layout, fields: profile.fields, recognition: profile.recognition,
            output: profile.output, structure: profile.structure)
        XCTAssertNil(try ScenarioStructureMatcher.evaluate(input(), profiles: [data(future)]).first?.profile)
    }

    func testPagesAreIndependentAndInputOrderDoesNotChooseTemplate() throws {
        let a = try XCTUnwrap(ScenarioStructureMatcher.evaluate(input(), profiles: []).first?.candidate)
        let b = try XCTUnwrap(ScenarioStructureMatcher.evaluate(input(swapped: true), profiles: []).first?.candidate)
        let sample = ScenarioObservationInput(filename: "mixed.pdf", pages: [input().pages[0], .init(pageNumber: 2, views: input(swapped: true).pages[0].views)])
        let profiles = [data(a, id: "a"), data(b, id: "b")]
        let forward = try ScenarioStructureMatcher.evaluate(sample, profiles: profiles)
        let reverse = try ScenarioStructureMatcher.evaluate(sample, profiles: Array(profiles.reversed()))
        XCTAssertEqual(forward, reverse)
        XCTAssertEqual(forward.compactMap { $0.profile?.id }, ["a", "b"])
    }

    func testExactStructuralAliasesDoNotCompeteAndNearbyLayoutsRemainAmbiguous() throws {
        let a = try XCTUnwrap(ScenarioStructureMatcher.evaluate(input(), profiles: []).first?.candidate)
        let alias = try ScenarioStructureMatcher.evaluate(input(), profiles: [data(a, id: "z"), data(a, id: "a")])
        XCTAssertEqual(alias.first?.status, .reused)
        XCTAssertEqual(alias.first?.profile?.id, "a")
        let altered = ScenarioStructure(anchors: try XCTUnwrap(a.structure).anchors.map { anchor in
            var box = anchor.box
            if anchor.field == "shot" { box[0] += 0.025; box[2] += 0.025 }
            return .init(field: anchor.field, box: box)
        })
        let b = ScenarioProfile(schemaVersion: 1, fingerprintVersion: 2, fingerprint: try ScenarioStructureMatcher.fingerprint(altered),
            label: "b", layout: a.layout, fields: a.fields, recognition: a.recognition, output: a.output, structure: altered)
        let ambiguous = try ScenarioStructureMatcher.evaluate(input(), profiles: [data(a), data(b, id: "b")])
        XCTAssertEqual(ambiguous.first?.status, .ambiguous)
        XCTAssertNil(ambiguous.first?.profile)
        let differentInstructions = ScenarioProfile(schemaVersion: 1, fingerprintVersion: 2, fingerprint: a.fingerprint,
            label: "special rules", layout: a.layout, fields: a.fields,
            recognition: .init(headerTokens: a.recognition.headerTokens, promptHints: ["different confirmed instructions"]),
            output: a.output, structure: a.structure)
        let conflict = try ScenarioStructureMatcher.evaluate(input(), profiles: [data(a), data(differentInstructions, id: "rules")],
            matching: .init(threshold: 0.85, ambiguityMargin: 0))
        XCTAssertEqual(conflict.first?.status, .ambiguous)
    }

    func testCandidateConfirmationIsExplicitAndReadOnlyEvaluationDoesNotWrite() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let library = try ProjectLibraryStore(libraryRoot: root.appending(path: "Library.slatesync-library"))
        let runtime = ProjectRuntime(library: library)
        let projectID = ProjectLibraryStore.defaultProjectID
        let service = ScenarioMatchingService(projectID: projectID, persistence: runtime)
        let decisions = try await service.evaluate(input: input())
        let decision = try XCTUnwrap(decisions.first)
        let initial = try await runtime.listScenarios(projectID: projectID)
        XCTAssertTrue(initial.isEmpty)
        let observation = ScenarioLearningObservation(sourceDigest: "source-one", decision: decision)
        try await runtime.saveScenarioObservation(projectID: projectID, observation: observation)
        try await runtime.saveScenarioObservation(projectID: projectID, observation: observation)
        let pending = try await runtime.listScenarioCandidates(projectID: projectID)
        XCTAssertEqual(pending.count, 1)
        XCTAssertEqual(pending.first?.sourceCount, 1)
        let stillEmpty = try await runtime.listScenarios(projectID: projectID)
        XCTAssertTrue(stillEmpty.isEmpty)
        let confirmed = try await runtime.confirmScenarioCandidate(projectID: projectID, candidateID: XCTUnwrap(pending.first?.id), label: "A机场记单", existingProfileID: nil)
        XCTAssertEqual(confirmed.sampleCount, 1)
        let newDecisions = try await service.evaluate(input: input(content: "new shoot"))
        let reused = try XCTUnwrap(newDecisions.first)
        XCTAssertEqual(reused.profile?.id, confirmed.id)
        let afterRead = try await runtime.loadScenario(projectID: projectID, scenarioID: confirmed.id)
        XCTAssertEqual(afterRead, confirmed)
        try await runtime.saveScenarioObservation(projectID: projectID, observation: .init(sourceDigest: "source-two", decision: reused))
        let afterSave = try await runtime.loadScenario(projectID: projectID, scenarioID: confirmed.id)
        XCTAssertEqual(afterSave.sampleCount, 2)
        let remaining = try await runtime.listScenarioCandidates(projectID: projectID)
        XCTAssertTrue(remaining.isEmpty)
        let variant = try XCTUnwrap(ScenarioStructureMatcher.evaluate(input(swapped: true), profiles: []).first)
        try await runtime.saveScenarioObservation(projectID: projectID, observation: .init(sourceDigest: "manual-association", decision: variant))
        let variants = try await runtime.listScenarioCandidates(projectID: projectID)
        let associated = try await runtime.confirmScenarioCandidate(projectID: projectID, candidateID: XCTUnwrap(variants.first?.id), label: "", existingProfileID: confirmed.id)
        XCTAssertEqual(associated.id, confirmed.id)
        XCTAssertEqual(associated.structure, confirmed.structure, "One association must not overwrite a confirmed descriptor")
        try await runtime.close()
        try await library.close()
        let reopenedLibrary = try ProjectLibraryStore(libraryRoot: root.appending(path: "Library.slatesync-library"))
        let reopened = ProjectRuntime(library: reopenedLibrary)
        let saved = try await reopened.loadScenario(projectID: projectID, scenarioID: confirmed.id)
        XCTAssertEqual(saved.structure, confirmed.structure)
        XCTAssertEqual(saved.sampleCount, 3)
        // Confirmed variants survive reopening without replacing the original
        // descriptor or adding another pending candidate on the next source.
        let reopenedService = ScenarioMatchingService(projectID: projectID, persistence: reopened)
        let nextDecisions = try await reopenedService.evaluate(input: input(swapped: true))
        let next = try XCTUnwrap(nextDecisions.first)
        XCTAssertEqual(next.profile?.id, confirmed.id)
        XCTAssertEqual(next.profile?.structure, confirmed.structure)
        try await reopened.saveScenarioObservation(projectID: projectID,
            observation: .init(sourceDigest: "next-variant-source", decision: next))
        let pendingAgain = try await reopened.listScenarioCandidates(projectID: projectID)
        XCTAssertTrue(pendingAgain.isEmpty)
        try await reopened.close()
        try await reopenedLibrary.close()
    }

    func testConfirmedAssociationFollowsMergeAndUndoWithoutLearningAutomaticMatches() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "scenario-association-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try ScenarioStore(projectDirectory: root)
        let original = try XCTUnwrap(ScenarioStructureMatcher.evaluate(input(), profiles: []).first?.candidate)
        let source = try await store.importProfile(original)
        let variant = try XCTUnwrap(ScenarioStructureMatcher.evaluate(input(swapped: true), profiles: [source]).first)
        // A successful automatic match is historical evidence, never a new
        // manual structure rule, even when its observed geometry differs.
        try await store.saveObservation(.init(sourceDigest: "automatic", decision:
            .init(pageNumber: 1, status: .reused, candidate: variant.candidate, profile: source)))
        let before = try await store.snapshot()
        XCTAssertTrue(before.confirmedAssociations.isEmpty)
        try await store.saveObservation(.init(sourceDigest: "manual", decision: variant))
        let pending = try await store.listCandidates()
        _ = try await store.confirmCandidate(XCTUnwrap(pending.first?.id), label: "", existingProfileID: source.id)
        let confirmed = try await store.getProfile(source.id)
        XCTAssertEqual(confirmed.profile, original)

        let target = try await store.importProfile(ScenarioProfileEngine().profile(from: input(), resolve: .init()))
        let preview = try await store.previewMerge(sourceID: source.id, targetID: target.id)
        let receipt = try await store.merge(preview)
        let merged = try await store.snapshot()
        let routed = try ScenarioStructureMatcher.evaluate(input(swapped: true), profiles: merged.profiles,
            confirmedAssociations: merged.confirmedAssociations)
        XCTAssertEqual(routed.first?.profile?.id, target.id)
        XCTAssertEqual(routed.first?.profile?.recognition, target.recognition)
        try await store.undoMerge(receipt.id)
        let undone = try await store.snapshot()
        let restored = try ScenarioStructureMatcher.evaluate(input(swapped: true), profiles: undone.profiles,
            confirmedAssociations: undone.confirmedAssociations)
        XCTAssertEqual(restored.first?.profile?.id, source.id)
        XCTAssertEqual(restored.first?.profile?.profile, original)
        try await store.close()
    }

    func testManualAssociationResolvesAmbiguityButConflictingAssociationsAbstain() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "scenario-ambiguous-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try ScenarioStore(projectDirectory: root)
        let modern = try XCTUnwrap(ScenarioStructureMatcher.evaluate(input(), profiles: []).first?.candidate)
        let chosen = try await store.importProfile(modern)
        let legacy = try await store.importProfile(.init(schemaVersion: 1, fingerprintVersion: 1,
            fingerprint: String(repeating: "a", count: 32), label: "Legacy rules", layout: modern.layout,
            fields: modern.fields, recognition: .init(headerTokens: modern.recognition.headerTokens,
                promptHints: ["Distinct confirmed interpretation"]), output: modern.output, structure: modern.structure))
        // Both profiles describe the same headers but retain different rules.
        let ambiguous = try XCTUnwrap(ScenarioStructureMatcher.evaluate(input(), profiles: [chosen, legacy]).first)
        XCTAssertEqual(ambiguous.status, .ambiguous)
        try await store.saveObservation(.init(sourceDigest: "ambiguous", decision: ambiguous))
        let pending = try await store.listCandidates()
        _ = try await store.confirmCandidate(XCTUnwrap(pending.first?.id), label: "", existingProfileID: chosen.id)
        let snapshot = try await store.snapshot()
        let resolved = try ScenarioStructureMatcher.evaluate(input(), profiles: snapshot.profiles,
            confirmedAssociations: snapshot.confirmedAssociations)
        XCTAssertEqual(resolved.first?.profile?.id, chosen.id)
        let savedBefore = try await store.getProfile(chosen.id)
        _ = try await store.snapshot()
        let savedAfter = try await store.getProfile(chosen.id)
        XCTAssertEqual(savedBefore, savedAfter, "Reading associations must not change counts or timestamps")
        let conflict = snapshot.confirmedAssociations + [ScenarioConfirmedAssociation(profileID: legacy.id,
            structure: try XCTUnwrap(modern.structure))]
        let conflicting = try ScenarioStructureMatcher.evaluate(input(), profiles: snapshot.profiles, confirmedAssociations: conflict)
        let reversed = try ScenarioStructureMatcher.evaluate(input(), profiles: Array(snapshot.profiles.reversed()), confirmedAssociations: Array(conflict.reversed()))
        XCTAssertEqual(conflicting, reversed)
        XCTAssertEqual(conflicting.first?.status, .ambiguous)
        try await store.close()
    }

    private func data(_ profile: ScenarioProfile, id: String = "known") -> ScenarioData {
        .init(id: id, profile: profile, sampleCount: 1, createdAt: "2026-01-01", updatedAt: "", lastUsedAt: "")
    }

    private func input(content: String = "A001 37 02 2026-01-01", width: Int = 1200, detail: Bool = false,
                       shift: Double = 0, swapped: Bool = false) -> ScenarioObservationInput {
        let headers = swapped ? ["场次", "次", "镜", "视频码", "A机"] : ["场次", "镜", "次", "视频码", "A机"]
        let positions = [0.05, 0.23, 0.36, 0.52, 0.74]
        var blocks = zip(headers, positions).map { text, x in
            ScenarioOCRBlock(text: text, confidence: 0.99, bboxNormalized: [x + shift, 0.12 + shift, x + 0.05 + shift, 0.16 + shift])
        }
        blocks.append(.init(text: content, confidence: 0.99, bboxNormalized: [0.05, 0.02, 0.65, 0.07]))
        blocks.append(.init(text: "各种手写内容", confidence: 0.8, bboxNormalized: [0.1, 0.4, 0.5, 0.6]))
        let full = ScenarioOCRView(width: width, height: width * 2, blocks: blocks)
        return .init(filename: "sample-\(width).pdf", pages: [.init(pageNumber: 1, views: detail ? [full, full, full] : [full])])
    }
}

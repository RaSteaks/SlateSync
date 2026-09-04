import Foundation
import XCTest
import SlateSyncDomain
import SlateSyncPersistence
@testable import SlateSyncWorkflow

final class ScenarioProfileEngineTests: XCTestCase {
    func testReviewedObservationProducesExactFingerprintAndFields() async throws {
        let engine = ScenarioProfileEngine()
        let profile = try await engine.profile(from: fixtureObservation(), resolve: .init())
        XCTAssertEqual(profile.fingerprint, "e6ac0b81193ca50f1612d66ce5f1d586")
        XCTAssertEqual(profile.layout.headerTokens, ["a机", "场次", "次", "镜"])
        XCTAssertEqual(profile.layout.columnBands, [15, 2, 5, 6])
        XCTAssertEqual(profile.fields.scene.region, [0.05, 0.08, 0.12, 0.12])
        XCTAssertEqual(profile.fields.take.region, [0.05, 0.08, 0.35, 0.12])
        let similarity = try await engine.similarity(profile, profile)
        XCTAssertEqual(similarity, 1)
    }

    func testCanonicalizationSimilarityPromptLimitsAndInvalidProfiles() async throws {
        let engine = ScenarioProfileEngine()
        let original = try await engine.profile(from: sample(includeInvalidBlock: true), resolve: .init())
        let shuffled = try await engine.profile(from: sample(shuffled: true, includeInvalidBlock: true), resolve: .init())
        XCTAssertEqual(original.fingerprint, shuffled.fingerprint)
        XCTAssertEqual(original.layout.blockCount, 7)

        let differentLayout = ScenarioLayout(
            pages: original.layout.pages,
            headerTokens: [],
            cameraGroups: original.layout.cameraGroups,
            columnBands: original.layout.columnBands,
            rowBands: original.layout.rowBands,
            blockCount: original.layout.blockCount
        )
        let different = copy(original, fingerprint: String(repeating: "0", count: 32), layout: differentLayout)
        let score = try await engine.similarity(original, different)
        XCTAssertEqual(score, 0.6)
        let normalizedSimilarity = try await engine.similarity(copy(original, fingerprint: ""), original)
        XCTAssertEqual(normalizedSimilarity, 1)

        let multiPage = ScenarioObservationInput(filename: "multi", pages: [
            .init(pageNumber: 0, views: [.init(width: 600, height: 900, blocks: [
                .init(text: "一机", confidence: 1, bboxNormalized: [0, 0, 0.1, 0.1]),
                .init(text: String(repeating: "😀", count: 21), confidence: 1, bboxNormalized: [0.2, 0, 0.3, 0.1]),
            ])]),
            .init(pageNumber: 2, views: [.init(width: 900, height: 600, blocks: [.init(text: "BCAM", confidence: 1, bboxNormalized: [0.1, 0.1, 0.2, 0.2])])]),
        ])
        let multiProfile = try await engine.profile(from: multiPage, resolve: .init())
        XCTAssertEqual(multiProfile.layout.pages.map { $0.views[0].orientation }, ["portrait", "landscape"])
        XCTAssertEqual(multiProfile.layout.pages.map(\.pageNumber), [0, 2])
        XCTAssertFalse(multiProfile.layout.headerTokens.contains(String(repeating: "😀", count: 21)), "JS limits header tokens by UTF-16 length")
        XCTAssertEqual(multiProfile.layout.cameraGroups, ["bcam", "一机"])
        XCTAssertEqual(multiProfile.layout.blockCount, 3)

        let hints = (0..<25).map { _ in String(repeating: "x", count: 1_100) }
        let oversized = copy(original, label: String(repeating: "L", count: 130), recognition: .init(headerTokens: ["  SCENE  ", "scene"], promptHints: hints))
        let normalized = try await engine.normalize(oversized)
        XCTAssertEqual(normalized.label.count, 120)
        XCTAssertEqual(normalized.recognition.headerTokens, ["scene"])
        XCTAssertEqual(normalized.recognition.promptHints.count, 20)
        XCTAssertEqual(normalized.recognition.promptHints[0].utf16.count, 1_000)
        let prompt = await engine.promptInstruction(normalized)
        XCTAssertTrue(prompt.contains("当前场记结构"))

        let future = copy(original, schemaVersion: 2)
        do { _ = try await engine.normalize(future); XCTFail("Expected future schema rejection") }
        catch { XCTAssertEqual((error as? SlateSyncError)?.code, "SCENARIO_VERSION") }
        let badScene = ScenarioFieldProfile(label: "场次", aliases: [], region: [-1, 0, 1, 1], inherit: true, required: true)
        let badFields = ScenarioFields(
            cardNumber: original.fields.cardNumber, videoCode: original.fields.videoCode, scene: badScene,
            shot: original.fields.shot, take: original.fields.take, takeStatus: original.fields.takeStatus,
            description: original.fields.description, comments: original.fields.comments,
            shotSize: original.fields.shotSize, cameraPosition: original.fields.cameraPosition
        )
        do { _ = try await engine.normalize(copy(original, fields: badFields)); XCTFail("Expected bbox rejection") }
        catch { XCTAssertEqual((error as? SlateSyncError)?.code, "SCENARIO_BBOX") }
    }

    func testMatchCreateReusePersistsAtomically() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let library = try ProjectLibraryStore(libraryRoot: root.appending(path: "Library.slatesync-library", directoryHint: .isDirectory))
        let runtime = ProjectRuntime(library: library)
        let projectID = ProjectLibraryStore.defaultProjectID
        let service = ScenarioMatchingService(projectID: projectID, persistence: runtime)
        let first = try await service.matchAndSave(input: sample())
        let second = try await service.matchAndSave(input: sample(filename: "second.png"))
        XCTAssertEqual(first.match, "created")
        XCTAssertEqual(second.match, "reused")
        XCTAssertEqual(first.profile.id, second.profile.id)
        XCTAssertEqual(second.profile.sampleCount, 2)
        let summaries = try await runtime.listScenarios(projectID: projectID)
        XCTAssertEqual(summaries.count, 1)
        let project = try await library.getProject(projectID)
        let libraryInfo = try await library.libraryInfo()
        let database = try SQLiteDatabase(url: URL(fileURLWithPath: libraryInfo.path).appending(path: project.relativePath).appending(path: SQLiteV1.projectDatabaseFilename))
        let storedObservation = try await database.scalar("SELECT observation_json FROM scenario_observations ORDER BY created_at LIMIT 1;")
        let rawObservation = try XCTUnwrap(storedObservation)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(rawObservation.utf8)) as? [String: Any])
        XCTAssertNotNil(object["fingerprint"])
        XCTAssertNil(object["profile"], "v1 observation JSON keeps profile fields at the root")
        try await database.close()
        try await runtime.close()
        try await library.close()
    }

    func testConcurrentReuseRollbackReopenAndProjectIsolation() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let libraryRoot = root.appending(path: "Library.slatesync-library", directoryHint: .isDirectory)
        let library = try ProjectLibraryStore(libraryRoot: libraryRoot)
        let runtime = ProjectRuntime(library: library)
        let projectID = ProjectLibraryStore.defaultProjectID
        let service = ScenarioMatchingService(projectID: projectID, persistence: runtime)
        let competingService = ScenarioMatchingService(projectID: projectID, persistence: runtime)
        let firstInput = sample(filename: "one.png")
        let secondInput = sample(filename: "two.png")
        let results = try await withThrowingTaskGroup(of: ScenarioMatchResult.self) { group in
            group.addTask { try await service.matchAndSave(input: firstInput) }
            group.addTask { try await competingService.matchAndSave(input: secondInput) }
            var values: [ScenarioMatchResult] = []
            for try await value in group { values.append(value) }
            return values
        }
        XCTAssertEqual(Set(results.map(\.profile.id)).count, 1)
        let id = try XCTUnwrap(results.first?.profile.id)
        let concurrentProfile = try await runtime.loadScenario(projectID: projectID, scenarioID: id)
        XCTAssertEqual(concurrentProfile.sampleCount, 2)

        let candidate = try await ScenarioProfileEngine().profile(from: sample(), resolve: .init())
        do {
            _ = try await runtime.applyScenarioMatch(projectID: projectID, candidate: candidate, selectedProfileID: "scenario-missing", observationPayload: Data("{}".utf8))
            XCTFail("Expected foreign-key rollback")
        } catch { }
        let rolledBackProfile = try await runtime.loadScenario(projectID: projectID, scenarioID: id)
        XCTAssertEqual(rolledBackProfile.sampleCount, 2)
        let otherProject = try await library.createProject(name: "Other", description: "")
        let other = try await ScenarioMatchingService(projectID: otherProject.id, persistence: runtime).matchAndSave(input: sample())
        XCTAssertEqual(other.profile.sampleCount, 1)
        let isolatedProfile = try await runtime.loadScenario(projectID: projectID, scenarioID: id)
        XCTAssertEqual(isolatedProfile.sampleCount, 2)
        try await runtime.close()
        try await library.close()

        let reopenedLibrary = try ProjectLibraryStore(libraryRoot: libraryRoot)
        let reopenedRuntime = ProjectRuntime(library: reopenedLibrary)
        let reopenedProfile = try await reopenedRuntime.loadScenario(projectID: projectID, scenarioID: id)
        XCTAssertEqual(reopenedProfile.sampleCount, 2)
        let reopenedOther = try await reopenedRuntime.loadScenario(projectID: otherProject.id, scenarioID: other.profile.id)
        XCTAssertEqual(reopenedOther.sampleCount, 1)
        try await reopenedRuntime.close()
        try await reopenedLibrary.close()
    }

    private func sample(filename: String = "episode-01-slate.png", shuffled: Bool = false, includeInvalidBlock: Bool = false) -> ScenarioObservationInput {
        var blocks: [ScenarioOCRBlock] = [
            .init(text: "场次", confidence: 0.99, bboxNormalized: [0.05, 0.08, 0.12, 0.12]),
            .init(text: "镜", confidence: 0.99, bboxNormalized: [0.2, 0.08, 0.25, 0.12]),
            .init(text: "次", confidence: 0.99, bboxNormalized: [0.3, 0.08, 0.35, 0.12]),
            .init(text: "A机", confidence: 0.99, bboxNormalized: [0.7, 0.08, 0.78, 0.12]),
            .init(text: "87A", confidence: 0.95, bboxNormalized: [0.05, 0.45, 0.12, 0.5]),
            .init(text: "01", confidence: 0.95, bboxNormalized: [0.2, 0.45, 0.25, 0.5]),
            .init(text: "02", confidence: 0.95, bboxNormalized: [0.3, 0.45, 0.35, 0.5]),
        ]
        if includeInvalidBlock { blocks.append(.init(text: "ignored", confidence: .infinity, bboxNormalized: [-1, 0, 1, 1])) }
        if shuffled { blocks.reverse() }
        return ScenarioObservationInput(filename: filename, ocrEngine: "paddleocr", ocrUsed: true, pages: [.init(pageNumber: 1, views: [.init(width: 1200, height: 800, blocks: blocks)])])
    }

    private func fixtureObservation() throws -> ScenarioObservationInput {
        // The reviewed JS-derived observation is mandatory differential evidence.
        let url = try XCTUnwrap(Bundle.module.url(forResource: "observation", withExtension: "json"), "Missing SM05 Scenario observation fixture")
        return try JSONDecoder().decode(ScenarioObservationInput.self, from: Data(contentsOf: url))
    }

    private func copy(
        _ profile: ScenarioProfile,
        schemaVersion: Int? = nil,
        fingerprint: String? = nil,
        label: String? = nil,
        layout: ScenarioLayout? = nil,
        fields: ScenarioFields? = nil,
        recognition: ScenarioRecognitionConfig? = nil
    ) -> ScenarioProfile {
        ScenarioProfile(
            schemaVersion: schemaVersion ?? profile.schemaVersion,
            fingerprintVersion: profile.fingerprintVersion,
            fingerprint: fingerprint ?? profile.fingerprint,
            label: label ?? profile.label,
            layout: layout ?? profile.layout,
            fields: fields ?? profile.fields,
            recognition: recognition ?? profile.recognition,
            output: profile.output
        )
    }
}

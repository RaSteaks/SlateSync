import Foundation
import SlateSyncDomain

/// Serializes score selection per project and delegates the create/reuse plus
/// observation write through ProjectRuntime's project-addressed lease boundary.
public actor ScenarioMatchingService {
    private let engine: ScenarioProfileEngine
    private let projectID: String
    private let persistence: any ScenarioMatchingPersistence

    public init(
        projectID: String,
        engine: ScenarioProfileEngine = ScenarioProfileEngine(),
        persistence: any ScenarioMatchingPersistence
    ) {
        self.projectID = projectID
        self.engine = engine
        self.persistence = persistence
    }

    public func matchAndSave(
        input: ScenarioObservationInput,
        resolve: ProjectSettings.ResolveSettings = .init(),
        matching: ScenarioMatchingConfig = .init()
    ) async throws -> ScenarioMatchResult {
        try matching.validate()
        let candidate = try await engine.profile(from: input, resolve: resolve)
        let summaries = try await persistence.listScenarios(projectID: projectID)
        var scored: [(data: ScenarioData, score: Double, order: Int)] = []
        for (order, summary) in summaries.enumerated() {
            try Task.checkCancellation()
            let data = try await persistence.loadScenario(projectID: projectID, scenarioID: summary.id)
            let stored = try await engine.normalize(Self.profile(data))
            scored.append((data, try await engine.similarity(candidate, stored), order))
        }
        // JavaScript's stable sort preserves last_used_at order for score ties.
        scored.sort { left, right in left.score == right.score ? left.order < right.order : left.score > right.score }
        let best = scored.first
        let second = scored.dropFirst().first
        let confident = best.map { candidate in
            candidate.score >= matching.threshold && second.map { candidate.score - $0.score >= matching.ambiguityMargin } != false
        } ?? false
        let match = confident ? "reused" : "created"
        let score = confident ? (best?.score ?? 1) : 1
        let ambiguous = best.map { !confident && $0.score >= matching.threshold } ?? false
        // v1 stores profile fields at the observation root. A nested `profile`
        // key would make the same project.sqlite unreadable by Electron.
        let payload = try JSONEncoder().encode(ScenarioObservationPayload(candidate: candidate, matchedScore: score, match: match))
        let committed = try await persistence.applyScenarioMatch(
            projectID: projectID,
            candidate: candidate,
            selectedProfileID: confident ? best?.data.id : nil,
            observationPayload: payload
        )
        return ScenarioMatchResult(profile: committed.profile, observationId: committed.observationID, match: match, score: score, ambiguous: ambiguous)
    }

    private static func profile(_ data: ScenarioData) -> ScenarioProfile {
        ScenarioProfile(schemaVersion: data.schemaVersion, fingerprintVersion: data.fingerprintVersion, fingerprint: data.fingerprint, label: data.label, layout: data.layout, fields: data.fields, recognition: data.recognition, output: data.output)
    }
}

private struct ScenarioObservationPayload: Encodable {
    let schemaVersion: Int
    let fingerprintVersion: Int
    let fingerprint: String
    let label: String
    let layout: ScenarioLayout
    let fields: ScenarioFields
    let recognition: ScenarioRecognitionConfig
    let output: ScenarioOutputConfig
    let matchedScore: Double
    let match: String

    init(candidate: ScenarioProfile, matchedScore: Double, match: String) {
        schemaVersion = candidate.schemaVersion
        fingerprintVersion = candidate.fingerprintVersion
        fingerprint = candidate.fingerprint
        label = candidate.label
        layout = candidate.layout
        fields = candidate.fields
        recognition = candidate.recognition
        output = candidate.output
        self.matchedScore = matchedScore
        self.match = match
    }
}

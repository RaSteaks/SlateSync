import Foundation

/// Versioned structural evidence is separate from the v1 storage envelope.
/// Anchors describe printed headers in full-page coordinates, never filled values.
public struct ScenarioStructure: Codable, Hashable, Sendable {
    public struct Anchor: Codable, Hashable, Sendable {
        public let field: String
        public let box: [Double]
        public init(field: String, box: [Double]) { self.field = field; self.box = box }
    }
    public let version: Int
    public let anchors: [Anchor]
    public init(version: Int = 2, anchors: [Anchor]) { self.version = version; self.anchors = anchors }
}

/// Matching-only evidence from explicitly confirmed observations. It does not
/// replace a profile's original geometry or promote automatic matches to rules.
public struct ScenarioConfirmedAssociation: Codable, Hashable, Sendable {
    public let profileID: String
    public let structure: ScenarioStructure
    public init(profileID: String, structure: ScenarioStructure) {
        self.profileID = profileID; self.structure = structure
    }
}

/// Profiles and confirmed associations must describe the same storage revision.
public struct ScenarioMatchingSnapshot: Sendable {
    public let profiles: [ScenarioData]
    public let confirmedAssociations: [ScenarioConfirmedAssociation]
    public init(profiles: [ScenarioData], confirmedAssociations: [ScenarioConfirmedAssociation] = []) {
        self.profiles = profiles; self.confirmedAssociations = confirmedAssociations
    }
}

public struct ScenarioMatchDiagnostic: Codable, Hashable, Sendable {
    public let profileID: String
    public let score: Double
    public let coverage: Double
    public let geometry: Double
    public let orderMatches: Bool
    public init(profileID: String, score: Double, coverage: Double, geometry: Double, orderMatches: Bool) {
        self.profileID = profileID; self.score = score; self.coverage = coverage
        self.geometry = geometry; self.orderMatches = orderMatches
    }
}

/// A decision is read-only. Saving an observation or confirming a candidate
/// is an explicit later operation, so evaluation cannot mutate a template library.
public struct ScenarioPageDecision: Codable, Hashable, Sendable {
    public enum Status: String, Codable, Sendable { case reused, candidate, ambiguous, insufficient }
    public let pageNumber: Int
    public let status: Status
    public let candidate: ScenarioProfile?
    public let profile: ScenarioData?
    public let score: Double?
    public let diagnostics: [ScenarioMatchDiagnostic]
    public init(pageNumber: Int, status: Status, candidate: ScenarioProfile?, profile: ScenarioData? = nil,
                score: Double? = nil, diagnostics: [ScenarioMatchDiagnostic] = []) {
        self.pageNumber = pageNumber; self.status = status; self.candidate = candidate
        self.profile = profile; self.score = score; self.diagnostics = diagnostics
    }
}

public struct ScenarioCandidate: Codable, Hashable, Sendable {
    public let id: String
    public let profile: ScenarioProfile
    public let sourceCount: Int
    public init(id: String, profile: ScenarioProfile, sourceCount: Int) {
        self.id = id; self.profile = profile; self.sourceCount = sourceCount
    }
}

/// Only successful recognition writes this versioned observation. A nil
/// profile association is a candidate, not a new formal Scenario Profile.
public struct ScenarioLearningObservation: Codable, Hashable, Sendable {
    public let sourceDigest: String
    public let decision: ScenarioPageDecision
    public init(sourceDigest: String, decision: ScenarioPageDecision) {
        self.sourceDigest = sourceDigest; self.decision = decision
    }
}

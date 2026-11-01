import Foundation

public struct ScenarioMergePreview: Codable, Hashable, Sendable {
    public let source: ScenarioData
    public let target: ScenarioData
    public let warnings: [String]
    public init(source: ScenarioData, target: ScenarioData, warnings: [String]) {
        self.source = source; self.target = target; self.warnings = warnings
    }
}

/// The receipt refers to a durable before/after record. Merging keeps the old
/// profile ID as an alias so historical tasks never acquire dangling references.
public struct ScenarioMergeReceipt: Codable, Hashable, Sendable {
    public let id: String
    public let sourceID: String
    public let targetID: String
    public let sourceLabel: String
    public let targetLabel: String
    public init(id: String, sourceID: String, targetID: String, sourceLabel: String, targetLabel: String) {
        self.id = id; self.sourceID = sourceID; self.targetID = targetID
        self.sourceLabel = sourceLabel; self.targetLabel = targetLabel
    }
}

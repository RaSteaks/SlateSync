import Foundation
import SlateSyncDomain

/// Evaluation consumes a frozen snapshot and invokes the production matcher.
/// It has no persistence dependency and cannot learn from expected labels.
public enum ScenarioEvaluation {
    public struct ExpectedPage: Codable, Sendable {
        public let pageNumber: Int
        public let templateID: String?
        public init(pageNumber: Int, templateID: String?) { self.pageNumber = pageNumber; self.templateID = templateID }
        private enum CodingKeys: String, CodingKey { case pageNumber, templateID }
        public init(from decoder: any Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            guard values.contains(.templateID) else {
                throw DecodingError.keyNotFound(CodingKeys.templateID, .init(codingPath: decoder.codingPath,
                    debugDescription: "Use an explicit null for an unknown template; missing labels are not ground truth."))
            }
            pageNumber = try values.decode(Int.self, forKey: .pageNumber)
            templateID = try values.decodeIfPresent(String.self, forKey: .templateID)
        }
        public func encode(to encoder: any Encoder) throws {
            var values = encoder.container(keyedBy: CodingKeys.self)
            try values.encode(pageNumber, forKey: .pageNumber)
            if let templateID { try values.encode(templateID, forKey: .templateID) }
            else { try values.encodeNil(forKey: .templateID) }
        }
    }
    public struct Sample: Sendable {
        public let id: String
        public let sourceGroupID: String
        public let observation: ScenarioObservationInput
        public let expected: [ExpectedPage]
        public init(id: String, sourceGroupID: String, observation: ScenarioObservationInput, expected: [ExpectedPage]) {
            self.id = id; self.sourceGroupID = sourceGroupID; self.observation = observation; self.expected = expected
        }
    }
    public struct PageResult: Codable, Sendable {
        public let sampleID: String
        public let sourceGroupID: String
        public let pageNumber: Int
        public let expectedTemplateID: String?
        public let predictedTemplateID: String?
        public let status: ScenarioPageDecision.Status
        public let diagnostics: [ScenarioMatchDiagnostic]
    }
    public struct Report: Codable, Sendable {
        public let schemaVersion: Int
        public let scope: String
        public let structureVersion: Int
        public let matching: ScenarioMatchingConfig
        public let pages: [PageResult]
        public let knownPages: Int
        public let automaticallyAssignedKnownPages: Int
        public let correctlyAssignedKnownPages: Int
        public let unknownPages: Int
        public let incorrectlyAssignedUnknownPages: Int
        public let knownCoverage: Double?
        public let knownPrecision: Double?
        public let unknownAcceptance: Double?
    }

    public static func run(_ samples: [Sample], templates: [ScenarioData], matching: ScenarioMatchingConfig = .init()) throws -> Report {
        guard Set(samples.map(\.id)).count == samples.count, Set(templates.map(\.id)).count == templates.count,
              templates.allSatisfy({ !$0.id.isEmpty && $0.id.count <= 256 && $0.canonicalID == nil }) else {
            throw SlateSyncError(code: "EVALUATION_ID", message: "评测样本和模板 ID 必须唯一")
        }
        let knownIDs = Set(templates.map(\.id))
        var pages: [PageResult] = []
        for sample in samples {
            try Task.checkCancellation()
            let numbers = sample.observation.pages.map(\.pageNumber)
            guard !sample.id.isEmpty, sample.id.count <= 256, !sample.sourceGroupID.isEmpty, sample.sourceGroupID.count <= 256,
                  !numbers.isEmpty,
                  numbers.allSatisfy({ $0 > 0 }),
                  Set(numbers).count == numbers.count,
                  Set(sample.expected.map(\.pageNumber)) == Set(numbers), sample.expected.count == numbers.count,
                  sample.expected.compactMap(\.templateID).allSatisfy(knownIDs.contains) else {
                throw SlateSyncError(code: "EVALUATION_LABELS", message: "每一页都需要独立真值，已知模板标签必须存在于冻结快照")
            }
            // Labels are read only after inference and never passed to matching.
            let decisions = try ScenarioStructureMatcher.evaluate(sample.observation, profiles: templates, matching: matching)
            for decision in decisions {
                let expected = sample.expected.first { $0.pageNumber == decision.pageNumber }
                pages.append(.init(sampleID: sample.id, sourceGroupID: sample.sourceGroupID, pageNumber: decision.pageNumber,
                    expectedTemplateID: expected?.templateID, predictedTemplateID: decision.profile?.id,
                    status: decision.status, diagnostics: decision.diagnostics))
            }
        }
        let known = pages.filter { $0.expectedTemplateID != nil }
        let assigned = known.filter { $0.predictedTemplateID != nil }
        let unknown = pages.filter { $0.expectedTemplateID == nil }
        let correct = assigned.filter { $0.expectedTemplateID == $0.predictedTemplateID }.count
        let falseAcceptance = unknown.filter { $0.predictedTemplateID != nil }.count
        return .init(schemaVersion: 1, scope: "template-classification", structureVersion: 2, matching: matching, pages: pages,
                     knownPages: known.count, automaticallyAssignedKnownPages: assigned.count,
                     correctlyAssignedKnownPages: correct,
                     unknownPages: unknown.count, incorrectlyAssignedUnknownPages: falseAcceptance,
                     knownCoverage: known.isEmpty ? nil : Double(assigned.count) / Double(known.count),
                     knownPrecision: assigned.isEmpty ? nil : Double(correct) / Double(assigned.count),
                     unknownAcceptance: unknown.isEmpty ? nil : Double(falseAcceptance) / Double(unknown.count))
    }
}

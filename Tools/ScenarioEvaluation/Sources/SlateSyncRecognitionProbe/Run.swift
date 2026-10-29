import Foundation
import SlateSyncDomain
import SlateSyncMedia
import SlateSyncWorkflow

/// Offline probe only. Expected values never enter the production OCR call;
/// final-field scoring accepts separately exported production results.
@main struct RecognitionProbe {
    struct Manifest: Decodable {
        let samples: [Sample]
        let features: [String]
        let saveImages: Bool?
    }
    struct Sample: Decodable {
        let id: String
        let path: String
        let accuracy: MediaAccuracy?
        let recognizedResult: String?
        let labels: [Label]?
        let completeRecordCoverage: Bool?
    }
    struct Label: Decodable {
        let materialKey: String
        // Only listed fields are scored. An explicit empty string represents
        // a manually confirmed empty value; omission is unlabelled, not wrong.
        let fields: [String: String]
    }
    struct FieldScore: Encodable {
        let materialKey: String
        let field: String
        let expected: String
        let actual: String?
        let outcome: String
    }
    struct Score: Encodable {
        let missingKeys: [String]
        let extraKeys: [String]?
        let duplicateKeys: [String]
        let unkeyedRecordCount: Int
        let fields: [FieldScore]
    }
    struct Report: Encodable {
        let sample: String
        let sourceSHA256: String
        let features: [String]
        let strategyVersion: Int
        let sourceRevision: String?
        let operatingSystem: String
        let visionConfiguration: VisionOCRConfiguration
        let accuracy: MediaAccuracy
        let elapsedMilliseconds: Int
        let ocr: OCROutcome
        let structures: [Int: RecognitionTableStructure]
        let diagnostics: [String]
        let score: Score?
    }
    struct ProbeError: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) { self.description = description }
    }

    static func main() async throws {
        let arguments = CommandLine.arguments
        guard arguments.count == 3 else { throw ProbeError("Usage: SlateSyncRecognitionProbe manifest.json new-output-directory") }
        let manifestURL = URL(fileURLWithPath: arguments[1]).standardizedFileURL.resolvingSymlinksInPath()
        let root = manifestURL.deletingLastPathComponent()
        let output = URL(fileURLWithPath: arguments[2]).standardizedFileURL
        let data = try Data(contentsOf: manifestURL)
        guard data.count <= 4 * 1024 * 1024 else { throw ProbeError("Manifest exceeds 4 MiB") }
        let manifest = try JSONDecoder().decode(Manifest.self, from: data)
        let supported = Set(["dynamicCrops", "structureEvidence", "losslessLocalOCR", "targetedReview"])
        guard Set(manifest.features).isSubset(of: supported), !manifest.samples.isEmpty, manifest.samples.count <= 30,
              Set(manifest.samples.map(\.id)).count == manifest.samples.count,
              manifest.samples.allSatisfy({ !$0.id.isEmpty && $0.id.count <= 80 && $0.id.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }) }) else {
            throw ProbeError("Invalid features, sample count or sample IDs")
        }
        guard !FileManager.default.fileExists(atPath: output.path) else { throw ProbeError("Output directory must not exist") }
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: false)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try data.write(to: output.appendingPathComponent("manifest.json"), options: .atomic)
        let features = Set(manifest.features)
        let policy = RecognitionOptimizationPolicy(dynamicCrops: features.contains("dynamicCrops"),
            structureEvidence: features.contains("structureEvidence"), losslessLocalOCR: features.contains("losslessLocalOCR"),
            targetedReview: features.contains("targetedReview"))
        let vision = VisionOCRService()
        let ocr = LocalOCRService(vision: vision, paddle: nil, settings: .init(),
            visionAvailable: await vision.isAvailable(), paddleAvailable: false, cacheByView: true)
        do {
            for sample in manifest.samples {
                let input = try confined(sample.path, root: root)
                let source = try await MediaPreparationService().recognitionSource(.file(input), operation: .init())
                let frozenInput = await source.inputSnapshot()
                let start = ProcessInfo.processInfo.systemUptime
                let workflow = MediaOCRWorkflow(ocr: ocr, ownsOCR: false, policy: policy)
                let artifact: MediaOCRArtifact
                do {
                    artifact = try await workflow.run(input: frozenInput, session: sample.id,
                        accuracy: sample.accuracy ?? .high, cacheEnabled: false)
                    await workflow.close()
                } catch { await workflow.close(); throw error }
                let elapsed = Int((ProcessInfo.processInfo.systemUptime - start) * 1000)
                let score: Score?
                if let resultPath = sample.recognizedResult {
                    let resultData = try Data(contentsOf: confined(resultPath, root: root))
                    guard resultData.count <= 20 * 1024 * 1024 else { throw ProbeError("Recognition result exceeds 20 MiB") }
                    score = try evaluate(JSONDecoder().decode(RecognitionSheet.self, from: resultData), sample: sample)
                } else { score = nil }
                let report = Report(sample: sample.id, sourceSHA256: source.digest, features: manifest.features,
                    strategyVersion: RecognitionOptimizationPolicy.version,
                    sourceRevision: ProcessInfo.processInfo.environment["SLATESYNC_EVALUATION_REVISION"],
                    operatingSystem: ProcessInfo.processInfo.operatingSystemVersionString, visionConfiguration: .init(),
                    accuracy: sample.accuracy ?? .high, elapsedMilliseconds: elapsed, ocr: artifact.outcome,
                    structures: artifact.optimization?.structures ?? [:], diagnostics: artifact.optimization?.diagnostics ?? [], score: score)
                let directory = output.appendingPathComponent(sample.id, isDirectory: true)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
                try encoder.encode(report).write(to: directory.appendingPathComponent("report.json"), options: .atomic)
                if manifest.saveImages == true {
                    for page in artifact.document.pages {
                        for view in page.views {
                            try view.image.jpeg.write(to: directory.appendingPathComponent("page-\(page.pageNumber)-view-\(view.viewIndex).jpg"), options: .atomic)
                        }
                    }
                }
            }
            await ocr.close()
            try Data("Completed offline OCR probe; no Provider requests.\n".utf8).write(to: output.appendingPathComponent("completed.txt"), options: .atomic)
        } catch { await ocr.close(); throw error }
    }

    static func confined(_ path: String, root: URL) throws -> URL {
        let url = root.appendingPathComponent(path).standardizedFileURL.resolvingSymlinksInPath()
        guard !path.hasPrefix("/"), url.path.hasPrefix(root.path + "/") else { throw ProbeError("Inputs must remain inside the manifest directory") }
        return url
    }

    static func evaluate(_ result: RecognitionSheet, sample: Sample) throws -> Score {
        let labels = sample.labels ?? []
        guard Set(labels.map(\.materialKey)).count == labels.count,
              labels.allSatisfy({ Set($0.fields.keys).isSubset(of: ["scene", "shot", "take", "takeStatus"]) }) else {
            throw ProbeError("Duplicate labels or unsupported scoring fields")
        }
        let keyed = result.records.compactMap { record in RecognitionNormalizer.materialKey(record).map { ($0, record) } }
        let grouped = Dictionary(grouping: keyed, by: { $0.0 })
        var scores: [FieldScore] = []
        for label in labels {
            let matches = grouped[label.materialKey] ?? []
            let record = matches.count == 1 ? matches.first?.1 : nil
            for field in label.fields.keys.sorted() {
                let actual: String? = switch field {
                case "scene": record?.scene
                case "shot": record?.shot
                case "take": record?.take
                case "takeStatus": record?.takeStatus?.rawValue
                default: nil
                }
                let expected = (label.fields[field] ?? "").precomposedStringWithCanonicalMapping.trimmingCharacters(in: .whitespacesAndNewlines)
                let normalized = actual?.precomposedStringWithCanonicalMapping.trimmingCharacters(in: .whitespacesAndNewlines)
                let outcome: String
                if matches.count > 1 { outcome = "duplicate" }
                else if matches.isEmpty { outcome = "missing-record" }
                else if (normalized ?? "") == expected { outcome = "correct" }
                else if normalized == nil { outcome = "unknown" }
                else { outcome = "wrong" }
                scores.append(.init(materialKey: label.materialKey, field: field, expected: expected, actual: actual, outcome: outcome))
            }
        }
        let expectedKeys = Set(labels.map(\.materialKey)), actualKeys = Set(grouped.keys)
        return .init(missingKeys: expectedKeys.subtracting(actualKeys).sorted(),
            extraKeys: sample.completeRecordCoverage == true ? actualKeys.subtracting(expectedKeys).sorted() : nil,
            duplicateKeys: grouped.filter { $0.value.count > 1 }.keys.sorted(),
            unkeyedRecordCount: result.records.count - keyed.count, fields: scores)
    }
}

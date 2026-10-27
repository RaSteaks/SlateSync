import Darwin
import Foundation
import SlateSyncDomain
import SlateSyncMedia
import SlateSyncWorkflow

private struct Corpus: Codable {
    enum Mode: String, Codable { case training, evaluation }
    struct Input: Codable {
        let id: String
        let sourceGroupID: String
        let path: String
        let expected: [ScenarioEvaluation.ExpectedPage]
    }
    let schemaVersion: Int
    let mode: Mode?
    let templates: [ScenarioData]
    let samples: [Input]
    let matching: ScenarioMatchingConfig?
    let trainingSourceGroupIDs: [String]?
}

@main
struct Run {
    static func main() async {
        do { try await run() }
        catch {
            let code = (error as? SlateSyncError)?.code ?? "EVALUATION_FAILED"
            let message = StructuredLogRedactor.redactText((error as? SlateSyncError)?.message ?? String(describing: error))
            // Invalid corpora fail normally instead of generating a crash report
            // outside the caller's controlled evidence directory.
            try? FileHandle.standardError.write(contentsOf: Data("[\(code)] \(message)\n".utf8))
            exit(1)
        }
    }

    private static func run() async throws {
        let arguments = CommandLine.arguments
        guard arguments.count == 3 else {
            throw SlateSyncError(code: "EVALUATION_USAGE", message: "Usage: SlateSyncEvaluation <corpus.json> <new-output-directory>")
        }
        let manifest = URL(fileURLWithPath: arguments[1]).standardizedFileURL.resolvingSymlinksInPath()
        let corpusRoot = manifest.deletingLastPathComponent()
        let output = URL(fileURLWithPath: arguments[2]).standardizedFileURL
        guard !FileManager.default.fileExists(atPath: output.path) else {
            throw SlateSyncError(code: "EVALUATION_OUTPUT", message: "Use a new output directory; existing evidence is never overwritten")
        }
        let bytes = try boundedJSON(manifest)
        let corpus = try JSONDecoder().decode(Corpus.self, from: bytes)
        guard corpus.schemaVersion == 1, !corpus.samples.isEmpty, corpus.samples.count <= 1000 else { throw MediaFailure.invalidInput }
        guard corpus.mode != .training || corpus.templates.isEmpty else { throw MediaFailure.invalidInput }
        guard Set(corpus.samples.map(\.id)).count == corpus.samples.count else { throw MediaFailure.invalidInput }
        if corpus.mode != .training, let training = corpus.trainingSourceGroupIDs {
            guard Set(training).isDisjoint(with: corpus.samples.map(\.sourceGroupID)) else {
                throw SlateSyncError(code: "EVALUATION_LEAKAGE", message: "Training and evaluation source groups must not overlap")
            }
        }
        let engine = VisionOCRService()
        let visionAvailable = await engine.isAvailable()
        let preparation = MediaPreparationService()
        var samples: [ScenarioEvaluation.Sample] = []
        var timing: [String: [String: Int]] = [:]
        var pageCount = 0, evidenceBytes = 0
        do {
            for source in corpus.samples {
                let path = corpusRoot.appending(path: source.path).standardizedFileURL.resolvingSymlinksInPath()
                guard path.path.hasPrefix(corpusRoot.path + "/") else {
                    throw SlateSyncError(code: "EVALUATION_PATH", message: "Sample paths must stay within the corpus directory")
                }
                let observation: ScenarioObservationInput
                if path.pathExtension.lowercased() == "json" {
                    let data = try boundedJSON(path)
                    observation = try JSONDecoder().decode(ScenarioObservationInput.self, from: data)
                } else {
                    guard visionAvailable else { throw MediaFailure.unavailable }
                    let start = ProcessInfo.processInfo.systemUptime
                    let document = try await preparation.prepare(.file(path), options: .init(includesDetails: false))
                    let preparedAt = ProcessInfo.processInfo.systemUptime
                    let result = try await engine.recognize(document)
                    // A successful OCR call with zero text is a measurable
                    // abstention; framework failures still abort the run.
                    observation = ScenarioOCRAdapter.observation(filename: document.filename, outcome: .used(result, cacheHit: false))
                    timing[source.id] = ["prepare": Int((preparedAt - start) * 1000),
                        "ocr": Int((ProcessInfo.processInfo.systemUptime - preparedAt) * 1000)]
                }
                pageCount += observation.pages.count
                evidenceBytes += try JSONEncoder().encode(observation).count
                guard pageCount <= 300, evidenceBytes <= 128 * 1024 * 1024 else {
                    throw SlateSyncError(code: "EVALUATION_BUDGET", message: "Split corpora larger than 300 pages or 128 MiB of OCR evidence into separate batches")
                }
                samples.append(.init(id: source.id, sourceGroupID: source.sourceGroupID, observation: observation, expected: source.expected))
            }
            let report: ScenarioEvaluation.Report? = try corpus.mode == .training ? nil : ScenarioEvaluation.run(samples, templates: corpus.templates, matching: corpus.matching ?? .init())
            let templates = try corpus.mode == .training ? makeSnapshot(samples, matching: corpus.matching ?? .init()) : corpus.templates
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
            if let report { try encoder.encode(report).write(to: output.appending(path: "report.json"), options: .atomic) }
            try encoder.encode(timing).write(to: output.appending(path: "timing.json"), options: .atomic)
            // Save the actual frozen inputs beside the result for local replay;
            // these files are not sent to a Provider or any project library.
            try bytes.write(to: output.appending(path: "corpus.json"), options: .atomic)
            let replay = Corpus(schemaVersion: 1, mode: .evaluation, templates: templates, samples: corpus.mode == .training ? [] : corpus.samples.enumerated().map { index, source in
                .init(id: source.id, sourceGroupID: source.sourceGroupID, path: "observation-\(index + 1).json", expected: source.expected)
            }, matching: corpus.matching,
                trainingSourceGroupIDs: corpus.mode == .training ? Array(Set(samples.map(\.sourceGroupID))).sorted() : corpus.trainingSourceGroupIDs)
            try encoder.encode(replay).write(to: output.appending(path: corpus.mode == .training ? "snapshot.json" : "replay.json"), options: .atomic)
            let metadata: [String: JSONValue] = [
                "osVersion": .string(ProcessInfo.processInfo.operatingSystemVersionString),
                "trainingSplitChecked": .boolean(corpus.mode != .training && corpus.trainingSourceGroupIDs != nil),
                "providedSourceRevision": .string(ProcessInfo.processInfo.environment["SLATESYNC_EVALUATION_REVISION"] ?? "unspecified"),
                "providerRequests": .number(0), "projectLibraryWrites": .number(0),
            ]
            try encoder.encode(metadata).write(to: output.appending(path: "runtime.json"), options: .atomic)
            for (index, sample) in samples.enumerated() {
                try encoder.encode(sample.observation).write(to: output.appending(path: "observation-\(index + 1).json"), options: .atomic)
            }
            if let report {
                print("Evaluated \(report.pages.count) pages; known assignments \(report.correctlyAssignedKnownPages)/\(report.automaticallyAssignedKnownPages), coverage \(report.automaticallyAssignedKnownPages)/\(report.knownPages).")
                print("Report: \(output.appending(path: "report.json").path)")
            } else {
                print("Created \(templates.count) template prototypes. Add disjoint evaluation samples to snapshot.json before measuring accuracy.")
            }
            await engine.close()
        } catch {
            await engine.close()
            throw error
        }
    }

    private static func makeSnapshot(_ samples: [ScenarioEvaluation.Sample], matching: ScenarioMatchingConfig) throws -> [ScenarioData] {
        var templates: [String: ScenarioData] = [:]
        var groups: [String: Set<String>] = [:]
        for sample in samples.sorted(by: { $0.id < $1.id }) {
            guard !sample.id.isEmpty, sample.id.count <= 256, !sample.sourceGroupID.isEmpty, sample.sourceGroupID.count <= 256,
                  !sample.observation.pages.isEmpty,
                  sample.observation.pages.allSatisfy({ $0.pageNumber > 0 }),
                  Set(sample.observation.pages.map(\.pageNumber)).count == sample.observation.pages.count,
                  sample.expected.count == sample.observation.pages.count,
                  Set(sample.expected.map(\.pageNumber)) == Set(sample.observation.pages.map(\.pageNumber)) else {
                throw SlateSyncError(code: "EVALUATION_LABELS", message: "Training pages require explicit independent labels")
            }
            for page in sample.observation.pages {
                guard let label = sample.expected.first(where: { $0.pageNumber == page.pageNumber })?.templateID, !label.isEmpty, label.count <= 256 else {
                    throw SlateSyncError(code: "EVALUATION_LABELS", message: "Training pages require a nonempty template ID")
                }
                let input = ScenarioObservationInput(filename: label, pages: [page])
                let decision = try ScenarioStructureMatcher.evaluate(input, profiles: templates[label].map { [$0] } ?? [], matching: matching).first
                guard let candidate = decision?.candidate,
                      templates[label] == nil || decision?.status == .reused else {
                    throw SlateSyncError(code: "EVALUATION_STRUCTURE", message: "Training evidence is insufficient or examples with the same label have conflicting structures")
                }
                let previous = templates[label]
                groups[label, default: []].insert(sample.sourceGroupID)
                templates[label] = .init(id: label, profile: previous?.profile ?? candidate,
                    sampleCount: groups[label, default: []].count, createdAt: "", updatedAt: "", lastUsedAt: "")
            }
        }
        return templates.values.sorted { $0.id < $1.id }
    }

    private static func boundedJSON(_ url: URL) throws -> Data {
        guard try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else { throw MediaFailure.invalidInput }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: 20 * 1024 * 1024 + 1) ?? Data()
        guard !data.isEmpty, data.count <= 20 * 1024 * 1024 else { throw MediaFailure.invalidInput }
        return data
    }
}

import Foundation
import SlateSyncDomain
import SlateSyncPersistence
import XCTest

@testable import SlateSyncWorkflow

/// These regressions cross real module boundaries using only temporary data
/// and synthetic transport; no app, provider, or user's project is opened.
@MainActor
final class ArchitectureBoundaryTests: XCTestCase {
    func testUnrepresentableUsageIsIgnoredWithoutTrapping() throws {
        for number in ["9223372036854775807", "9223372036854775808", "1e300", "-1", "1.5"] {
            let data = Data(
                "{\"choices\":[{\"message\":{\"content\":\"{}\"}}],\"usage\":{\"total_tokens\":\(number),\"prompt_tokens\":12}}"
                    .utf8)
            let result = try ProviderRecognitionClient.extract(data, transport: .chatCompletions, mode: .jsonObject)
            XCTAssertNil(result.usage?.totalTokens)
            XCTAssertEqual(result.usage?.promptTokens, 12)
        }
    }

    func testUsageAggregationRejectsOverflowWithoutLosingOtherCounters() {
        let combined = RecognitionNormalizer.aggregateUsage([
            .init(totalTokens: Int.max, inputTokens: 3), .init(totalTokens: 1, inputTokens: 4)
        ])
        XCTAssertNil(combined?.totalTokens)
        XCTAssertEqual(combined?.inputTokens, 7)
        let layout = ScenarioLayout(pages: [], headerTokens: [], cameraGroups: [],
            columnBands: [Double(Int.max), 1e100], rowBands: [], blockCount: 0)
        XCTAssertEqual(ScenarioProfileEngine.fingerprint(layout).count, 32)
    }

    func testNativeProjectionRetainsUnknownFieldsAndClearsKnownOptionals() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "architecture-projection-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let library = try ProjectLibraryStore(libraryRoot: root)
        let runtime = ProjectRuntime(library: library)
        let projectID = ProjectLibraryStore.defaultProjectID
        _ = try await runtime.saveTask(
            projectID: projectID, taskID: "draft",
            payload: Data(
                #"{"id":"draft","customPrompt":"old","scenarioId":"selected","unknownFutureField":{"kept":true},"createdAt":"2020-01-01T00:00:00.000Z"}"#
                    .utf8))
        _ = try await runtime.saveTaskProjection(
            projectID: projectID, taskID: "draft", task: .init(id: "draft", customPrompt: "new"))
        let bytes = try await runtime.loadTask(projectID: projectID, taskID: "draft")
        let saved = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        XCTAssertEqual((saved["unknownFutureField"] as? [String: Bool])?["kept"], true)
        XCTAssertEqual(saved["customPrompt"] as? String, "new")
        XCTAssertNil(saved["scenarioId"])
        XCTAssertEqual(saved["createdAt"] as? String, "2020-01-01T00:00:00.000Z")
        try await runtime.close()
        try await library.close()
    }

    func testSimultaneousProbeAdmissionAndTerminalClose() async throws {
        let count = 32
        let gate = AdmissionGate(expected: count)
        let transport = AdmissionTransport(gate: gate)
        let id = "openai-compatible:123e4567-e89b-42d3-a456-426614174000"
        let provider = CustomProviderConfiguration(
            id: id, name: "Test", baseUrl: "https://fixture.invalid/v1", transport: .chatCompletions,
            manualModelIds: ["vision"])
        let probe = ModelCapabilityProbeService(
            registry: ProviderRegistry(customProviders: [provider]),
            client: ProviderRecognitionClient(transport: transport))
        let accepted = await withTaskGroup(of: Bool.self) { group in
            for _ in 0..<count {
                group.addTask {
                    do {
                        _ = try await probe.probe(providerID: id, modelIDs: ["vision"])
                        return true
                    } catch {
                        await gate.reject()
                        return false
                    }
                }
            }
            var accepted = 0
            for await success in group { if success { accepted += 1 } }
            return accepted
        }
        XCTAssertEqual(accepted, 1)
        let calls = await transport.calls
        XCTAssertEqual(calls, 1)
        await probe.close()
        do {
            _ = try await probe.probe(providerID: id, modelIDs: ["vision"])
            XCTFail("Closed probes cannot restart work")
        } catch { XCTAssertEqual((error as? SlateSyncError)?.code, RecognitionFailure.closed.code) }
    }
}

private actor AdmissionGate {
    let expected: Int
    var arrivals = 0
    var waiters: [CheckedContinuation<Void, Never>] = []
    init(expected: Int) { self.expected = expected }
    func reject() {
        arrivals += 1
        releaseIfReady()
    }
    func request() async {
        arrivals += 1
        if arrivals == expected {
            releaseIfReady()
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }
    private func releaseIfReady() {
        if arrivals == expected {
            let pending = waiters
            waiters = []
            pending.forEach { $0.resume() }
        }
    }
}
private actor AdmissionTransport: ProviderHTTPTransporting {
    let gate: AdmissionGate
    var calls = 0
    init(gate: AdmissionGate) { self.gate = gate }
    func send(_ request: ProviderTransportRequest) async throws -> ProviderTransportResponse {
        calls += 1
        await gate.request()
        return .init(
            status: 200, body: Data(#"{"choices":[{"message":{"content":"{\"ok\":true,\"marker\":\"ss-7q\"}"}}]}"#.utf8)
        )
    }
    func close() {}
}

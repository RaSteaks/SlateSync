import Foundation
import SlateSyncDomain
import SlateSyncMedia
@testable import SlateSyncWorkflow
import XCTest

private actor SM07CoordinatorPreparation: MediaPreparing {
    private(set) var calls = 0

    func prepare(
        _ input: MediaInput,
        options: MediaPreparationOptions,
        operation: MediaOperation,
        progress: MediaProgressSink?
    ) async throws -> PreparedDocument {
        calls += 1
        try operation.check()
        let image = try PreparedImage(jpeg: Data([0xff, 0xd8, 0xff, 0xd9]), width: 1, height: 1)
        progress?(.init(stage: "prepare", completed: 1, total: 1))
        return .init(filename: "fixture.jpg", pages: [
            .init(pageNumber: 1, views: [
                .init(viewIndex: 0, viewType: .full, image: image),
                .init(viewIndex: 1, viewType: .coreDetail, image: image),
            ])
        ])
    }
}

private actor SM07CoordinatorOCR: LocalOCREngine {
    private(set) var closes = 0

    func recognize(
        _ document: PreparedDocument,
        operation: MediaOperation,
        progress: MediaProgressSink?
    ) async throws -> OCREngineResult {
        try operation.check()
        progress?(.init(stage: "ocr", completed: document.viewCount, total: document.viewCount))
        return .init(engine: .vision, modelVersion: "fixture", pages: document.pages.map { page in
            .init(pageNumber: page.pageNumber, views: page.views.map { view in
                .init(viewIndex: view.viewIndex, viewType: view.viewType, width: view.image.width, height: view.image.height, blocks: [
                    .init(order: 0, text: "A001 C001 1 2 3 √", confidence: 0.95, bbox: [0, 0, 1, 1], bboxNormalized: [0, 0, 1, 1])
                ])
            })
        })
    }

    func close() { closes += 1 }
}

private actor SM07CoordinatorTransport: ProviderHTTPTransporting {
    enum Mode: Sendable { case success, stall }
    let mode: Mode
    private(set) var calls = 0
    private(set) var closed = false

    init(_ mode: Mode = .success) { self.mode = mode }

    func send(_ request: ProviderTransportRequest) async throws -> ProviderTransportResponse {
        calls += 1
        if mode == .stall {
            while true { try await Task.sleep(for: .milliseconds(10)) }
        }
        let sheet: JSONValue = .object([
            "sheetTitle": .string("fixture"),
            "records": .array([.object([
                "cardNumber": .string("A001"), "videoCode": .string("C001"),
                "scene": .string("1"), "shot": .string("2"), "take": .string("3"),
                "takeStatus": .string("√"), "description": .null, "comments": .null,
                "shotSize": .null, "cameraPosition": .null, "confidence": .string("high"),
            ])]),
            "warnings": .array([]),
        ])
        let text = String(data: try JSONEncoder().encode(sheet), encoding: .utf8)!
        let envelope: JSONValue = .object([
            "id": .string("response-fixture"), "model": .string("gpt-4o-mini"),
            "output_text": .string(text),
            "usage": .object(["input_tokens": .number(4), "output_tokens": .number(5)]),
        ])
        return .init(status: 200, body: try JSONEncoder().encode(envelope))
    }

    func close() { closed = true }
    func waitUntilStarted() async { while calls == 0 { await Task.yield() } }
}

private actor SM07RecognitionPersistence: RecognitionPersistence {
    let settings: ProjectSettings
    private(set) var tasks: [Data] = []
    private(set) var diagnostics: [Data] = []
    private(set) var touches = 0

    init(settings: ProjectSettings) { self.settings = settings }

    func recognitionProject(projectID: String) -> ProjectData {
        .init(summary: .init(
            id: projectID, name: "Fixture", relativePath: projectID,
            createdAt: "2026-09-05T00:00:00Z", updatedAt: "2026-09-05T00:00:00Z"
        ), settings: settings)
    }

    func saveTask(projectID: String, taskID: String?, payload: Data) -> String {
        tasks.append(payload); return taskID ?? "task-fixture"
    }

    func saveDiagnostic(projectID: String, sessionID: String?, payload: Data) -> String {
        diagnostics.append(payload); return sessionID ?? "diagnostic-fixture"
    }

    func touchRecognitionActivity(projectID: String) { touches += 1 }
}

@MainActor final class SM07CoordinatorTests: XCTestCase {
    private func runtime(
        transport: SM07CoordinatorTransport,
        preparation: SM07CoordinatorPreparation,
        ocr: SM07CoordinatorOCR,
        persistence: SM07RecognitionPersistence? = nil,
        limiter: RecognitionLimiter? = nil
    ) -> RecognitionCoordinator {
        let registry = ProviderRegistry()
        let client = ProviderRecognitionClient(transport: transport)
        return RecognitionCoordinator(
            registry: registry,
            client: client,
            mediaFactory: {
                MediaOCRWorkflow(
                    preparation: preparation,
                    ocr: LocalOCRService(
                        vision: ocr, paddle: nil, settings: .init(),
                        visionAvailable: true, paddleAvailable: false
                    )
                )
            },
            persistence: persistence,
            settings: .init([.modelPageConcurrency: "2"]),
            limiter: limiter
        )
    }

    private func request(projectID: String = "project-a", legacy: Data? = nil) -> NativeRecognitionRequest {
        .init(
            projectID: projectID, input: .bytes(Data("fixture".utf8), filename: "fixture.jpg"),
            filename: "fixture.jpg", taskID: "requested-task", providerID: "openai",
            modelID: "openai/gpt-4o-mini",
            settings: .init(providerId: "openai", modelId: "openai/gpt-4o-mini", accuracyMode: .standard),
            legacyRequest: legacy
        )
    }

    func testFLW01FLW03FLW04FLW06FLW08FLW09FLW10RES01EndToEndPersistenceAndProgress() async throws {
        let transport = SM07CoordinatorTransport(), preparation = SM07CoordinatorPreparation(), ocr = SM07CoordinatorOCR()
        let persistence = SM07RecognitionPersistence(settings: .init(providerId: "openai", modelId: "openai/gpt-4o-mini", accuracyMode: .standard))
        let coordinator = runtime(transport: transport, preparation: preparation, ocr: ocr, persistence: persistence)
        let stream = await coordinator.progress(for: "project-a")
        let progressTask = Task { () -> [RecognitionProgress] in
            var events: [RecognitionProgress] = []
            for await event in stream {
                events.append(event)
                if event.phase == "complete" { break }
            }
            return events
        }

        let output = try await coordinator.recognize(request())
        let events = await progressTask.value
        let taskPayloads = await persistence.tasks, diagnosticPayloads = await persistence.diagnostics
        let touches = await persistence.touches, active = await coordinator.activeOperationCount()
        let task = try JSONDecoder().decode(TaskData.self, from: try XCTUnwrap(taskPayloads.first))

        XCTAssertEqual(output.result.records.first?.cardNumber, "A001")
        XCTAssertEqual(output.result.records.first?.scene, "001")
        XCTAssertEqual(output.result.records.first?.shot, "02")
        XCTAssertEqual(output.result.records.first?.takeStatus, .passed)
        XCTAssertEqual(output.usage?.inputTokens, 4); XCTAssertEqual(output.taskId, "requested-task")
        XCTAssertEqual(task.status, "completed"); XCTAssertNil(task.imageDataGroups); XCTAssertEqual(task.editedRecords?.count, 1)
        XCTAssertEqual(diagnosticPayloads.count, 1); XCTAssertEqual(touches, 1); XCTAssertEqual(active, 0)
        XCTAssertTrue(events.contains { $0.phase == "ocr" }); XCTAssertEqual(events.last?.phase, "complete")
        XCTAssertEqual(events.compactMap(\.percent), events.compactMap(\.percent).sorted())

        await coordinator.close(); await coordinator.close()
        let transportClosed = await transport.closed, observerCount = await coordinator.observerCount()
        XCTAssertTrue(transportClosed); XCTAssertEqual(observerCount, 0)
        do { _ = try await coordinator.recognize(request()); XCTFail() }
        catch { XCTAssertEqual((error as? SlateSyncError)?.code, "RECOGNITION_CLOSED") }
    }

    func testFLW02DirectPDFGuardHasZeroMediaOrNetworkAndPersistsDiagnostic() async throws {
        let transport = SM07CoordinatorTransport(), preparation = SM07CoordinatorPreparation(), ocr = SM07CoordinatorOCR()
        let persistence = SM07RecognitionPersistence(settings: .init(providerId: "openai", modelId: "openai/gpt-4o-mini", accuracyMode: .standard))
        let coordinator = runtime(transport: transport, preparation: preparation, ocr: ocr, persistence: persistence)
        let legacy = Data(#"{"pdfDataUrl":"data:application/pdf;base64,AAAA"}"#.utf8)
        do { _ = try await coordinator.recognize(request(legacy: legacy)); XCTFail() }
        catch { XCTAssertEqual((error as? SlateSyncError)?.code, "DIRECT_PDF_UNSUPPORTED") }
        let preparationCalls = await preparation.calls, transportCalls = await transport.calls
        let tasks = await persistence.tasks, diagnostics = await persistence.diagnostics
        XCTAssertEqual(preparationCalls, 0); XCTAssertEqual(transportCalls, 0)
        XCTAssertTrue(tasks.isEmpty); XCTAssertEqual(diagnostics.count, 1)
        await coordinator.close()
    }

    func testFLW05FLW07GlobalFailFastAndProjectCancellationDrain() async throws {
        let transport = SM07CoordinatorTransport(.stall), preparation = SM07CoordinatorPreparation(), ocr = SM07CoordinatorOCR()
        let limiter = RecognitionLimiter(limit: 1)
        let coordinator = runtime(transport: transport, preparation: preparation, ocr: ocr, limiter: limiter)
        let first = Task { try await coordinator.recognize(request(projectID: "project-a")) }
        await transport.waitUntilStarted()
        do { _ = try await coordinator.recognize(request(projectID: "project-b")); XCTFail() }
        catch { XCTAssertEqual((error as? SlateSyncError)?.code, "RECOGNITION_BUSY"); XCTAssertEqual((error as? SlateSyncError)?.status, 429) }

        let canceled = await coordinator.cancelAndWait(projectID: "project-a")
        XCTAssertTrue(canceled)
        do { _ = try await first.value; XCTFail() }
        catch { XCTAssertEqual((error as? SlateSyncError)?.code, "RECOGNITION_CANCELED") }
        let active = await coordinator.activeOperationCount(), limited = await limiter.activeCount()
        XCTAssertEqual(active, 0); XCTAssertEqual(limited, 0)
        await coordinator.close()
    }
}

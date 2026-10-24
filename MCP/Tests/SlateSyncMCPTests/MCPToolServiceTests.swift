import CoreGraphics
import Foundation
import ImageIO
import MCP
import SlateSyncDomain
import SlateSyncPersistence
import SlateSyncWorkflow
import UniformTypeIdentifiers
import XCTest
@testable import SlateSyncMCP

/// All I/O uses disposable roots. Provider responses are injected, so these
/// tests never access the operator's library, credentials or a real model API.
@MainActor final class MCPToolServiceTests: XCTestCase {
    private func root() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appending(path: "mcp-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }
    private func service(_ root: URL, models: Bool = false, transport: (any ProviderHTTPTransporting)? = nil) throws -> MCPToolService {
        let runtime = SlateSyncRuntime(locator: .init(root: root.appending(path: "settings")),
            environment: ["VISIONOCR_ENABLED": "false", "PADDLEOCR_ENABLED": "false"])
        let factory: (@Sendable () -> any ProviderHTTPTransporting)?
        if let transport { factory = { transport } } else { factory = nil }
        return try MCPToolService(files: .init(roots: [root]), runtime: runtime, allowsModelRequests: models,
            transportFactory: factory)
    }
    private func csv(_ root: URL, secondRow: Bool = false) throws -> URL {
        let file = root.appending(path: "resolve.csv")
        try Data(("File Name,Scene,Shot,Take,Comments\r\nA001C001.mov,,,,\r\n"
            + (secondRow ? "B001C002.mov,keep,,,\r\n" : "")).utf8).write(to: file)
        return file
    }
    private let record: Value = ["cardNumber": "A001", "videoCode": "C001", "scene": "1", "shot": "2", "take": "3", "takeStatus": "过"]

    func testImportPreviewExportUsesSharedByteSemanticsAndNeverOverwrites() async throws {
        let root = try root(), service = try service(root), csv = try csv(root)
        let slate = root.appending(path: "slate.csv")
        try Data("File Name,Scene,Shot,Take,Comments\nA001C001.mov,1,2,3,OK\n".utf8).write(to: slate)
        let imported = try await service.call(.init(name: "slatesync_import_slate_csv", arguments: ["path": .string(slate.path)]))
        let records = try XCTUnwrap(imported.structuredContent?["records"])
        let preview = try await service.call(.init(name: "slatesync_preview_merge", arguments: ["csvPath": .string(csv.path), "records": records]))
        XCTAssertEqual(preview.structuredContent?["canExport"], true)
        XCTAssertEqual(preview.structuredContent?["matchedRecordCount"], 1)
        let output = root.appending(path: "output.csv")
        let args: [String: Value] = ["csvPath": .string(csv.path), "records": records, "outputPath": .string(output.path)]
        let exported = try await service.call(.init(name: "slatesync_export_csv", arguments: args))
        XCTAssertEqual(exported.isError, false)
        let expected = try await SM05WorkflowServices().mergeAndEncode(source: Data(contentsOf: csv),
            records: [.init(cardNumber: "A001", videoCode: "C001", scene: "1", shot: "2", take: "3", takeStatus: .passed)])
        XCTAssertEqual(try Data(contentsOf: output), expected.data)
        let again = try await service.call(.init(name: "slatesync_export_csv", arguments: args))
        XCTAssertEqual(again.structuredContent?["code"], "MCP_OUTPUT_EXISTS")
        XCTAssertEqual(try Data(contentsOf: output), expected.data)
        await service.close()
    }

    func testReviewMustBeExplicitAndIncompletePreviewRemainsAvailable() async throws {
        let root = try root(), service = try service(root), csv = try csv(root, secondRow: true)
        var args: [String: Value] = ["csvPath": .string(csv.path), "records": .array([record]),
                                    "outputPath": .string(root.appending(path: "reviewed.csv").path)]
        let blocked = try await service.call(.init(name: "slatesync_export_csv", arguments: args))
        XCTAssertEqual(blocked.structuredContent?["code"], "MCP_REVIEW_REQUIRED")
        args["allowWarnings"] = true
        let exported = try await service.call(.init(name: "slatesync_export_csv", arguments: args))
        XCTAssertEqual(exported.isError, false)
        args["records"] = [["cardNumber": "A001", "videoCode": "C001"]]
        let incomplete = try await service.call(.init(name: "slatesync_export_csv", arguments: args))
        XCTAssertEqual(incomplete.structuredContent?["code"], "CSV_NO_EXPORT")
        args.removeValue(forKey: "outputPath"); args.removeValue(forKey: "allowWarnings")
        let preview = try await service.call(.init(name: "slatesync_preview_merge", arguments: args))
        XCTAssertEqual(preview.isError, false)
        XCTAssertEqual(preview.structuredContent?["canExport"], false)
        XCTAssertEqual(preview.structuredContent?["statuses"]?.arrayValue?.first?["status"], "incomplete")
        await service.close()
    }

    func testScanUsesEditedMaterialIdentityAndReportsConflicts() async throws {
        let root = try root(), service = try service(root), csv = try csv(root)
        let folder = root.appending(path: "B001C002")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for (name, fps) in [("B001C002-slate.txt", "24"), ("camera-slate.txt", "48")] {
            try Data("Clip Name: B001C002\nSensor FPS: \(fps)".utf8).write(to: folder.appending(path: name))
        }
        let result = try await service.call(.init(name: "slatesync_scan_metadata", arguments: [
            "csvPath": .string(csv.path), "directoryPath": .string(root.path),
            "edits": [["rowIndex": 0, "columnIndex": 0, "value": "B001C002.mov"]]
        ]))
        XCTAssertEqual(result.structuredContent?["metadata"]?.arrayValue?.count, 2)
        XCTAssertEqual(result.structuredContent?["missingKeys"], Value.array([]))
        await service.close()
    }

    func testFileGrantsRejectTraversalSiblingPrefixAndEscapingSymlink() throws {
        let root = try root(), outside = try self.root()
        let secret = outside.appending(path: "outside.txt")
        try Data("outside".utf8).write(to: secret)
        let access = try MCPFileAccess(roots: [root])
        XCTAssertThrowsError(try access.read(secret.path, maximumBytes: 100))
        XCTAssertThrowsError(try access.permittedURL(root.path + "-sibling/file"))
        XCTAssertThrowsError(try access.permittedURL(root.path + "/../other/file"))
        let link = root.appending(path: "link.txt")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: secret)
        XCTAssertThrowsError(try access.read(link.path, maximumBytes: 100))
        XCTAssertThrowsError(try access.writeNew(Data("overwrite".utf8), path: link.path))
        XCTAssertEqual(try Data(contentsOf: secret), Data("outside".utf8))
        // No grants allow protocol startup, but still deny all file operations.
        let empty = try MCPFileAccess(roots: [])
        XCTAssertThrowsError(try empty.read(secret.path, maximumBytes: 100))
        XCTAssertThrowsError(try empty.writeNew(Data(), path: root.appending(path: "denied.csv").path))
        XCTAssertThrowsError(try MCPFileAccess(roots: [URL(fileURLWithPath: "/")]))
    }

    func testSchemaValidationRejectsUnknownFieldsAndInvalidEnumsBeforeIO() async throws {
        let root = try root(), service = try service(root)
        for arguments: [String: Value] in [
            ["csvPath": "/does-not-exist", "records": [], "apiKey": "never-accepted"],
            ["csvPath": "/does-not-exist", "records": [], "limit": 0],
            ["csvPath": "/does-not-exist", "records": [["takeStatus": "guess"]]],
            ["csvPath": "/does-not-exist", "records": [], "edits": [["rowIndex": -1, "columnIndex": 0, "value": "x"]]]
        ] {
            do {
                _ = try await service.call(.init(name: "slatesync_preview_merge", arguments: arguments))
                XCTFail("Invalid input must be rejected before file access")
            } catch let error as MCPError {
                guard case .invalidParams = error else { return XCTFail("Unexpected error \(error)") }
            }
        }
        let disabled = try await service.call(.init(name: "slatesync_recognize", arguments: ["path": "/does-not-exist"]))
        XCTAssertEqual(disabled.structuredContent?["code"], "MCP_MODEL_REQUESTS_DISABLED")
        await service.close()
    }

    func testPreviewPagesReportTotals() async throws {
        let root = try root(), service = try service(root), csv = try csv(root, secondRow: true)
        let result = try await service.call(.init(name: "slatesync_preview_merge", arguments: [
            "csvPath": .string(csv.path), "records": .array([record]), "offset": 1, "limit": 1
        ]))
        XCTAssertEqual(result.structuredContent?["rowCount"], 2)
        XCTAssertEqual(result.structuredContent?["rows"]?.arrayValue?.count, 1)
        XCTAssertEqual(result.structuredContent?["rows"]?.arrayValue?.first?.arrayValue?.first, "B001C002.mov")
        await service.close()
    }

    func testRecognitionRunsSharedPipelineWithInjectedProviderAndProgress() async throws {
        let root = try root(), transport = MCPFixtureTransport()
        let service = try service(root, models: true, transport: transport)
        let path = try image(root)
        let progress = MCPProgressCollector()
        let result = try await service.call(.init(name: "slatesync_recognize", arguments: [
            "path": .string(path.path), "providerID": "openai", "modelID": "openai/gpt-4o-mini", "accuracyMode": "standard"
        ]), progress: { await progress.append($0) })
        XCTAssertEqual(result.isError, false, "\(result.content)")
        XCTAssertEqual(result.structuredContent?["records"]?.arrayValue?.first?["scene"], "001")
        let calls = await transport.calls
        let phases = await progress.phases
        XCTAssertEqual(calls, 1)
        XCTAssertTrue(phases.contains("complete"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appending(path: "settings/Projects").path))
        await service.close()
    }

    func testCloseCancelsAndJoinsRecognition() async throws {
        let root = try root(), transport = MCPFixtureTransport(stalls: true)
        let service = try service(root, models: true, transport: transport)
        let path = try image(root)
        let call = Task { try await service.call(.init(name: "slatesync_recognize", arguments: [
            "path": .string(path.path), "providerID": "openai", "modelID": "openai/gpt-4o-mini", "accuracyMode": "standard"
        ])) }
        await transport.waitUntilStarted()
        await service.close()
        do { _ = try await call.value; XCTFail("Closing must cancel recognition") } catch is CancellationError { }
        let closed = await transport.closed
        XCTAssertTrue(closed)
    }

    private func image(_ root: URL) throws -> URL {
        let context = try XCTUnwrap(CGContext(data: nil, width: 64, height: 64, bitsPerComponent: 8, bytesPerRow: 256,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(gray: 1, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
        let data = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try XCTUnwrap(context.makeImage()), nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        let path = root.appending(path: "slate.jpg"); try (data as Data).write(to: path); return path
    }
}

private extension Value {
    // Concise assertions still inspect the SDK's structured JSON, not text matches.
    subscript(_ key: String) -> Value? { objectValue?[key] }
}

private actor MCPProgressCollector {
    var phases: [String] = []
    func append(_ progress: RecognitionProgress) { phases.append(progress.phase) }
}

private actor MCPFixtureTransport: ProviderHTTPTransporting {
    var calls = 0
    var closed = false
    let stalls: Bool
    init(stalls: Bool = false) { self.stalls = stalls }
    func send(_ request: ProviderTransportRequest) async throws -> ProviderTransportResponse {
        calls += 1
        if stalls { while true { try await Task.sleep(for: .milliseconds(10)) } }
        let text = #"{"records":[{"cardNumber":"A001","videoCode":"C001","scene":"1","shot":"2","take":"3","takeStatus":"过","confidence":"high"}],"warnings":[]}"#
        return .init(status: 200, body: try JSONEncoder().encode(["output_text": text]))
    }
    func close() { closed = true }
    func waitUntilStarted() async {
        // The timeout makes setup failures visible instead of hanging a suite.
        for _ in 0..<5_000 {
            if calls > 0 { return }
            try? await Task.sleep(for: .milliseconds(1))
        }
    }
}

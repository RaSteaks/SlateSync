import Foundation
import SlateSyncDomain
@testable import SlateSyncWorkflow
import XCTest

/// Offline probes exercise real decision branches without a user's Python,
/// Paddle installation, project data, credentials, or model downloads.
final class OCREnvironmentCheckerTests: XCTestCase, @unchecked Sendable {
    private actor Runner: PaddleInstallerCommandRunning {
        var calls: [(URL, [String], [String: String], Duration)] = []
        let python: String
        let dependencies: String
        let failsPython: Bool
        let failsDependencies: Bool
        init(supported: Bool = true, missing: String? = nil, failsPython: Bool = false, failsDependencies: Bool = false) {
            python = "{\"supported\":\(supported),\"version\":\"3.12.1\",\"executable\":\"/fixture/python\",\"architecture\":\"arm64\"}"
            dependencies = "[" + ["paddle", "paddleocr", "cv2", "numpy", "pip", "venv"].map {
                "{\"name\":\"\($0)\",\"available\":\($0 != missing),\"version\":\"3.0\"}"
            }.joined(separator: ",") + "]"
            self.failsPython = failsPython; self.failsDependencies = failsDependencies
        }
        func run(executable: URL, arguments: [String], directory: URL, environment: [String: String], timeout: Duration) async throws -> PaddleInstallerCommandResult {
            calls.append((executable, arguments, environment, timeout))
            let isPython = arguments.last?.contains("sys.version_info") == true
            if isPython ? failsPython : failsDependencies { throw CocoaError(.executableNotLoadable) }
            return .init(stdout: isPython ? python : dependencies)
        }
        func cancel() async {}
        func capturedCalls() -> [(URL, [String], [String: String], Duration)] { calls }
    }

    private func check(_ runner: Runner, python: String = "/fixture/python", language: String = "zh-Hans") async throws -> [OCREnvironmentCheck] {
        try await OCREnvironmentChecker(runner: runner).check(
            values: .init([.paddleOCRPython: python, .visionOCRLanguage: language]),
            directory: URL(fileURLWithPath: NSTemporaryDirectory()),
            runnerURL: URL(fileURLWithPath: "/fixture/missing-runner.py"),
            environment: ["PATH": "/usr/bin", "OPENAI_API_KEY": "secret", "PIP_INDEX_URL": "private"])
    }

    func testReportsVersionsAndStripsCredentials() async throws {
        let runner = Runner()
        let checks = try await check(runner)
        XCTAssertEqual(checks.first { $0.id == "python" }?.status, .passed)
        XCTAssertTrue(checks.first { $0.id == "python" }?.detail.contains("arm64") == true)
        XCTAssertEqual(checks.first { $0.id == "paddle" }?.detail, "3.0")
        XCTAssertEqual(checks.first { $0.id == "runner" }?.status, .failed)
        let calls = await runner.capturedCalls()
        XCTAssertEqual(calls.count, 2)
        XCTAssertTrue(calls.allSatisfy { $0.2["OPENAI_API_KEY"] == nil && $0.2["PIP_INDEX_URL"] == nil })
        XCTAssertEqual(calls.last?.3, .seconds(45))
        XCTAssertEqual(calls.last?.2["PADDLE_PDX_DISABLE_MODEL_SOURCE_CHECK"], "True")
    }

    func testExplicitBrokenPythonDoesNotFallback() async throws {
        let runner = Runner(failsPython: true)
        let checks = try await check(runner)
        XCTAssertEqual(checks.first { $0.id == "python" }?.status, .failed)
        let calls = await runner.capturedCalls()
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls.first?.0.path, "/fixture/python")
    }

    func testUnsupportedPythonStopsBeforeImports() async throws {
        let runner = Runner(supported: false)
        let checks = try await check(runner)
        XCTAssertEqual(checks.first { $0.id == "python" }?.status, .failed)
        let calls = await runner.capturedCalls()
        XCTAssertEqual(calls.count, 1)
    }

    func testSystemPythonIsNotPresentedAsConfiguredOCR() async throws {
        let checks = try await check(Runner(), python: "")
        XCTAssertEqual(checks.first { $0.id == "configuration" }?.status, .warning)
    }

    func testMissingDependencyIsDistinctFromOptionalInstallTool() async throws {
        let missingPaddle = try await check(Runner(missing: "paddle"))
        let missingPip = try await check(Runner(missing: "pip"))
        XCTAssertEqual(missingPaddle.first { $0.id == "paddle" }?.status, .failed)
        XCTAssertEqual(missingPip.first { $0.id == "pip" }?.status, .warning)
        XCTAssertEqual(missingPip.first { $0.id == "paddle" }?.status, .passed)
    }

    func testImportCrashKeepsPythonAndVisionResults() async throws {
        let checks = try await check(Runner(failsDependencies: true))
        XCTAssertEqual(checks.first { $0.id == "dependencies" }?.status, .failed)
        XCTAssertEqual(checks.first { $0.id == "python" }?.status, .passed)
        XCTAssertNotNil(checks.first { $0.id == "vision" })
    }

    func testUnsupportedVisionLanguageIsUnavailable() async throws {
        let checks = try await check(Runner(), language: "invalid-language")
        XCTAssertEqual(checks.first { $0.id == "vision" }?.status, .failed)
    }
}

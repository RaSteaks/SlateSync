import XCTest
@testable import SlateSyncDomain

final class GlobalSettingsTests: XCTestCase {
    func testDefaultsCoverEveryDeclaredGlobalSetting() {
        XCTAssertEqual(GlobalSettingsValidator.defaults.values.count, GlobalSettingKey.allCases.count)
        for key in GlobalSettingKey.allCases {
            XCTAssertNotNil(GlobalSettingsValidator.defaults[key], key.rawValue)
        }
    }

    func testResolutionPrecedenceMatchesNativeStartupContract() throws {
        let global = try GlobalSettingsPatch(rawValues: [
            "OPENAI_BASE_URL": "https://global.example/v1",
            "PADDLEOCR_PYTHON": "/global/python",
        ])
        let explicit = GlobalSettingValues([.openAIBaseUrl: "https://explicit.example/v1"])
        let process = [
            "OPENAI_BASE_URL": "https://process.example/v1",
            "OPENROUTER_BASE_URL": "https://process.example/v1",
            "PADDLEOCR_PYTHON": "/process/python",
            "PADDLEOCR_LANGUAGE": "",
        ]
        let envFile = [
            "OPENAI_BASE_URL": "https://env.example/v1",
            "OPENROUTER_BASE_URL": "https://env.example/v1",
            "PADDLEOCR_LANGUAGE": "en",
        ]
        let legacyPythonPath = "/legacy/python"
        let resolved = GlobalSettingsValidator.resolveValues(
            processEnvironment: process,
            envFile: envFile,
            globalOverrides: GlobalSettingValues(global.values.reduce(into: [:]) { result, entry in
                result[entry.key] = entry.value ?? ""
            }),
            explicit: explicit,
            legacyPaddlePythonPath: legacyPythonPath
        )

        XCTAssertEqual(resolved[.openAIBaseUrl], "https://explicit.example/v1")
        XCTAssertEqual(resolved[.openRouterBaseUrl], "https://process.example/v1")
        XCTAssertEqual(resolved[.paddleOCRPython], "/global/python")
        XCTAssertEqual(resolved[.paddleOCRLanguage], "ch")
        XCTAssertEqual(resolved[.visionOCRLanguage], "zh-Hans")
    }

    func testResolutionKeepsLegacyPythonAboveProcessOnlyWhenGlobalDoesNotOwnIt() {
        let legacy = "/legacy/python"
        let process = ["PADDLEOCR_PYTHON": "/process/python"]
        let env = ["PADDLEOCR_PYTHON": "/env/python"]

        let legacyResolved = GlobalSettingsResolution.resolve(
            key: .paddleOCRPython,
            processEnvironment: process,
            envFile: env,
            legacyPaddlePythonPath: legacy
        )
        let globalResolved = GlobalSettingsResolution.resolve(
            key: .paddleOCRPython,
            processEnvironment: process,
            envFile: env,
            globalOverrides: GlobalSettingValues([.paddleOCRPython: "/global/python"]),
            legacyPaddlePythonPath: legacy
        )
        XCTAssertEqual(legacyResolved.value, "/legacy/python")
        XCTAssertEqual(legacyResolved.source, .legacySettings)
        XCTAssertEqual(globalResolved.value, "/global/python")
        XCTAssertEqual(globalResolved.source, .globalSettings)
    }

    func testDynamicPaddleCacheDefaultUsesTheNativeApplicationSupportRoot() {
        let root = URL(fileURLWithPath: "/tmp/slatesync-domain-root", isDirectory: true)

        let resolved = GlobalSettingsResolution.resolve(
            key: .paddlePDXCacheHome,
            applicationSupportRoot: root
        )

        // The dynamic native default must point at the same product data root
        // that the runtime passes to its settings and migration stores.
        XCTAssertEqual(resolved.value, root.appending(path: "paddlex").path)
        XCTAssertEqual(resolved.source, .defaults)
    }

    func testURLAndNumericValidationRejectUnsafeValues() {
        XCTAssertThrowsError(try GlobalSettingsPatch(rawValues: ["OPENAI_BASE_URL": "file:///tmp/key"]))
        XCTAssertThrowsError(try GlobalSettingsPatch(rawValues: ["OPENAI_BASE_URL": "https://user:pass@example.test/v1"]))
        XCTAssertThrowsError(try GlobalSettingsPatch(rawValues: ["MAX_BODY_MB": "201"]))
        XCTAssertThrowsError(try GlobalSettingsPatch(rawValues: ["VISIONOCR_TIMEOUT_MS": "9000"]))
    }

    func testJavaScriptTextBoundariesAndEnumNormalizationArePreserved() throws {
        XCTAssertEqual(
            try GlobalSettingsPatch(rawValues: ["PADDLEOCR_PYTHON": String(repeating: "p", count: 200)])
                .values[.paddleOCRPython],
            String(repeating: "p", count: 200)
        )
        XCTAssertThrowsError(
            try GlobalSettingsPatch(rawValues: ["PADDLEOCR_PYTHON": String(repeating: "p", count: 201)])
        )
        XCTAssertThrowsError(
            try GlobalSettingsPatch(rawValues: ["PADDLEOCR_LANGUAGE": String(repeating: "😀", count: 61)])
        )

        let normalized = try GlobalSettingsPatch(rawValues: [
            "OPENAI_COMPATIBLE_API_MODE": " RESPONSES ",
            "MAX_BODY_MB": " 1e2 ",
        ])
        XCTAssertEqual(normalized.values[.openAICompatibleAPIMode], "responses")
        XCTAssertEqual(normalized.values[.maxBodyMB], "100")
    }

    func testURLNormalizationMatchesJavaScriptURLAuthorityAndDotSegments() throws {
        let patch = try GlobalSettingsPatch(rawValues: [
            "OPENAI_BASE_URL": "https://EXAMPLE.com:443/a/../v1///"
        ])

        // The Electron global-settings normalizer removes one trailing slash
        // after WHATWG URL canonicalization; the Swift helper must also drop
        // the default port and resolve literal dot segments.
        XCTAssertEqual(
            patch.values[.openAIBaseUrl] ?? nil,
            "https://example.com/v1//"
        )
    }
}

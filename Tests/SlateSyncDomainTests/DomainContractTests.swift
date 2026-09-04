import Foundation
import XCTest
@testable import SlateSyncDomain

final class DomainContractTests: XCTestCase {
    func testLegacyTaskFixtureDecodesAndPreservesCSVCompatibility() throws {
        let data = try fixtureData(named: "legacy-task")
        let task = try JSONDecoder().decode(TaskData.self, from: data)

        XCTAssertEqual(task.id, "baseline-task-001")
        XCTAssertEqual(task.projectSettingsSnapshot?.accuracyMode, .high)
        XCTAssertEqual(task.resolveCsvTable?.format.lineEnding, "\n")
        XCTAssertEqual(task.result?.records.first?.takeStatus, .passed)
        XCTAssertEqual(task.usage?.inputTokens, 10)
        XCTAssertEqual(task.slateMetadata?.first?.materialKey, "A001C001")
    }

    func testLegacyTaskWithoutWarningsDefaultsToAnEmptyList() throws {
        let data = Data(
            #"{"id":"legacy-no-warnings","result":{"sheetTitle":"Legacy","records":[]}}"#.utf8
        )

        let task = try JSONDecoder().decode(TaskData.self, from: data)

        // Frozen Electron snapshots may omit the field entirely; absence is
        // distinct from a malformed value and must remain a readable task.
        XCTAssertEqual(task.result?.warnings, [])
    }

    func testLegacyProjectFixtureUsesDefaultsAndIgnoresUnknownFields() throws {
        let project = try JSONDecoder().decode(
            ProjectData.self,
            from: fixtureData(named: "legacy-project")
        )

        XCTAssertEqual(project.summary.name, "默认项目")
        XCTAssertEqual(project.settings.version, 1)
        XCTAssertEqual(project.settings.resolve.fieldFormats.scene, "XXX")
        XCTAssertEqual(project.settings.resolve.comments.goodTake, "_OK")
        XCTAssertEqual(project.lastRecognitionDefaults?.modelId, "openai/gpt-5.6-luna")
    }

    func testWorkflowRejectsInvalidValuesWhileProjectSettingsNormalizeThem() throws {
        let invalidSettings = Data(#"{"version":2}"#.utf8)
        let normalizedSettings = try JSONDecoder().decode(ProjectSettings.self, from: invalidSettings)
        XCTAssertEqual(normalizedSettings.version, 1)

        let malformedSettings = try JSONDecoder().decode(
            ProjectSettings.self,
            from: Data(#"{"version":"future","accuracyMode":"unsupported"}"#.utf8)
        )
        XCTAssertEqual(malformedSettings.version, 1)
        XCTAssertEqual(malformedSettings.accuracyMode, .high)

        let coercedLegacyValues = try JSONDecoder().decode(
            ProjectSettings.self,
            from: Data(#"{"providerId":[0,false,null],"customPrompt":0,"resolve":{"comments":{"goodTake":[0,false,null]}}}"#.utf8)
        )
        // Match JavaScript's top-level `String(value || "")` and its array
        // element coercion at the forgiving legacy boundary.
        XCTAssertEqual(coercedLegacyValues.providerId, "0,false,")
        XCTAssertEqual(coercedLegacyValues.customPrompt, "")
        XCTAssertEqual(coercedLegacyValues.resolve.comments.goodTake, "0,false,")

        let invalidWorkflow = Data(#"{"scenario":{"matching":{"threshold":0.1}}}"#.utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(WorkflowConfig.self, from: invalidWorkflow)) { error in
            XCTAssertEqual((error as? SlateSyncError)?.code, "CONFIG_INVALID")
        }

        let legacyCSV = Data(#"{"encoding":"utf-8","delimiter":",","newline":"\n","bom":false}"#.utf8)
        let format = try JSONDecoder().decode(ResolveCSVFormat.self, from: legacyCSV)
        XCTAssertEqual(format.lineEnding, "\n")
    }

    func testWorkflowIsStrictAfterNormalizationWhileProjectSettingsAreForgiving() throws {
        let workflow = try JSONDecoder().decode(
            WorkflowConfig.self,
            from: Data(
                #"{"resolve":{"fieldFormats":{"scene":" xxx ","shot":" x ","take":"xx"},"comments":{"goodTake":" _PASS ","holdTake":"_KEEP"}}}"#.utf8
            )
        )
        XCTAssertEqual(workflow.resolve.fieldFormats.scene, "XXX")
        XCTAssertEqual(workflow.resolve.fieldFormats.shot, "X")
        XCTAssertEqual(workflow.resolve.comments.goodTake, "_PASS")

        let javascriptNumericWorkflow = try JSONDecoder().decode(
            WorkflowConfig.self,
            from: Data(
                #"{"slate":{"maxDirectoryDepth":"0x4"},"scenario":{"matching":{"threshold":"9e-1","ambiguityMargin":"5e-2"}}}"#.utf8
            )
        )
        XCTAssertEqual(javascriptNumericWorkflow.slate.maxDirectoryDepth, 4)
        XCTAssertEqual(javascriptNumericWorkflow.scenario.matching.threshold, 0.9, accuracy: 0.000001)
        XCTAssertEqual(javascriptNumericWorkflow.scenario.matching.ambiguityMargin, 0.05, accuracy: 0.000001)

        XCTAssertThrowsError(
            try JSONDecoder().decode(
                WorkflowConfig.self,
                from: Data(#"{"resolve":{"fieldFormats":{"scene":"XXXXXXX"}}}"#.utf8)
            )
        )

        let project = try JSONDecoder().decode(
            ProjectSettings.self,
            from: Data(
                #"{"version":1,"customPrompt":null,"resolve":{"fieldFormats":{"scene":" xxx ","shot":"invalid","take":7},"comments":{"goodTake":" _PASS ","holdTake":42}}}"#.utf8
            )
        )
        // Project snapshots are normalized field-by-field so one malformed
        // legacy value does not make an otherwise usable project unreadable.
        XCTAssertEqual(project.resolve.fieldFormats.scene, "XXX")
        XCTAssertEqual(project.resolve.fieldFormats.shot, "XX")
        XCTAssertEqual(project.resolve.fieldFormats.take, "XX")
        XCTAssertEqual(project.resolve.comments.goodTake, "_PASS")
        XCTAssertEqual(project.resolve.comments.holdTake, "42")
    }

    func testTransientCredentialRequestsRoundTripWhilePersistedConfigStaysSecretFree() throws {
        let request = CustomProviderConfigRequest(
            name: "Gateway",
            baseUrl: "https://gateway.example/v1",
            apiKey: "sk-test-secret",
            replaceApiKey: true
        )
        let encodedRequest = String(decoding: try JSONEncoder().encode(request), as: UTF8.self)
        XCTAssertTrue(encodedRequest.contains("sk-test-secret"))
        XCTAssertTrue(encodedRequest.contains("apiKey"))
        let decodedRequest = try JSONDecoder().decode(
            CustomProviderConfigRequest.self,
            from: Data(encodedRequest.utf8)
        )
        XCTAssertEqual(decodedRequest.apiKey, "sk-test-secret")
        XCTAssertEqual(decodedRequest.replaceApiKey, true)

        let keyRequest = ProviderKeyRequest(provider: "openai", apiKey: "sk-another-secret")
        let encodedKey = String(decoding: try JSONEncoder().encode(keyRequest), as: UTF8.self)
        XCTAssertTrue(encodedKey.contains("sk-another-secret"))
        XCTAssertTrue(encodedKey.contains("apiKey"))
        let decodedKey = try JSONDecoder().decode(
            ProviderKeyRequest.self,
            from: Data(encodedKey.utf8)
        )
        XCTAssertEqual(decodedKey, keyRequest)

        let persisted = CustomProviderConfiguration(
            id: "openai-compatible",
            name: "Gateway",
            baseUrl: "https://gateway.example/v1"
        )
        let encodedPersisted = String(decoding: try JSONEncoder().encode(persisted), as: UTF8.self)
        XCTAssertFalse(encodedPersisted.contains("apiKey"))
        XCTAssertFalse(encodedPersisted.contains("sk-test-secret"))
    }

    func testUpdateCustomProviderPreservesProviderIdThroughCodableRoundTrip() throws {
        let request = CustomProviderConfigRequest(
            id: "openai-compatible:00000000-0000-4000-8000-000000000007",
            providerId: "openai-compatible:00000000-0000-4000-8000-000000000007",
            name: "Gateway",
            baseUrl: "https://gateway.example/v1"
        )
        let update = UpdateCustomProviderRequest(id: request.id ?? "", request: request)

        let data = try JSONEncoder().encode(update)
        let decoded = try JSONDecoder().decode(UpdateCustomProviderRequest.self, from: data)

        // `providerId` is the additive alias used by newer IPC callers; it
        // must survive native Codable even though `id` remains required here.
        XCTAssertEqual(decoded.providerId, request.providerId)
        XCTAssertEqual(decoded.configRequest.providerId, request.providerId)
    }

    func testDomainResultUsesSharedSuccessAndFailureWireShapes() throws {
        let success: DomainResult<String> = .success("ready")
        let successData = try JSONEncoder().encode(success)
        let successObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: successData) as? [String: Any]
        )
        XCTAssertEqual(successObject["ok"] as? Bool, true)
        XCTAssertEqual(successObject["data"] as? String, "ready")
        XCTAssertEqual(try JSONDecoder().decode(DomainResult<String>.self, from: successData), success)

        let failure: DomainResult<String> = .failure(
            SlateSyncError(code: "TEST", message: "failed", retryable: true)
        )
        let failureData = try JSONEncoder().encode(failure)
        let failureObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: failureData) as? [String: Any]
        )
        XCTAssertEqual(failureObject["ok"] as? Bool, false)
        let errorObject = try XCTUnwrap(failureObject["error"] as? [String: Any])
        XCTAssertEqual(errorObject["code"] as? String, "TEST")
        XCTAssertEqual(errorObject["message"] as? String, "failed")
        XCTAssertEqual(errorObject["retryable"] as? Bool, true)
        XCTAssertEqual(try JSONDecoder().decode(DomainResult<String>.self, from: failureData), failure)

        XCTAssertThrowsError(
            try JSONDecoder().decode(
                DomainResult<String>.self,
                from: Data(#"{"ok":true,"data":"ready","error":null}"#.utf8)
            )
        )
        XCTAssertThrowsError(
            try JSONDecoder().decode(
                DomainResult<String>.self,
                from: Data(#"{"ok":false,"data":"unexpected","error":{"code":"TEST","message":"failed","retryable":true}}"#.utf8)
            )
        )
    }

    func testDiscriminatedResultsRejectCrossBranchFieldsAndEncodeExactShapes() throws {
        let ocrError = OcrCheckError(code: "OCR_UNAVAILABLE", message: "unavailable")
        let ocrSuccess = try OcrCheckResult(
            ok: true,
            paddleVersion: "3.0",
            paddleOcrVersion: "3.1"
        )
        let ocrSuccessObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(ocrSuccess)) as? [String: Any]
        )
        XCTAssertEqual(ocrSuccessObject.keys.sorted(), ["ok", "paddleOcrVersion", "paddleVersion"])
        XCTAssertThrowsError(
            try OcrCheckResult(ok: true, paddleVersion: "3.0", error: ocrError)
        )
        XCTAssertThrowsError(
            try JSONDecoder().decode(
                OcrCheckResult.self,
                from: Data(#"{"ok":true,"paddleVersion":"3.0","paddleOcrVersion":"3.1","error":null}"#.utf8)
            )
        )
        let visionSuccess = try VisionOcrCheckResult(
            ok: true,
            engine: "Vision",
            modelVersion: "macOS-Vision",
            systemVersion: "15.0"
        )
        XCTAssertEqual(visionSuccess.ok, true)
        XCTAssertThrowsError(
            try VisionOcrCheckResult(ok: false, engine: "Vision", error: ocrError)
        )

        let library = ValidatedLibraryInfo(
            id: "library-1",
            name: "Library",
            path: "/synthetic/library",
            projectCount: 1
        )
        let imported = try LibraryImportResult(
            canceled: false,
            restartRequired: true,
            library: library
        )
        let importedObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(imported)) as? [String: Any]
        )
        XCTAssertEqual(importedObject["canceled"] as? Bool, false)
        XCTAssertEqual(importedObject["restartRequired"] as? Bool, true)
        XCTAssertNotNil(importedObject["library"])

        let canceledData = try JSONEncoder().encode(LibraryImportResult.canceled)
        let canceledObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: canceledData) as? [String: Any]
        )
        XCTAssertEqual(canceledObject.keys.sorted(), ["canceled"])
        XCTAssertThrowsError(
            try JSONDecoder().decode(
                LibraryImportResult.self,
                from: Data(#"{"canceled":true,"restartRequired":false}"#.utf8)
            )
        )
        XCTAssertThrowsError(
            try LibraryImportResult(canceled: false, library: library)
        )

        let libraryInfo = LibraryInfo(id: "library-1", name: "Library", path: "/synthetic/library")
        let renamed = try LibraryRenameResult(
            canceled: false,
            restartRequired: true,
            library: libraryInfo
        )
        XCTAssertEqual(renamed.restartRequired, true)
        XCTAssertThrowsError(try LibraryRenameResult(canceled: true, library: libraryInfo))

        let projectSummary = ProjectSummary(
            id: "project-1",
            name: "Project",
            relativePath: "Project.slatesync-project",
            createdAt: "2026-09-04T00:00:00Z",
            updatedAt: "2026-09-04T00:00:00Z"
        )
        let project = ProjectData(summary: projectSummary)
        let importedProject = try ProjectImportResult(canceled: false, project: project)
        XCTAssertNotNil(importedProject.project)
        XCTAssertThrowsError(try ProjectImportResult(canceled: true, project: project))
        let exportedProject = try ProjectExportResult(
            canceled: false,
            project: projectSummary,
            path: "/synthetic/Project.slatesync-project"
        )
        XCTAssertEqual(exportedProject.path, "/synthetic/Project.slatesync-project")
        XCTAssertThrowsError(try ProjectExportResult(canceled: true, path: "/synthetic/project"))
        let exportedLibrary = try LibraryExportResult(canceled: false, library: library)
        XCTAssertNotNil(exportedLibrary.library)
    }

    func testLegacyCustomProviderFieldsReceiveNativeDefaults() throws {
        let data = Data(#"{"id":"openai-compatible:00000000-0000-4000-8000-000000000001","label":"Legacy","baseUrl":"https://gateway.example/v1"}"#.utf8)
        let provider = try JSONDecoder().decode(CustomProviderConfiguration.self, from: data)

        XCTAssertEqual(provider.name, "Legacy")
        XCTAssertEqual(provider.transport, .chatCompletions)
        XCTAssertEqual(provider.jsonMode, .jsonSchema)
        XCTAssertEqual(provider.imageDetail, .high)
        XCTAssertEqual(provider.revision, 1)
    }

    func testGlobalSettingPatchIsTypedAndOCRRoutingIsExclusive() throws {
        let patch = try GlobalSettingsPatch(rawValues: [
            "PADDLEOCR_ENABLED": "true",
            "MAX_BODY_MB": "120",
        ])
        let routed = GlobalSettingsValidator.normalizeOcrRoutingPatch(patch)

        XCTAssertEqual(routed.values[.paddleOCREnabled], "true")
        XCTAssertEqual(routed.values[.visionOCREnabled], "false")
        XCTAssertEqual(routed.values[.visionOCRRequired], "false")
        XCTAssertEqual(routed.values[.maxBodyMB], "120")
        XCTAssertThrowsError(try GlobalSettingsPatch(rawValues: ["NOT_A_SETTING": "1"]))
    }

    private func fixtureData(named name: String) throws -> Data {
        let url = try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: "json"))
        return try Data(contentsOf: url)
    }
}

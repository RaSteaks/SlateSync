import SlateSyncDomain
@testable import SlateSyncUI
import XCTest

/// Regression freeze for review finding #8: saving a changed workflow config
/// path must not hot-switch it. The save response carries `restartRequired`
/// and the Settings surface announces "已保存；工作流路径下次启动生效。" —
/// the retained Electron save status — instead of the plain saved message.
@MainActor
final class GlobalSettingsRestartStatusTests: XCTestCase {
    private func projection(restartRequired: Bool) -> GlobalSettingsProjection {
        GlobalSettingsProjection(
            values: GlobalSettingValues([.slateSyncConfigPath: "next.json"]),
            customProviders: [],
            providers: [],
            models: [],
            configuredCredentialProviderIDs: [],
            visionAvailable: false,
            paddleAvailable: false,
            runtime: GlobalRuntimeProjection(
                resolvedSettingCount: 1,
                globalConfigVersion: 2,
                environmentFileLoaded: false,
                workflowConfigPath: "/tmp/next.json"
            ),
            restartRequired: restartRequired
        )
    }

    private actor RestartSettingsFake: GlobalSettingsWorkflowServing {
        private(set) var checkedValues: GlobalSettingValues?
        let saveResponse: GlobalSettingsProjection
        private let loadResponse: GlobalSettingsProjection
        private let suspendsChecks: Bool

        init(saveResponse: GlobalSettingsProjection, loadResponse: GlobalSettingsProjection, suspendsChecks: Bool = false) {
            self.saveResponse = saveResponse
            self.loadResponse = loadResponse
            self.suspendsChecks = suspendsChecks
        }

        func globalSettings() async throws -> GlobalSettingsProjection { loadResponse }
        // Diagnostics echo their snapshot, allowing the model tests to detect
        // accidental saves, draft resets, or stale-result publication.
        func checkOCREnvironment(values: GlobalSettingValues) async throws -> [OCREnvironmentCheck] {
            checkedValues = values
            if suspendsChecks { try await Task.sleep(for: .seconds(60)) }
            return [.init(id: "python", title: "Python", status: .passed, detail: "3.12")]
        }
        func saveGlobalSettings(
            values: GlobalSettingValues,
            customProviders: [CustomProviderConfiguration]
        ) async throws -> GlobalSettingsProjection { saveResponse }
        func setProviderCredential(_ value: String?, providerID: String) async throws {}


        func discoverModels(providerID: String, forceRefresh: Bool) async throws -> ModelDiscoveryResult {
            throw SlateSyncError(code: "TEST_UNREACHABLE", message: "not part of this fixture", status: 500)
        }
        func probeModels(providerID: String, modelIDs: [String], progress: @escaping @Sendable (ModelProbeProgress) -> Void) async throws -> ModelProbeResult {
            throw SlateSyncError(code: "TEST_UNREACHABLE", message: "not part of this fixture", status: 500)
        }
        func cancelModelProbe(providerID: String) async {}
        func installPaddleOCR(progress: @escaping @Sendable (PaddleOcrInstallProgress) -> Void) async throws -> PaddleOcrInstallResult {
            throw SlateSyncError(code: "TEST_UNREACHABLE", message: "not part of this fixture", status: 500)
        }
        func cancelPaddleOCRInstallation() async {}
    }

    func testOCRCheckUsesDraftAndMarksResultsStaleAfterEditing() async {
        let fake = RestartSettingsFake(saveResponse: projection(restartRequired: false), loadResponse: projection(restartRequired: false))
        let model = GlobalSettingsModel(service: fake)
        await model.load()
        model.setValue("/draft/python", for: .paddleOCRPython)
        await model.checkOCREnvironment()
        let checked = await fake.checkedValues
        XCTAssertEqual(checked?[.paddleOCRPython], "/draft/python")
        XCTAssertNil(model.live?.values[.paddleOCRPython])
        XCTAssertFalse(model.ocrChecksAreStale)
        model.setValue("fast", for: .visionOCRRecognitionLevel)
        XCTAssertTrue(model.ocrChecksAreStale)
        await model.checkOCREnvironment()
        XCTAssertFalse(model.ocrChecksAreStale)
        XCTAssertEqual(model.value(.paddleOCRPython), "/draft/python")
        model.invalidateOCREnvironmentCheck()
        XCTAssertTrue(model.ocrChecks.isEmpty)
    }

    func testOCRCheckDoesNotRunAfterDrain() async {
        let fake = RestartSettingsFake(saveResponse: projection(restartRequired: false), loadResponse: projection(restartRequired: false))
        let model = GlobalSettingsModel(service: fake)
        await model.drain()
        await model.checkOCREnvironment()
        let checked = await fake.checkedValues
        XCTAssertNil(checked)
        XCTAssertFalse(model.ocrCheckOperation.isRunning)
    }

    func testDrainCancelsAndJoinsRunningOCRCheck() async {
        let fake = RestartSettingsFake(saveResponse: projection(restartRequired: false), loadResponse: projection(restartRequired: false), suspendsChecks: true)
        let model = GlobalSettingsModel(service: fake)
        let task = Task { await model.checkOCREnvironment() }
        while !model.ocrCheckOperation.isRunning { await Task.yield() }
        await model.drain()
        await task.value
        XCTAssertEqual(model.ocrCheckOperation, .canceled)
        XCTAssertTrue(model.ocrChecks.isEmpty)
    }

    func testChangedWorkflowPathSaveAnnouncesRestartRequirement() async {
        let fake = RestartSettingsFake(
            saveResponse: projection(restartRequired: true),
            loadResponse: projection(restartRequired: false)
        )
        let model = GlobalSettingsModel(service: fake)
        await model.load()

        model.setValue("next.json", for: .slateSyncConfigPath)
        await model.save()

        guard case .succeeded(let message) = model.operation else {
            return XCTFail("保存应成功：\(model.operation)")
        }
        XCTAssertEqual(message, "已保存；工作流路径下次启动生效。")
        XCTAssertEqual(model.live?.restartRequired, true, "重启要求必须随投影发布给 Settings 页面")
    }

    func testUnchangedWorkflowPathSaveKeepsPlainStatus() async {
        let fake = RestartSettingsFake(
            saveResponse: projection(restartRequired: false),
            loadResponse: projection(restartRequired: false)
        )
        let model = GlobalSettingsModel(service: fake)
        await model.load()

        await model.save()

        guard case .succeeded(let message) = model.operation else {
            return XCTFail("保存应成功：\(model.operation)")
        }
        XCTAssertEqual(message, "全局设置已保存")
        XCTAssertEqual(model.live?.restartRequired, false)
    }
}

import Foundation
import AppKit
import Darwin
import SlateSyncDomain
import SlateSyncPersistence
@testable import SlateSyncUI
@testable import SlateSyncWorkflow
import XCTest
import SwiftUI
import CryptoKit

final class SM08OwnershipTests: XCTestCase {
    func testAutosaveFlushWritesOnlyLatestImmutableSnapshot() async throws {
        let probe = AutosaveProbe()
        let autosave = WorkspaceAutosave(delay: .seconds(30)) { projectID, taskID, snapshot in
            try await probe.write(projectID: projectID, taskID: taskID, snapshot: snapshot)
        }
        await autosave.schedule(projectID: "p1", taskID: "t1", snapshot: TaskData(customPrompt: "旧值"))
        await autosave.schedule(projectID: "p1", taskID: "t1", snapshot: TaskData(customPrompt: "最新值"))

        try await autosave.flush()

        let writes = await probe.snapshots
        let hasPending = await autosave.hasPendingChanges()
        XCTAssertEqual(writes.map(\.customPrompt), ["最新值"])
        XCTAssertFalse(hasPending)
    }

    func testAutosaveFailureRetainsSnapshotForRetry() async throws {
        let probe = AutosaveProbe(failuresRemaining: 1)
        let autosave = WorkspaceAutosave(delay: .seconds(30)) { projectID, taskID, snapshot in
            try await probe.write(projectID: projectID, taskID: taskID, snapshot: snapshot)
        }
        await autosave.schedule(projectID: "p1", taskID: "t1", snapshot: TaskData(customPrompt: "保留我"))

        do {
            try await autosave.flush()
            XCTFail("首次写入应失败")
        } catch {
            let hasPending = await autosave.hasPendingChanges()
            XCTAssertTrue(hasPending)
        }
        try await autosave.retry()

        let writes = await probe.snapshots
        let hasPending = await autosave.hasPendingChanges()
        XCTAssertEqual(writes.map(\.customPrompt), ["保留我"])
        XCTAssertFalse(hasPending)
    }

    @MainActor
    func testProjectMutationsStopAtFailedWorkspaceBarrier() async {
        let service = ProjectLibraryFake()
        let barrier = MutationBarrierProbe()
        let model = ProjectLibraryModel(service: service) {
            try await barrier.flush()
        }
        await model.load()
        let project = service.projectSummary

        await model.archive(project)
        await model.export(project, to: URL(fileURLWithPath: "/tmp/project.slatesync-project"))
        await model.importProject(from: URL(fileURLWithPath: "/tmp/import.slatesync-project"))
        await model.importLibrary(from: URL(fileURLWithPath: "/tmp/import.slatesync-library"))
        await model.relocateLibrary(to: URL(fileURLWithPath: "/tmp/library"))
        model.libraryNameDraft = "新项目库"
        await model.renameLibrary()
        model.requestDeletion(project)
        model.deletionConfirmation = project.name
        await model.confirmDeletion()

        let calls = await service.mutationCalls
        let flushes = await barrier.flushCount
        XCTAssertTrue(calls.isEmpty)
        XCTAssertEqual(flushes, 7)
        XCTAssertEqual(model.error?.code, "TEST_BARRIER")
        XCTAssertEqual(model.projectPendingDeletion?.id, project.id)
    }

    @MainActor
    func testHelpIsFrozenToSixOfflineSearchableSections() {
        let help = HelpModel()
        XCTAssertEqual(help.sections.count, 6)
        help.query = "OCR"
        XCTAssertFalse(help.results.isEmpty)
        XCTAssertTrue(help.results.allSatisfy { $0.title.contains("OCR") || $0.body.contains("OCR") })
    }

    @MainActor
    func testCSVModelAcceptsFarRowEditWithoutEagerViewState() async {
        let service = WorkspaceFake(rowCount: 10_000)
        let model = ResolveCSVModel(service: service)
        await model.importData(Data(), filename: "10k.csv")
        let revision = model.revision

        model.receive(CSVCellCommit(
            tableID: model.tableID,
            rowID: 9_999,
            columnID: 1,
            revision: revision,
            value: "中文 IME 🎬"
        ))

        XCTAssertEqual(model.table?.rows[9_999][1], "中文 IME 🎬")
        XCTAssertEqual(model.table?.rows.count, 10_000)
    }

    func testCSVKeyboardNavigationUsesGridOrderAndBounds() {
        XCTAssertEqual(
            CSVKeyboardNavigation.destination(row: 0, column: 1, rows: 2, columns: 3, movement: .next)?.row,
            0
        )
        XCTAssertEqual(
            CSVKeyboardNavigation.destination(row: 1, column: 0, rows: 2, columns: 3, movement: .previous)?.column,
            2
        )
        XCTAssertEqual(
            CSVKeyboardNavigation.destination(row: 1, column: 1, rows: 2, columns: 3, movement: .firstColumn)?.column,
            0
        )
        XCTAssertNil(CSVKeyboardNavigation.destination(row: 1, column: 2, rows: 2, columns: 3, movement: .next))
        XCTAssertNil(CSVKeyboardNavigation.destination(row: 0, column: 0, rows: 2, columns: 3, movement: .up))
    }

    func testLocalLogStoreUsesPermissionsFiltersAndReadClamp() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "SM08Logs-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LocalLogStore(directory: root, now: { Date(timeIntervalSince1970: 1_700_000_000) })
        await store.append(ProductLogEntry(
            timestamp: Date(timeIntervalSince1970: 1_700_000_000),
            severity: .warning,
            category: "recognition",
            event: "retry",
            message: "已脱敏事件"
        ))

        let entries = await store.read(limit: 9_999, severities: [.warning], category: "recognition")
        XCTAssertEqual(entries.map(\.message), ["已脱敏事件"])
        let directoryMode = try FileManager.default.attributesOfItem(atPath: root.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(directoryMode?.intValue, 0o700)
        let file = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil).first)
        let fileMode = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(fileMode?.intValue, 0o600)
    }

    func testPaddleInstallerUsesPinnedOfflineStagesAndSanitizedEnvironment() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "SM08Paddle-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let requirements = try XCTUnwrap(Bundle.module.url(
            forResource: "sm08-requirements-ocr",
            withExtension: "txt"
        ))
        let runner = PaddleInstallerFakeRunner()
        let installer = PaddleOCRInstallerService(
            userDataRoot: root,
            requirementsURL: requirements,
            runner: runner
        )
        let progress = ProgressProbe()

        let result = try await installer.install { value in
            Task { await progress.append(value) }
        }
        // Progress callbacks are synchronous, but the Sendable test collector
        // crosses an actor hop; wait for all five fixed stages deterministically.
        for _ in 0..<100 where await progress.values.count < 5 { await Task.yield() }

        let values = await progress.values
        let commands = await runner.commands
        XCTAssertEqual(values.map(\.stage), [.detectPython, .createEnvironment, .installDependencies, .verify, .completed])
        XCTAssertEqual(values.map(\.percent), [5, 20, 35, 90, 100])
        XCTAssertEqual(result.paddleVersion, "3.3.1")
        XCTAssertEqual(result.paddleOcrVersion, "3.7.0")
        XCTAssertTrue(commands.contains { $0.arguments.suffix(2) == ["-r", requirements.path] })
        XCTAssertTrue(commands.allSatisfy { $0.timeout == .seconds(30 * 60) })
        XCTAssertTrue(commands.allSatisfy { $0.environment["OPENAI_API_KEY"] == nil })
        XCTAssertTrue(commands.allSatisfy { $0.environment["PIP_INDEX_URL"] == nil })
        XCTAssertTrue(commands.allSatisfy { $0.environment["PIP_EXTRA_INDEX_URL"] == nil })
        XCTAssertTrue(commands.allSatisfy { $0.environment["PIP_DISABLE_PIP_VERSION_CHECK"] == "1" })
    }

    func testPaddleInstallerRejectsManagedDirectorySymlinkWithoutInstalling() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "SM08PaddleSymlink-\(UUID().uuidString)", directoryHint: .isDirectory)
        let outside = FileManager.default.temporaryDirectory
            .appending(path: "SM08PaddleOutside-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: outside)
        }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: root.appending(path: "paddleocr-venv"),
            withDestinationURL: outside
        )
        let requirements = try XCTUnwrap(Bundle.module.url(
            forResource: "sm08-requirements-ocr",
            withExtension: "txt"
        ))
        let runner = PaddleInstallerFakeRunner()
        let installer = PaddleOCRInstallerService(userDataRoot: root, requirementsURL: requirements, runner: runner)

        do {
            _ = try await installer.install { _ in }
            XCTFail("符号链接必须被拒绝")
        } catch let error as SlateSyncError {
            XCTAssertEqual(error.code, "PADDLEOCR_INSTALL_PATH_INVALID")
        }
        let commands = await runner.commands
        XCTAssertEqual(commands.count, 1, "只允许执行本地 Python 版本检查")
    }

    func testPaddleInstallerCancelAndDrainWaitsForInjectedRunner() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "SM08PaddleCancel-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let requirements = try XCTUnwrap(Bundle.module.url(
            forResource: "sm08-requirements-ocr",
            withExtension: "txt"
        ))
        let runner = BlockingPaddleInstallerFakeRunner()
        let installer = PaddleOCRInstallerService(userDataRoot: root, requirementsURL: requirements, runner: runner)
        let installation = Task { try await installer.install { _ in } }
        for _ in 0..<100 where !(await runner.isRunning) { await Task.yield() }

        await installer.cancelAndDrain()

        do {
            _ = try await installation.value
            XCTFail("取消的安装不应成功")
        } catch let error as SlateSyncError {
            XCTAssertEqual(error.code, "PADDLEOCR_INSTALL_CANCELED")
        }
        let isRunning = await runner.isRunning
        XCTAssertFalse(isRunning)
    }

    @MainActor
    func testRouteBarrierKeepsWorkspaceAndDraftWhenAutosaveFails() async {
        let service = WorkspaceFake(rowCount: 0, saveFailuresRemaining: 1)
        let workspace = WorkspaceModel(service: service)
        let session = AppSessionModel(workspace: workspace)
        let project = ProjectSummary(
            id: "p1",
            name: "片场 A",
            relativePath: "projects/p1",
            createdAt: "2026-09-05T00:00:00Z",
            updatedAt: "2026-09-05T00:00:00Z"
        )

        await session.openProject(project)
        workspace.customPrompt = "不能丢失的草稿"
        await session.navigate(to: .logs)

        XCTAssertEqual(session.route, .workspace)
        XCTAssertEqual(workspace.customPrompt, "不能丢失的草稿")
        XCTAssertEqual(session.navigationError?.code, "TEST_WRITE")
    }

    @MainActor
    func testConcurrentTerminationRequestsJoinOneLifecycleDrain() async {
        let lifecycle = LifecycleProbe()
        let termination = TerminationCoordinator(lifecycle: lifecycle)

        async let first = termination.requestTermination()
        async let second = termination.requestTermination()
        let results = await [first, second]
        let drainCount = await lifecycle.drainCount

        XCTAssertEqual(results, [true, true])
        XCTAssertEqual(drainCount, 1)
        XCTAssertFalse(termination.isDraining)
    }

    @MainActor
    func testSettingsDiscoveryAndProbeUseOfflineFacadeProjection() async {
        let service = GlobalSettingsFake()
        let model = GlobalSettingsModel(service: service)
        await model.load()
        XCTAssertTrue(model.addCustomProvider(
            name: "本地接口",
            baseURL: "http://localhost:11434/v1/",
            modelID: "vision-test"
        ))
        XCTAssertTrue(model.customProviders.last?.id.hasPrefix(CustomProviderValidator.idPrefix) == true)
        XCTAssertEqual(model.customProviders.last?.baseUrl, "http://localhost:11434/v1")

        let created = try? XCTUnwrap(model.customProviders.last)
        let saved = await model.saveCustomProvider(
            existing: created,
            name: "本地接口 2",
            baseURL: "http://localhost:11434/v1",
            modelIDs: "vision-test, vision-backup",
            transport: .responses,
            jsonMode: .jsonObject,
            imageDetail: .original
        )
        XCTAssertTrue(saved)
        XCTAssertEqual(model.customProviders.last?.id, created?.id)
        XCTAssertEqual(model.customProviders.last?.revision, (created?.revision ?? 0) + 1)
        XCTAssertNil(model.customProviders.last?.capabilityCache)
        XCTAssertEqual(model.customProviders.last?.manualModelIds, ["vision-test", "vision-backup"])

        await model.discover(providerID: "custom-test")
        XCTAssertEqual(model.discoveryResults["custom-test"]?.models.map(\.id), ["vision-test"])
        await model.probe(providerID: "custom-test", modelIDs: ["vision-test"])
        let discoveryCount = await service.discoveryCount
        let probeCount = await service.probeCount

        XCTAssertEqual(model.probeProgress["custom-test"]?.percent, 100)
        XCTAssertEqual(discoveryCount, 1)
        XCTAssertEqual(probeCount, 1)
        if case .succeeded = model.providerOperations["custom-test"] {} else {
            XCTFail("能力验证应当进入终态")
        }
    }

    @MainActor
    func testResultEditIsCanonicalAndFlushJoinsPendingCommit() async throws {
        let workspaceService = WorkspaceFake(rowCount: 0)
        let workspace = WorkspaceModel(service: workspaceService)
        try await workspace.activate(projectID: "p1")
        let recognition = RecognitionModel(service: workspaceService, settings: GlobalSettingsFake())
        recognition.load(task: TaskData(editedRecords: [
            PersistedRecognitionRecord(
                id: "record-1",
                scene: "12",
                takeStatus: .passed,
                description: "初稿"
            )
        ]))

        recognition.update(recordID: "record-1", path: \.description, value: "中文 IME 校对") {
            workspace.stageEditedRecords($0)
        }
        try await workspace.flush()

        let saved = await workspaceService.savedEditedRecords
        XCTAssertEqual(saved.last?.first?.description, "中文 IME 校对")
        XCTAssertEqual(saved.last?.first?.takeStatus, .passed)
    }

    @MainActor
    func testMixedResultAndPromptEditsPersistTheLatestCompleteSnapshot() async throws {
        let service = WorkspaceFake(rowCount: 0)
        let workspace = WorkspaceModel(service: service)
        try await workspace.activate(projectID: "p1")
        // Regression: the old result timer enqueued its captured full task
        // after the newer prompt enqueue and silently restored the old prompt.
        workspace.stageEditedRecords([.init(id: "r1", description: "已校对")])
        workspace.customPrompt = "最新提示词"
        try await workspace.flush()
        let saved = await service.savedTasks
        XCTAssertEqual(saved.last?.customPrompt, "最新提示词")
        XCTAssertEqual(saved.last?.editedRecords?.first?.description, "已校对")
        XCTAssertEqual(saved.last?.id, "t1")
    }

    @MainActor
    func testRecognitionOptionsPersistAndRestoreThroughTaskSnapshot() async throws {
        let service = WorkspaceFake(rowCount: 0)
        let workspace = WorkspaceModel(service: service)
        try await workspace.activate(projectID: "p1")

        workspace.stageRecognitionOptions(
            providerID: "openai",
            modelID: "gpt-vision",
            accuracyMode: .standard,
            scenarioID: "scenario-1"
        )
        try await workspace.flush()

        let savedTasks = await service.savedTasks
        let saved = try XCTUnwrap(savedTasks.last)
        XCTAssertEqual(saved.provider, "openai")
        XCTAssertEqual(saved.model, "gpt-vision")
        XCTAssertEqual(saved.accuracyMode, .standard)
        XCTAssertEqual(saved.scenarioId, "scenario-1")

        // A fresh window reloads the task from the fake's persisted snapshot;
        // this is the same boundary used by the production ProjectRuntime.
        let reopened = WorkspaceModel(service: service)
        try await reopened.activate(projectID: "p1")
        XCTAssertEqual(reopened.selectedTask?.provider, "openai")
        XCTAssertEqual(reopened.selectedTask?.model, "gpt-vision")
        XCTAssertEqual(reopened.selectedTask?.accuracyMode, .standard)
        XCTAssertEqual(reopened.selectedTask?.scenarioId, "scenario-1")
    }

    @MainActor
    func testCloseJoinsPendingEnqueueBeforeClosingWriter() async throws {
        let service = WorkspaceFake(rowCount: 0)
        let workspace = WorkspaceModel(service: service)
        try await workspace.activate(projectID: "p1")
        workspace.stageEditedRecords([.init(id: "r1", description: "关闭前的最后一笔")])
        try await workspace.close()
        let saved = await service.savedTasks
        XCTAssertEqual(saved.last?.editedRecords?.first?.description, "关闭前的最后一笔")
    }

    @MainActor
    func testReopeningSameProjectDoesNotDiscardFailedDraft() async throws {
        let service = WorkspaceFake(rowCount: 0, saveFailuresRemaining: 1)
        let workspace = WorkspaceModel(service: service)
        try await workspace.activate(projectID: "p1")
        workspace.customPrompt = "重开项目也应保留"
        do {
            try await workspace.activate(projectID: "p1")
            XCTFail("同项目刷新必须经过保存屏障")
        } catch {
            XCTAssertEqual(workspace.customPrompt, "重开项目也应保留")
            XCTAssertEqual(workspace.projectID, "p1")
        }
    }

    @MainActor
    func testCSVCommitPersistsThroughWorkspaceAndRejectsPreviousTable() async throws {
        let service = WorkspaceFake(rowCount: 10_000)
        let workspace = WorkspaceModel(service: service)
        try await workspace.activate(projectID: "p1")
        let csv = ResolveCSVModel(service: service)
        csv.onTableChange = { [weak workspace] in workspace?.stageCSV($0, filename: $1) }
        await csv.importData(Data(), filename: "Resolve.csv")
        let old = CSVCellCommit(tableID: csv.tableID, rowID: 9_999, columnID: 1, revision: csv.revision, value: "保留末行")
        csv.receive(old)
        try await workspace.flush()
        let saved = await service.savedTasks
        XCTAssertEqual(saved.last?.resolveCsvTable?.rows[9_999][1], "保留末行")
        csv.reset()
        await csv.importData(Data(), filename: "new.csv")
        csv.receive(old)
        XCTAssertNotEqual(csv.table?.rows[9_999][1], "保留末行")
    }

    @MainActor
    func testMetadataMatchingUsesCanonicalResolveMaterialKeys() async throws {
        let service = WorkspaceFake(rowCount: 1)
        let csv = ResolveCSVModel(service: service)
        await csv.importData(Data(), filename: "Resolve.csv")
        let expectedKeys = try await csv.materialKeys()
        XCTAssertEqual(expectedKeys, ["A:1:1", "A:1:2"])

        let metadata = MetadataScanModel(service: service)
        let directory = URL(fileURLWithPath: "/private/tmp/sm08-metadata-fixture")
        metadata.scan(directory, expectedKeys: expectedKeys)
        for _ in 0..<100 where await service.metadataExpectedKeys.isEmpty { await Task.yield() }
        let passedKeys = await service.metadataExpectedKeys
        XCTAssertEqual(passedKeys, ["A:1:1", "A:1:2"])
        await metadata.drain()
    }

    @MainActor
    func testProjectOwnershipRejectsSecondWriterAndReleasesOnlyItsOwner() throws {
        let ownership = ProjectWindowOwnership()
        let first = UUID(), second = UUID()
        try ownership.acquire(projectID: "p1", windowID: first)
        try ownership.acquire(projectID: "p2", windowID: second)
        XCTAssertThrowsError(try ownership.acquire(projectID: "p1", windowID: second))
        ownership.release(projectID: "p1", windowID: second)
        XCTAssertThrowsError(try ownership.acquire(projectID: "p1", windowID: second))
        ownership.release(projectID: "p1", windowID: first)
        XCTAssertNoThrow(try ownership.acquire(projectID: "p1", windowID: second))
    }

    @MainActor
    func testCredentialRefreshRetainsUnrelatedSettingsDraft() async throws {
        let service = GlobalSettingsFake()
        let settings = GlobalSettingsModel(service: service)
        await settings.load()
        settings.setValue("45", for: .modelRequestTimeoutMS)
        try await settings.storeCredential("fake-test-only", providerID: "custom-test")
        await settings.load()
        XCTAssertEqual(settings.value(.modelRequestTimeoutMS), "45")
    }

    @MainActor
    func testInvalidSettingsNeverReachTolerantPersistence() async {
        let service = GlobalSettingsFake()
        let settings = GlobalSettingsModel(service: service)
        await settings.load()
        settings.setValue("invalid-number", for: .modelRequestTimeoutMS)
        await settings.save()
        let saves = await service.saveCount
        XCTAssertEqual(saves, 0)
        XCTAssertEqual(settings.value(.modelRequestTimeoutMS), "invalid-number")
        if case .failed = settings.operation {} else { XCTFail("非法输入不能显示保存成功") }
    }

    func testPrivacyIsEnforcedAtLogSinkAndReadBoundary() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "SM08Privacy-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LocalLogStore(directory: root)
        let secret = "unique-provider-token-123"
        await store.append(.init(timestamp: Date(), severity: .error, category: "Authorization: Bearer \(secret)", event: "sk-private-secret", message: "Authorization: Bearer \(secret); /Users/person/private.mov", operationID: secret))
        let entries = await store.read()
        let file = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil).first)
        let raw = try String(contentsOf: file, encoding: .utf8)
        XCTAssertEqual(entries.count, 1)
        for forbidden in [secret, "sk-private-secret", "/Users/person"] { XCTAssertFalse(raw.contains(forbidden)) }
        let error = ProductPrivacy.error(SlateSyncError(code: "PROVIDER", message: secret, providerError: true))
        XCTAssertFalse(error.message.contains(secret))
        // A token need not have a recognizable provider prefix or punctuation.
        let arbitraryEvent = ProductPrivacy.log(.init(timestamp: Date(), severity: .error,
            category: "app", event: "privatecredential", message: "失败"))
        XCTAssertEqual(arbitraryEvent.event, "event")
    }

    func testPaddleInstallerRejectsNestedSymlinkBeforeVenvMutation() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "SM08Nested-\(UUID())")
        let outside = FileManager.default.temporaryDirectory.appending(path: "SM08Outside-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: outside) }
        let venv = root.appending(path: "paddleocr-venv")
        try FileManager.default.createDirectory(at: venv, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: venv.appending(path: "bin"), withDestinationURL: outside)
        let requirements = try XCTUnwrap(Bundle.module.url(forResource: "sm08-requirements-ocr", withExtension: "txt"))
        let runner = PaddleInstallerFakeRunner()
        let installer = PaddleOCRInstallerService(userDataRoot: root, requirementsURL: requirements, runner: runner)
        do { _ = try await installer.install { _ in }; XCTFail("嵌套路径越界必须失败") }
        catch let error as SlateSyncError { XCTAssertEqual(error.code, "PADDLEOCR_INSTALL_PATH_INVALID") }
        let commands = await runner.commands
        XCTAssertEqual(commands.count, 1)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: outside.path).isEmpty)
    }

    func testRealInstallerRunnerTimeoutReapsTERMResistantChild() async throws {
        try await assertRunnerReapsChild(cancel: false)
    }

    func testRealInstallerRunnerTaskCancellationReapsTERMResistantChild() async throws {
        try await assertRunnerReapsChild(cancel: true)
    }

    func testRealInstallerRunnerDrainsNoisyChildWithoutStarvingTimeout() async throws {
        try await assertRunnerReapsChild(cancel: false, noisy: true)
    }

    private func assertRunnerReapsChild(cancel: Bool, noisy: Bool = false) async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "SM08Process-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let pidFile = root.appending(path: "child.pid")
        let runner = ProcessPaddleInstallerCommandRunner()
        // Only shell builtins execute: no network, dependencies, subprocesses,
        // production Python, or user files. TERM is ignored to exercise KILL.
        let task = Task {
            try await runner.run(executable: URL(fileURLWithPath: "/bin/sh"),
                arguments: ["-c", "trap '' TERM; echo $$ > child.pid; while :; do \(noisy ? "printf 'fixture-output\\n'" : ":"); done"],
                directory: root, environment: ["PATH": "/usr/bin:/bin"],
                timeout: cancel ? .seconds(20) : .milliseconds(100))
        }
        for _ in 0..<100 where !FileManager.default.fileExists(atPath: pidFile.path) {
            try await Task.sleep(for: .milliseconds(10))
        }
        let pid = try XCTUnwrap(Int32(String(contentsOf: pidFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)))
        if cancel { task.cancel() }
        do { _ = try await task.value; XCTFail("取消或超时不可返回成功") }
        catch let error as SlateSyncError {
            XCTAssertEqual(error.code, cancel ? "PADDLEOCR_INSTALL_CANCELED" : "PADDLEOCR_INSTALL_TIMEOUT")
        }
        XCTAssertEqual(Darwin.kill(pid, 0), -1, "返回前必须回收实际子进程")
        XCTAssertEqual(errno, ESRCH)
    }
}

private actor ProgressProbe {
    private(set) var values: [PaddleOcrInstallProgress] = []
    func append(_ value: PaddleOcrInstallProgress) { values.append(value) }
}

private actor MutationBarrierProbe {
    private(set) var flushCount = 0

    func flush() throws {
        flushCount += 1
        throw SlateSyncError(code: "TEST_BARRIER", message: "注入保存失败", retryable: true)
    }
}

private actor ProjectLibraryFake: ProjectLibraryWorkflowServing {
    nonisolated let projectSummary = ProjectSummary(
        id: "project-1",
        name: "片场 A",
        relativePath: "projects/project-1",
        createdAt: "2026-09-05T00:00:00Z",
        updatedAt: "2026-09-05T00:00:00Z"
    )
    private(set) var mutationCalls: [String] = []
    private let refreshGate: SM08TestGate?
    private let projectCount: Int
    init(refreshGate: SM08TestGate? = nil, projectCount: Int = 1) { self.refreshGate = refreshGate; self.projectCount = projectCount }

    func projectLibrary() async throws -> ProjectLibraryProjection {
        if !mutationCalls.isEmpty { await refreshGate?.wait() }
        return ProjectLibraryProjection(
            library: LibraryInfo(id: "library-1", name: "测试库", path: "/tmp/library"),
            active: (0..<projectCount).map { index in
                .init(id: "project-\(index)", name: "片场 \(index) 🎬", description: index.isMultiple(of: 3) ? "中文 长字段 场记拍摄说明" : "",
                      relativePath: "Projects/project-\(index)", createdAt: "2026-09-05T00:00:00Z", updatedAt: "2026-09-05T00:00:00Z")
            },
            archived: []
        )
    }

    func project(id: String) async throws -> ProjectData { ProjectData(summary: projectSummary) }
    func createProject(name: String, description: String) async throws -> ProjectData {
        mutationCalls.append("create")
        return ProjectData(summary: projectSummary)
    }
    func updateProject(id: String, name: String, description: String, settings: ProjectSettings) async throws -> ProjectData {
        mutationCalls.append("update")
        return ProjectData(summary: projectSummary, settings: settings)
    }
    func archiveProject(id: String) async throws -> ProjectData {
        mutationCalls.append("archive")
        return ProjectData(summary: projectSummary)
    }
    func restoreProject(id: String) async throws -> ProjectData {
        mutationCalls.append("restore")
        return ProjectData(summary: projectSummary)
    }
    func deleteProject(id: String) async throws { mutationCalls.append("delete") }
    func importProject(from packageURL: URL) async throws -> ProjectData {
        mutationCalls.append("import-project")
        return ProjectData(summary: projectSummary)
    }
    func exportProject(id: String, to packageURL: URL) async throws -> ProjectExportResult {
        mutationCalls.append("export-project")
        return .canceled
    }
    func exportLibrary(to packageURL: URL) async throws -> LibraryExportResult {
        mutationCalls.append("export-library")
        return .canceled
    }
    func importLibrary(from packageURL: URL) async throws -> LibraryImportResult {
        mutationCalls.append("import-library")
        return .canceled
    }
    func relocateLibrary(to parentDirectory: URL) async throws -> LibraryLocationResult {
        mutationCalls.append("relocate-library")
        return .canceled
    }
    func renameLibrary(to name: String) async throws -> LibraryRenameResult {
        mutationCalls.append("rename-library")
        return .canceled
    }
}

private actor PaddleInstallerFakeRunner: PaddleInstallerCommandRunning {
    struct Command: Sendable {
        let arguments: [String]
        let environment: [String: String]
        let timeout: Duration
    }
    private(set) var commands: [Command] = []

    func run(
        executable: URL,
        arguments: [String],
        directory: URL,
        environment: [String: String],
        timeout: Duration
    ) async throws -> PaddleInstallerCommandResult {
        commands.append(.init(arguments: arguments, environment: environment, timeout: timeout))
        if arguments.last == "--version" { return .init(stdout: "Python 3.12.1\n") }
        if arguments.contains("import paddle,paddleocr;print(paddle.__version__+'\\t'+paddleocr.__version__)") {
            return .init(stdout: "3.3.1\t3.7.0\n")
        }
        return .init()
    }

    func cancel() async {}
}

private actor BlockingPaddleInstallerFakeRunner: PaddleInstallerCommandRunning {
    private(set) var isRunning = false
    private var isCanceled = false

    func run(
        executable: URL,
        arguments: [String],
        directory: URL,
        environment: [String: String],
        timeout: Duration
    ) async throws -> PaddleInstallerCommandResult {
        isRunning = true
        defer { isRunning = false }
        while !isCanceled { try await Task.sleep(for: .milliseconds(5)) }
        throw SlateSyncError(code: "PADDLEOCR_INSTALL_CANCELED", message: "fake canceled")
    }

    func cancel() async { isCanceled = true }
}

private actor AutosaveProbe {
    private(set) var snapshots: [TaskData] = []
    private var failuresRemaining: Int
    init(failuresRemaining: Int = 0) { self.failuresRemaining = failuresRemaining }

    func write(projectID: String, taskID: String?, snapshot: TaskData) throws -> String {
        if failuresRemaining > 0 {
            failuresRemaining -= 1
            throw SlateSyncError(code: "TEST_WRITE", message: "注入写入失败", retryable: true)
        }
        snapshots.append(snapshot)
        return taskID ?? "generated"
    }
}

private actor WorkspaceFake: WorkspaceWorkflowServing {
    let table: ResolveCSVTable
    private var saveFailuresRemaining: Int
    private let taskCount: Int
    private let decodeGate: SM08TestGate?
    private let loadGate: SM08TestGate?
    private(set) var metadataScanCount = 0
    private(set) var metadataExpectedKeys: [String] = []
    private(set) var savedEditedRecords: [[PersistedRecognitionRecord]] = []
    private(set) var savedTasks: [TaskData] = []
    init(rowCount: Int, saveFailuresRemaining: Int = 0, decodeGate: SM08TestGate? = nil, taskCount: Int = 1, loadGate: SM08TestGate? = nil) {
        self.taskCount = taskCount
        self.decodeGate = decodeGate
        self.loadGate = loadGate
        self.saveFailuresRemaining = saveFailuresRemaining
        table = ResolveCSVTable(
            headers: ["文件名", "注释"],
            rows: (0..<rowCount).map { ["A\($0).mov", $0.isMultiple(of: 3) ? "保" : ""] },
            format: ResolveCSVFormat()
        )
    }
    func listTasks(projectID: String) async throws -> [TaskListItem] {
        (1...taskCount).map { .init(id: "t\($0)", filename: "场记单 \($0 % 100).pdf", recordCount: $0 % 30, status: "draft") }
    }
    func loadTask(projectID: String, taskID: String) async throws -> TaskData {
        await loadGate?.wait()
        if let saved = savedTasks.last(where: { $0.id == taskID }) { return saved }
        return TaskData(id: taskID, projectId: projectID, customPrompt: "")
    }
    func saveTask(projectID: String, taskID: String?, task: TaskData) async throws -> String {
        if saveFailuresRemaining > 0 {
            saveFailuresRemaining -= 1
            throw SlateSyncError(code: "TEST_WRITE", message: "注入写入失败", retryable: true)
        }
        if let editedRecords = task.editedRecords { savedEditedRecords.append(editedRecords) }
        savedTasks.append(task)
        return taskID ?? "generated"
    }
    func deleteTask(projectID: String, taskID: String) async throws {}
    func decodeResolveCSV(_ data: Data) async throws -> ResolveCSVTable { await decodeGate?.wait(); return table }
    func encodeResolveCSV(_ table: ResolveCSVTable) async throws -> Data { Data() }
    func resolveMaterialKeys(in table: ResolveCSVTable) async throws -> [String] {
        ["A:1:1", "A:1:2"]
    }
    func scanMetadata(directory: URL, options: SlateMetadataScanOptions) async throws -> ScanResult {
        metadataScanCount += 1
        metadataExpectedKeys = options.expectedKeys
        return ScanResult(metadata: [], warnings: [], stats: ScanStats(visitedDirectories: 0, prunedDirectories: 0, skippedDeepDirectories: 0, discoveredSlateFiles: 0, readSlateFiles: 0, learnedStructures: 0), missingKeys: [])
    }
    func recognize(_ request: NativeRecognitionRequest) async throws -> RecognitionData { throw SlateSyncError(code: "TEST", message: "unused") }
    func recognitionProgress(projectID: String) async -> AsyncStream<RecognitionProgress> { AsyncStream { $0.finish() } }
    func cancelRecognition(projectID: String) async {}
    func closeProject(id: String) async throws {}
}

private actor LifecycleProbe: ProductLifecycleServing {
    private(set) var drainCount = 0
    func drain() async throws {
        drainCount += 1
        // Keep the first request suspended long enough for the second caller
        // to observe and join the coordinator's in-flight task.
        await Task.yield()
    }
}

private actor GlobalSettingsFake: GlobalSettingsWorkflowServing {
    private(set) var discoveryCount = 0
    private(set) var probeCount = 0
    private(set) var saveCount = 0
    private let credentialGate: SM08TestGate?
    init(credentialGate: SM08TestGate? = nil) { self.credentialGate = credentialGate }

    func globalSettings() async throws -> GlobalSettingsProjection { Self.projection }
    func saveGlobalSettings(
        values: GlobalSettingValues,
        customProviders: [CustomProviderConfiguration]
    ) async throws -> GlobalSettingsProjection { saveCount += 1; return Self.projection }
    func setProviderCredential(_ value: String?, providerID: String) async throws { await credentialGate?.wait() }
    func retryLegacyCredentialMigration() async throws -> GlobalSettingsProjection { Self.projection }

    func discoverModels(providerID: String, forceRefresh: Bool) async throws -> ModelDiscoveryResult {
        discoveryCount += 1
        return ModelDiscoveryResult(
            provider: providerID,
            source: .api,
            refreshedAt: "2026-09-05T00:00:00Z",
            availableModelCount: 1,
            visionModelCount: 1,
            fixedModelCount: 0,
            models: [Self.model]
        )
    }

    func probeModels(
        providerID: String,
        modelIDs: [String],
        progress: @escaping @Sendable (ModelProbeProgress) -> Void
    ) async throws -> ModelProbeResult {
        probeCount += 1
        let result = ModelCapabilityProbeResult(
            supported: true,
            model: "vision-test",
            transport: .chatCompletions,
            checkedAt: "2026-09-05T00:00:00Z",
            message: "验证通过",
            capabilityStatus: .verified
        )
        progress(.init(providerId: providerID, model: "vision-test", completed: 1, total: 1, percent: 100, result: result))
        return .init(canceled: false, results: [result], completed: 1, total: 1)
    }

    func cancelModelProbe(providerID: String) async {}
    func installPaddleOCR(
        progress: @escaping @Sendable (PaddleOcrInstallProgress) -> Void
    ) async throws -> PaddleOcrInstallResult {
        .init(pythonPath: "/tmp/fake-python", setupCompleted: true, setupSkipped: false, paddleVersion: "3.3.1", paddleOcrVersion: "3.7.0")
    }
    func cancelPaddleOCRInstallation() async {}

    private nonisolated static let model = ModelData(
        id: "vision-test",
        label: "Vision Test",
        description: "offline fixture",
        providers: ["custom-test"],
        verifiedAvailable: true,
        capabilityStatus: .verified
    )
    private nonisolated static let projection = GlobalSettingsProjection(
        values: .init(),
        customProviders: [],
        providers: [.init(id: "custom-test", label: "Custom Test", configured: true)],
        models: [model],
        configuredCredentialProviderIDs: [],
        visionAvailable: true,
        paddleAvailable: false,
        runtime: .init(
            resolvedSettingCount: 0,
            globalConfigVersion: 1,
            environmentFileLoaded: false,
            migrationStatus: .sourceMissing
        )
    )
}

/// Deterministic suspension proves barriers are joined; it deliberately does
/// not respond to cancellation, matching a parser or atomic write in flight.
private actor SM08TestGate {
    private var released = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var started = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        started = true
        startWaiters.forEach { $0.resume() }; startWaiters.removeAll()
        if !released { await withCheckedContinuation { waiters.append($0) } }
    }
    func entered() async {
        if !started { await withCheckedContinuation { startWaiters.append($0) } }
    }
    func release() {
        released = true
        waiters.forEach { $0.resume() }; waiters.removeAll()
    }
}

extension SM08OwnershipTests {
    @MainActor
    func testTerminationJoinsLibraryMutationBeforeClosingLifecycle() async throws {
        let gate = SM08TestGate()
        let service = LifecycleProbe()
        let termination = TerminationCoordinator(lifecycle: service)
        let mutation = Task { try await termination.performLibraryMutation { await gate.wait() } }
        await gate.entered()
        let quit = Task { await termination.requestTermination() }
        for _ in 0..<20 { await Task.yield() }
        let before = await service.drainCount
        XCTAssertEqual(before, 0)
        XCTAssertTrue(termination.isMutatingLibrary)
        await gate.release()
        try await mutation.value
        let result = await quit.value
        XCTAssertTrue(result)
        let after = await service.drainCount
        XCTAssertEqual(after, 1)
    }

    @MainActor
    func testLibraryMutationKeepsBarrierThroughCrossWindowReconciliation() async {
        let gate = SM08TestGate()
        let service = ProjectLibraryFake(refreshGate: gate)
        let termination = TerminationCoordinator(lifecycle: LifecycleProbe())
        let projects = ProjectLibraryModel(service: service)
        projects.mutationCoordinator = termination.performLibraryMutation
        var reconciled = false
        projects.didChangeLibrary = { _ in
            XCTAssertTrue(termination.isMutatingLibrary)
            reconciled = true
        }
        let archive = Task { await projects.archive(service.projectSummary) }
        await gate.entered()
        XCTAssertTrue(termination.isMutatingLibrary)
        XCTAssertFalse(reconciled)
        await gate.release()
        await archive.value
        XCTAssertTrue(reconciled)
        XCTAssertFalse(termination.isMutatingLibrary)
    }

    @MainActor
    func testCSVDrainJoinsDecoderAndRejectsLatePublication() async {
        let gate = SM08TestGate()
        let csv = ResolveCSVModel(service: WorkspaceFake(rowCount: 10_000, decodeGate: gate))
        var publications = 0
        csv.onTableChange = { _, _ in publications += 1 }
        let decode = Task { await csv.importData(Data(), filename: "large.csv") }
        await gate.entered()
        var drained = false
        let drain = Task { await csv.drain(); drained = true }
        for _ in 0..<20 { await Task.yield() }
        XCTAssertFalse(drained)
        await gate.release()
        await decode.value
        await drain.value
        XCTAssertEqual(publications, 0)
        XCTAssertNil(csv.table)
        XCTAssertEqual(csv.operation, .canceled)
    }

    @MainActor
    func testSettingsDrainWaitsForCredentialAcknowledgement() async throws {
        let gate = SM08TestGate()
        let settings = GlobalSettingsModel(service: GlobalSettingsFake(credentialGate: gate))
        let write = Task { try await settings.storeCredential("fixture-secret", providerID: "custom-test") }
        await gate.entered()
        var drained = false
        let drain = Task { await settings.drain(); drained = true }
        for _ in 0..<20 { await Task.yield() }
        XCTAssertFalse(drained)
        await gate.release()
        try await write.value
        await drain.value
        XCTAssertTrue(drained)
        do { try await settings.storeCredential("must-not-write", providerID: "custom-test"); XCTFail("Closed settings admitted a write") }
        catch { XCTAssertEqual((error as? SlateSyncError)?.code, "SETTINGS_CLOSING") }
    }

    @MainActor
    func testMetadataPersistsAndResetsWithTaskSelection() async throws {
        let service = WorkspaceFake(rowCount: 0)
        let workspace = WorkspaceModel(service: service)
        try await workspace.activate(projectID: "p1")
        let scan = ScanResult(metadata: [.init(sourceName: "A001.mov", clipName: "A001", materialKey: "A001", sensorFps: "24", shootDay: "1")],
            warnings: ["fixture warning"], stats: .init(visitedDirectories: 1, prunedDirectories: 0,
                skippedDeepDirectories: 0, discoveredSlateFiles: 1, readSlateFiles: 1, learnedStructures: 0), missingKeys: ["A002"])
        workspace.stageMetadata(scan, directoryName: "fixture")
        try await workspace.flush()
        let saved = await service.savedTasks.last
        XCTAssertEqual(saved?.slateMetadata?.first?.materialKey, "A001")
        XCTAssertEqual(saved?.missingMetadataKeys, ["A002"])
        let metadata = MetadataScanModel(service: service)
        metadata.load(task: saved)
        XCTAssertEqual(metadata.result?.metadata, scan.metadata)
        metadata.load(task: nil)
        XCTAssertNil(metadata.result)
        try await workspace.close()
    }

    @MainActor
    func testBundledHelpChineseHashAndNoResults() {
        let help = HelpModel()
        XCTAssertNil(help.resourceError)
        XCTAssertEqual(help.sections.count, 6)
        XCTAssertEqual(help.contentSHA256.count, 64)
        XCTAssertEqual(Set(help.sections.map(\.id)).count, 6)
        // Language acceptance is Chinese only under the Owner's scope update.
        XCTAssertEqual(help.title(help.sections[0]), "快速开始")
        help.query = "永久删除"
        XCTAssertEqual(help.results.map(\.id), ["projects"])
        help.query = "不存在的帮助条目734"
        XCTAssertTrue(help.results.isEmpty)
    }

    func testLogRetentionBadUTF8NewestFirstAndHardCap() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "sm08-logs-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = ISO8601DateFormatter().date(from: "2026-09-06T12:00:00Z")!
        let logs = LocalLogStore(directory: root, calendar: calendar, now: { now })
        for day in 0..<9 {
            await logs.append(.init(timestamp: now.addingTimeInterval(Double(-day * 86400)), severity: .info,
                category: "app", event: "started", message: "fixture day \(day)"))
        }
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        var lines = Data([0xff, 0xfe, 0x0a])
        for index in 0..<2100 {
            lines.append(try encoder.encode(ProductLogEntry(timestamp: now.addingTimeInterval(Double(index)),
                severity: index.isMultiple(of: 2) ? .info : .warning, category: "app", event: "completed", message: "fixture \(index)")))
            lines.append(10)
        }
        lines.append(Data("{partial".utf8))
        try lines.write(to: root.appending(path: "slatesync-2026-09-06.log"))
        let snapshot = await logs.readSnapshot(limit: 99999)
        XCTAssertEqual(snapshot.entries.count, 2000)
        XCTAssertEqual(snapshot.entries.first?.message, "fixture 2099")
        XCTAssertTrue(snapshot.degraded)
        XCTAssertEqual(snapshot.skippedLines, 2)
        let defaultResult = await logs.read()
        XCTAssertEqual(defaultResult.count, 500)
        let filtered = await logs.read(limit: 2000, severities: [.warning], category: "app")
        XCTAssertEqual(filtered.count, 1050)
        // Trigger rotation using today's event after planting older day files.
        await logs.append(.init(timestamp: now, severity: .info, category: "app", event: "completed", message: "rotate"))
        let names = try FileManager.default.contentsOfDirectory(atPath: root.path)
        XCTAssertEqual(names.filter { $0.hasSuffix(".log") }.count, 7)
        XCTAssertFalse(names.contains("slatesync-2026-08-30.log"))
    }
}

extension SM08OwnershipTests {
    func testLocalSlateCSVMatchesRetainedWorkerOracle() async throws {
        struct Oracle: Decodable {
            struct Case: Decodable { let input: String; let parsed: [SlateCsvRecord]?; let records: [PersistedRecognitionRecord]?; let error: String? }
            let cases: [Case]
        }
        let url = try XCTUnwrap(Bundle.module.url(forResource: "sm08-local-slate-oracle", withExtension: "json"))
        let oracle = try JSONDecoder().decode(Oracle.self, from: Data(contentsOf: url))
        let workflow = SlateCSVWorkflow()
        for fixture in oracle.cases {
            do {
                let parsed = try await workflow.decode(Data(fixture.input.utf8))
                XCTAssertNil(fixture.error)
                XCTAssertEqual(parsed, fixture.parsed)
                let records = await workflow.records(parsed)
                XCTAssertEqual(records, fixture.records)
            } catch { XCTAssertNotNil(fixture.error, "Unexpected error: \(error)") }
        }
    }

    func testNativeRecognitionPatchPreservesMediaCSVAndMetadata() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "sm08-recognition-patch-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let library = try ProjectLibraryStore(applicationSupportRoot: root)
        let project = try await library.createProject(name: "fixture", description: "")
        let runtime = ProjectRuntime(library: library)
        let task = TaskData(projectId: project.id, filename: "fixture.pdf", imageDataGroups: [["fixture-only"]],
            resolveCsvFilename: "fixture.csv", resolveCsvTable: .init(headers: ["File Name"], rows: [["A001C001.mov"]], format: .init()),
            slateMetadata: [.init(materialKey: "A:1:1")], customPrompt: "retained prompt")
        let id = try await runtime.saveTask(projectID: project.id, taskID: nil, payload: JSONEncoder().encode(task))
        let adapter = NativeRecognitionPersistence(runtime: runtime)
        let patch = TaskData(status: "completed", provider: "fixture-provider", model: "fixture-model",
            editedRecords: [.init(id: "record", scene: "1", shot: "2", take: "3")])
        _ = try await adapter.saveTask(projectID: project.id, taskID: id, payload: JSONEncoder().encode(patch))
        let saved = try JSONDecoder().decode(TaskData.self, from: await runtime.loadTask(projectID: project.id, taskID: id))
        XCTAssertEqual(saved.imageDataGroups, task.imageDataGroups)
        XCTAssertEqual(saved.resolveCsvTable, task.resolveCsvTable)
        XCTAssertEqual(saved.slateMetadata, task.slateMetadata)
        XCTAssertEqual(saved.customPrompt, task.customPrompt)
        XCTAssertEqual(saved.editedRecords, patch.editedRecords)
        XCTAssertEqual(saved.status, "completed")
        try await runtime.close()
        try await library.close()
    }

    func testRealSQLiteProjectAndTaskScaleLoad() async throws {
        let container = FileManager.default.temporaryDirectory
            .appending(path: "sm08-real-scale-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: container, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: container) }
        let libraryRoot = container.appending(path: "Scale.slatesync-library", directoryHint: .isDirectory)
        let library = try ProjectLibraryStore(libraryRoot: libraryRoot)
        _ = try await library.libraryInfo()

        // The permanent default row counts toward the 500-project fixture;
        // every task below is written through the real project SQLite runtime.
        for index in 1..<500 {
            _ = try await library.createProject(name: "规模项目 \(index)", description: "SM08 SQLite fixture")
        }
        let runtime = ProjectRuntime(library: library)
        let encoder = JSONEncoder()
        for index in 0..<1_000 {
            let taskID = "sm08-task-\(String(format: "%04d", index))"
            let payload = try encoder.encode(TaskData(
                projectId: ProjectLibraryStore.defaultProjectID,
                status: "draft",
                filename: "场记单 \(index).pdf"
            ))
            _ = try await runtime.saveTask(
                projectID: ProjectLibraryStore.defaultProjectID,
                taskID: taskID,
                payload: payload
            )
        }
        try await runtime.close()
        try await library.close()

        // Reopen both stores before measuring so the result exercises actual
        // SQLite bootstrap/list paths instead of the construction-time cache.
        let reopened = try ProjectLibraryStore(libraryRoot: libraryRoot)
        let taskRuntime = ProjectRuntime(library: reopened)
        func loadProjects() async throws -> Double {
            let start = ContinuousClock.now
            let projects = try await reopened.listProjects()
            XCTAssertEqual(projects.count, 500)
            return sm08Milliseconds(start.duration(to: .now))
        }
        func loadTasks() async throws -> Double {
            let start = ContinuousClock.now
            let tasks = try await taskRuntime.listTaskItems(projectID: ProjectLibraryStore.defaultProjectID)
            XCTAssertEqual(tasks.count, 1_000)
            return sm08Milliseconds(start.duration(to: .now))
        }

        _ = try await loadProjects()
        _ = try await loadTasks()
        var projectSamples: [Double] = []
        var taskSamples: [Double] = []
        for _ in 0..<5 {
            projectSamples.append(try await loadProjects())
            taskSamples.append(try await loadTasks())
        }
        XCTAssertLessThanOrEqual(projectSamples.max() ?? .infinity, 1_500)
        XCTAssertLessThanOrEqual(taskSamples.max() ?? .infinity, 900)

        if let path = ProcessInfo.processInfo.environment["SLATESYNC_SM08_METRICS_DIR"] {
            let output: [String: Any] = [
                "schemaVersion": 1,
                "projects": 500,
                "tasks": 1_000,
                "warmups": 1,
                "samples": 5,
                "projectLoadMs": projectSamples,
                "taskLoadMs": taskSamples,
                "projectP95BudgetMs": 1_500,
                "taskP95BudgetMs": 900,
            ]
            let directory = URL(fileURLWithPath: path, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try JSONSerialization.data(withJSONObject: output, options: [.sortedKeys, .prettyPrinted])
                .write(to: directory.appending(path: "real-sqlite-scale.json"))
        }
        try await taskRuntime.close()
        try await reopened.close()
    }
}


extension SM08OwnershipTests {
    @MainActor
    func testFiveSampleProjectAndTaskNativeListScale() async throws {
        var projectsMS: [Double] = [], tasksMS: [Double] = [], projectSelectionMS: [Double] = [], taskSelectionMS: [Double] = []
        var projectRows: [Int] = [], taskRows: [Int] = []
        let fixtureProjects = ProjectLibraryFake(projectCount: 500)
        let fixtureTasks = WorkspaceFake(rowCount: 0, taskCount: 1000)
        for sample in 0..<6 {
            let projects = ProjectLibraryModel(service: fixtureProjects)
            let start = ContinuousClock.now
            await projects.load()
            let library = SM08ListHarness(ProjectLibraryView(model: projects, onOpen: { _ in }))
            try await library.settle()
            let projectTime = sm08Milliseconds(start.duration(to: .now))
            let projectTable = try XCTUnwrap(library.table)
            XCTAssertEqual(projects.activeProjects.count, 500)
            XCTAssertGreaterThanOrEqual(projectTable.numberOfRows, 500)
            let selectStart = ContinuousClock.now
            projectTable.scrollRowToVisible(projectTable.numberOfRows - 1)
            projectTable.selectRowIndexes(IndexSet(integer: projectTable.numberOfRows - 1), byExtendingSelection: false)
            projectTable.layoutSubtreeIfNeeded(); projectTable.displayIfNeeded()
            let selectedTime = sm08Milliseconds(selectStart.duration(to: .now))
            let visibleProjects = projectTable.rows(in: projectTable.visibleRect).length
            XCTAssertLessThanOrEqual(visibleProjects, 80)
            library.close()
            let workspace = WorkspaceModel(service: fixtureTasks)
            let taskStart = ContinuousClock.now
            try await workspace.activate(projectID: "fixture")
            let tasks = SM08ListHarness(TaskRailView(model: workspace))
            try await tasks.settle()
            let taskTime = sm08Milliseconds(taskStart.duration(to: .now))
            let taskTable = try XCTUnwrap(tasks.table)
            XCTAssertEqual(workspace.tasks.count, 1000)
            let taskSelectStart = ContinuousClock.now
            taskTable.scrollRowToVisible(taskTable.numberOfRows - 1)
            try await workspace.selectTask("t1000")
            taskTable.layoutSubtreeIfNeeded(); taskTable.displayIfNeeded()
            let taskSelectedTime = sm08Milliseconds(taskSelectStart.duration(to: .now))
            let visibleTasks = taskTable.rows(in: taskTable.visibleRect).length
            XCTAssertLessThanOrEqual(visibleTasks, 100)
            tasks.close()
            try await workspace.close()
            if sample > 0 {
                projectsMS.append(projectTime); tasksMS.append(taskTime)
                projectSelectionMS.append(selectedTime); taskSelectionMS.append(taskSelectedTime)
                projectRows.append(visibleProjects); taskRows.append(visibleTasks)
            }
        }
        XCTAssertLessThanOrEqual(projectsMS.max() ?? .infinity, 1500)
        XCTAssertLessThanOrEqual(tasksMS.max() ?? .infinity, 900)
        XCTAssertLessThanOrEqual(projectSelectionMS.max() ?? .infinity, 120)
        XCTAssertLessThanOrEqual(taskSelectionMS.max() ?? .infinity, 120)
        if let path = ProcessInfo.processInfo.environment["SLATESYNC_SM08_METRICS_DIR"] {
            let projectFixture = try JSONEncoder().encode(await fixtureProjects.projectLibrary().active)
            let taskFixture = try JSONEncoder().encode(await fixtureTasks.listTasks(projectID: "fixture"))
            func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
            let output: [String: Any] = ["schemaVersion": 1, "samples": 5, "warmups": 1, "projects": 500, "tasks": 1000,
                "projectFixtureSHA256": digest(projectFixture), "taskFixtureSHA256": digest(taskFixture),
                "projectProjectionAndMountMs": projectsMS, "taskProjectionAndMountMs": tasksMS,
                "projectSelectionMs": projectSelectionMS, "taskSelectionMs": taskSelectionMS,
                "projectVisibleRows": projectRows, "taskVisibleRows": taskRows]
            let directory = URL(fileURLWithPath: path, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try projectFixture.write(to: directory.appending(path: "projects-500.json"))
            try taskFixture.write(to: directory.appending(path: "tasks-1000.json"))
            try JSONSerialization.data(withJSONObject: output, options: [.sortedKeys, .prettyPrinted])
                .write(to: directory.appending(path: "native-project-task-scale.json"))
        }
    }
}

private func sm08Milliseconds(_ duration: Duration) -> Double {
    Double(duration.components.seconds) * 1000 + Double(duration.components.attoseconds) / 1e15
}

extension SM08OwnershipTests {
    @MainActor
    func testLateProjectOpenCannotOverrideNewerHelpNavigation() async throws {
        let gate = SM08TestGate()
        let workspace = WorkspaceModel(service: WorkspaceFake(rowCount: 0, loadGate: gate))
        let session = AppSessionModel(workspace: workspace)
        let project = ProjectLibraryFake().projectSummary
        let open = Task { await session.openProject(project) }
        await gate.entered()
        await session.navigate(to: .help)
        await gate.release()
        await open.value
        XCTAssertEqual(session.route, .help)
        // The completed read still has a valid workspace owner; commands and
        // navigation must use that same identity rather than a stale copy.
        XCTAssertEqual(session.projectID, workspace.projectID)
        XCTAssertEqual(session.projectID, project.id)
        try await workspace.close()
    }

    @MainActor
    func testReconciliationInvalidatesPendingProjectNavigation() async throws {
        let gate = SM08TestGate()
        let workspace = WorkspaceModel(service: WorkspaceFake(rowCount: 0, loadGate: gate))
        let session = AppSessionModel(workspace: workspace)
        let open = Task { await session.openProject(ProjectLibraryFake().projectSummary) }
        await gate.entered()
        session.reconcileClosedProject()
        await gate.release()
        await open.value
        XCTAssertEqual(session.route, .projects)
        try await workspace.close()
    }

    @MainActor
    func testInputAdmissionBlocksPickerAndDropDuringRecognition() async throws {
        let service = WorkspaceFake(rowCount: 0)
        let mediaService = SM08MediaAdmissionProbe()
        let media = MediaInputModel(service: mediaService)
        let metadata = MetadataScanModel(service: service)
        var recognitionRunning = true
        media.permitsNewOperation = { !recognitionRunning }
        metadata.permitsNewOperation = { !recognitionRunning }
        var writes = 0
        media.onPrepared = { _ in writes += 1 }
        metadata.onResult = { _, _ in writes += 1 }
        let url = URL(fileURLWithPath: "/private/tmp/blocked-input")
        media.select(url)
        metadata.scan(url)
        for _ in 0..<20 { await Task.yield() }
        let blockedMedia = await mediaService.calls
        let blockedMetadata = await service.metadataScanCount
        XCTAssertEqual(blockedMedia, 0)
        XCTAssertEqual(blockedMetadata, 0)
        XCTAssertEqual(writes, 0)
        XCTAssertFalse(media.canAcceptInput)
        // Reopening admission must restore the same entry points.
        recognitionRunning = false
        media.select(url)
        metadata.scan(url)
        for _ in 0..<200 {
            if await mediaService.calls == 1, await service.metadataScanCount == 1 { break }
            await Task.yield()
        }
        let allowedMedia = await mediaService.calls
        let allowedMetadata = await service.metadataScanCount
        XCTAssertEqual(allowedMedia, 1)
        XCTAssertEqual(allowedMetadata, 1)
        await media.drain()
        await metadata.drain()
    }

    @MainActor
    func testCSVDuplicateCommitDoesNotPublishAnotherSnapshot() async {
        let csv = ResolveCSVModel(service: WorkspaceFake(rowCount: 1))
        await csv.importData(Data(), filename: "测试.csv")
        var writes = 0
        csv.onTableChange = { _, _ in writes += 1 }
        let edit = CSVCellCommit(tableID: csv.tableID, rowID: 0, columnID: 1, revision: csv.revision, value: "中文校对")
        csv.receive(edit)
        csv.receive(edit)
        XCTAssertEqual(writes, 1)
        XCTAssertEqual(csv.table?.rows[0][1], "中文校对")
    }
}

/// Counts dispatch without reading the supplied file; denied input must never
/// reach an adapter, even through a late picker completion or workspace drop.
private actor SM08MediaAdmissionProbe: MediaInputWorkflowServing {
    private(set) var calls = 0
    func prepareInput(_ input: MediaInput) async throws -> PreparedDocument {
        calls += 1
        throw SlateSyncError(code: "TEST_INPUT", message: "测试输入")
    }
    func restoreInput(groups: [[String]], filename: String) async throws -> PreparedDocument {
        throw SlateSyncError(code: "TEST_UNUSED", message: "未使用")
    }
}

import AppKit
import SlateSyncDomain
import SwiftUI
import XCTest

@testable import SlateSyncUI

/// Offscreen design review renders. The test is inert unless
/// `SLATESYNC_DESIGN_SNAPSHOT_DIR` names an output folder, so normal runs and
/// CI skip it. Every screen is mounted from the real SwiftUI views over
/// synthetic fixtures (no user project, Library, Keychain or network) inside a
/// test-owned window placed far off screen; nothing is activated or presented,
/// and pixels come from `cacheDisplay`, never from the display.
@MainActor
final class DesignSnapshotTests: XCTestCase {
    fileprivate nonisolated static let size = CGSize(width: 1280, height: 800)

    func testRenderDesignScreens() async throws {
        guard let path = ProcessInfo.processInfo.environment["SLATESYNC_DESIGN_SNAPSHOT_DIR"] else {
            throw XCTSkip("Set SLATESYNC_DESIGN_SNAPSHOT_DIR to render design snapshots.")
        }
        let output = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let only = ProcessInfo.processInfo.environment["SLATESYNC_DESIGN_SNAPSHOT_ONLY"]
        for dark in [false, true] {
            let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            for screen in Screen.allCases where only == nil || only == screen.rawValue {
                let rig = try await Rig.make(screen: screen)
                let image = try await render(rig.content, size: screen.size, appearance: appearance, title: screen.windowTitle)
                try image.write(to: output.appendingPathComponent("\(screen.rawValue)-\(dark ? "dark" : "light").png"))
                await rig.tearDown()
            }
        }
    }

    enum Screen: String, CaseIterable {
        case library, input, running, results, csv, settings, providers

        var size: CGSize { self == .settings || self == .providers ? CGSize(width: 780, height: 620) : DesignSnapshotTests.size }
        var windowTitle: String? { nil }
    }

    // MARK: Rendering

    /// Mounts `content` in an off-screen titled window and returns a PNG of the
    /// complete window frame, title bar and toolbar included when AppKit
    /// materializes them.
    private func render(_ content: some View, size: CGSize, appearance: NSAppearance?, title: String?) async throws -> Data {
        let controller = NSHostingController(rootView: content)
        // Size the hosting view before the window adopts it so the first
        // layout pass already sees the real width, as a launched window does.
        controller.view.frame = CGRect(origin: .zero, size: size)
        let window = NSWindow(
            contentRect: CGRect(x: -20_000, y: -20_000, width: size.width, height: size.height),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = appearance
        window.contentViewController = controller
        window.setContentSize(size)
        window.setFrameOrigin(CGPoint(x: -20_000, y: -20_000))
        if let title { window.title = title }
        defer { window.contentViewController = nil; window.close() }
        // Let SwiftUI, the split view and the native tables settle.
        for _ in 0..<12 {
            window.contentView?.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            try await Task.sleep(for: .milliseconds(120))
        }
        let frameView = try XCTUnwrap(window.contentView?.superview ?? window.contentView)
        let bounds = frameView.bounds
        let rep = try XCTUnwrap(frameView.bitmapImageRepForCachingDisplay(in: bounds))
        // Render at 2× so type and hairlines can be judged.
        rep.size = bounds.size
        frameView.cacheDisplay(in: bounds, to: rep)
        return try XCTUnwrap(rep.representation(using: .png, properties: [:]))
    }
}

// MARK: - Fixture rig

/// One fully wired set of real models over the synthetic service. `content`
/// is the real SwiftUI tree for the requested screen.
@MainActor
private struct Rig {
    let content: AnyView
    let tearDown: @MainActor () async -> Void

    static func make(screen: DesignSnapshotTests.Screen) async throws -> Rig {
        let service = DesignFixtureService()
        let settingsService = DesignSettingsService()
        let workspace = WorkspaceModel(service: service)
        workspace.acquireProject = { _ in }
        workspace.releaseProject = { _ in }
        let recognition = RecognitionModel(service: service, settings: settingsService)
        let csv = ResolveCSVModel(service: service)
        let metadata = MetadataScanModel(service: service)
        let media = MediaInputModel(service: service)
        let projects = ProjectLibraryModel(service: service)
        let session = AppSessionModel(workspace: workspace)
        let projectSettings = ProjectSettingsModel(service: service)
        let logs = LogsModel(service: service)
        let help = HelpModel()
        let navigation = SettingsNavigationModel()
        let termination = TerminationCoordinator(lifecycle: DesignLifecycle())

        if screen == .settings || screen == .providers {
            if screen == .providers { navigation.navigate(to: .providers) }
            // The one-time credential-storage notice is migration state, not
            // part of the design under review.
            UserDefaults.standard.set(true, forKey: "providerFileCredentialNoticeDismissed")
            let global = GlobalSettingsModel(service: settingsService)
            await global.load()
            // SwiftPM has no app bundle metadata. Render the shipped notice from
            // its single source so snapshots include the real Settings footer.
            let projectRoot = URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            let info = try PropertyListSerialization.propertyList(
                from: Data(contentsOf: projectRoot.appending(path: "SlateSyncApp/Info.plist")),
                format: nil) as? [String: Any]
            let copyrightNotice = try XCTUnwrap(info?["NSHumanReadableCopyright"] as? String)
            let view = SettingsRootView(
                settings: global, paddleInstaller: PaddleInstallerModel(service: settingsService),
                navigation: navigation, copyrightNotice: copyrightNotice)
            return Rig(content: AnyView(view), tearDown: {})
        }

        await projects.load()
        await recognition.loadOptions()

        func openWorkspace(entry: WorkspaceEntryPoint) async throws {
            let project = try XCTUnwrap(projects.activeProjects.first)
            await session.openProject(project)
            try await workspace.selectTask("t1")
            let task = try await service.loadTask(projectID: project.id, taskID: "t1")
            recognition.load(task: task)
            csv.load(task: task)
            media.load(task: task)
            metadata.load(task: task)
        }

        let root = { (entry: WorkspaceEntryPoint) in
            AppRootView(
                session: session, projects: projects, workspace: workspace, recognition: recognition,
                csv: csv, metadata: metadata, media: media, projectSettings: projectSettings,
                logs: logs, help: help, settingsNavigation: navigation, termination: termination)
        }

        switch screen {
        case .library:
            return Rig(content: AnyView(root(.input)), tearDown: {})
        case .input:
            try await openWorkspace(entry: .input)
            try await settle(media)
            return Rig(content: AnyView(root(.input)), tearDown: {})
        case .running:
            try await openWorkspace(entry: .input)
            try await settle(media)
            let request = NativeRecognitionRequest(
                projectID: "p1", input: .bytes(Data(), filename: "D02_场记_A机.pdf"),
                filename: "D02_场记_A机.pdf", taskID: "t1", providerID: "openrouter", modelID: "qwen-flash",
                settings: workspace.projectSettings, slateCSVRecords: [], preparedDocument: media.document)
            recognition.recognize(request) {}
            for _ in 0..<40 where recognition.progress == nil { try await Task.sleep(for: .milliseconds(50)) }
            return Rig(content: AnyView(root(.input)), tearDown: { await service.releaseRecognition(); recognition.cancel() })
        case .results, .csv:
            try await openWorkspace(entry: screen == .results ? .result : .resolveCSV)
            try await settle(media)
            if screen == .csv {
                await csv.merge(records: recognition.resolveRecords, metadata: [], settings: workspace.projectSettings.resolve)
            }
            let split = NavigationSplitView {
                SidebarView(selection: .constant(.workspace), currentProjectName: "雾河", workspace: workspace)
                    .navigationSplitViewColumnWidth(min: SidebarView.minimumColumnWidth, ideal: 230, max: 280)
            } detail: {
                WorkspaceView(
                    workspace: workspace, recognition: recognition, csv: csv, metadata: metadata, media: media,
                    entryPoint: screen == .results ? .result : .resolveCSV)
            }
            return Rig(content: AnyView(split), tearDown: {})
        case .settings, .providers:
            // Returned before the project models were loaded, above.
            throw SlateSyncError(code: "DESIGN_FIXTURE", message: "settings screens are built earlier")
        }
    }

    private static func settle(_ media: MediaInputModel) async throws {
        for _ in 0..<40 where media.document == nil { try await Task.sleep(for: .milliseconds(50)) }
    }
}

// MARK: - Synthetic services

private struct DesignLifecycle: ProductLifecycleServing {
    func drain() async throws {}
}

/// A synthetic camera-report sheet, drawn with AppKit and encoded as JPEG.
@MainActor
private enum DesignSheetArt {
    static func jpeg(page: Int) throws -> PreparedImage {
        let size = CGSize(width: 880, height: 1140)
        let image = NSImage(size: size)
        image.lockFocus()
        NSColor(srgbRed: 0.985, green: 0.980, blue: 0.965, alpha: 1).setFill()
        CGRect(origin: .zero, size: size).fill()
        let ink = NSColor(srgbRed: 0.13, green: 0.25, blue: 0.56, alpha: 1)
        let rule = NSColor(srgbRed: 0.16, green: 0.20, blue: 0.27, alpha: 0.35)
        let label = NSColor(srgbRed: 0.35, green: 0.37, blue: 0.40, alpha: 1)
        let small: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 17, weight: .semibold), .foregroundColor: label, .kern: 1.6]
        NSAttributedString(string: "CAMERA REPORT · A CAM", attributes: small).draw(at: CGPoint(x: 60, y: size.height - 72))
        NSAttributedString(string: "DAY 02 · P\(page)", attributes: small).draw(at: CGPoint(x: size.width - 190, y: size.height - 72))
        let columns: [(String, CGFloat)] = [("ROLL", 150), ("SCENE", 170), ("SHOT", 120), ("TAKE", 120), ("NOTES", 260)]
        let rows: [[String]] = [
            ["A002", "12A", "1", "1", "NG 穿帮"], ["A002", "12A", "1", "2", "OK"], ["A002", "12A", "1", "3", "声音杂"],
            ["A002", "12A", "2", "1", "OK 保"], ["A002", "12A", "2", "2", "灯光变"], ["A003", "12B", "1", "1", "OK"],
            ["A003", "12B", "1", "2", "NG"], ["A003", "12B", "2", "1", "OK 保一条"], ["A003", "12B", "2", "2", "焦点虚"],
            ["A003", "13", "1", "1", "OK"], ["A003", "13", "1", "2", "OK"], ["A004", "13", "2", "1", "穿帮"],
            ["A004", "13", "2", "2", ""], ["A004", "14", "1", "1", "OK"], ["A004", "14", "1", "2", "OK 表演好"],
            ["A004", "14", "2", "1", "OK"], ["A004", "14", "2", "2", ""], ["A004", "14", "3", "1", "OK"],
        ]
        let top = size.height - 130
        var x: CGFloat = 60
        for (title, width) in columns {
            NSAttributedString(string: title, attributes: small).draw(at: CGPoint(x: x + 8, y: top))
            x += width
        }
        rule.setStroke()
        let rowHeight: CGFloat = 56
        for (index, row) in rows.enumerated() {
            let y = top - 12 - CGFloat(index + 1) * rowHeight
            let line = NSBezierPath(); line.lineWidth = 1.4
            line.move(to: CGPoint(x: 60, y: y)); line.line(to: CGPoint(x: size.width - 60, y: y)); line.stroke()
            var cx: CGFloat = 60
            for (column, value) in row.enumerated() {
                let attrs: [NSAttributedString.Key: Any] = [
                    .font: NSFont(name: "Noteworthy-Bold", size: 30) ?? NSFont.systemFont(ofSize: 30),
                    .foregroundColor: ink,
                ]
                NSAttributedString(string: value, attributes: attrs).draw(at: CGPoint(x: cx + 8, y: y + 10))
                cx += columns[column].1
            }
            if row[4].hasPrefix("OK") {
                ink.setStroke()
                let ring = NSBezierPath(ovalIn: CGRect(x: 60 + 560 - 6, y: y + 6, width: 70, height: 42))
                ring.lineWidth = 3; ring.stroke()
            }
        }
        image.unlockFocus()
        guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
              let data = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.85])
        else { throw SlateSyncError(code: "DESIGN_FIXTURE", message: "could not encode the synthetic sheet") }
        return try PreparedImage(jpeg: data, width: Int(size.width), height: Int(size.height))
    }
}

private actor DesignFixtureService: WorkspaceWorkflowServing, MediaInputWorkflowServing,
    ProjectContextWorkflowServing, LocalSlateWorkflowServing, ResolveExportWorkflowServing,
    LogWorkflowServing, ProjectLibraryWorkflowServing
{
    private var recognitionOpen = false
    func releaseRecognition() { recognitionOpen = true }

    private static let summaries: [ProjectSummary] = [
        ProjectSummary(id: "p1", name: "雾河", description: "", relativePath: "p1", createdAt: "2026-08-01T08:00:00Z",
                       updatedAt: "2026-10-23T06:20:00Z", taskCount: 3),
        ProjectSummary(id: "p2", name: "夜行列车", description: "第二机位补拍", relativePath: "p2", createdAt: "2026-07-12T08:00:00Z",
                       updatedAt: "2026-10-22T13:05:00Z", taskCount: 5),
        ProjectSummary(id: "p3", name: "默认项目", description: "从旧版 SlateSync 数据迁移的默认项目", relativePath: "p3",
                       createdAt: "2026-06-02T08:00:00Z", updatedAt: "2026-09-02T08:00:00Z", taskCount: 0),
    ]

    // MARK: Library
    func retryProjectLibraryUnlock() async {}
    func projectLibrary() async throws -> ProjectLibraryProjection {
        ProjectLibraryProjection(
            library: LibraryInfo(id: "lib", name: "项目库", path: "/tmp/library"),
            active: Self.summaries,
            archived: [ProjectSummary(id: "p4", name: "城南旧事 · 补拍", description: "", relativePath: "p4",
                                      archivedAt: "2026-08-20T08:00:00Z", createdAt: "2026-03-01T08:00:00Z",
                                      updatedAt: "2026-08-20T08:00:00Z", taskCount: 2)])
    }
    func project(id: String) async throws -> ProjectData { ProjectData(summary: Self.summaries[0]) }
    func createProject(name: String, description: String) async throws -> ProjectData { throw unused() }
    func updateProject(id: String, name: String, description: String, settings: ProjectSettings) async throws -> ProjectData { throw unused() }
    func archiveProject(id: String) async throws -> ProjectData { throw unused() }
    func restoreProject(id: String) async throws -> ProjectData { throw unused() }
    func deleteProject(id: String) async throws {}
    func importProject(from packageURL: URL) async throws -> ProjectData { throw unused() }
    func exportProject(id: String, to packageURL: URL) async throws -> ProjectExportResult { throw unused() }
    func exportLibrary(to packageURL: URL) async throws -> LibraryExportResult { throw unused() }
    func importLibrary(from packageURL: URL) async throws -> LibraryImportResult { throw unused() }
    func relocateLibrary(to parentDirectory: URL) async throws -> LibraryLocationResult { throw unused() }
    func renameLibrary(to name: String) async throws -> LibraryRenameResult { throw unused() }
    func listScenarios(projectID: String) async throws -> [ScenarioSummary] { [] }

    // MARK: Tasks
    func listTasks(projectID: String) async throws -> [TaskListItem] {
        [
            TaskListItem(id: "t1", filename: "D02_场记_A机.pdf", pageCount: 3, recordCount: 42, status: "completed"),
            TaskListItem(id: "t2", filename: "D02_场记_B机.pdf", pageCount: 2, recordCount: 28, status: "completed"),
            TaskListItem(id: "t3", filename: "D03_场记.jpg", pageCount: 1, recordCount: 0, status: "failed"),
        ]
    }

    func loadTask(projectID: String, taskID: String) async throws -> TaskData {
        guard taskID == "t1" else { return TaskData(id: taskID, projectId: projectID, filename: "task", customPrompt: "") }
        // Realistic take sequences: NG first, then a keeper; some shots keep two.
        let plan: [(String, Int, Int)] = [("12A", 1, 3), ("12A", 2, 2), ("12B", 1, 2), ("12B", 2, 2), ("13", 1, 2),
            ("13", 2, 2), ("14", 1, 2), ("14", 2, 2), ("14", 3, 1), ("15", 1, 3), ("15", 2, 2), ("16", 1, 2),
            ("16", 2, 2), ("17", 1, 3), ("17", 2, 2), ("18", 1, 2), ("18", 2, 2), ("19", 1, 2)]
        var records: [PersistedRecognitionRecord] = []
        var clip = 14, roll = 2
        for (index, entry) in plan.enumerated() {
            for take in 1...entry.2 {
                let sequence: [TakeStatus?] = entry.2 == 1 ? [.passed]
                    : entry.2 == 2 ? [[TakeStatus.rejected, .passed], [.passed, .hold], [.passed, .passed]][index % 3]
                    : [.rejected, .hold, .passed]
                let status: TakeStatus? = records.count >= 36 ? nil : sequence[take - 1]
                records.append(PersistedRecognitionRecord(
                    id: "r\(records.count)", sourcePage: 1,
                    cardNumber: "A\(String(format: "%03d", roll))",
                    videoCode: "A\(String(format: "%03d", roll))C\(String(format: "%03d", clip))_0812_R3KD",
                    scene: entry.0, shot: String(entry.1), take: String(take), takeStatus: status,
                    description: "", comments: status == .rejected ? "NG" : (status == .hold ? "备用" : ""),
                    confidence: .high))
                clip += 1
                if clip > 22 { clip = 1; roll += 1 }
            }
        }
        return TaskData(
            id: taskID, projectId: projectID, status: "completed", filename: "D02_场记_A机.pdf", fileType: "pdf",
            pageCount: 3, imageDataGroups: [["page1"], ["page2"], ["page3"]],
            resolveCsvTable: Self.resolveTable, provider: "openrouter", model: "qwen-flash", customPrompt: "", accuracyMode: .standard,
            editedRecords: records)
    }

    static let resolveTable: ResolveCSVTable = {
        let headers = ["File Name", "Scene", "Shot", "Take", "Good Take", "FPS", "Shoot Day", "Comments"]
        var rows: [[String]] = []
        var clip = 14, roll = 2
        for index in 0..<40 {
            let unmatched = [2, 13].contains(index)
            let name = "A\(String(format: "%03d", roll))C\(String(format: "%03d", unmatched ? 99 : clip))_0812_R3KD.mov"
            rows.append([name, unmatched ? "" : ["12A", "12B", "13", "14", "15"][index / 8],
                         unmatched ? "" : String(index % 3 + 1), unmatched ? "" : String(index % 3 + 1),
                         index % 2 == 0 ? "true" : "", index == 6 ? "23.976" : "24.000",
                         index == 4 ? "" : "D02", index % 5 == 1 ? "NG" : ""])
            if !unmatched { clip += 1; if clip > 22 { clip = 1; roll += 1 } }
        }
        return ResolveCSVTable(headers: headers, rows: rows, format: ResolveCSVFormat())
    }()

    func saveTask(projectID: String, taskID: String?, task: TaskData) async throws -> String { taskID ?? "t1" }
    func deleteTask(projectID: String, taskID: String) async throws {}
    func decodeResolveCSV(_ data: Data) async throws -> ResolveCSVTable { Self.resolveTable }
    func encodeResolveCSV(_ table: ResolveCSVTable) async throws -> Data { Data() }
    func resolveMaterialKeys(in table: ResolveCSVTable) async throws -> [String] { [] }
    func scanMetadata(directory: URL, options: SlateMetadataScanOptions) async throws -> ScanResult { throw unused() }
    func recognize(_ request: NativeRecognitionRequest) async throws -> RecognitionData {
        while !recognitionOpen {
            try Task.checkCancellation()
            try await Task.sleep(for: .milliseconds(20))
        }
        throw unused()
    }
    func recognitionProgress(projectID: String) async -> AsyncStream<RecognitionProgress> {
        AsyncStream { continuation in
            continuation.yield(RecognitionProgress(phase: "recognizing", completed: 2, total: 3, message: "正在识别第 2 页", percent: 56, pageNumber: 2))
        }
    }
    func cancelRecognition(projectID: String) async { recognitionOpen = true }
    func closeProject(id: String) async throws {}

    // MARK: Media
    func prepareInput(_ input: MediaInput) async throws -> PreparedDocument { throw unused() }
    func restoreInput(groups: [[String]], filename: String) async throws -> PreparedDocument {
        let pages = try await MainActor.run {
            try groups.indices.map { index in
                PreparedMediaPage(pageNumber: index + 1,
                                  views: [PreparedMediaView(viewIndex: 0, viewType: .full, image: try DesignSheetArt.jpeg(page: index + 1))])
            }
        }
        return PreparedDocument(filename: filename, pages: pages)
    }

    // MARK: Local slate / Resolve
    func decodeSlateCSV(_ data: Data) async throws -> [SlateCsvRecord] { [] }
    func localSlateRecords(_ records: [SlateCsvRecord]) async -> [PersistedRecognitionRecord] { [] }
    func previewResolve(source: Data, records: [ResolveSlateRecord], metadata: [PersistedSlateMetadata],
                        settings: ProjectSettings.ResolveSettings, edits: [ResolveSparseEdit]) async throws -> ResolveMergeResult {
        ResolveMergeResult(
            table: Self.resolveTable,
            statuses: [ResolveRecordStatus(recordIndex: 0, status: "unmatched", fileName: "A002C099_0812_R3KD.mov")],
            warnings: [], addedColumns: [], matchedRecordCount: 36,
            cameraFpsMatchedMaterialCount: 36, cameraFpsMatchedRowCount: 36,
            shootDayMatchedMaterialCount: 35, shootDayMatchedRowCount: 35, updatedRowCount: 36, changes: [],
            expectedMaterialCount: 40, recognizedMaterialCount: 36,
            unrecognizedMaterials: ["A002C099_0812_R3KD", "A003C099_0812_R3KD"], unrecognizedRowIndexes: [],
            rowKeys: Self.resolveTable.rows.map { $0[0] },
            missingCameraFPSKeys: [], missingShootDayKeys: ["A002C017_0812_R3KD"],
            sequenceAnomalies: [SlateSequenceAnomaly(key: "A002C019", type: "sequence", message: "A002C019 条号次序异常")])
    }
    func mergeResolve(source: Data, records: [ResolveSlateRecord], metadata: [PersistedSlateMetadata],
                      settings: ProjectSettings.ResolveSettings, edits: [ResolveSparseEdit]) async throws -> ResolveExportArtifact { throw unused() }
    func exportStandalone(records: [ResolveSlateRecord], settings: ProjectSettings.ResolveSettings) async throws -> Data { Data() }

    // MARK: Logs
    func logEntries(limit: Int, severities: Set<ProductLogSeverity>, category: String?) async -> [ProductLogEntry] { [] }
    func recordLog(_ entry: ProductLogEntry) async {}
    func logsDirectory() async -> URL { FileManager.default.temporaryDirectory }

    private func unused() -> SlateSyncError { SlateSyncError(code: "DESIGN_FIXTURE", message: "not part of the design fixture") }
}

private actor DesignSettingsService: GlobalSettingsWorkflowServing {
    private nonisolated static let projection = GlobalSettingsProjection(
        values: GlobalSettingValues([.defaultProviderID: "openrouter", .defaultModelID: "qwen-flash"]),
        customProviders: [],
        providers: [
            .init(id: "openrouter", label: "OpenRouter", configured: true),
            .init(id: "deepseek", label: "DeepSeek", configured: false),
        ],
        models: [
            ModelData(id: "qwen-flash", label: "Qwen 3.7 Flash", description: "", providers: ["openrouter"],
                      verifiedAvailable: true, capabilityStatus: .verified),
        ],
        configuredCredentialProviderIDs: ["openrouter"],
        visionAvailable: true, paddleAvailable: false,
        runtime: .init(resolvedSettingCount: 0, globalConfigVersion: 1, environmentFileLoaded: false)
    )
    func checkOCREnvironment(values: GlobalSettingValues) async throws -> [OCREnvironmentCheck] { [] }
    func globalSettings() async throws -> GlobalSettingsProjection { Self.projection }
    func saveGlobalSettings(values: GlobalSettingValues, customProviders: [CustomProviderConfiguration]) async throws -> GlobalSettingsProjection { Self.projection }
    func setProviderCredential(_ value: String?, providerID: String) async throws {}
    func resetLocalProviderCredentials() async throws {}
    func discoverDraftModelIDs(baseURL: String, apiKey: String, savedProviderID: String?) async throws -> [String] { [] }
    func discoverModels(providerID: String, forceRefresh: Bool) async throws -> ModelDiscoveryResult { throw SlateSyncError(code: "DESIGN_FIXTURE", message: "unused") }
    func probeModels(providerID: String, modelIDs: [String], progress: @escaping @Sendable (ModelProbeProgress) -> Void) async throws -> ModelProbeResult { throw SlateSyncError(code: "DESIGN_FIXTURE", message: "unused") }
    func cancelModelProbe(providerID: String) async {}
    func installPaddleOCR(progress: @escaping @Sendable (PaddleOcrInstallProgress) -> Void) async throws -> PaddleOcrInstallResult { throw SlateSyncError(code: "DESIGN_FIXTURE", message: "unused") }
    func cancelPaddleOCRInstallation() async {}
}

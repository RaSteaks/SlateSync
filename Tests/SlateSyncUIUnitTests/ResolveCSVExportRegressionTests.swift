import SlateSyncDomain
import SlateSyncWorkflow
@testable import SlateSyncUI
import XCTest

/// Regression freeze for review findings #3–6: the merged export must follow
/// the retained Worker's `export-resolve` — start from the retained raw table,
/// re-merge the latest recognition records, apply manual sparse edits last,
/// canonicalize the whole table, refuse an empty-record export, and suggest
/// the old `<baseName>_场记已回填.csv` filename.
@MainActor
final class ResolveCSVExportRegressionTests: XCTestCase {
    private let rawCSV = "File Name,Scene,Shot,Take,Comments\r\nA001C001.mov,,,,\r\n"
    private let twoRowCSV = "File Name,Scene,Shot,Take,Comments\r\nA001C001.mov,,,,\r\nB002C002.mov,2,,1,\r\n"

    private func record(scene: String) -> ResolveSlateRecord {
        .init(cardNumber: "A001", videoCode: "C001", scene: scene, shot: "01", take: "01", takeStatus: .passed)
    }

    private func makeModel() -> (ResolveCSVModel, CSVExportFake) {
        let fake = CSVExportFake()
        return (ResolveCSVModel(service: fake), fake)
    }

    private func sceneValue(of table: ResolveCSVTable, row: Int) -> String? {
        guard let column = table.headers.firstIndex(of: "Scene") else { return nil }
        return table.rows.indices.contains(row) ? table.rows[row][column] : nil
    }

    private func takeValue(of table: ResolveCSVTable, row: Int) -> String? {
        guard let column = table.headers.firstIndex(of: "Take") else { return nil }
        return table.rows.indices.contains(row) ? table.rows[row][column] : nil
    }

    // MARK: - #3 default export filename

    func testSuggestedFilenameFreezesOldBaseName() {
        // Frozen renderer naming (old app.js baseName + exportCsv): strip the
        // last extension, replace every run of characters outside ASCII word
        // chars, hyphen and U+4E00–U+9FFF with "_", then append the suffix.
        XCTAssertEqual(ResolveCSVModel.suggestedFilename("我的 场记.v2.csv", fallback: "Resolve", suffix: "场记已回填"), "我的_场记_v2_场记已回填.csv")
        XCTAssertEqual(ResolveCSVModel.suggestedFilename("Take 01!.csv", fallback: "Resolve", suffix: "场记已回填"), "Take_01__场记已回填.csv")
        XCTAssertEqual(ResolveCSVModel.suggestedFilename("提前：拍摄.csv", fallback: "Resolve", suffix: "场记已回填"), "提前_拍摄_场记已回填.csv")
        XCTAssertEqual(ResolveCSVModel.suggestedFilename("A-1.csv", fallback: "Resolve", suffix: "场记已回填"), "A-1_场记已回填.csv")
        XCTAssertEqual(ResolveCSVModel.suggestedFilename(nil, fallback: "Resolve", suffix: "场记已回填"), "Resolve_场记已回填.csv")
        XCTAssertEqual(ResolveCSVModel.suggestedFilename("第一拍摄日", fallback: "场记单", suffix: "场记识别"), "第一拍摄日_场记识别.csv")
        XCTAssertEqual(ResolveCSVModel.suggestedFilename(nil, fallback: "场记单", suffix: "场记识别"), "场记单_场记识别.csv")
    }

    // MARK: - #5 export uses the latest records, merged from raw bytes

    func testExportReMergesLatestRecordsFromRawBytes() async throws {
        let (model, _) = makeModel()
        await model.importData(Data(rawCSV.utf8), filename: "原始.csv")
        // First merge stages the visible preview (scene 001).
        await model.merge(records: [record(scene: "001")], metadata: [], settings: .init())
        // Records change afterwards; the export must re-merge from the raw
        // table instead of re-encoding the stale merged preview.
        let exported = try await model.exportData(records: [record(scene: "002")], metadata: [], settings: .init())
        let table = try await ResolveCSVEngine().decode(exported)
        XCTAssertEqual(sceneValue(of: table, row: 0), "002", "导出必须使用最新识别记录：\(table.rows)")
    }

    // MARK: - #4/#6 canonicalized whole-table encode

    func testExportCanonicalizesUnmergedRows() async throws {
        let (model, _) = makeModel()
        await model.importData(Data(twoRowCSV.utf8), filename: "原始.csv")
        // Only the first row matches a record; the second row must still be
        // canonicalized by the export encode pass (old export-resolve did).
        let exported = try await model.exportData(records: [record(scene: "001")], metadata: [], settings: .init())
        let table = try await ResolveCSVEngine().decode(exported)
        XCTAssertEqual(sceneValue(of: table, row: 1), "002", "未匹配行也需按位宽规范化：\(table.rows)")
        XCTAssertEqual(takeValue(of: table, row: 1), "01", "未匹配行也需按位宽规范化：\(table.rows)")
    }

    // MARK: - sparse manual edits survive merge and export

    func testExportAppliesManualEditsAfterMerge() async throws {
        // Old export truth: Comments is a strict marker allowlist at encode
        // ("manual edits must not reintroduce arbitrary text"), while unknown
        // passthrough columns keep manual edits byte-for-byte.
        let withNotes = "File Name,Scene,Shot,Take,Comments,Notes\r\nA001C001.mov,,,,,\r\n"
        let (model, _) = makeModel()
        await model.importData(Data(withNotes.utf8), filename: "原始.csv")
        model.receive(CSVCellCommit(tableID: model.tableID, rowID: 0, columnID: 4, revision: model.revision, value: "ok"))
        model.receive(CSVCellCommit(tableID: model.tableID, rowID: 0, columnID: 5, revision: model.revision, value: "备注信息"))
        await model.merge(records: [record(scene: "001")], metadata: [], settings: .init())
        XCTAssertEqual(model.table?.rows[0][1], "001")
        XCTAssertEqual(model.table?.rows[0][4], "ok", "合并结果应最后应用手动编辑：\(String(describing: model.table?.rows.first))")
        let exported = try await model.exportData(records: [record(scene: "001")], metadata: [], settings: .init())
        let table = try await ResolveCSVEngine().decode(exported)
        XCTAssertEqual(table.rows[0][1], "001")
        XCTAssertEqual(table.rows[0][4], "_OK", "Comments 手动编辑按旧规则收敛为标记：\(table.rows)")
        XCTAssertEqual(table.rows[0][5], "备注信息", "透传列的手动编辑必须逐字节保留：\(table.rows)")
    }

    // MARK: - #6 empty-record export guard

    func testExportWithoutRecordsThrowsNoExport() async throws {
        let (model, _) = makeModel()
        await model.importData(Data(rawCSV.utf8), filename: "原始.csv")
        do {
            _ = try await model.exportData(records: [], metadata: [], settings: .init())
            XCTFail("没有识别记录时导出必须失败（旧行为）")
        } catch let error as SlateSyncError {
            XCTAssertEqual(error.code, "CSV_NO_EXPORT")
        }
    }

    // MARK: - persistence carries raw bytes and edits

    func testOnTableChangeCarriesRawBytesAndEdits() async throws {
        let (model, _) = makeModel()
        var snapshots: [CSVStageSnapshot] = []
        model.onTableChange = { snapshots.append($0) }
        await model.importData(Data(rawCSV.utf8), filename: "原始.csv")
        model.receive(CSVCellCommit(tableID: model.tableID, rowID: 0, columnID: 4, revision: model.revision, value: "保留"))
        XCTAssertEqual(snapshots.count, 2)
        XCTAssertEqual(snapshots.last?.filename, "原始.csv")
        XCTAssertEqual(snapshots.last?.edits, ["0:4": "保留"])
        XCTAssertEqual(snapshots.last?.rawBase64, Data(rawCSV.utf8).base64EncodedString())
        XCTAssertEqual(snapshots.last?.table.rows[0][4], "保留")
    }

    func testLoadRestoresRawBytesAndEditsForCanonicalExport() async throws {
        let (model, _) = makeModel()
        let withNotes = "File Name,Scene,Shot,Take,Comments,Notes\r\nA001C001.mov,,,,,\r\n"
        let merged = ResolveCSVTable(headers: ["File Name", "Scene", "Shot", "Take", "Comments", "Notes"], rows: [["A001C001.mov", "001", "01", "01", "", ""]], format: .init())
        let task = TaskData(
            resolveCsvBase64: Data(withNotes.utf8).base64EncodedString(),
            resolveCsvFilename: "原始.csv",
            resolveCsvTable: merged,
            resolveCsvEdits: ["0:4": "ok", "0:5": "备注信息"]
        )
        model.load(task: task)
        let exported = try await model.exportData(records: [record(scene: "009")], metadata: [], settings: .init())
        let table = try await ResolveCSVEngine().decode(exported)
        XCTAssertEqual(sceneValue(of: table, row: 0), "009", "恢复的任务必须从原始字节重新合并：\(table.rows)")
        XCTAssertEqual(table.rows[0][4], "_OK", "恢复的任务必须保留并规范 Comments 编辑：\(table.rows)")
        XCTAssertEqual(table.rows[0][5], "备注信息", "恢复的任务必须保留透传列编辑：\(table.rows)")
    }

    func testMergeAppliesEditsAndUpdateDisplayFromRaw() async throws {
        let (model, _) = makeModel()
        await model.importData(Data(rawCSV.utf8), filename: "原始.csv")
        model.receive(CSVCellCommit(tableID: model.tableID, rowID: 0, columnID: 4, revision: model.revision, value: "保留"))
        await model.merge(records: [record(scene: "001")], metadata: [], settings: .init())
        XCTAssertEqual(model.table?.rows[0][1], "001")
        XCTAssertEqual(model.table?.rows[0][4], "保留")
    }

    // MARK: - TaskData snapshot persistence

    func testStageCSVPersistsRawBytesAndEditsThroughWorkspace() async throws {
        let fake = CSVExportFake(storedTask: TaskData(id: "t1"), taskList: [TaskListItem(id: "t1", recordCount: 0, status: "completed")])
        let workspace = WorkspaceModel(service: fake)
        try await workspace.activate(projectID: "p1")
        let model = ResolveCSVModel(service: fake)
        var snapshots: [CSVStageSnapshot] = []
        model.onTableChange = { snapshot in
            snapshots.append(snapshot)
            workspace.stageCSV(snapshot.table, filename: snapshot.filename, edits: snapshot.edits, rawBase64: snapshot.rawBase64)
        }
        await model.importData(Data(rawCSV.utf8), filename: "原始.csv")
        model.receive(CSVCellCommit(tableID: model.tableID, rowID: 0, columnID: 4, revision: model.revision, value: "保留"))
        try await workspace.flush()
        XCTAssertEqual(snapshots.count, 2)
        let staged = try XCTUnwrap(workspace.selectedTask)
        XCTAssertEqual(staged.resolveCsvFilename, "原始.csv")
        XCTAssertEqual(staged.resolveCsvEdits, ["0:4": "保留"], "手动编辑必须进入任务快照")
        XCTAssertEqual(staged.resolveCsvBase64, Data(rawCSV.utf8).base64EncodedString(), "原始字节必须进入任务快照")
        XCTAssertEqual(staged.resolveCsvTable?.rows[0][4], "保留")
    }
}

/// Minimal service double that delegates CSV work to the real SM-05 services,
/// so the regression freezes the production merge/encode semantics.
private actor CSVExportFake: WorkspaceWorkflowServing, ResolveExportWorkflowServing {
    private let sm05 = SM05WorkflowServices()
    private let engine = ResolveCSVEngine()
    private let storedTask: TaskData
    private let taskList: [TaskListItem]

    init(storedTask: TaskData = TaskData(), taskList: [TaskListItem] = []) {
        self.storedTask = storedTask
        self.taskList = taskList
    }

    func decodeResolveCSV(_ data: Data) async throws -> ResolveCSVTable { try await engine.decode(data) }

    func encodeResolveCSV(_ table: ResolveCSVTable) async throws -> Data { try await engine.encode(table) }

    func resolveMaterialKeys(in table: ResolveCSVTable) async throws -> [String] { try await sm05.resolveMaterialKeys(in: table) }

    func mergeResolve(
        source: Data,
        records: [ResolveSlateRecord],
        metadata: [PersistedSlateMetadata],
        settings: ProjectSettings.ResolveSettings,
        edits: [ResolveSparseEdit]
    ) async throws -> ResolveExportArtifact {
        try await sm05.mergeAndEncode(source: source, records: records, metadata: metadata, fieldFormats: settings.fieldFormats, comments: settings.comments, edits: edits)
    }

    func exportStandalone(records: [ResolveSlateRecord], settings: ProjectSettings.ResolveSettings) async throws -> Data {
        try await sm05.exportStandalone(records: records, fieldFormats: settings.fieldFormats)
    }

    func listTasks(projectID: String) async throws -> [TaskListItem] { taskList }
    func loadTask(projectID: String, taskID: String) async throws -> TaskData { storedTask }
    func saveTask(projectID: String, taskID: String?, task: TaskData) async throws -> String { taskID ?? "fake" }
    func deleteTask(projectID: String, taskID: String) async throws {}
    func scanMetadata(directory: URL, options: SlateMetadataScanOptions) async throws -> ScanResult {
        throw SlateSyncError(code: "TEST_UNREACHABLE", message: "scanMetadata is not part of this fixture", status: 500)
    }
    func recognize(_ request: NativeRecognitionRequest) async throws -> RecognitionData {
        throw SlateSyncError(code: "TEST_UNREACHABLE", message: "recognize is not part of this fixture", status: 500)
    }
    func recognitionProgress(projectID: String) async -> AsyncStream<RecognitionProgress> {
        AsyncStream { $0.finish() }
    }
    func cancelRecognition(projectID: String) async {}
    func closeProject(id: String) async throws {}
}

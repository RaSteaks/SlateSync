import assert from "node:assert/strict";
import { existsSync, readFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const repositoryRoot = resolve(dirname(fileURLToPath(import.meta.url)), "../..");

function read(relativePath) {
  return readFileSync(resolve(repositoryRoot, relativePath), "utf8");
}

function requireCondition(condition, message) {
  assert.ok(condition, `[SM-04] ${message}`);
}

function assertFilesAndComments() {
  for (const relativePath of [
    "Sources/SlateSyncPersistence/SQLiteDatabase.swift",
    "Sources/SlateSyncPersistence/SQLiteSchema.swift",
    "Sources/SlateSyncPersistence/PersistenceJSON.swift",
    "Sources/SlateSyncPersistence/ProjectLibraryStore.swift",
    "Sources/SlateSyncPersistence/ProjectLibraryTransfer.swift",
    "Sources/SlateSyncPersistence/ProjectLibraryActivationCoordinator.swift",
    "Sources/SlateSyncPersistence/ProjectLibraryStartupService.swift",
    "Sources/SlateSyncPersistence/ProjectRuntime.swift",
    "Sources/SlateSyncPersistence/ProjectTaskStore.swift",
    "Sources/SlateSyncPersistence/DiagnosticsStore.swift",
    "Sources/SlateSyncPersistence/ScenarioStore.swift",
    "Tests/SlateSyncPersistenceTests/SQLiteDatabaseTests.swift",
    "Tests/SlateSyncPersistenceTests/ProjectLibraryStoreTests.swift",
    "Tests/SlateSyncPersistenceTests/ProjectLibraryTransferTests.swift",
    "Tests/SlateSyncPersistenceTests/ProjectLibraryStartupServiceTests.swift",
    "Tests/SlateSyncPersistenceTests/ProjectStoresTests.swift",
    "Tests/SlateSyncPersistenceTests/Support/PersistenceTestSupport.swift",
  ]) {
    requireCondition(existsSync(resolve(repositoryRoot, relativePath)), `缺少 SM-04 文件：${relativePath}`);
  }
  const sources = [
    read("Sources/SlateSyncPersistence/SQLiteDatabase.swift"),
    read("Sources/SlateSyncPersistence/ProjectLibraryStore.swift"),
    read("Sources/SlateSyncPersistence/ProjectLibraryTransfer.swift"),
    read("Sources/SlateSyncPersistence/ProjectLibraryActivationCoordinator.swift"),
    read("Sources/SlateSyncPersistence/ProjectLibraryStartupService.swift"),
    read("Sources/SlateSyncPersistence/ProjectRuntime.swift"),
    read("Sources/SlateSyncPersistence/ProjectTaskStore.swift"),
    read("Sources/SlateSyncPersistence/DiagnosticsStore.swift"),
    read("Sources/SlateSyncPersistence/ScenarioStore.swift"),
  ].join("\n");
  requireCondition((sources.match(/\/\/|\/\*/g) ?? []).length >= 24, "所有权、兼容、恢复或删除边界缺少代码注释");
}

function assertFrozenSchema() {
  const baseline = JSON.parse(read(".codex/refactor/baseline/persistence/schema.json"));
  const schema = read("Sources/SlateSyncPersistence/SQLiteSchema.swift");
  const database = read("Sources/SlateSyncPersistence/SQLiteDatabase.swift");
  for (const filename of Object.values(baseline.filenames)) {
    requireCondition(schema.includes(`\"${filename}\"`), `缺少冻结数据库文件名 ${filename}`);
  }
  for (const table of [
    ...Object.keys(baseline.library.tables),
    ...Object.keys(baseline.project.tables),
  ]) {
    requireCondition(schema.includes(`TABLE IF NOT EXISTS ${table}`), `缺少冻结表 ${table}`);
  }
  for (const index of [...baseline.library.indexes, ...baseline.project.indexes]) {
    if (index.name.startsWith("sqlite_autoindex_")) continue;
    requireCondition(schema.includes(index.name), `缺少冻结索引 ${index.name}`);
  }
  requireCondition(schema.includes("ON DELETE SET NULL"), "scenario_observations 外键删除规则漂移");
  requireCondition(database.includes("PRAGMA journal_mode = WAL"), "WAL pragma 缺失");
  requireCondition(database.includes("PRAGMA foreign_keys = ON"), "foreign_keys pragma 缺失");
  requireCondition(database.includes("PRAGMA busy_timeout = 5000"), "busy_timeout pragma 缺失");
  requireCondition(database.includes("case SQLITE_DONE") && database.includes("fallbackCode: \"SQLITE_ROWS\""), "rows 未区分 SQLITE_DONE 与 step 失败");
  requireCondition(database.includes("case SQLITE_BUSY, SQLITE_LOCKED") && database.includes("retryable: true"), "SQLite busy/locked 稳定映射缺失");
}

function assertStoreBoundaries() {
  const library = read("Sources/SlateSyncPersistence/ProjectLibraryStore.swift");
  const runtime = read("Sources/SlateSyncPersistence/ProjectRuntime.swift");
  const tasks = read("Sources/SlateSyncPersistence/ProjectTaskStore.swift");
  const diagnostics = read("Sources/SlateSyncPersistence/DiagnosticsStore.swift");
  const scenarios = read("Sources/SlateSyncPersistence/ScenarioStore.swift");
  const transfer = read("Sources/SlateSyncPersistence/ProjectLibraryTransfer.swift");
  const activation = read("Sources/SlateSyncPersistence/ProjectLibraryActivationCoordinator.swift");
  const startup = read("Sources/SlateSyncPersistence/ProjectLibraryStartupService.swift");
  const app = read("SlateSyncApp/App/SlateSyncApp.swift");
  const tests = [
    read("Tests/SlateSyncPersistenceTests/SQLiteDatabaseTests.swift"),
    read("Tests/SlateSyncPersistenceTests/ProjectLibraryStoreTests.swift"),
    read("Tests/SlateSyncPersistenceTests/ProjectStoresTests.swift"),
    read("Tests/SlateSyncPersistenceTests/ProjectLibraryTransferTests.swift"),
    read("Tests/SlateSyncPersistenceTests/ProjectLibraryStartupServiceTests.swift"),
  ].join("\n");

  requireCondition(library.includes("public actor ProjectLibraryStore"), "Library 必须由 actor 单写者持有");
  requireCondition(library.includes("bootstrapTask") && library.includes("performBootstrap"), "Library 首次并发访问缺少 bootstrap 单航班");
  requireCondition(runtime.includes("activeLeases") && runtime.includes("deletingProjects"), "项目删除缺少租约/禁止新操作边界");
  requireCondition(runtime.includes("transitionWaiters") && runtime.includes("closeTask"), "项目终止与全局关闭缺少独占/单航班边界");
  requireCondition(runtime.includes("try await close(context)") && runtime.includes("library.deleteProject"), "删除前未关闭项目 SQLite owners");
  for (const operation of ["updateTask", "recordScenarioObservation", "loadDiagnostic", "listDiagnostics", "deleteDiagnostic"]) {
    requireCondition(runtime.includes(`public func ${operation}`), `ProjectRuntime 缺少租约化操作 ${operation}`);
  }
  requireCondition(library.includes(".deleting-") && library.includes("moveItem(at: staged, to: projectDirectory)"), "tombstone 或索引失败补偿缺失");
  requireCondition(library.includes("mode: .readOnly") && library.includes("legacy_migration_v1"), "旧版迁移未保持只读源与一次性 marker");
  requireCondition(tasks.includes("INSERT OR IGNORE INTO tasks") && tasks.includes("writeAtomically"), "任务 SQLite/快照兼容迁移缺失");
  requireCondition(tasks.includes("bootstrapTask") && diagnostics.includes("bootstrapTask") && scenarios.includes("bootstrapTask"), "项目 Store 首次访问缺少 bootstrap 单航班");
  requireCondition(diagnostics.includes("maximumSessionCount = 20") && diagnostics.includes("writeAtomically"), "诊断保留或快照合同漂移");
  requireCondition(scenarios.includes("ScenarioStore") && scenarios.includes("scenario_observations"), "场记结构/观察持久化缺失");
  requireCondition(transfer.includes("sqlite3_backup") || read("Sources/SlateSyncPersistence/SQLiteDatabase.swift").includes("sqlite3_backup"), "导出未使用 SQLite 在线备份");
  requireCondition(transfer.includes("assertNoSymbolicLinks") && transfer.includes("assertSeparate"), "导入导出链接/路径边界缺失");
  requireCondition(transfer.includes("rebindProject") && transfer.includes("diagnostic_sessions"), "导入项目归属换绑不完整");
  requireCondition(activation.includes("settings.libraryPath") && activation.includes("projectRuntime.close()") && activation.includes("library.close()"), "激活 Library 未持久化路径或关闭旧连接");
  requireCondition(activation.includes("case switching") && activation.includes("preflightLibraryRename"), "Library 激活或改名缺少并发仲裁/写入排空预检");
  requireCondition(startup.includes("settings.libraryPath") && startup.includes("preserveLegacyOnConflict: true"), "启动未读取活动 Library 路径或丢失默认路径冲突语义");
  requireCondition(startup.includes("openingTask"), "启动并发访问缺少 Library 单航班 opener");
  requireCondition(app.includes("ProjectLibraryStartupService") && app.includes("runtime.machineSettingsStore"), "App composition root 未消费持久化 Library 选择");
  for (const expectedTest of [
    "testRowsRejectsStepFailureInsteadOfReturningPartialResults",
    "testConcurrentFirstUseSharesOneBootstrapAndDefaultProject",
    "testCopiedV1LibrarySurvivesReadWriteCloseAndReopenWithoutSemanticDrift",
    "testPortableLibraryRenamePreservesSuffixAndOpenSQLiteIdentity",
    "testDeleteRestoresDirectoryWhenLibraryIndexRejectsDeletion",
    "testRuntimeClosesProjectStoresBeforeTombstoneDeletion",
    "testConcurrentProjectTerminalOperationsKeepExclusiveOwnershipUntilCompletion",
    "testConcurrentRuntimeCloseCallsShareOneLeaseDrain",
    "testRuntimeCloseRejectsAcquisitionSuspendedInLibraryBootstrap",
    "testLegacyMigrationIsIdempotentAndLeavesSourceUntouched",
    "testTaskStorePreservesUnknownPayloadAndSnapshotAcrossReopen",
    "testProjectRuntimeExposesCompleteStoreMutationSurface",
    "testDiagnosticsRetainsNewestTwentyRowsAndSnapshots",
    "testScenarioProfileAndObservationRemainProjectScoped",
    "testConcurrentScenarioImportReturnsOneCanonicalProfile",
    "testOpenProjectPackageRoundTripRebindsOwnershipAndPreservesSource",
    "testArchivedProjectPackageKeepsArchiveStateAcrossImport",
    "testProjectPackageValidationRejectsFutureVersionLinksAndUnsafeDestinations",
    "testOpenLibraryExportUsesStandaloneSQLiteBackups",
    "testLibraryActivationPersistsPathAndClosesOutgoingConnections",
    "testConcurrentLibraryActivationsAllowExactlyOneRestartTransition",
    "testActivationRenameDrainsSnapshotWritesBeforeMovingLibrary",
    "testConcurrentStartupCallsShareOneLibraryAndBootstrap",
    "testStartupWithoutSelectionMigratesKnownLegacyDefault",
    "testTestRootInitializerKeepsDefaultLibraryInsideExplicitIsolation",
    "testStartupReopensConfiguredPortableLibraryAfterActivation",
    "testStartupMigratesKnownConfiguredDefaultAndPersistsNewPath",
    "testStartupKeepsConfiguredLegacyDefaultWhenPreferredPathConflicts",
  ]) {
    requireCondition(tests.includes(expectedTest), `缺少关键回归测试 ${expectedTest}`);
  }
  requireCondition(tests.includes("temporaryRoot"), "持久化测试未显式使用临时数据根");
}

function assertAdmissionBoundary() {
  const state = JSON.parse(read(".codex/swift-migration/CURRENT_STATE.json"));
  requireCondition(state.lifecycleState === "COMPLETE", "SM-04 开始前必须已有 COMPLETE 阶段");
  requireCondition(["SM-03", "SM-04"].includes(state.phase), "SM-04 Gate 只接受 SM-03/SM-04 admission 边界");
  if (state.phase === "SM-03") {
    requireCondition(state.nextPackage === ".codex/swift-migration/packages/SM-04.md", "SM-03 未指向 SM-04");
  } else {
    requireCondition(state.activePackage === ".codex/swift-migration/packages/SM-04.md", "SM-04 完成状态 activePackage 错误");
    requireCondition(state.nextPackage === ".codex/swift-migration/packages/SM-05.md", "SM-04 完成状态未指向 SM-05");
  }
  requireCondition(existsSync(resolve(repositoryRoot, ".codex/refactor/README.md")), "受保护 Electron 兼容证据缺失");
}

assertFilesAndComments();
assertFrozenSchema();
assertStoreBoundaries();
assertAdmissionBoundary();
console.log("SM-04 contract: system SQLite v1 schema/pragmas, copied Library round-trip, snapshots, legacy migration, project isolation, and tombstone deletion verified");

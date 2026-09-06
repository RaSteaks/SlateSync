import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import {
  mkdirSync,
  readFileSync,
  writeFileSync,
} from "node:fs";
import {
  dirname,
  join,
  relative,
  resolve,
} from "node:path";
import { fileURLToPath } from "node:url";
import { sourceFingerprint } from "./sm08_contract.mjs";

const repository = resolve(dirname(fileURLToPath(import.meta.url)), "../..");
const fixtureRoot = join(repository, "Tests/SlateSyncUIUnitTests/Fixtures/SM08");
const coverage = JSON.parse(readFileSync(join(fixtureRoot, "sm08-coverage.json"), "utf8"));
const budget = JSON.parse(readFileSync(join(fixtureRoot, "performance-budget.json"), "utf8"));
const hash = data => createHash("sha256").update(data).digest("hex");

const owner = test => `SlateSyncUIUnitTests.SM08OwnershipTests/${test}`;
const native = test => `SlateSyncUIUnitTests.SM08NativeSurfaceTests/${test}`;
const persistence = (suite, test) => `SlateSyncPersistenceTests.${suite}/${test}`;
const media = (suite, test) => `SlateSyncMediaTests.${suite}/${test}`;
const workflow = (suite, test) => `SlateSyncWorkflowTests.${suite}/${test}`;
const ui = test => `SlateSyncUITests.SlateSyncUITests/${test}`;

const uiLaunch = ui("testLaunchesMainWindowAndProjectLibrary");
const uiCreate = ui("testCreatesProjectAndOpensWorkspaceInIsolatedLibrary");
const uiHelp = ui("testHelpRouteUsesBundleLocalSearch");
const uiLogs = ui("testLogsRouteRendersLocalLogSurface");
const uiWindows = ui("testIndependentWindowsAndNewWindowAfterClosingLastWindow");
const uiSettings = ui("testSettingsCanOpenAndCloseWithoutReplacingHelpRoute");
const uiChinese = ui("testChineseKeyboardWorkflowAndApplicationReopen");
const uiAppearance = ui("testMinimumWindowAccessibilityAndLightDarkAppearance");
const nativeScale = native("testNativeCSVReusesViewsForTenThousandRowsAndReleasesOwners");
const nativeIME = native("testNativeCSVMarkedTextDoesNotCommitAndFlushRetainsComposition");
const nativeHeaders = native("testNativeCSVExposesAccessibleHeadersAndEditableCells");
const nativeClose = native("testWindowCloseVetoRetainsWindowUntilRetrySucceeds");
const nativeReplace = native("testNativeCSVReplacesRowsWhenIdentityChangesAtSameRevision");

// Each entry names the real XCTest that produces the assertion. The generated
// artifact contains the exact PASS line and selected metric values, so a
// future Gate cannot turn a manual acceptance label into a self-attested PASS.
const evidencePlan = {
  "APP-01": { runner: "xcode", tests: [uiLaunch, uiAppearance], expected: "main window and Settings appearance remain within the declared minimum bounds" },
  "APP-02": { runner: "xcode", tests: [uiLaunch, uiHelp], expected: "project-library and Help routes are reachable through the native sidebar" },
  "APP-03": { runner: "xcode", tests: [uiSettings], expected: "Command-, opens an independent Settings window and closing it restores Help" },
  "APP-04": { runner: "xcode", tests: [uiWindows, uiChinese], expected: "focused commands act on the current window and the focused Workspace owner" },
  "APP-06": { runner: "xcode", tests: [uiWindows, uiChinese], expected: "window close, last-window reopen, and application quit/relaunch complete" },
  "PRJ-01": { runner: "xcode", tests: [uiLaunch], expected: "isolated project library launches with a stable project route" },
  "PRJ-02": { runner: "xcode", tests: [uiCreate], expected: "Chinese project creation completes through the validated sheet" },
  "PRJ-03": { runner: "xcode", tests: [uiCreate, uiChinese], expected: "project open and Workspace activation use the current project" },
  "PRJ-04": { runner: "swift", tests: [persistence("ProjectLibraryTransferTests", "testOpenProjectPackageRoundTripRebindsOwnershipAndPreservesSource")], expected: "project package round trip preserves source and ownership" },
  "PRJ-05": { runner: "swift", tests: [persistence("ProjectLibraryTransferTests", "testActivationRenameDrainsSnapshotWritesBeforeMovingLibrary")], expected: "library activation and rename drain writes before moving the store" },
  "PRJ-06": { runner: "swift", tests: [owner("testInvalidSettingsNeverReachTolerantPersistence"), persistence("ProjectStoresTests", "testProjectRuntimeExposesCompleteStoreMutationSurface")], expected: "project settings validation and complete runtime mutation surface remain atomic" },
  "PRJ-07": { runner: "swift", tests: [persistence("ProjectLibraryStoreTests", "testDeleteRestoresDirectoryWhenLibraryIndexRejectsDeletion"), owner("testProjectOwnershipRejectsSecondWriterAndReleasesOnlyItsOwner")], expected: "delete failure recovery and exclusive project ownership are retained" },
  "PRJ-08": { runner: "swift", tests: [owner("testFiveSampleProjectAndTaskNativeListScale"), owner("testRealSQLiteProjectAndTaskScaleLoad")], metrics: ["native-project-task-scale.json", "real-sqlite-scale.json"], expected: "500-project native list and SQLite scale measurements stay within budget" },
  "TSK-01": { runner: "xcode", tests: [uiCreate, uiChinese], expected: "Workspace task creation and project task restoration are reachable" },
  "TSK-02": { runner: "swift", tests: [owner("testFiveSampleProjectAndTaskNativeListScale")], metrics: ["native-project-task-scale.json"], expected: "1,000 tasks remain lazy, selectable, and within the visible-row budget" },
  "TSK-03": { runner: "swift", tests: [owner("testInputAdmissionBlocksPickerAndDropDuringRecognition")], expected: "file input admission and cancellation are blocked during recognition" },
  "TSK-04": { runner: "swift", tests: [media("MediaResourceTests", "testTwentyPagesThreeRoundsDrainOwnedResources"), workflow("MediaOCRWorkflowTests", "testProjectSwitchCacheIsolationAndCloseDrain")], expected: "preview/media owners drain across repeated rounds and project switching" },
  "TSK-08": { runner: "swift", tests: [media("MediaResourceTests", "testTwentyPagesThreeRoundsDrainOwnedResources"), owner("testCSVDrainJoinsDecoderAndRejectsLatePublication")], expected: "scoped media and late decoder resources release on close" },
  "REC-02": { runner: "swift", tests: [owner("testRecognitionOptionRestorationNeverSubstitutesUnavailableValues")], expected: "recognition refuses unavailable persisted options instead of substituting them" },
  "REC-03": { runner: "swift", tests: [owner("testSettingsAndInstallerProgressCannotRegressAfterActorHop"), workflow("SM07CoordinatorTests", "testFLW01FLW03FLW04FLW06FLW08FLW09FLW10RES01EndToEndPersistenceAndProgress")], expected: "recognition progress remains ordered and reconnects to the active operation" },
  "REC-04": { runner: "swift", tests: [owner("testRecognitionCancellationBlocksNewLocalOperationUntilServiceDrain"), owner("testRecognitionCancellationTicketInvalidatesOnlyQueuedProject")], expected: "recognition cancellation and ticket races drain without stale side effects" },
  "REC-05": { runner: "swift", tests: [media("OCRPolicyTests", "testRequiredOptionalDisabledAndCancellationPolicies"), workflow("SM07CoordinatorTests", "testFLW05FLW07GlobalFailFastAndProjectCancellationDrain")], expected: "required/optional OCR and global fail-fast policy remain compatible" },
  "REC-06": { runner: "swift", tests: [owner("testResultEditIsCanonicalAndFlushJoinsPendingCommit"), nativeIME], expected: "result edits flush safely and marked Chinese composition is not destructive" },
  "REC-07": { runner: "swift", tests: [owner("testLocalSlateCSVMatchesRetainedWorkerOracle"), workflow("ResolveCSVMergerTests", "testAliasesIdentityMetadataCommentsEditsAndSequenceAudits")], expected: "local merge and remote result paths share the canonical CSV model" },
  "REC-08": { runner: "swift", tests: [owner("testPrivacyIsEnforcedAtLogSinkAndReadBoundary"), workflow("SM07RegistryTests", "testREG05PublicProjectionRedactsSecretsAndPrices")], expected: "recognition public surfaces and logs remain secret-free" },
  "CSV-01": { runner: "swift", tests: [workflow("ResolveCSVEngineTests", "testReviewedFixturesMatchSourceAndRoundTripByteGoldens"), owner("testLocalSlateCSVMatchesRetainedWorkerOracle")], expected: "CSV parsing and encoding retain the frozen byte-compatible oracle" },
  "CSV-02": { runner: "swift", tests: [nativeScale], metrics: ["native-csv-scale.json"], expected: "10,000-row NSTableView reuses visible views within the frozen limit" },
  "CSV-03": { runner: "swift", tests: [nativeHeaders, nativeReplace], expected: "headers, editable cells, and same-revision identity replacement remain stable" },
  "CSV-05": { runner: "swift", tests: [owner("testCSVKeyboardNavigationUsesGridOrderAndBounds"), owner("testCSVKeyboardSelectorsPreserveIMEAndNativeClipboardRouting"), nativeIME], expected: "CSV keyboard selectors, native clipboard, and Chinese IME preserve editing safety" },
  "CSV-06": { runner: "swift", tests: [nativeHeaders], expected: "native table, headers, and editable cells expose accessibility semantics" },
  "CSV-07": { runner: "swift", tests: [owner("testMetadataMatchingUsesCanonicalResolveMaterialKeys"), owner("testMetadataPersistsAndResetsWithTaskSelection"), workflow("SlateMetadataTests", "testBoundedScannerPrunesAndReportsMissing")], expected: "metadata canonical matching, persistence, missing keys, and bounded scanning pass" },
  "CSV-08": { runner: "swift", tests: [nativeScale, nativeIME, nativeHeaders, nativeReplace, native("testForegroundCSVMeetsDisplayCadenceBudget")], metrics: ["native-csv-scale.json", "native-csv-foreground.json"], expected: "10,000-row edit, cadence, view count, memory, and release budgets pass" },
  "SET-01": { runner: "swift", tests: [owner("testInvalidSettingsNeverReachTolerantPersistence"), owner("testCredentialRefreshRetainsUnrelatedSettingsDraft")], expected: "typed settings validation and unrelated draft preservation remain atomic" },
  "SET-02": { runner: "swift", tests: [persistence("KeychainMigrationTests", "testLegacyCredentialsMigrateAndRemoveSourceOnlyAfterVerification"), persistence("KeychainMigrationTests", "testMalformedEmptyAndDuplicateLegacyFilesNeverExposeSecrets")], expected: "Keychain migration preserves ownership and never exposes secrets" },
  "SET-06": { runner: "swift", tests: [media("OCRContractTests", "testPaddleSettingsAndSelectionOracles"), owner("testPaddleInstallerUsesPinnedOfflineStagesAndSanitizedEnvironment")], expected: "Vision/Paddle preference and pinned installer checks remain offline" },
  "LOG-03": { runner: "xcode", tests: [uiLogs], expected: "Logs route renders its local refresh surface" },
  "LOG-04": { runner: "swift", tests: [owner("testPrivacyIsEnforcedAtLogSinkAndReadBoundary"), owner("testLogRetentionBadUTF8NewestFirstAndHardCap")], expected: "log payload/path/secret negative coverage remains redacted and bounded" },
  "A11Y-01": { runner: "swift", tests: [nativeHeaders], expected: "Chinese table labels and editable-cell semantics are exposed to accessibility" },
  "A11Y-02": { runner: "xcode", tests: [uiChinese, uiWindows], expected: "keyboard-only creation, close, reopen, and project restoration complete" },
  "A11Y-03": { runner: "xcode", tests: [uiAppearance], expected: "light and dark appearances retain the native route and controls" },
  "A11Y-04": { runner: "swift", tests: [nativeIME, owner("testCSVKeyboardSelectorsPreserveIMEAndNativeClipboardRouting")], expected: "marked Chinese composition survives cancel/flush without accidental commit" },
  "A11Y-05": { runner: "xcode", tests: [uiHelp], expected: "offline Help route and Chinese searchable catalog render" },
  "PERF-01": { runner: "swift", tests: [owner("testRealSQLiteProjectAndTaskScaleLoad"), owner("testFiveSampleProjectAndTaskNativeListScale")], metrics: ["real-sqlite-scale.json", "native-project-task-scale.json"], expected: "500 projects and 1,000 tasks stay below load and selection budgets" },
  "PERF-02": { runner: "swift", tests: [nativeScale, native("testForegroundCSVMeetsDisplayCadenceBudget")], metrics: ["native-csv-scale.json", "native-csv-foreground.json"], expected: "10,000-row CSV render, scroll, edit, FPS, memory, and release budgets pass" },
  "PERF-03": { runner: "swift", tests: [nativeScale, nativeClose, owner("testConcurrentTerminationRequestsJoinOneLifecycleDrain"), media("MediaResourceTests", "testTwentyPagesThreeRoundsDrainOwnedResources")], metrics: ["native-csv-scale.json"], expected: "window close, repeated termination, native owners, and timers drain" },
};

function readJSON(path) {
  return JSON.parse(readFileSync(path, "utf8"));
}

function sha256File(path) {
  return hash(readFileSync(path));
}

function findPassLine(log, reference) {
  const [suite, test] = reference.split("/");
  const prefix = `Test Case '-[${suite} ${test}]' passed`;
  const line = log.split(/\r?\n/).find(candidate => candidate.includes(prefix));
  assert.ok(line, `missing executed PASS for ${reference}`);
  const durationMatch = line.match(/passed \(([0-9]+(?:\.[0-9]+)?) seconds\)/);
  return { line: line.trim(), durationMs: durationMatch ? Number(durationMatch[1]) * 1000 : 0 };
}

function sourceArtifact(path) {
  const absolute = resolve(path);
  return {
    path: relative(repository, absolute),
    sha256: sha256File(absolute),
  };
}

function commandFor(runner, durationMs) {
  if (runner === "xcode") {
    return {
      executable: "/usr/bin/xcodebuild",
      arguments: ["-project", "SlateSync.xcodeproj", "-scheme", "SlateSync", "-testPlan", "SlateSync", "-destination", "platform=macOS", "test"],
      exitCode: 0,
      durationMs,
    };
  }
  return {
    executable: "/usr/bin/swift",
    arguments: ["test"],
    environment: {
      SLATESYNC_SM08_FOREGROUND_GATE: "1",
      SLATESYNC_SM08_METRICS_DIR: "<gate-result>/sm08-metrics",
    },
    exitCode: 0,
    durationMs,
  };
}

function validateMetric(name, value) {
  if (name === "real-sqlite-scale.json") {
    assert.equal(value.projects, 500);
    assert.equal(value.tasks, 1_000);
    assert.equal(value.warmups, budget.warmups);
    assert.equal(value.samples, budget.samples);
    assert.ok(value.projectLoadMs.length === budget.samples);
    assert.ok(value.taskLoadMs.length === budget.samples);
    assert.ok(Math.max(...value.projectLoadMs) <= budget.projects500.coldLoadMsP95);
    assert.ok(Math.max(...value.taskLoadMs) <= budget.tasks1000.warmLoadMsP95);
  } else if (name === "native-project-task-scale.json") {
    assert.equal(value.projects, 500);
    assert.equal(value.tasks, 1_000);
    assert.equal(value.warmups, budget.warmups);
    assert.equal(value.samples, budget.samples);
    assert.ok(Math.max(...value.projectSelectionMs) <= budget.projects500.selectionRenderMsP95);
    assert.ok(Math.max(...value.taskSelectionMs) <= budget.tasks1000.selectionRenderMsP95);
    assert.ok(Math.max(...value.projectVisibleRows) <= budget.projects500.visibleRowsMax);
    assert.ok(Math.max(...value.taskVisibleRows) <= budget.tasks1000.visibleRowsMax);
  } else if (name === "native-csv-scale.json") {
    assert.equal(value.fixtureRows, 10_000);
    assert.equal(value.warmups, budget.warmups);
    assert.equal(value.samples, budget.samples);
    assert.ok(Math.max(...value.snapshotMs) <= budget.csv10000.snapshotMsP95);
    assert.ok(Math.max(...value.farRowEditMs) <= budget.csv10000.farRowEditMsP95);
    assert.ok(Math.max(...value.visibleCellCounts) <= budget.csv10000.visibleViewsMax);
    assert.ok(Math.max(...value.residentDeltaBytes) <= budget.csv10000.maximumResidentDeltaBytes);
    assert.ok(value.retainedResidentBytes <= budget.csv10000.retainedResidentDeltaBytes);
  } else if (name === "native-csv-foreground.json") {
    assert.equal(value.fixtureRows, 10_000);
    assert.equal(value.displayBacked, true);
    assert.ok(value.scrollFramesPerSecond >= budget.csv10000.minimumScrollFPS);
  } else {
    assert.fail(`unknown SM-08 metric ${name}`);
  }
}

export function validateEvidencePlan() {
  const required = coverage.manualOrGate.filter(id => id !== "GOV-01");
  assert.deepEqual(Object.keys(evidencePlan).sort(), required.sort());
  for (const [id, entry] of Object.entries(evidencePlan)) {
    assert.ok(["swift", "xcode"].includes(entry.runner), `${id}: runner missing`);
    assert.ok(entry.tests.length > 0, `${id}: test mapping missing`);
    for (const reference of entry.tests) {
      assert.match(reference, /^[A-Za-z0-9_.]+\/test[A-Za-z0-9_]+$/);
    }
  }
}

export function generateEvidence({ swiftLogPath, xcodeLogPath, xcodeSummaryPath, metricsDir, outputPath }) {
  validateEvidencePlan();
  const swiftLog = readFileSync(swiftLogPath, "utf8");
  const xcodeLog = readFileSync(xcodeLogPath, "utf8");
  const summary = readJSON(xcodeSummaryPath);
  assert.equal(String(summary.result).toLowerCase(), "passed");
  assert.equal(Number(summary.failedTests || 0), 0);

  const metricValues = new Map();
  for (const name of ["real-sqlite-scale.json", "native-project-task-scale.json", "native-csv-scale.json", "native-csv-foreground.json"]) {
    const path = join(metricsDir, name);
    const value = readJSON(path);
    validateMetric(name, value);
    metricValues.set(name, { path, value });
  }

  const outputAbsolute = resolve(outputPath);
  const outputRelative = relative(repository, outputAbsolute);
  assert.match(outputRelative, /^\.codex\/gate-results\/SM-08\//);
  const artifactDirectory = join(dirname(outputAbsolute), "native-evidence");
  mkdirSync(artifactDirectory, { recursive: true });
  const acceptance = {};
  const inputArtifacts = [swiftLogPath, xcodeLogPath, xcodeSummaryPath, ...[...metricValues.values()].map(item => item.path)];
  for (const [id, entry] of Object.entries(evidencePlan)) {
    const log = entry.runner === "xcode" ? xcodeLog : swiftLog;
    const passLines = entry.tests.map(reference => findPassLine(log, reference));
    const durationMs = passLines.reduce((sum, item) => sum + item.durationMs, 0);
    const assertions = passLines.map((item, index) => ({
      id: `${id}:test-${index + 1}`,
      result: "PASS",
      expected: `${entry.tests[index]} exits with XCTest PASS`,
      observed: item.line,
    }));
    for (const metricName of entry.metrics ?? []) {
      const metric = metricValues.get(metricName);
      assert.ok(metric, `${id}: missing metric ${metricName}`);
      const value = JSON.stringify(metric.value, Object.keys(metric.value).sort());
      assertions.push({
        id: `${id}:metric-${metricName.replace(/[^A-Za-z0-9]+/g, "-")}`,
        result: "PASS",
        expected: `${metricName} satisfies the frozen SM-08 budget`,
        observed: `${metricName}: ${value}`,
      });
    }
    const artifactPath = join(artifactDirectory, `${id}.json`);
    const artifactPayload = {
      schemaVersion: 1,
      phase: "SM-08",
      acceptanceID: id,
      sourceFingerprint: sourceFingerprint(),
      sourceInputs: inputArtifacts.map(sourceArtifact),
      expected: entry.expected,
      executedTests: passLines.map((item, index) => ({ reference: entry.tests[index], output: item.line })),
      metrics: (entry.metrics ?? []).map(name => ({ name, value: metricValues.get(name).value })),
    };
    writeFileSync(artifactPath, `${JSON.stringify(artifactPayload, null, 2)}\n`);
    const path = relative(repository, artifactPath);
    acceptance[id] = {
      result: "PASS",
      command: commandFor(entry.runner, durationMs),
      assertions,
      artifacts: [{ acceptanceID: id, kind: "json", path, sha256: sha256File(artifactPath) }],
    };
  }
  const report = {
    schemaVersion: 1,
    phase: "SM-08",
    sourceFingerprint: sourceFingerprint(),
    generatedAt: new Date().toISOString(),
    acceptance,
  };
  writeFileSync(outputAbsolute, `${JSON.stringify(report, null, 2)}\n`);
  return report;
}

function argument(name) {
  const index = process.argv.indexOf(name);
  assert.ok(index >= 0 && process.argv[index + 1], `${name} is required`);
  return process.argv[index + 1];
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  validateEvidencePlan();
  if (process.argv.includes("--self-test")) {
    console.log("SM-08 native evidence plan self-test PASS");
  } else {
    generateEvidence({
      swiftLogPath: argument("--swift-log"),
      xcodeLogPath: argument("--xcode-log"),
      xcodeSummaryPath: argument("--xcode-summary"),
      metricsDir: argument("--metrics-dir"),
      outputPath: argument("--output"),
    });
    console.log("SM-08 native evidence generated: 45 acceptance entries");
  }
}

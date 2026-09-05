import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { existsSync, readFileSync, readdirSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const repositoryRoot = resolve(dirname(fileURLToPath(import.meta.url)), "../..");

function read(relativePath, encoding = "utf8") {
  return readFileSync(resolve(repositoryRoot, relativePath), encoding);
}

function requireCondition(condition, message) {
  assert.ok(condition, `[SM-05] ${message}`);
}

function assertFilesAndComments() {
  const files = [
    "Sources/SlateSyncDomain/SM05WorkflowModels.swift",
    "Sources/SlateSyncWorkflow/ResolveCSVEngine.swift",
    "Sources/SlateSyncWorkflow/ResolveCSVNormalization.swift",
    "Sources/SlateSyncWorkflow/ResolveCSVMerger.swift",
    "Sources/SlateSyncWorkflow/SlateMetadataParser.swift",
    "Sources/SlateSyncWorkflow/MetadataStructure.swift",
    "Sources/SlateSyncWorkflow/SlateMetadataScanner.swift",
    "Sources/SlateSyncWorkflow/ScenarioProfileEngine.swift",
    "Sources/SlateSyncWorkflow/ScenarioMatchingService.swift",
    "Sources/SlateSyncWorkflow/SM05WorkflowServices.swift",
    "Tests/SlateSyncWorkflowTests/ResolveCSVEngineTests.swift",
    "Tests/SlateSyncWorkflowTests/ResolveCSVMergerTests.swift",
    "Tests/SlateSyncWorkflowTests/SlateMetadataTests.swift",
    "Tests/SlateSyncWorkflowTests/ScenarioProfileEngineTests.swift",
    "Tests/SlateSyncWorkflowTests/SM05WorkflowServiceTests.swift",
  ];
  for (const file of files) {
    requireCondition(existsSync(resolve(repositoryRoot, file)), `缺少实现或测试文件：${file}`);
  }
  const source = files.filter((file) => file.startsWith("Sources/")).map((file) => read(file)).join("\n");
  requireCondition((source.match(/\/\/|\/\*/g) ?? []).length >= 18, "兼容、所有权、边界或事务说明注释不足");
  requireCondition(!/try!|as!|@unchecked\s+Sendable/.test(source), "SM-05 源码含禁止的不安全构造");
}

function assertCoverageMapAndScope() {
  const manifestPath = "Tests/SlateSyncWorkflowTests/Fixtures/SM05/coverage.json";
  const manifestText = read(manifestPath);
  const manifest = JSON.parse(manifestText);
  const testSources = readdirSync(resolve(repositoryRoot, "Tests/SlateSyncWorkflowTests"))
    .filter((name) => name.endsWith("Tests.swift"))
    .map((name) => read(`Tests/SlateSyncWorkflowTests/${name}`)).join("\n");
  const expected = [
    ...Array.from({ length: 8 }, (_, index) => `CSV-${String(index + 1).padStart(2, "0")}`),
    ...Array.from({ length: 11 }, (_, index) => `MRG-${String(index + 1).padStart(2, "0")}`),
    ...Array.from({ length: 10 }, (_, index) => `META-${String(index + 1).padStart(2, "0")}`),
    ...Array.from({ length: 12 }, (_, index) => `SCN-${String(index + 1).padStart(2, "0")}`),
    "PERF-01", "SVC-01",
  ];
  requireCondition(JSON.stringify(Object.keys(manifest.coverage).sort()) === JSON.stringify(expected.sort()), "测试样本 coverage ID 不完整或含未审查项");
  for (const [id, test] of Object.entries(manifest.coverage)) {
    requireCondition(testSources.includes(`func ${test}`), `${id} 指向不存在的原生测试 ${test}`);
  }
  requireCondition(manifest.performance.outputSha256 === "ad23d3d8236478d658cfa72a45b7703ba5f9ffc3eab8ebf27bcd644cbb7ad227", "PERF-01 输出 hash 漂移");
  requireCondition(!manifestText.includes("/Users/") && !manifestText.includes("Application Support"), "fixture manifest 含真实用户路径");
  const fixtureFiles = readdirSync(resolve(repositoryRoot, "Tests/SlateSyncWorkflowTests/Fixtures/SM05"), { recursive: true });
  requireCondition(!fixtureFiles.some((name) => String(name).endsWith(".DS_Store")), "fixture 目录含 .DS_Store");
  const requiredFixtureClasses = ["CSV", "Metadata", "ScannerTree", "Scenario", "Performance"];
  for (const directory of requiredFixtureClasses) {
    requireCondition(existsSync(resolve(repositoryRoot, `Tests/SlateSyncWorkflowTests/Fixtures/SM05/${directory}`)), `缺少 ${directory} fixture 类别`);
  }
}

function assertFrozenFixtures() {
  for (const filename of [
    "manifest.json",
    "resolve-source.csv",
    "resolve-source-utf8.csv",
    "resolve-source-utf16le.csv",
    "resolve-source-utf16be.csv",
    "resolve-source-semicolon.csv",
  ]) {
    const baseline = read(`test/fixtures/baseline/csv/${filename}`, null);
    const native = read(`Tests/SlateSyncWorkflowTests/Fixtures/SM05/CSV/${filename}`, null);
    const digest = (value) => createHash("sha256").update(value).digest("hex");
    requireCondition(digest(native) === digest(baseline), `原生副本与冻结 CSV 漂移：${filename}`);
  }

  const fixtureRoot = "Tests/SlateSyncWorkflowTests/Fixtures/SM05";
  const manifest = JSON.parse(read(`${fixtureRoot}/fixture-manifest.json`));
  for (const [relativePath, expectedHash] of Object.entries(manifest.files)) {
    const contents = read(`${fixtureRoot}/${relativePath}`, null);
    const actualHash = createHash("sha256").update(contents).digest("hex");
    requireCondition(actualHash === expectedHash, `SM-05 fixture hash 漂移：${relativePath}`);
  }
  for (const required of [
    "Metadata/kinefinity-revision-2.txt",
    "Scenario/observation.json",
    "ScannerTree/scanner-tree-manifest.json",
    "Performance/performance-manifest.json",
  ]) requireCondition(manifest.files[required], `fixture manifest 未冻结 ${required}`);
}

function assertCSVAndMetadataContracts() {
  const engine = read("Sources/SlateSyncWorkflow/ResolveCSVEngine.swift");
  const normalization = read("Sources/SlateSyncWorkflow/ResolveCSVNormalization.swift");
  const merger = read("Sources/SlateSyncWorkflow/ResolveCSVMerger.swift");
  const scanner = read("Sources/SlateSyncWorkflow/SlateMetadataScanner.swift");
  const tests = [
    read("Tests/SlateSyncWorkflowTests/ResolveCSVEngineTests.swift"),
    read("Tests/SlateSyncWorkflowTests/ResolveCSVMergerTests.swift"),
    read("Tests/SlateSyncWorkflowTests/SlateMetadataTests.swift"),
  ].join("\n");
  for (const token of ["utf16LittleEndian", "utf16BigEndian", "detectDelimiter", "detectLineEnding", "canonicalizeComments"]) {
    requireCondition(engine.includes(token), `CSV 编解码合同缺少 ${token}`);
  }
  for (const token of ["precomposedStringWithCompatibilityMapping", "chineseNumeralsToArabic", "canonicalMaterialKey", "normalizeScene"]) {
    requireCondition(normalization.includes(token), `归一化合同缺少 ${token}`);
  }
  requireCondition(merger.includes("buildRowIndex") && merger.includes("duplicate") && merger.includes("conflict"), "合并器未体现索引、重复与冲突规则");
  requireCondition(scanner.includes("Task.checkCancellation") && scanner.includes("isSymbolicLink") && scanner.includes("maxFileBytes"), "metadata 扫描缺少取消、符号链接或大小边界");
  for (const test of [
    "testReviewedFixturesMatchSourceAndRoundTripByteGoldens",
    "testReviewedMergeAndStandaloneByteGoldens",
    "testNormalizationMaterialKeysAndDuplicateConflictRules",
    "testTenThousandRowIndexedMergeTimingAndScaling",
    "testKinefinityParserAndStructures",
    "testBoundedScannerPrunesAndReportsMissing",
    "testFormatValidationAndJavaScriptLineSeparatorCompatibility",
    "testJavaScriptAuditOrderAndRawSparseEditSemantics",
  ]) requireCondition(tests.includes(test), `缺少关键 CSV/metadata 测试 ${test}`);
  requireCondition(tests.includes("SM05_PERFORMANCE_GATE") && tests.includes("largeMedian, 2.0") && tests.includes("2.5"), "10k Release 性能预算未锁定");
}

function assertScenarioContracts() {
  const profile = read("Sources/SlateSyncWorkflow/ScenarioProfileEngine.swift");
  const matching = read("Sources/SlateSyncWorkflow/ScenarioMatchingService.swift");
  const store = read("Sources/SlateSyncPersistence/ScenarioStore.swift");
  const runtime = read("Sources/SlateSyncPersistence/ProjectRuntime.swift");
  const tests = read("Tests/SlateSyncWorkflowTests/ScenarioProfileEngineTests.swift");
  requireCondition(profile.includes("schemaVersion = 1") && profile.includes("fingerprintVersion = 1"), "Scenario 版本合同漂移");
  requireCondition(profile.includes("hand-built v1 payload") && profile.includes("prefix(32)"), "fingerprint v1 稳定序列化或长度合同缺失");
  requireCondition(matching.includes("ambiguityMargin") && matching.includes("selectedProfileID"), "匹配阈值/歧义或复用选择合同缺失");
  requireCondition(!matching.includes("let profile: ScenarioProfile") && matching.includes("let fingerprint: String"), "observation_json 未保持 v1 扁平 Profile 键");
  requireCondition(matching.includes("any ScenarioMatchingPersistence") && runtime.includes("ScenarioMatchingPersistence"), "Scenario 匹配绕过 ProjectRuntime 租约");
  requireCondition(store.includes("applyScenarioMatch") && store.includes("database.transaction(commands)"), "Profile 样本数与 observation 未原子提交");
  for (const test of ["testReviewedObservationProducesExactFingerprintAndFields", "testMatchCreateReusePersistsAtomically"]) {
    requireCondition(tests.includes(test), `缺少关键 Scenario 测试 ${test}`);
  }
}

export function assertAdmissionBoundary(state = JSON.parse(read(".codex/swift-migration/CURRENT_STATE.json"))) {
  requireCondition(state.lifecycleState === "COMPLETE", "SM-05 诊断 Gate 必须从已完成阶段进入");
  requireCondition(["SM-04", "SM-05"].includes(state.phase), "SM-05 Gate 只接受 SM-04/SM-05 边界");
  if (state.phase === "SM-04") {
    requireCondition(state.nextPackage === ".codex/swift-migration/packages/SM-05.md", "SM-04 未指向 SM-05");
  } else {
    requireCondition(state.activePackage === ".codex/swift-migration/packages/SM-05.md", "SM-05 activePackage 错误");
  }
}

assertFilesAndComments();
assertCoverageMapAndScope();
assertFrozenFixtures();
assertCSVAndMetadataContracts();
assertScenarioContracts();
// Later phases rerun every technical assertion under their own admission Gate.
// The ordinary SM-05 entry retains its strict, independently tested boundary.
if (!process.argv.includes("--technical-only")) assertAdmissionBoundary();
console.log("SM-05 contract: CSV byte compatibility, indexed merge, bounded metadata, Scenario fingerprint/matching, atomic persistence, and Release performance budget verified");
